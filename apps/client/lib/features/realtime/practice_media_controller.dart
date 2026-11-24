import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../core/api_client.dart';
import '../../core/random_uuid.dart';
import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../conversation/conversation_projection.dart';
import '../conversation/final_transcript_journal.dart';
import '../conversation/playback_evidence_journal.dart';
import '../practice/practice_models.dart';
import '../practice/practice_repository.dart';
import '../practice/practice_completion_client.dart';
import '../practice/practice_completion_models.dart';
import '../practice/submission_manifest.dart';
import 'connection_lease_watchdog.dart';
import 'connection_observation_journal.dart';
import 'realtime_session_protocol.dart';
import 'realtime_transport.dart';

enum PracticeMediaPhase {
  idle,
  preparing,
  connecting,
  configuring,
  active,
  draining,
  localClosed,
}

enum MediaReleaseStatus { notNeeded, pending, released, unconfirmed }

enum MediaPlayback { idle, waiting, blocked, playing, paused }

typedef RealtimeSignallerFactory = RealtimeSignaller Function(
  ConnectionReservation connection,
  String clientInstanceId,
);

/// Owns exactly one media attempt. Local closure is not upstream termination.
class PracticeMediaController extends ChangeNotifier
    with WidgetsBindingObserver {
  PracticeMediaController({
    required this.repository,
    required this.transportFactory,
    required this.signallerFactory,
    this.protocolFactory = unavailableRealtimeProtocol,
    this.observationJournalFactory,
    this.transcriptJournalFactory,
    this.playbackEvidenceJournalFactory,
    this.practiceCompletionFactory,
    this.drainTimeout = const Duration(seconds: 3),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _clock() {
    if (drainTimeout < const Duration(seconds: 1) ||
        drainTimeout > const Duration(seconds: 5)) {
      throw ArgumentError.value(drainTimeout, 'drainTimeout');
    }
    _lease = ConnectionLeaseWatchdog(
      elapsed: _elapsed,
      onRenew: () => unawaited(_renew()),
      onExpired: () => unawaited(stop(reason: 'local_lease_expired')),
    );
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  final PracticeRepository repository;
  final RealtimeTransport Function() transportFactory;
  final RealtimeSignallerFactory signallerFactory;
  final RealtimeProtocolFactory protocolFactory;
  final ObservationJournalFactory? observationJournalFactory;
  final TranscriptJournalFactory? transcriptJournalFactory;
  final PlaybackEvidenceJournalFactory? playbackEvidenceJournalFactory;
  final PracticeCompletionFactory? practiceCompletionFactory;
  final Duration drainTimeout;
  final Duration Function() _elapsed;
  late final ConnectionLeaseWatchdog _lease;
  final String clientInstanceId = randomUuid();
  final String practiceKey = randomUuid();
  final String connectionKey = randomUuid();
  PracticeMediaPhase _phase = PracticeMediaPhase.idle;
  PracticeMediaPhase get phase => _phase;
  MediaReleaseStatus _releaseStatus = MediaReleaseStatus.notNeeded;
  MediaReleaseStatus get releaseStatus => _releaseStatus;
  MediaPlayback _playback = MediaPlayback.idle;
  MediaPlayback get playback => _playback;

  /// The current unknown-output interruption cannot safely resume this call.
  bool get interruptionNeedsEnd =>
      _phase == PracticeMediaPhase.active &&
      _outputHeld &&
      _unknownOutputResponses.isNotEmpty;
  int _playbackRevision = 0;
  String? _errorCode;
  String? get errorCode => _errorCode;
  String? _lastObservationCode;
  String? get lastObservationCode => _lastObservationCode;
  RealtimeObservationJournal? _observationJournal;
  String? _observationError;
  RealtimeObservationJournal? get observationJournal => _observationJournal;
  String? get observationErrorCode =>
      _observationError ?? _observationJournal?.errorCode;
  RealtimeTranscriptJournal? _transcriptJournal;
  String? _transcriptError;
  bool _transcriptAborted = false;
  RealtimeTranscriptJournal? get transcriptJournal {
    if (!repository.hasCurrentAccount) _abortTranscripts();
    return _transcriptJournal;
  }

  int get transcriptPendingCount => transcriptJournal?.pendingCount ?? 0;
  int get transcriptRejectedCount => transcriptJournal?.rejectedCount ?? 0;
  String? get transcriptErrorCode =>
      _transcriptError ?? transcriptJournal?.errorCode;
  RealtimePlaybackEvidenceJournal? _playbackEvidenceJournal;
  String? _playbackEvidenceError;
  bool _playbackEvidenceAborted = false;
  RealtimePlaybackEvidenceJournal? get playbackEvidenceJournal {
    if (!repository.hasCurrentAccount) _abortPlaybackEvidence();
    return _playbackEvidenceJournal;
  }

  int get playbackEvidencePendingCount =>
      playbackEvidenceJournal?.pendingCount ?? 0;
  int get playbackEvidenceRejectedCount =>
      playbackEvidenceJournal?.rejectedCount ?? 0;
  String? get playbackEvidenceErrorCode =>
      _playbackEvidenceError ?? playbackEvidenceJournal?.errorCode;
  RealtimePracticeCompletion? _practiceCompletion;
  PracticeCompletionManifest? _completionManifest;
  bool _completionIntentRequested = false;
  bool _completionRequestedOnClient = false;
  bool _completionManifestSent = false;
  bool _completionAborted = false;
  bool _completionReconciled = false;
  bool _completionSettling = false;
  String? _completionError;
  RealtimePracticeCompletion? get practiceCompletion {
    if (!repository.hasCurrentAccount) _abortCompletion();
    return _practiceCompletion;
  }

  bool get completionHasPendingWork {
    if (!repository.hasCurrentAccount) _abortCompletion();
    if (_completionAborted || !_completionIntentRequested) return false;
    return _completionSettling ||
        _completionError != null ||
        (_practiceCompletion?.hasPendingWork ?? true);
  }

  String? get completionErrorCode =>
      _completionError ?? practiceCompletion?.errorCode;
  bool _muted = false;
  bool get muted => _muted;
  bool _signallingAttempted = false;
  bool get signallingAttempted => _signallingAttempted;
  PracticePreparation? _practice;
  PracticePreparation? get practice => _practice;
  ConnectionReservation? _connection;
  ConnectionReservation? get connection => _connection;
  ConversationProjection? _conversation;
  ConversationSnapshot? get conversation {
    if (_disposed) return null;
    if (!repository.hasCurrentAccount) {
      _conversation?.clear();
      _greatestPlayedUntil.clear();
      _responsesWithKnownPlayback.clear();
      _abortTranscripts();
      _abortPlaybackEvidence();
      _abortCompletion();
      return null;
    }
    return _conversation?.snapshot;
  }

  bool _practiceRequested = false;
  bool _connectionRequested = false;
  bool _creating = false;
  bool _renewing = false;
  bool _closed = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _transportReady = false;
  bool _answerReceived = false;
  String? _confirmedChannel;
  final _channels = <String>{};
  final _events = <RealtimeTransportEvent>[];
  int _eventBytes = 0;
  RealtimeTransport? _transport;
  RealtimeSignaller? _signaller;
  RealtimeSessionProtocol? _protocol;
  Timer? _setupTimer;
  Timer? _configurationTimer;
  Duration? _setupDeadline;
  Duration? _configurationDeadline;
  Completer<void>? _begun;
  Future<void>? _cleanupTask;
  Completer<void>? _ended;
  Timer? _drainTimer;
  Duration? _drainDeadline;
  Duration? get drainDeadline => _drainDeadline;
  bool _draining = false;
  bool _preparingDrain = false;
  final _frozenTurns = <String, ConversationTurn>{};
  final _frozenResponses = <String>{};
  // Source revisions reset current alignment, but cannot erase known output.
  final _greatestPlayedUntil = <String, int>{};
  final _responsesWithKnownPlayback = <String>{};
  final _drainControls = <String>{};
  final _outputTailDeadlines = <String, Duration>{};
  final _outputTailReasons = <String, InterruptedPrefixReason>{};
  final _unknownOutputResponses = <String>{};
  final _confirmedContextResponses = <String>{};
  bool _needsContextConfirmation = false;
  bool _outputHeld = false;
  bool _holdingOutput = false;
  RealtimeContextSnapshot? _contextCandidate;
  bool _contextControlSent = false;
  final _pendingTail = <(ConversationUpdate, String)>[];
  int _pendingTailBytes = 0;

  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  static String _safeCode(String code) =>
      RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(code)
      ? code
      : 'connection_failed';
  static String _code(Object error) => error is ApiException
      ? _safeCode(error.code)
      : error is RealtimeFailure
      ? _safeCode(error.code)
      : error is ConversationFailure
      ? _safeCode(error.code)
      : 'connection_failed';

  void _publish(PracticeMediaPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  bool _guard() {
    if (_closed || _disposed) return false;
    final elapsed = _elapsed();
    final reason = _holdingOutput
        ? 'interruption_reentrant'
        : !repository.hasCurrentAccount
        ? 'account_changed'
        : !_foreground
        ? 'background'
        : _configurationDeadline != null && elapsed >= _configurationDeadline!
        ? 'configuration_timeout'
        : _setupDeadline != null && elapsed >= _setupDeadline!
        ? 'connection_timeout'
        : _lease.expired
        ? 'local_lease_expired'
        : _drainDeadline != null && elapsed >= _drainDeadline!
        ? 'tail_unconfirmed'
        : null;
    if (reason == null) return true;
    unawaited(stop(reason: reason));
    return false;
  }

  /// Completes on configuration + microphone activation, or immediate local closure.
  Future<void> begin({Difficulty? difficulty}) {
    if (_begun != null) return _begun!.future;
    if (_closed || _disposed) return Future.value();
    _begun = Completer<void>();
    unawaited(_run(difficulty));
    return _begun!.future;
  }

  Future<void> _run(Difficulty? difficulty) async {
    _creating = true;
    _publish(PracticeMediaPhase.preparing);
    try {
      if (!_guard()) return;
      _practiceRequested = true;
      _releaseStatus = MediaReleaseStatus.pending;
      _practice = await repository.createPractice(
        key: practiceKey,
        difficulty: difficulty,
      );
      if (!_guard()) return;
      if (_practice!.status != PracticeStatus.created) {
        throw const RealtimeFailure('preparation_state_changed');
      }
      final started = _elapsed();
      _connectionRequested = true;
      _connection = await repository.createConnection(
        _practice!,
        key: connectionKey,
        clientInstanceId: clientInstanceId,
      );
      if (!_guard()) return;
      if (!_connection!.canCancel) {
        throw const RealtimeFailure('connection_state_changed');
      }
      if (!_lease.arm(started, _connection!)) {
        throw const RealtimeFailure('local_lease_expired');
      }
      _conversation = ConversationProjection(
        ConversationScope(
          accountId: repository.accountId,
          sessionId: _connection!.sessionId,
          connectionId: _connection!.id,
          clientInstanceId: clientInstanceId,
          epoch: _connection!.epoch,
        ),
      );
      _creating = false;
      if (transcriptJournalFactory != null) {
        try {
          final journal = transcriptJournalFactory!(_conversation!.scope);
          if (!_guard()) {
            journal.abort();
            return;
          }
          _transcriptJournal = journal;
        } on Object {
          _transcriptError = 'transcript_unavailable';
        }
      }
      if (playbackEvidenceJournalFactory != null) {
        try {
          final journal = playbackEvidenceJournalFactory!(_conversation!.scope);
          if (!_guard()) {
            journal.abort();
            return;
          }
          _playbackEvidenceJournal = journal;
        } on Object {
          _playbackEvidenceError = 'playback_evidence_unavailable';
        }
      }
      _createCompletion();
      if (!_guard()) return;
      if (observationJournalFactory != null) {
        try {
          final journal = observationJournalFactory!(
            _connection!,
            clientInstanceId,
          );
          if (!_guard()) {
            journal.abort();
            return;
          }
          _observationJournal = journal;
        } on Object {
          _observationError = 'observation_unavailable';
        }
      }
      if (!_guard()) return;
      final protocol = protocolFactory(
        _practice!.configuration,
        RealtimeProtocolCallbacks(
          send: _send,
          confirmConfigured: _confirmConfigured,
          fail: (code) => unawaited(stop(reason: _safeCode(code))),
          emitConversation: _acceptConversation,
          sendDrainControl: _sendDrainControl,
          freezeResponse: _freezeResponse,
          quarantineUnknownResponse: _quarantineUnknownResponse,
          revokeFrozenPrefix: _revokeFrozenPrefix,
          prepareContext: _prepareContext,
          sendContextControl: _sendContextControl,
          confirmContextTruncated: _confirmContextTruncated,
        ),
      );
      if (!_guard()) {
        protocol.dispose();
        return;
      }
      _protocol = protocol;
      final signaller = signallerFactory(_connection!, clientInstanceId);
      if (!_guard()) {
        signaller.cancel();
        return;
      }
      _signaller = _AttemptSignaller(
        signaller,
        canUse: _guard,
        onOffer: () => _signallingAttempted = true,
        onAnswer: () => _answerReceived = true,
        onFailure: (code) => unawaited(stop(reason: code)),
      );
      if (!_guard()) return;
      final transport = transportFactory();
      if (!_guard()) {
        transport.stop();
        return;
      }
      _transport = transport;
      _transport!.setMuted(_muted);
      _publish(PracticeMediaPhase.connecting);
      if (!_guard()) return;
      _setupDeadline = _elapsed() + const Duration(seconds: 60);
      _setupTimer = Timer(
        const Duration(seconds: 60),
        () => unawaited(stop(reason: 'connection_timeout')),
      );
      await _transport!.start(
        signaller: _signaller!,
        onObservation: _observe,
        onEvent: _receive,
      );
      if (!_guard()) return;
      if (!_answerReceived) {
        throw const RealtimeFailure('invalid_transport_state');
      }
      _setupTimer?.cancel();
      _setupDeadline = null;
      _transportReady = true;
      _configurationDeadline = _elapsed() + const Duration(seconds: 20);
      _configurationTimer = Timer(
        const Duration(seconds: 20),
        () => unawaited(stop(reason: 'configuration_timeout')),
      );
      _recordObservation('transport_connected');
      if (!_guard()) return;
      _publish(PracticeMediaPhase.configuring);
      for (final channel in _channels.toList()) {
        if (!_guard()) return;
        _protocol!.channelOpened(channel);
      }
      final queued = List<RealtimeTransportEvent>.of(_events);
      _events.clear();
      _eventBytes = 0;
      for (final event in queued) {
        if (!_guard()) return;
        _protocol!.receive(event);
      }
    } on Object catch (error) {
      if (!_closed) {
        if (_practice == null &&
            error is ApiException &&
            error.code == 'realtime_unavailable') {
          _practiceRequested = false;
        }
        await stop(reason: _code(error));
      }
    } finally {
      _creating = false;
      if (_closed) await _cleanup();
    }
  }

  void _observe(RealtimeObservation observation) {
    if (!_guard()) return;
    if (!_draining &&
        _outputHeld &&
        {
          'playback_waiting',
          'playback_blocked',
          'playback_playing',
          'playback_paused',
        }.contains(observation.code)) {
      return;
    }
    _lastObservationCode = _safeCode(observation.code);
    if (observation.code == 'local_closed') {
      unawaited(stop(reason: _safeCode(observation.detail)));
      return;
    }
    if (_draining) return;
    final playbackRevision =
        {
          'playback_waiting',
          'playback_blocked',
          'playback_playing',
          'playback_paused',
        }.contains(observation.code)
        ? ++_playbackRevision
        : null;
    if ({
      'requesting_microphone',
      'negotiating',
      'playback_waiting',
      'playback_blocked',
      'playback_playing',
      'playback_paused',
    }.contains(observation.code)) {
      _recordObservation(observation.code);
      if (!_guard()) return;
    }
    if (observation.code == 'channel_open') {
      final id = observation.detail;
      if (id.isEmpty ||
          id.length > 64 ||
          (!_channels.contains(id) && _channels.length >= 8)) {
        unawaited(stop(reason: 'invalid_channel'));
        return;
      }
      if (_channels.add(id) && _transportReady) {
        _protocolCall(() => _protocol!.channelOpened(id));
      }
    }
    if (playbackRevision != null && playbackRevision != _playbackRevision) {
      return;
    }
    _playback = switch (observation.code) {
      'playback_waiting' => MediaPlayback.waiting,
      'playback_blocked' => MediaPlayback.blocked,
      'playback_playing' => MediaPlayback.playing,
      'playback_paused' => MediaPlayback.paused,
      _ => _playback,
    };
    if (_guard()) _publish(_phase);
  }

  void _receive(RealtimeTransportEvent event) {
    if (!_guard()) return;
    if (_draining && event.channelId != _confirmedChannel) return;
    final size = utf8.encode(event.json).length;
    if (!_channels.contains(event.channelId) || size > 65536) {
      unawaited(stop(reason: 'invalid_event'));
      return;
    }
    if (_transportReady) {
      _protocolCall(() => _protocol!.receive(event));
    } else if (_events.length >= 32 || _eventBytes + size > 131072) {
      unawaited(stop(reason: 'event_buffer_full'));
    } else {
      _events.add(event);
      _eventBytes += size;
    }
  }

  void _protocolCall(void Function() action) {
    try {
      action();
    } on Object catch (error) {
      unawaited(stop(reason: _code(error)));
    }
  }

  void _acceptConversation(ConversationUpdate update, String channelId) {
    if (!_guard()) return;
    if (_draining &&
        (channelId != _confirmedChannel || !_allowedTail(update))) {
      return;
    }
    if (_preparingDrain) {
      final text = switch (update) {
        TranscriptUpdate() => update.text,
        PlaybackUpdate() => update.playedText,
        TurnStartedUpdate() => '',
      };
      final bytes = text.length > ConversationProjection.maxTextBytes
          ? ConversationProjection.maxTextBytes + 1
          : utf8.encode(text).length;
      if (bytes > ConversationProjection.maxTextBytes ||
          _pendingTail.length >= 32 ||
          _pendingTailBytes + bytes > 131072) {
        unawaited(stop(reason: 'conversation_limit_reached'));
        return;
      }
      _pendingTail.add((update, channelId));
      _pendingTailBytes += bytes;
      return;
    }
    final response = switch (update) {
      TranscriptUpdate() => update.responseId,
      PlaybackUpdate() => update.responseId,
      TurnStartedUpdate() => update.responseId,
    };
    final tailDeadline = _outputTailDeadlines[response?.toLowerCase()];
    if (tailDeadline != null && _elapsed() >= tailDeadline) return;
    if (_needsContextConfirmation && response != null && tailDeadline == null) {
      unawaited(stop(reason: 'context_unconfirmed'));
      return;
    }
    if (!_draining && _outputHeld && response != null && tailDeadline == null) {
      unawaited(stop(reason: 'playback_quarantined'));
      return;
    }
    if (!_transportReady ||
        channelId != _confirmedChannel ||
        !_channels.contains(channelId) ||
        _conversation == null) {
      unawaited(stop(reason: 'conversation_invalid'));
      return;
    }
    if (update is PlaybackUpdate &&
        _unknownOutputResponses.contains(update.responseId.toLowerCase())) {
      return;
    }
    try {
      final result = _conversation!.apply(update);
      if (result == ConversationApplyResult.closed) {
        unawaited(stop(reason: 'conversation_closed'));
      } else if (result == ConversationApplyResult.applied && _guard()) {
        if (update is TranscriptUpdate && update.isFinal) {
          try {
            _transcriptJournal?.record(update);
          } on Object {
            _transcriptError = 'transcript_unavailable';
            _abortTranscripts();
            _transcriptJournal = null;
          }
        }
        if (update is PlaybackUpdate && _guard()) {
          if (update.status != DeliveryStatus.unknown) {
            _responsesWithKnownPlayback.add(update.responseId.toLowerCase());
          }
          final turn = _conversation!.snapshot.turns.singleWhere(
            (turn) => turn.turnId == update.turnId.toLowerCase(),
          );
          final until = turn.playback.playedUntilMs;
          if (until != null &&
              until > (_greatestPlayedUntil[turn.responseId!] ?? 0)) {
            _greatestPlayedUntil[turn.responseId!] = until;
          }
          _recordPlaybackEvidence((journal) => journal.recordAlignment(turn));
        }
        if (_guard()) _publish(_phase);
      }
    } on ConversationFailure catch (error) {
      unawaited(stop(reason: error.code));
    } on Object {
      unawaited(stop(reason: 'conversation_invalid'));
    }
  }

  void _send(String json, String channelId) {
    if (!_guard()) return;
    if (_draining) {
      unawaited(stop(reason: 'drain_protocol_violation'));
      return;
    }
    if (_needsContextConfirmation) {
      unawaited(stop(reason: 'context_unconfirmed'));
      return;
    }
    if (_outputHeld) {
      unawaited(stop(reason: 'playback_quarantined'));
      return;
    }
    if (!_transportReady || !_channels.contains(channelId)) {
      unawaited(stop(reason: 'invalid_channel'));
      return;
    }
    _protocolCall(() => _transport!.send(json, channelId));
  }

  void _confirmConfigured(String channelId) {
    if (!_guard()) return;
    if (_draining) return;
    if (!_transportReady ||
        !_answerReceived ||
        !_channels.contains(channelId) ||
        (_confirmedChannel != null && _confirmedChannel != channelId)) {
      unawaited(stop(reason: 'invalid_channel'));
      return;
    }
    if (_confirmedChannel != null) return;
    _confirmedChannel = channelId;
    _recordObservation('configuration_confirmed');
    unawaited(_activate(channelId));
  }

  Future<void> _activate(String channelId) async {
    if (!_guard()) return;
    try {
      await _transport!.activate(channelId);
      if (!_guard()) return;
      _configurationTimer?.cancel();
      _configurationDeadline = null;
      _recordObservation('microphone_active');
      if (!_guard()) return;
      _publish(PracticeMediaPhase.active);
      _completeBegin();
    } on Object catch (error) {
      if (!_closed) await stop(reason: _code(error));
    }
  }

  Future<void> _renew() async {
    if (!_guard() || _draining || _renewing || _connection == null) return;
    _renewing = true;
    final original = _connection!;
    final started = _elapsed();
    try {
      final renewed = await repository.renewConnection(original);
      if (!_guard()) return;
      if (_draining) return;
      if (![
            ConnectionStatus.preparing,
            ConnectionStatus.negotiating,
            ConnectionStatus.configuring,
            ConnectionStatus.ready,
          ].contains(renewed.status) ||
          (_answerReceived && renewed.status == ConnectionStatus.preparing) ||
          !renewed.lastSeenAt.isAfter(original.lastSeenAt)) {
        throw const RealtimeFailure('connection_state_changed');
      }
      _connection = renewed;
      if (!_lease.arm(started, renewed)) {
        throw const RealtimeFailure('local_lease_expired');
      }
    } on Object catch (error) {
      if (_guard() && !_draining) await stop(reason: _code(error));
    } finally {
      _renewing = false;
    }
  }

  void setMuted(bool value) {
    if (!_guard()) return;
    if (_draining || (!value && interruptionNeedsEnd)) return;
    final changed = _muted != value;
    _muted = value;
    _protocolCall(() => _transport?.setMuted(value));
    if (changed && _guard()) _recordObservation(value ? 'muted' : 'unmuted');
    if (_guard()) _publish(_phase);
  }

  Future<void> resumePlayback() async {
    if (!_guard() || _phase != PracticeMediaPhase.active || _outputHeld) return;
    final playbackRevision = ++_playbackRevision;
    try {
      await _transport!.resumePlayback();
    } on RealtimeFailure catch (error) {
      if (!_guard()) return;
      if (_draining) return;
      if (_outputHeld && error.code == 'playback_held') return;
      if (error.code == 'playback_blocked' ||
          error.code == 'playback_waiting') {
        if (playbackRevision != _playbackRevision) return;
        _playback = error.code == 'playback_blocked'
            ? MediaPlayback.blocked
            : MediaPlayback.waiting;
        _publish(_phase);
      } else {
        await stop(reason: _code(error));
      }
    } on Object catch (error) {
      if (_guard() && !_draining) await stop(reason: _code(error));
    }
  }

  void _completeBegin() {
    if (_begun != null && !_begun!.isCompleted) _begun!.complete();
  }

  void _recordObservation(String code, {String? reason}) {
    try {
      _observationJournal?.record(code, reason: reason);
    } on Object {
      _observationError = 'observation_unavailable';
      try {
        _observationJournal?.abort();
      } on Object {
        /* Best effort telemetry only. */
      }
      _observationJournal = null;
    }
  }

  void _finishObservations(String reason) {
    if (_observationJournal == null) return;
    try {
      if (!repository.hasCurrentAccount) {
        _observationJournal!.abort();
      } else {
        _recordObservation('local_closed', reason: reason);
        _observationJournal?.finish();
      }
    } on Object {
      _observationError = 'observation_unavailable';
    }
  }

  void _abortTranscripts() {
    if (_transcriptAborted || _transcriptJournal == null) return;
    _transcriptAborted = true;
    try {
      _transcriptJournal!.abort();
    } on Object {
      _transcriptError = 'transcript_unavailable';
    }
  }

  void _finishTranscripts() {
    if (_transcriptJournal == null || _transcriptAborted) return;
    try {
      _transcriptJournal!.finish();
    } on Object {
      _transcriptError = 'transcript_unavailable';
      _abortTranscripts();
    }
  }

  void _recordPlaybackEvidence(
    void Function(RealtimePlaybackEvidenceJournal) action,
  ) {
    if (_playbackEvidenceAborted || _playbackEvidenceJournal == null) return;
    try {
      action(_playbackEvidenceJournal!);
    } on Object {
      _playbackEvidenceError = 'playback_evidence_unavailable';
      _abortPlaybackEvidence();
    }
  }

  void _abortPlaybackEvidence() {
    if (_playbackEvidenceAborted || _playbackEvidenceJournal == null) return;
    _playbackEvidenceAborted = true;
    try {
      _playbackEvidenceJournal!.abort();
    } on Object {
      _playbackEvidenceError = 'playback_evidence_unavailable';
    }
  }

  void _finishPlaybackEvidence() {
    if (_playbackEvidenceAborted || _playbackEvidenceJournal == null) return;
    try {
      _playbackEvidenceJournal!.finish();
    } on Object {
      _playbackEvidenceError = 'playback_evidence_unavailable';
      _abortPlaybackEvidence();
    }
  }

  bool _allowedTail(ConversationUpdate update) {
    final turn = _frozenTurns[update.turnId.toLowerCase()];
    if (turn == null) return false;
    return switch (update) {
      TranscriptUpdate() =>
        update.isFinal &&
            update.turnIndex == turn.turnIndex &&
            update.role == turn.role &&
            update.responseId?.toLowerCase() == turn.responseId,
      PlaybackUpdate() =>
        turn.role == ConversationRole.assistant &&
            update.responseId.toLowerCase() == turn.responseId,
      TurnStartedUpdate() => false,
    };
  }

  void _sendDrainControl(
    String json,
    String channelId,
    RealtimeDrainControlKind kind,
    String? responseId,
  ) {
    if (!_guard() ||
        (!_draining &&
            !(_needsContextConfirmation &&
                kind == RealtimeDrainControlKind.cancelResponse))) {
      return;
    }
    if (channelId != _confirmedChannel ||
        (kind == RealtimeDrainControlKind.finishInput && responseId != null) ||
        (kind == RealtimeDrainControlKind.cancelResponse &&
            !(_draining
                ? _frozenResponses.contains(responseId?.toLowerCase())
                : _outputTailDeadlines.containsKey(
                    responseId?.toLowerCase(),
                  )))) {
      unawaited(stop(reason: 'drain_protocol_violation'));
      return;
    }
    final key = '${kind.name}:${responseId?.toLowerCase() ?? ''}';
    if (!_draining && kind == RealtimeDrainControlKind.cancelResponse) {
      final deadline = _outputTailDeadlines[responseId?.toLowerCase()];
      if (deadline == null || _elapsed() >= deadline) return;
    }
    if (!_drainControls.add(key)) return;
    _protocolCall(() => _transport!.send(json, channelId));
  }

  void _freezeResponse(String responseId, int boundary, String channelId) {
    if (!_guard()) return;
    final id = responseId.toLowerCase();
    if (_confirmedContextResponses.contains(id)) return;
    if (channelId != _confirmedChannel ||
        (_draining && !_frozenResponses.contains(responseId.toLowerCase()))) {
      unawaited(stop(reason: 'conversation_invalid'));
      return;
    }
    if (_unknownOutputResponses.contains(id)) {
      unawaited(stop(reason: 'playback_quarantined'));
      return;
    }
    _protocolCall(() {
      if (boundary < (_greatestPlayedUntil[id] ?? 0)) {
        throw const ConversationFailure('conversation_invalid');
      }
      final existing = _outputTailDeadlines.containsKey(id);
      final reason =
          _outputTailReasons[id] ??
          (_draining
              ? InterruptedPrefixReason.normalEnd
              : InterruptedPrefixReason.interrupted);
      final originalTurns = _conversation!.snapshot.turns
          .where((turn) => turn.responseId == id)
          .toList(growable: false);
      if (originalTurns.isEmpty ||
          originalTurns.any(
            (turn) => turn.role != ConversationRole.assistant,
          )) {
        throw const ConversationFailure('conversation_invalid');
      }
      if (!_draining && !existing && !_outputHeld) {
        _holdInterruptedOutput();
        if (!_guard()) return;
      }
      final result = _conversation!.freezeResponse(
        responseId,
        stopBoundaryMs: boundary,
        reason: reason,
      );
      if (result == ConversationApplyResult.applied) {
        for (final turn in originalTurns) {
          if (!_guard()) return;
          _recordPlaybackEvidence(
            (journal) => journal.recordFreeze(
              turn,
              stopBoundaryMs: boundary,
              reason: reason,
            ),
          );
        }
        if (!_guard()) return;
      }
      final configured = _elapsed() + drainTimeout;
      final lease = _lease.deadline;
      _outputTailDeadlines.putIfAbsent(
        id,
        () => lease != null && lease < configured ? lease : configured,
      );
      _outputTailReasons.putIfAbsent(id, () => reason);
      if (!_draining && !existing) {
        _needsContextConfirmation = true;
        _contextCandidate = null;
        _contextControlSent = false;
      }
      if (_guard() && !_draining && !existing) _publish(_phase);
    });
  }

  void _holdInterruptedOutput() {
    if (_outputHeld) return;
    // Gate reentrant callbacks before touching browser output.
    _outputHeld = true;
    _needsContextConfirmation = true;
    _playbackRevision++;
    _playback = MediaPlayback.paused;
    _holdingOutput = true;
    try {
      _transport!.holdPlayback();
    } finally {
      _holdingOutput = false;
    }
  }

  void _quarantineUnknownResponse(String responseId, String channelId) {
    if (!_guard()) return;
    final id = responseId.toLowerCase();
    final turns = _conversation?.snapshot.turns
        .where((turn) => turn.responseId == id)
        .toList(growable: false);
    if (_draining ||
        _phase != PracticeMediaPhase.active ||
        !_transportReady ||
        channelId != _confirmedChannel ||
        _responsesWithKnownPlayback.contains(id) ||
        turns == null ||
        turns.isEmpty ||
        turns.any(
          (turn) =>
              turn.role != ConversationRole.assistant ||
              turn.playback.status != DeliveryStatus.unknown,
        )) {
      unawaited(stop(reason: 'conversation_invalid'));
      return;
    }
    if (_unknownOutputResponses.contains(id)) return;
    if (_outputTailDeadlines.containsKey(id) ||
        _confirmedContextResponses.contains(id)) {
      unawaited(stop(reason: 'playback_quarantined'));
      return;
    }
    _protocolCall(() {
      _unknownOutputResponses.add(id);
      _needsContextConfirmation = true;
      _contextCandidate = null;
      _contextControlSent = false;
      _holdInterruptedOutput();
      if (!_guard()) return;
      final configured = _elapsed() + drainTimeout;
      final lease = _lease.deadline;
      _outputTailDeadlines[id] = lease != null && lease < configured
          ? lease
          : configured;
      // Let the adapter register the already-started user item before a
      // listener can synchronously end and freeze the conversation scope.
      scheduleMicrotask(() {
        if (_guard() && !_draining && _unknownOutputResponses.contains(id)) {
          _publish(_phase);
        }
      });
    });
  }

  void _revokeFrozenPrefix(String responseId, String channelId) {
    if (!_guard()) return;
    final id = responseId.toLowerCase();
    final deadline = _outputTailDeadlines[id];
    if (channelId != _confirmedChannel || deadline == null) {
      unawaited(stop(reason: 'conversation_invalid'));
      return;
    }
    if (_elapsed() >= deadline) return;
    ConversationApplyResult? result;
    _protocolCall(() => result = _conversation!.revokeFrozenPrefix(id));
    if (result == ConversationApplyResult.applied && _guard()) {
      _recordPlaybackEvidence((journal) => journal.recordRevoke(id));
    }
    if (!_guard()) return;
    if (_confirmedContextResponses.contains(id)) {
      unawaited(stop(reason: 'context_invalidated'));
      return;
    }
    if (_guard()) _publish(_phase);
  }

  RealtimeContextSnapshot? _prepareContext(String channelId) {
    if (!_guard() ||
        _draining ||
        !_needsContextConfirmation ||
        _unknownOutputResponses.isNotEmpty ||
        channelId != _confirmedChannel) {
      return null;
    }
    final snapshot = _conversation!.snapshot;
    if (_contextCandidate?.revision != snapshot.revision) {
      _contextCandidate = RealtimeContextSnapshot(
        revision: snapshot.revision,
        context: snapshot.context,
      );
      _contextControlSent = false;
    }
    return _contextCandidate;
  }

  bool _validContext(RealtimeContextSnapshot snapshot, String channelId) =>
      !_draining &&
      _needsContextConfirmation &&
      channelId == _confirmedChannel &&
      identical(snapshot, _contextCandidate) &&
      snapshot.revision == _conversation!.snapshot.revision;

  void _sendContextControl(
    String json,
    String channelId,
    RealtimeContextSnapshot snapshot,
  ) {
    if (!_guard() ||
        !_validContext(snapshot, channelId) ||
        _contextControlSent) {
      return;
    }
    _contextControlSent = true;
    _protocolCall(() => _transport!.send(json, channelId));
  }

  void _confirmContextTruncated(
    RealtimeContextSnapshot snapshot,
    String channelId,
  ) {
    if (!_guard() ||
        !_validContext(snapshot, channelId) ||
        !_contextControlSent) {
      return;
    }
    _confirmedContextResponses.addAll(_outputTailDeadlines.keys);
    _needsContextConfirmation = false;
  }

  void _createCompletion() {
    if (_completionAborted ||
        _practiceCompletion != null ||
        practiceCompletionFactory == null ||
        _conversation == null) {
      return;
    }
    try {
      final client = practiceCompletionFactory!(_conversation!.scope);
      if (_disposed || !repository.hasCurrentAccount || _completionAborted) {
        client.abort();
        return;
      }
      _practiceCompletion = client;
      client.addListener(_completionChanged);
      _completionError = null;
    } on Object {
      _completionError = 'completion_unavailable';
    }
  }

  void _requestCompletionEnd() {
    if (!_completionIntentRequested ||
        _completionAborted ||
        _disposed ||
        !repository.hasCurrentAccount) {
      return;
    }
    _createCompletion();
    final client = _practiceCompletion;
    if (client == null || _completionRequestedOnClient) return;
    try {
      _completionRequestedOnClient = true;
      client.requestEnd();
    } on Object {
      _completionError = 'completion_unavailable';
    }
  }

  void _captureCompletion(ConversationSnapshot snapshot, String reason) {
    if (_completionManifest != null ||
        _completionAborted ||
        _disposed ||
        !repository.hasCurrentAccount) {
      return;
    }
    try {
      final text = _transcriptJournal;
      final output = _playbackEvidenceJournal;
      final transcripts = text is SubmissionManifestProvider
          ? (text as SubmissionManifestProvider).submissionManifest
          : null;
      final playback = output is SubmissionManifestProvider
          ? (output as SubmissionManifestProvider).submissionManifest
          : null;
      if (!repository.hasCurrentAccount || _completionAborted) return;
      _completionManifest = PracticeCompletionManifest(
        scope: snapshot.scope,
        transcripts:
            transcripts ??
            SubmissionManifest.empty(SubmissionLedger.transcripts),
        playback:
            playback ?? SubmissionManifest.empty(SubmissionLedger.playback),
        tailStatus: reason == 'tail_unconfirmed'
            ? PracticeCompletionTailStatus.unconfirmed
            : PracticeCompletionTailStatus.aborted,
        unfinalizedTurnIds: snapshot.turns
            .where((t) => !t.isFinal)
            .map((t) => t.turnId),
        unconfirmedResponseIds: {
          for (final turn in snapshot.turns)
            if (turn.role == ConversationRole.assistant &&
                turn.playback.status == DeliveryStatus.unknown &&
                turn.frozenPrefix == null &&
                turn.responseId != null)
              turn.responseId!,
        },
        transcriptRejectedCount: text?.rejectedCount ?? 0,
        playbackRejectedCount: output?.rejectedCount ?? 0,
        journalUnavailable: transcripts == null || playback == null,
      );
      _sendCompletionManifest();
    } on Object {
      _completionError = 'completion_unavailable';
    }
  }

  void _sendCompletionManifest() {
    if (_completionManifestSent ||
        _completionManifest == null ||
        _practiceCompletion == null ||
        _completionAborted ||
        !repository.hasCurrentAccount) {
      return;
    }
    try {
      _practiceCompletion!.finish(_completionManifest!);
      _completionManifestSent = true;
    } on Object {
      _completionError = 'completion_unavailable';
    }
  }

  Future<void> retryCompletion() async {
    if (_disposed ||
        _completionAborted ||
        !repository.hasCurrentAccount ||
        !_completionIntentRequested) {
      return;
    }
    _completionError = null;
    _requestCompletionEnd();
    _sendCompletionManifest();
    try {
      await _practiceCompletion?.retryPending();
    } on Object {
      if (!_disposed && repository.hasCurrentAccount) {
        _completionError = 'completion_unavailable';
      }
    }
    if (!_disposed) {
      _completionChanged();
    }
  }

  void _completionChanged() {
    if (_disposed || _completionSettling) return;
    if (!repository.hasCurrentAccount) {
      _abortCompletion();
      return;
    }
    final receipt = _practiceCompletion?.receipt;
    if (receipt != null && !_completionReconciled) {
      _completionSettling = true;
      try {
        if (_conversation == null ||
            !sameCompletionScope(receipt.scope, _conversation!.scope)) {
          throw const FormatException();
        }
        final text = _transcriptJournal;
        if (text is SealedSubmissionReconciler) {
          (text as SealedSubmissionReconciler).reconcileSealed(
            receipt.transcripts,
          );
        }
        if (!repository.hasCurrentAccount) {
          _abortCompletion();
          return;
        }
        final output = _playbackEvidenceJournal;
        if (output is SealedSubmissionReconciler) {
          (output as SealedSubmissionReconciler).reconcileSealed(
            receipt.playback,
          );
        }
        _completionReconciled = true;
      } on Object {
        _completionError = 'completion_unavailable';
      } finally {
        _completionSettling = false;
      }
    }
    if (!_disposed) _publish(_phase);
  }

  void _abortCompletion() {
    if (_completionAborted) return;
    _completionAborted = true;
    _completionManifest = null;
    final client = _practiceCompletion;
    try {
      client?.removeListener(_completionChanged);
      client?.abort();
    } on Object {
      /* A failed observer must not retain account content or media. */
    }
  }

  /// Starts fixed local draining and separately records product-end intent.
  /// It never proves that upstream media has terminated.
  /// Repeated calls share the original operation and monotonic cutoff.
  Future<void> end() {
    if (_ended != null) return _ended!.future;
    _ended = Completer<void>();
    final done = _ended!.future;
    if (!_guard() || _phase != PracticeMediaPhase.active) {
      unawaited(stop(reason: 'ended_without_active'));
      return done;
    }
    final started = _elapsed();
    final configured = started + drainTimeout;
    final lease = _lease.deadline;
    _drainDeadline = lease != null && lease < configured ? lease : configured;
    _lease.stopRenewal();
    _draining = true;
    _phase = PracticeMediaPhase.draining;
    _preparingDrain = true;
    for (final turn in _conversation!.snapshot.turns) {
      _frozenTurns[turn.turnId] = turn;
      if (turn.responseId case final response?) _frozenResponses.add(response);
    }
    _playback = MediaPlayback.idle;
    _completionIntentRequested = practiceCompletionFactory != null;
    _requestCompletionEnd();
    if (!_guard()) return done;
    try {
      _transport!.beginDrain();
      if (!_guard()) return done;
      _protocol!.beginDrain();
      if (!_guard()) return done;
      for (final response in _frozenResponses) {
        if (_outputTailDeadlines.containsKey(response)) continue;
        var knownBoundary = _greatestPlayedUntil[response] ?? 0;
        for (final turn in _frozenTurns.values) {
          if (turn.responseId == response &&
              (turn.playback.playedUntilMs ?? 0) > knownBoundary) {
            knownBoundary = turn.playback.playedUntilMs!;
          }
        }
        _freezeResponse(response, knownBoundary, _confirmedChannel!);
        if (!_guard()) return done;
      }
      _preparingDrain = false;
      final pending = _pendingTail.toList(growable: false);
      _pendingTail.clear();
      _pendingTailBytes = 0;
      for (final (update, channel) in pending) {
        _acceptConversation(update, channel);
        if (!_guard()) return done;
      }
      _drainTimer = Timer(
        _drainDeadline! - _elapsed(),
        () => unawaited(stop(reason: 'tail_unconfirmed')),
      );
      _publish(PracticeMediaPhase.draining);
    } on Object catch (error) {
      unawaited(stop(reason: _code(error)));
    }
    return done;
  }

  /// Releases local resources synchronously; API cleanup is separate evidence.
  Future<void> stop({String reason = 'stopped'}) {
    final completionSnapshot =
        _completionIntentRequested && !_disposed && repository.hasCurrentAccount
        ? _conversation?.snapshot
        : null;
    if (_disposed ||
        !repository.hasCurrentAccount ||
        reason == 'account_changed') {
      _conversation?.clear();
      _greatestPlayedUntil.clear();
      _responsesWithKnownPlayback.clear();
      _abortTranscripts();
      _abortPlaybackEvidence();
      _abortCompletion();
    } else {
      _conversation?.seal();
    }
    if (_closed) {
      if (_ended case final operation? when !operation.isCompleted) {
        operation.complete();
      }
      return _creating ? Future.value() : _cleanup();
    }
    _closed = true;
    _errorCode = _safeCode(reason);
    _lease.stop();
    _setupTimer?.cancel();
    _configurationTimer?.cancel();
    _drainTimer?.cancel();
    _setupDeadline = null;
    _configurationDeadline = null;
    _events.clear();
    _channels.clear();
    _eventBytes = 0;
    _frozenTurns.clear();
    _frozenResponses.clear();
    _greatestPlayedUntil.clear();
    _responsesWithKnownPlayback.clear();
    _drainControls.clear();
    _outputTailDeadlines.clear();
    _outputTailReasons.clear();
    _unknownOutputResponses.clear();
    _confirmedContextResponses.clear();
    _contextCandidate = null;
    _needsContextConfirmation = false;
    _pendingTail.clear();
    _pendingTailBytes = 0;
    _playback = MediaPlayback.idle;
    for (final release in [
      () => _transport?.stop(),
      () => _signaller?.cancel(),
      () => _protocol?.dispose(),
    ]) {
      try {
        release();
      } on Object {
        /* Continue releasing independent resources. */
      }
    }
    _finishObservations(_errorCode!);
    _finishTranscripts();
    _finishPlaybackEvidence();
    if (completionSnapshot != null) {
      _captureCompletion(completionSnapshot, reason);
    }
    _releaseStatus = !_practiceRequested
        ? MediaReleaseStatus.notNeeded
        : _signallingAttempted
        ? MediaReleaseStatus.unconfirmed
        : MediaReleaseStatus.pending;
    _completeBegin();
    _publish(PracticeMediaPhase.localClosed);
    if (_ended case final operation? when !operation.isCompleted) {
      operation.complete();
    }
    return _creating ? Future.value() : _cleanup();
  }

  Future<void> _cleanup() =>
      _cleanupTask ??= Future<void>.microtask(_performCleanup);

  Future<void> _performCleanup() async {
    if (!_practiceRequested) return;
    _releaseStatus = MediaReleaseStatus.unconfirmed;
    if (_signallingAttempted ||
        !repository.hasCurrentAccount ||
        _practice == null ||
        (_connectionRequested && _connection == null)) {
      _publish(_phase);
      return;
    }
    try {
      var connection = _connection;
      if (connection != null) {
        if (connection.canCancel) {
          final target = connection;
          try {
            connection = await repository.cancelConnection(connection);
          } on ApiException catch (error) {
            if (error.code != 'connection_lease_expired') rethrow;
            connection = await repository.loadConnection(
              target.sessionId,
              target.id,
            );
          }
          _connection = connection;
        }
        if (!connection.safelyEnded ||
            connection.terminationStatus != TerminationStatus.notStarted) {
          return;
        }
      }
      _practice = await repository.cancelPractice(_practice!.id);
      if (_practice!.status == PracticeStatus.cancelled) {
        _releaseStatus = MediaReleaseStatus.released;
      }
    } on Object {
      /* No termination claim without a server-confirmed response. */
    } finally {
      _publish(_phase);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) unawaited(stop(reason: 'background'));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _conversation?.clear();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(stop(reason: 'disposed'));
    super.dispose();
  }
}

class _AttemptSignaller implements RealtimeSignaller {
  _AttemptSignaller(
    this.delegate, {
    required this.canUse,
    required this.onOffer,
    required this.onAnswer,
    required this.onFailure,
  });
  final RealtimeSignaller delegate;
  final bool Function() canUse;
  final void Function() onOffer;
  final void Function() onAnswer;
  final void Function(String) onFailure;
  bool _used = false;
  bool _cancelled = false;
  @override
  Future<String> exchangeOffer(String offer) async {
    if (_cancelled || !canUse()) throw const RealtimeFailure('cancelled');
    if (_used) throw const RealtimeFailure('signalling_already_attempted');
    _used = true;
    onOffer();
    try {
      final answer = await delegate.exchangeOffer(offer);
      if (_cancelled || !canUse()) throw const RealtimeFailure('cancelled');
      onAnswer();
      return answer;
    } on Object catch (error) {
      if (!_cancelled) onFailure(PracticeMediaController._code(error));
      rethrow;
    }
  }

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    delegate.cancel();
  }
}
