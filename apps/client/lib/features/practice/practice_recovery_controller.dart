import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../conversation/conversation_models.dart';
import '../conversation/final_transcript_read_models.dart';
import 'connection_observation_models.dart';
import 'practice_models.dart';
import 'practice_repository.dart';

enum PreparationCleanupStatus { idle, working, succeeded, unconfirmed, refused }

enum _RecoveryOperation {
  refresh,
  observations,
  discard,
  transcripts,
  refreshTranscripts,
}

/// Read snapshots and explicitly discard never-started preparation; never obtain media.
class PracticeRecoveryController extends ChangeNotifier {
  PracticeRecoveryController({
    required ApiClient api,
    required this.accountId,
    this._httpClientFactory = createHttpClient,
    this._elapsed,
  }) : _source = api;

  final ApiClient _source;
  final String accountId;
  final http.Client Function() _httpClientFactory;
  final Duration Function()? _elapsed;
  final _clock = Stopwatch()..start();
  Duration get _now => _elapsed?.call() ?? _clock.elapsed;
  bool _disposed = false;
  bool _busy = false;
  bool get busy => _busy;
  _RecoveryOperation? _operation;
  bool get loadingTranscripts => _busy && _isTranscriptRead(_operation);
  PracticeRecovery? _recovery;
  PracticeRecovery? get recovery => _canExposeData() ? _recovery : null;
  ConnectionObservationPage? _page;
  ConnectionObservationPage? get page => _canExposeData() ? _page : null;
  List<ConnectionObservation> _events = const [];
  List<ConnectionObservation> get events =>
      _canExposeData() ? _events : const [];
  FinalTranscriptHistory? _transcripts;
  FinalTranscriptHistory? get transcripts =>
      _canExposeData() ? _transcripts : null;
  String? _transcriptErrorCode;
  String? get transcriptErrorCode =>
      _canExposeData() ? _transcriptErrorCode : null;
  String? _errorCode;
  String? get errorCode {
    _canExposeData();
    return _errorCode;
  }

  String? _observationErrorCode;
  String? get observationErrorCode => _observationErrorCode;
  PreparationCleanupStatus _cleanupStatus = PreparationCleanupStatus.idle;
  PreparationCleanupStatus get cleanupStatus => _cleanupStatus;
  String? _cleanupErrorCode;
  String? get cleanupErrorCode => _cleanupErrorCode;
  Completer<void>? _inFlight;
  Completer<void>? _cancel;
  ApiClient? _ownedApi;

  Future<void> refresh() => _start(_RecoveryOperation.refresh);
  Future<void> loadObservations() => _start(_RecoveryOperation.observations);
  Future<void> loadTranscripts({bool refresh = false}) => _start(
    refresh
        ? _RecoveryOperation.refreshTranscripts
        : _RecoveryOperation.transcripts,
  );
  Future<void> discardPreparation(PracticePreparation original) =>
      _start(_RecoveryOperation.discard, original: original);

  static bool _isTranscriptRead(_RecoveryOperation? operation) =>
      operation == _RecoveryOperation.transcripts ||
      operation == _RecoveryOperation.refreshTranscripts;

  // A retained controller must not expose old text before provider disposal runs.
  // Consumers must still discard immutable snapshots on account scope changes.
  bool _canExposeData() {
    if (_disposed) return false;
    if (_source.hasCurrentAccount(accountId)) return true;
    _clearData();
    _errorCode = 'account_changed';
    if (_cancel != null && !_cancel!.isCompleted) _cancel!.complete();
    _ownedApi?.close();
    return false;
  }

  Future<void> _start(
    _RecoveryOperation operation, {
    PracticePreparation? original,
  }) {
    if (_disposed) return Future.value();
    if (_inFlight != null) return _inFlight!.future;
    if (operation == _RecoveryOperation.discard &&
        (original == null ||
            !identical(original, _recovery?.practice) ||
            !(_recovery?.canDiscardPreparation ?? false))) {
      return Future.value();
    }
    if (operation == _RecoveryOperation.observations &&
        (_recovery?.connection == null || (_page != null && !_page!.hasMore))) {
      return Future.value();
    }
    if (_isTranscriptRead(operation) &&
        (_recovery?.connection == null ||
            (operation == _RecoveryOperation.transcripts &&
                _transcripts != null &&
                !_transcripts!.hasMore))) {
      return Future.value();
    }
    final completion = Completer<void>();
    _inFlight = completion;
    _cancel = Completer<void>();
    _busy = true;
    _operation = operation;
    _errorCode = null;
    _observationErrorCode = null;
    _cleanupErrorCode = null;
    _cleanupStatus = operation == _RecoveryOperation.discard
        ? PreparationCleanupStatus.working
        : PreparationCleanupStatus.idle;
    if (operation == _RecoveryOperation.refresh) _clearData();
    if (_isTranscriptRead(operation)) _transcriptErrorCode = null;
    if (operation == _RecoveryOperation.refreshTranscripts) _transcripts = null;
    notifyListeners();
    unawaited(_perform(operation, completion, original));
    return completion.future;
  }

  void _clearData() {
    _recovery = null;
    _page = null;
    _events = const [];
    _transcripts = null;
    _transcriptErrorCode = null;
  }

