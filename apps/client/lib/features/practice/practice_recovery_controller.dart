import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import 'connection_observation_models.dart';
import 'practice_models.dart';
import 'practice_repository.dart';

/// Read-only snapshots. This controller never obtains or controls a media lease.
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
  PracticeRecovery? _recovery;
  PracticeRecovery? get recovery => _recovery;
  ConnectionObservationPage? _page;
  ConnectionObservationPage? get page => _page;
  List<ConnectionObservation> _events = const [];
  List<ConnectionObservation> get events => _events;
  String? _errorCode;
  String? get errorCode => _errorCode;
  String? _observationErrorCode;
  String? get observationErrorCode => _observationErrorCode;
  Completer<void>? _inFlight;
  Completer<void>? _cancel;
  ApiClient? _ownedApi;

  Future<void> refresh() => _start(observations: false);
  Future<void> loadObservations() => _start(observations: true);

  Future<void> _start({required bool observations}) {
    if (_disposed) return Future.value();
    if (_inFlight != null) return _inFlight!.future;
    if (observations &&
        (_recovery?.connection == null || (_page != null && !_page!.hasMore))) {
      return Future.value();
    }
    final completion = Completer<void>();
    _inFlight = completion;
    _cancel = Completer<void>();
    _busy = true;
    _errorCode = null;
    _observationErrorCode = null;
    if (!observations) _clearData();
    notifyListeners();
    unawaited(_perform(observations, completion));
    return completion.future;
  }

  void _clearData() {
    _recovery = null;
    _page = null;
    _events = const [];
  }

  Future<void> _perform(bool observations, Completer<void> completion) async {
    try {
      if (observations) {
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
                  }.contains(error.code)
            ? error.code
            : 'recovery_unavailable';
        if (code == 'account_changed' || code == 'unauthorized') {
          _clearData();
          _errorCode = code;
        } else if (observations) {
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
    if (_cancel != null && !_cancel!.isCompleted) _cancel!.complete();
    _ownedApi?.close();
    _ownedApi = null;
    _busy = false;
    if (_inFlight != null && !_inFlight!.isCompleted) _inFlight!.complete();
    _inFlight = null;
    super.dispose();
  }
}
