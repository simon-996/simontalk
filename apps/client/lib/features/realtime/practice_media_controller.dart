import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../core/api_client.dart';
import '../../core/random_uuid.dart';
import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../conversation/conversation_projection.dart';
import '../practice/practice_models.dart';
import '../practice/practice_repository.dart';
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
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _clock() {
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
  String? _errorCode;
  String? get errorCode => _errorCode;
  String? _lastObservationCode;
  String? get lastObservationCode => _lastObservationCode;
  RealtimeObservationJournal? _observationJournal;
  String? _observationError;
  RealtimeObservationJournal? get observationJournal => _observationJournal;
  String? get observationErrorCode =>
      _observationError ?? _observationJournal?.errorCode;
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
      : 'connection_failed';

  void _publish(PracticeMediaPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  bool _guard() {
    if (_closed || _disposed) return false;
    final elapsed = _elapsed();
    final reason = !repository.hasCurrentAccount
        ? 'account_changed'
        : !_foreground
        ? 'background'
        : _configurationDeadline != null && elapsed >= _configurationDeadline!
        ? 'configuration_timeout'
        : _setupDeadline != null && elapsed >= _setupDeadline!
        ? 'connection_timeout'
        : _lease.expired
        ? 'local_lease_expired'
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
    _lastObservationCode = _safeCode(observation.code);
    if (observation.code == 'local_closed') {
      unawaited(stop(reason: _safeCode(observation.detail)));
      return;
    }
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
    if (!_transportReady ||
        channelId != _confirmedChannel ||
        !_channels.contains(channelId) ||
        _conversation == null) {
      unawaited(stop(reason: 'conversation_invalid'));
      return;
    }
    try {
      final result = _conversation!.apply(update);
      if (result == ConversationApplyResult.closed) {
        unawaited(stop(reason: 'conversation_closed'));
      } else if (result == ConversationApplyResult.applied && _guard()) {
        _publish(_phase);
      }
    } on ConversationFailure catch (error) {
      unawaited(stop(reason: error.code));
    } on Object {
      unawaited(stop(reason: 'conversation_invalid'));
    }
  }

  void _send(String json, String channelId) {
    if (!_guard()) return;
    if (!_transportReady || !_channels.contains(channelId)) {
      unawaited(stop(reason: 'invalid_channel'));
      return;
    }
    _protocolCall(() => _transport!.send(json, channelId));
  }

  void _confirmConfigured(String channelId) {
    if (!_guard()) return;
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
    if (!_guard() || _renewing || _connection == null) return;
    _renewing = true;
    final original = _connection!;
    final started = _elapsed();
    try {
      final renewed = await repository.renewConnection(original);
      if (!_guard()) return;
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
      if (!_closed) await stop(reason: _code(error));
    } finally {
      _renewing = false;
    }
  }

  void setMuted(bool value) {
    if (!_guard()) return;
    final changed = _muted != value;
    _muted = value;
    _protocolCall(() => _transport?.setMuted(value));
    if (changed && _guard()) _recordObservation(value ? 'muted' : 'unmuted');
    if (_guard()) _publish(_phase);
  }

  Future<void> resumePlayback() async {
    if (!_guard() || _phase != PracticeMediaPhase.active) return;
    try {
      await _transport!.resumePlayback();
    } on RealtimeFailure catch (error) {
      if (!_guard()) return;
      if (error.code == 'playback_blocked' ||
          error.code == 'playback_waiting') {
        _playback = error.code == 'playback_blocked'
            ? MediaPlayback.blocked
            : MediaPlayback.waiting;
        _publish(_phase);
      } else {
        await stop(reason: _code(error));
      }
    } on Object catch (error) {
      if (!_closed) await stop(reason: _code(error));
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

  /// Releases local resources synchronously; API cleanup is separate evidence.
  Future<void> stop({String reason = 'stopped'}) {
    if (_disposed ||
        !repository.hasCurrentAccount ||
        reason == 'account_changed') {
      _conversation?.clear();
    } else {
      _conversation?.seal();
    }
    if (_closed) return _creating ? Future.value() : _cleanup();
    _closed = true;
    _errorCode = _safeCode(reason);
    _lease.stop();
    _setupTimer?.cancel();
    _configurationTimer?.cancel();
    _setupDeadline = null;
    _configurationDeadline = null;
    _events.clear();
    _channels.clear();
    _eventBytes = 0;
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
    _releaseStatus = !_practiceRequested
        ? MediaReleaseStatus.notNeeded
        : _signallingAttempted
        ? MediaReleaseStatus.unconfirmed
        : MediaReleaseStatus.pending;
    _completeBegin();
    _publish(PracticeMediaPhase.localClosed);
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