  Future<void> _perform(
    _RecoveryOperation operation,
    Completer<void> completion,
    PracticePreparation? original,
  ) async {
    try {
      if (operation == _RecoveryOperation.discard) {
        await _read((repo) => repo.discardPreparation(original!));
        _checkAccount();
        _clearData();
        _cleanupStatus = PreparationCleanupStatus.succeeded;
      } else if (_isTranscriptRead(operation)) {
        final connection = _recovery!.connection!;
        final previous =
            _transcripts ??
            FinalTranscriptHistory.empty(
              ConversationScope(
                accountId: accountId,
                sessionId: connection.sessionId,
                connectionId: connection.id,
                clientInstanceId: connection.clientInstanceId,
                epoch: connection.epoch,
              ),
            );
        final next = await _read(
          (repo) => repo.loadFinalTranscripts(
            connection,
            afterSequence: previous.nextAfterSequence,
          ),
        );
        _checkAccount();
        try {
          _transcripts = previous.append(next);
        } on Object {
          throw const ApiException('invalid_response', '文字记录响应异常。');
        }
      } else if (operation == _RecoveryOperation.observations) {
        final connection = _recovery!.connection!;
        final next = await _read(
          (repo) => repo.loadConnectionObservations(
            connection,
            afterSequence: _page?.nextAfterSequence ?? 0,
          ),
        );
        _checkAccount();
        final combined = [..._events, ...next.events];
        if ((_page != null &&
                (next.totalEvents < _page!.totalEvents ||
                    next.lastSequence < _page!.lastSequence)) ||
            combined.map((e) => e.eventId).toSet().length != combined.length ||
            combined.length > next.totalEvents ||
            (next.hasMore && combined.length >= next.totalEvents) ||
            (!next.hasMore && combined.length != next.totalEvents)) {
          throw const ApiException('invalid_response', '连接记录响应异常。');
        }
        _events = List.unmodifiable(combined);
        _page = next;
      } else {
        final result = await _read((repo) => repo.loadCurrentPreparation());
        _checkAccount();
        _recovery = result;
      }
    } on Object catch (error) {
      if (!_disposed) {
        final code = !_source.hasCurrentAccount(accountId)
            ? 'account_changed'
            : error is ApiException && error.statusCode == 401
            ? 'unauthorized'
            : error is ApiException &&
                  const {
                    'account_changed',
                    'unauthorized',
                    'invalid_response',
                    'network_error',
                    'service_unavailable',
                    'rate_limited',
                    'preparation_changed',
                    'preparation_not_discardable',
                    'practice_not_found',
                    'connection_not_found',
                    'csrf_invalid',
                    'origin_forbidden',
                  }.contains(error.code)
            ? error.code
            : 'recovery_unavailable';
        if (code == 'account_changed' || code == 'unauthorized') {
          _clearData();
          _cleanupStatus = PreparationCleanupStatus.idle;
          _errorCode = code;
        } else if (_isTranscriptRead(operation)) {
          if (code == 'practice_not_found' || code == 'connection_not_found') {
            _clearData();
            _errorCode = code;
          } else {
            _transcriptErrorCode = code;
          }
        } else if (operation == _RecoveryOperation.discard) {
          _clearData();
          _cleanupErrorCode = code;
          _cleanupStatus =
              error is ApiException &&
                  error.statusCode != null &&
                  error.statusCode! >= 400 &&
                  error.statusCode! < 500
              ? PreparationCleanupStatus.refused
              : PreparationCleanupStatus.unconfirmed;
        } else if (operation == _RecoveryOperation.observations) {
          _observationErrorCode = code;
        } else {
          _errorCode = code;
        }
      }
    } finally {
      if (identical(_inFlight, completion)) {
        _inFlight = null;
        _cancel = null;
        _busy = false;
        _operation = null;
        if (!_disposed) notifyListeners();
      }
      if (!completion.isCompleted) completion.complete();
    }
  }

  void _checkAccount() {
    if (_disposed || !_source.hasCurrentAccount(accountId)) {
      throw const ApiException('account_changed', '当前账号已变化。');
    }
  }

  Future<T> _read<T>(Future<T> Function(PracticeRepository) read) async {
    _checkAccount();
    final started = _now;
    final cancel = _cancel!;
    final client = _httpClientFactory();
    if (_disposed || !_source.hasCurrentAccount(accountId)) {
      client.close();
      _checkAccount();
    }
    final api = _source.forkForAccount(accountId: accountId, client: client);
    _ownedApi = api;
    try {
      final result = await Future.any<T>([
        read(PracticeRepository(api, accountId: accountId)),
        cancel.future.then<T>(
          (_) => throw const ApiException('account_changed', '读取已取消。'),
        ),
      ]).timeout(const Duration(seconds: 8));
      _checkAccount();
      if (_now - started >= const Duration(seconds: 8)) {
        throw TimeoutException('Read deadline');
      }
      return result;
    } on TimeoutException {
      throw const ApiException('network_error', '读取超时，请重试。');
    } finally {
      api.close();
      if (identical(_ownedApi, api)) _ownedApi = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearData();
    _cleanupStatus = PreparationCleanupStatus.idle;
    _cleanupErrorCode = null;
    if (_cancel != null && !_cancel!.isCompleted) _cancel!.complete();
    _ownedApi?.close();
    _ownedApi = null;
    _busy = false;
    _operation = null;
    if (_inFlight != null && !_inFlight!.isCompleted) _inFlight!.complete();
    _inFlight = null;
    super.dispose();
  }
}
