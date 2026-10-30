import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import '../practice/submission_manifest.dart';
import 'conversation_models.dart';
import 'playback_evidence_models.dart';

abstract interface class RealtimePlaybackEvidenceJournal extends Listenable {
  int get pendingCount;
  int get rejectedCount;
  String? get errorCode;
  void recordAlignment(ConversationTurn turn);
  void recordFreeze(
    ConversationTurn turn, {
    required int stopBoundaryMs,
    required InterruptedPrefixReason reason,
  });
  void recordRevoke(String responseId);
  Future<void> retryPending();
  void finish();
  void abort();
}

typedef PlaybackEvidenceJournalFactory =
    RealtimePlaybackEvidenceJournal Function(ConversationScope scope);
typedef PlaybackEvidenceJournalCreator =
    RealtimePlaybackEvidenceJournal Function(
      ApiClient accountApi,
      ConversationScope scope,
    );

/// Account-bound acknowledgement queue for independent device-output reports.
/// ACKs only release pending submissions; generated source dependencies remain
/// bounded until capture finishes, then all confirmed body text is released.
class PlaybackEvidenceJournal extends ChangeNotifier
    implements
        RealtimePlaybackEvidenceJournal,
        SubmissionManifestProvider,
        SealedSubmissionReconciler {
  PlaybackEvidenceJournal({
    required ApiClient accountApi,
    required this.scope,
    http.Client Function()? clientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _clientFactory = clientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();

  final ConversationScope scope;
  final ApiClient _source;
  final http.Client Function() _clientFactory;
  final Duration Function() _elapsed;
  PlaybackEvidenceLedger _ledger = PlaybackEvidenceLedger.empty();
  final _queue = <PlaybackEvidenceEvent>[];
  final _submissionRefs = <SubmissionEventRef>[];
  bool _settled = false;
  int _permanentlyUnsaved = 0;
  int _pendingBytes = 0;
  int _pendingNormal = 0;
  int _recordedEvents = 0;
  int _recordedNormal = 0;
  int _recordedRevocations = 0;
  int _recordedBytes = 0;
  int _confirmedEvents = 0;
  int _confirmedBytes = 0;
  int _rejected = 0;
  String? _inputError;
  String? _requestError;
  bool _finished = false;
  bool _aborted = false;
  bool _paused = false;
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

  @override
  int get rejectedCount => _rejected;
  @override
  SubmissionManifest? get submissionManifest => _ownsAccount()
      ? SubmissionManifest(
          ledger: SubmissionLedger.playback,
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

  void _record(PlaybackEvidenceEvent Function(String id, int sequence) create) {
    if (!_ownsAccount() || _finished || _settled) return;
    try {
      final event = create(randomUuid(), _recordedEvents + 1);
      if (event.kind == PlaybackEvidenceKind.revoke &&
          _ledger.revokedResponseIds.contains(event.responseId)) {
        return;
      }
      if (_ledger.events.any((old) => old.sameSnapshot(event))) return;
      final revoke = event.kind == PlaybackEvidenceKind.revoke;
      final responseKnown = _ledger.events.any(
        (old) => old.responseId == event.responseId,
      );
      final turnKnown =
          event.turnId == null ||
          _ledger.turns.any((old) => old.turnId == event.turnId);
      if ((!revoke &&
              (_pendingNormal >= 64 ||
                  _pendingBytes + event.textBytes > 262144 ||
                  _recordedNormal >= maxPlaybackEvidenceNormalEvents)) ||
          (revoke && _recordedRevocations >= maxPlaybackEvidenceRevocations) ||
          _recordedBytes + event.textBytes > maxPlaybackEvidenceTextBytes ||
          (!responseKnown &&
              _ledger.events.map((e) => e.responseId).toSet().length >= 256) ||
          (!turnKnown && _ledger.turns.length >= 256)) {
        _reject('playback_limit_reached');
        return;
      }
      // Check the whole next state before changing sequence or queue budgets.
      final next = _ledger.append(event);
      _ledger = next;
      _queue.add(event);
      _recordedEvents++;
      _submissionRefs.add(
        SubmissionEventRef(sequence: event.sequence, eventId: event.eventId),
      );
      _recordedBytes += event.textBytes;
      _pendingBytes += event.textBytes;
      if (revoke) {
        _recordedRevocations++;
      } else {
        _recordedNormal++;
        _pendingNormal++;
      }
      _schedule();
      notifyListeners();
    } on FormatException {
      _reject('playback_invalid');
    }
  }

  @override
  void recordAlignment(ConversationTurn turn) => _record(
    (id, sequence) =>
        PlaybackEvidenceEvent.alignment(turn, eventId: id, sequence: sequence),
  );
  @override
  void recordFreeze(
    ConversationTurn turn, {
    required int stopBoundaryMs,
    required InterruptedPrefixReason reason,
  }) => _record(
    (id, sequence) => PlaybackEvidenceEvent.freeze(
      turn,
      eventId: id,
      sequence: sequence,
      stopBoundaryMs: stopBoundaryMs,
      reason: reason,
    ),
  );
  @override
  void recordRevoke(String responseId) => _record(
    (id, sequence) => PlaybackEvidenceEvent.revoke(
      responseId,
      eventId: id,
      sequence: sequence,
    ),
  );

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
        final bytes = batch.fold<int>(0, (n, e) => n + e.textBytes);
        try {
          final data = await _exchange(batch);
          if (!_ownsAccount() || _settled) return;
          if (!_validAcknowledgement(data, batch, bytes)) {
            throw const ApiException('invalid_response', '播放证据保存确认异常。');
          }
          _queue.removeRange(0, batch.length);
          _pendingBytes -= bytes;
          _pendingNormal -= batch
              .where((e) => e.kind != PlaybackEvidenceKind.revoke)
              .length;
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
    List<PlaybackEvidenceEvent> batch,
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
        _aborted ? 'cancelled' : 'playback_timeout',
        '播放证据保存已停止。',
      );
    }
    final cancelled = Completer<Map<String, dynamic>>();
    final deadline = Completer<Map<String, dynamic>>();
    _cancelBatch = () {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const ApiException('cancelled', '播放证据保存已停止。'));
      }
    };
    final timer = Timer(
      remaining,
      () => deadline.completeError(
        const ApiException('playback_timeout', '播放证据保存超时。'),
      ),
    );
    try {
      final result = await Future.any([
        api.request(
          'POST',
          '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}/playback-evidence',
          accountId: scope.accountId,
          body: {
            'client_instance_id': scope.clientInstanceId,
            'epoch': scope.epoch,
            'events': batch
                .map((e) => e.toRequestJson())
                .toList(growable: false),
          },
        ),
        cancelled.future,
        deadline.future,
      ]);
      if (_elapsed() >= cutoff) {
        throw const ApiException('playback_timeout', '播放证据保存超时。');
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
    List<PlaybackEvidenceEvent> batch,
    int bytes,
  ) {
    final ids = data['acknowledged_event_ids'];
    const keys = {
      'source',
      'account_id',
      'session_id',
      'connection_id',
      'client_instance_id',
      'epoch',
      'last_sequence',
      'total_events',
      'total_text_bytes',
      'acknowledged_event_ids',
    };
    return data.keys.every(keys.contains) &&
        data['source'] == 'client_reported' &&
        data['account_id'] == scope.accountId &&
        data['session_id'] == scope.sessionId &&
        data['connection_id'] == scope.connectionId &&
        data['client_instance_id'] == scope.clientInstanceId &&
        data['epoch'] is int &&
        data['epoch'] == scope.epoch &&
        data['last_sequence'] is int &&
        data['last_sequence'] == batch.last.sequence &&
        data['total_events'] is int &&
        data['total_events'] == _confirmedEvents + batch.length &&
        data['total_text_bytes'] is int &&
        data['total_text_bytes'] == _confirmedBytes + bytes &&
        ids is List &&
        ids.length == batch.length &&
        List.generate(
          batch.length,
          (i) => ids[i] == batch[i].eventId,
        ).every((v) => v);
  }

  static String _errorCode(Object error) {
    const known = {
      'network_error',
      'playback_timeout',
      'playback_conflict',
      'playback_sequence_stale',
      'playback_revision_stale',
      'playback_limit_reached',
      'playback_revoked',
      'invalid_response',
      'csrf_invalid',
      'practice_input_sealed',
      'completion_manifest_conflict',
    };
    return error is ApiException && known.contains(error.code)
        ? error.code
        : 'playback_failed';
  }

  @override
  void finish() {
    if (!_ownsAccount() || _finished) return;
    _finished = true;
    _releaseConfirmedText();
    _schedule();
    notifyListeners();
  }

  void _releaseConfirmedText() {
    if (_finished && _queue.isEmpty) _ledger = PlaybackEvidenceLedger.empty();
  }

  @override
  void reconcileSealed(SubmissionManifest received) {
    if (!_ownsAccount() || _settled) return;
    if (received.ledger != SubmissionLedger.playback) {
      throw const FormatException();
    }
    final refs = {
      for (final event in received.events) event.sequence: event.eventId,
    };
    _permanentlyUnsaved = _queue
        .where((event) => refs[event.sequence] != event.eventId)
        .length;
    _settled = true;
    _finished = true;
    _cancelBatch?.call();
    _activeApi?.close();
    _queue.clear();
    _ledger = PlaybackEvidenceLedger.empty();
    _pendingBytes = 0;
    _pendingNormal = 0;
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
    _ledger = PlaybackEvidenceLedger.empty();
    _pendingBytes = 0;
    _pendingNormal = 0;
    notifyListeners();
  }
}
