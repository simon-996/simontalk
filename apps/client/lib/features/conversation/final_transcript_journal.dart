import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import '../practice/submission_manifest.dart';
import 'conversation_models.dart';
import 'conversation_projection.dart';

abstract interface class RealtimeTranscriptJournal extends Listenable {
  int get pendingCount;
  int get rejectedCount;
  String? get errorCode;
  void record(TranscriptUpdate update);
  Future<void> retryPending();
  void finish();
  void abort();
}

typedef TranscriptJournalFactory = RealtimeTranscriptJournal Function(
  ConversationScope scope,
);

typedef TranscriptJournalCreator = RealtimeTranscriptJournal Function(
  ApiClient accountApi,
  ConversationScope scope,
);

/// An in-memory acknowledgement queue. Submission never proves audio delivery.
class FinalTranscriptJournal extends ChangeNotifier
    implements
        RealtimeTranscriptJournal,
        SubmissionManifestProvider,
        SealedSubmissionReconciler {
  FinalTranscriptJournal({
    required ApiClient accountApi,
    required this.scope,
    http.Client Function()? clientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _projection = ConversationProjection(scope),
       _clientFactory = clientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();

  final ConversationScope scope;
  final ApiClient _source;
  final ConversationProjection _projection;
  final http.Client Function() _clientFactory;
  final Duration Function() _elapsed;
  final _queue = <Map<String, Object>>[];
  final _submissionRefs = <SubmissionEventRef>[];
  bool _settled = false;
  int _permanentlyUnsaved = 0;
  int _pendingBytes = 0;
  int _recordedEvents = 0;
  int _recordedBytes = 0;
  int _confirmedEvents = 0;
  int _confirmedBytes = 0;
  int _rejected = 0;
  String? _inputError;
  String? _requestError;
  bool _paused = false;
  bool _finished = false;
  bool _aborted = false;
  Future<void>? _task;
  ApiClient? _activeApi;
  void Function()? _cancelBatch;

  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool _ownsAccount() {
    if (_aborted) return false;
    if (_source.hasCurrentAccount(scope.accountId)) return true;
    _loseAccount();
    return false;
  }

  @override
  int get pendingCount {
    _ownsAccount();
    return _queue.length;
  }

  bool get hasPendingLearnerTurn =>
      _ownsAccount() && _queue.any((event) => event['role'] == 'user');

  @override
  int get rejectedCount => _rejected;

  @override
  SubmissionManifest? get submissionManifest => _ownsAccount()
      ? SubmissionManifest(
          ledger: SubmissionLedger.transcripts,
          events: _submissionRefs,
          totalTextBytes: _recordedBytes,
          pendingCountAtClose: _queue.length,
        )
      : null;

  @override
  int get permanentlyUnsavedCount {
    _ownsAccount();
    return _permanentlyUnsaved;
  }

  @override
  String? get errorCode {
    _ownsAccount();
    return _requestError == 'account_changed' ||
            _requestError == 'unauthorized' ||
            _requestError == 'sealed_unsaved'
        ? _requestError
        : _inputError ?? _requestError;
  }

  void _reject(String code) {
    _rejected++;
    _inputError = code;
    notifyListeners();
  }

  @override
  void record(TranscriptUpdate update) {
    if (!_ownsAccount() || _finished || _settled || !update.isFinal) return;
    final provider = update.providerItemId;
    if (update.text.contains('\u0000') ||
        (provider != null &&
            (provider.contains('\u0000') ||
                utf8.decode(utf8.encode(provider)) != provider))) {
      _reject('transcript_invalid');
      return;
    }
    try {
      if (_projection.apply(update) != ConversationApplyResult.applied) return;
    } on ConversationFailure catch (error) {
      _reject(
        error.code == 'conversation_limit_reached'
            ? 'transcript_limit_reached'
            : 'transcript_invalid',
      );
      return;
    }
    final bytes = utf8.encode(update.text).length;
    if (_queue.length >= 64 ||
        _pendingBytes + bytes > 262144 ||
        _recordedEvents >= 512 ||
        _recordedBytes + bytes > 1048576) {
      _reject('transcript_limit_reached');
      return;
    }
    final eventId = randomUuid();
    _queue.add(
      Map.unmodifiable({
        'event_id': eventId,
        'sequence': ++_recordedEvents,
        'turn_id': update.turnId.toLowerCase(),
        'turn_index': update.turnIndex,
        'role': update.role.name,
        'revision': update.revision,
        'text': update.text,
        'response_id': ?update.responseId?.toLowerCase(),
        'provider_item_id': ?provider,
      }),
    );
    _submissionRefs.add(
      SubmissionEventRef(sequence: _recordedEvents, eventId: eventId),
    );
    _pendingBytes += bytes;
    _recordedBytes += bytes;
    _schedule();
    notifyListeners();
  }

  void _schedule() {
    if (_aborted || _settled || _paused || _queue.isEmpty || _task != null) {
      return;
    }
    _task = Future<void>.microtask(_drain);
  }

  @override
  Future<void> retryPending() {
    if (!_ownsAccount() || _settled) return Future.value();
    if (_task != null) return _task!;
    _paused = false;
    _requestError = null;
    _schedule();
    notifyListeners();
    return _task ?? Future.value();
  }

  void _loseAccount([String code = 'account_changed']) {
    _requestError = code;
    abort();
  }

  Future<void> _drain() async {
    try {
      while (!_aborted && !_settled && !_paused && _queue.isNotEmpty) {
        if (!_ownsAccount()) return;
        final batch = _queue.take(4).toList(growable: false);
        final bytes = batch.fold<int>(
          0,
          (sum, e) => sum + utf8.encode(e['text'] as String).length,
        );
        try {
          final data = await _exchange(batch);
          if (!_ownsAccount() || _settled) return;
          if (!_validAcknowledgement(data, batch, bytes)) {
            throw const ApiException('invalid_response', '文字保存确认异常。');
          }
          _queue.removeRange(0, batch.length);
          _pendingBytes -= bytes;
          _confirmedEvents += batch.length;
          _confirmedBytes += bytes;
          _requestError = null;
          _releaseConfirmedText();
          notifyListeners();
        } on Object catch (error) {
          if (_aborted || _settled) return;
          if (!_source.hasCurrentAccount(scope.accountId) ||
              (error is ApiException && error.code == 'account_changed')) {
            _loseAccount();
          } else if (error is ApiException && error.code == 'unauthorized') {
            _loseAccount('unauthorized');
          } else {
            _paused = true;
            _requestError = _errorCode(error);
            notifyListeners();
          }
        }
      }
    } finally {
      _task = null;
    }
  }

  Future<Map<String, dynamic>> _exchange(
    List<Map<String, Object>> batch,
  ) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    final api = _activeApi = _source.forkForAccount(
      accountId: scope.accountId,
      client: _clientFactory(),
    );
    final remaining = cutoff - _elapsed();
    if (_aborted || remaining <= Duration.zero) {
      _activeApi = null;
      api.close();
      throw ApiException(
        _aborted ? 'cancelled' : 'transcript_timeout',
        '文字保存已停止。',
      );
    }
    final cancelled = Completer<Map<String, dynamic>>();
    final deadline = Completer<Map<String, dynamic>>();
    _cancelBatch = () {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const ApiException('cancelled', '文字保存已停止。'));
      }
    };
    final timer = Timer(remaining, () {
      deadline.completeError(
        const ApiException('transcript_timeout', '文字保存超时。'),
      );
    });
    try {
      final result = await Future.any([
        api.request(
          'POST',
          '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}/transcripts',
          accountId: scope.accountId,
          body: {
            'client_instance_id': scope.clientInstanceId,
            'epoch': scope.epoch,
            'events': batch,
          },
        ),
        cancelled.future,
        deadline.future,
      ]);
      if (_elapsed() >= cutoff) {
        throw const ApiException('transcript_timeout', '文字保存超时。');
      }
      return result;
    } finally {
      timer.cancel();
      _activeApi = null;
      _cancelBatch = null;
      api.close();
    }
  }

  bool _validAcknowledgement(
    Map<String, dynamic> data,
    List<Map<String, Object>> batch,
    int bytes,
  ) {
    final ids = data['acknowledged_event_ids'];
    return data['source'] == 'client_reported' &&
        data['account_id'] == scope.accountId &&
        data['session_id'] == scope.sessionId &&
        data['connection_id'] == scope.connectionId &&
        data['client_instance_id'] == scope.clientInstanceId &&
        data['epoch'] is int &&
        data['epoch'] == scope.epoch &&
        data['last_sequence'] is int &&
        data['last_sequence'] == batch.last['sequence'] &&
        data['total_events'] is int &&
        data['total_events'] == _confirmedEvents + batch.length &&
        data['total_text_bytes'] is int &&
        data['total_text_bytes'] == _confirmedBytes + bytes &&
        ids is List &&
        ids.length == batch.length &&
        List.generate(
          batch.length,
          (i) => ids[i] == batch[i]['event_id'],
        ).every((matches) => matches);
  }

  static String _errorCode(Object error) {
    const known = {
      'network_error',
      'transcript_timeout',
      'transcript_conflict',
      'transcript_sequence_stale',
      'transcript_revision_stale',
      'transcript_limit_reached',
      'invalid_response',
      'csrf_invalid',
      'practice_input_sealed',
      'completion_manifest_conflict',
    };
    return error is ApiException && known.contains(error.code)
        ? error.code
        : 'transcript_failed';
  }

  @override
  void finish() {
    if (!_ownsAccount() || _finished) return;
    _finished = true;
    _projection.seal();
    _releaseConfirmedText();
    _schedule();
    notifyListeners();
  }

  void _releaseConfirmedText() {
    if (_finished && _queue.isEmpty) _projection.clear();
  }

  @override
  void reconcileSealed(SubmissionManifest received) {
    if (!_ownsAccount() || _settled) return;
    if (received.ledger != SubmissionLedger.transcripts) {
      throw const FormatException();
    }
    final refs = {
      for (final event in received.events) event.sequence: event.eventId,
    };
    _permanentlyUnsaved = _queue
        .where((event) => refs[event['sequence']] != event['event_id'])
        .length;
    _settled = true;
    _finished = true;
    _cancelBatch?.call();
    _activeApi?.close();
    _queue.clear();
    _pendingBytes = 0;
    _projection.clear();
    _requestError = _permanentlyUnsaved > 0 ? 'sealed_unsaved' : null;
    notifyListeners();
  }

  @override
  void abort() {
    if (_aborted) return;
    _aborted = true;
    _cancelBatch?.call();
    _activeApi?.close();
    _queue.clear();
    _submissionRefs.clear();
    _permanentlyUnsaved = 0;
    _pendingBytes = 0;
    _projection.clear();
    notifyListeners();
  }
}
