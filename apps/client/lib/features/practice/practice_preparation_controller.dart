import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/api_client.dart';
import '../../core/random_uuid.dart';
import '../account/account_models.dart';
import 'practice_models.dart';
import 'practice_repository.dart';

enum PreparationPhase {
  idle,
  preparing,
  reserved,
  releasing,
  uncertain,
  blocked,
  stopped,
}

/// Owns one preparation, before any provider signalling or media starts.
/// A reserved business lease is never evidence of model readiness or billing limits.
class PracticePreparationController extends ChangeNotifier
    with WidgetsBindingObserver {
  PracticePreparationController({
    required this.repository,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _clock() {
    WidgetsBinding.instance.addObserver(this);
  }

  final PracticeRepository repository;
  final Duration Function() _elapsed;
  final String clientInstanceId = randomUuid();
  final String _practiceKey = randomUuid();
  final String _connectionKey = randomUuid();
  PreparationPhase _phase = PreparationPhase.idle;
  PreparationPhase get phase => _phase;
  String? _errorCode;
  String? get errorCode => _errorCode;
  PracticePreparation? _practice;
  PracticePreparation? get practice => _practice;
  ConnectionReservation? _connection;
  ConnectionReservation? get connection => _connection;
  Difficulty? _difficulty;
  Duration? _connectionStarted;
  Duration? _localDeadline;
  bool _practiceRequested = false;
  bool _connectionRequested = false;
  bool _creating = false;
  bool _renewing = false;
  bool _stopping = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _renewTimer;
  Timer? _deadlineTimer;
  Future<void>? _cleanupTask;

  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool _active(int generation) =>
      !_disposed && !_stopping && generation == _generation;
  void _publish(PreparationPhase phase, {String? error}) {
    _phase = phase;
    if (error != null) _errorCode = error;
    if (!_disposed) notifyListeners();
  }

  Future<void> begin({Difficulty? difficulty}) async {
    if (_disposed || _phase != PreparationPhase.idle || _creating) return;
    _difficulty = difficulty;
    await _run();
  }

  /// User initiated retry only; retains creation keys, or retries safe cleanup.
  Future<void> retry() async {
    if (_disposed || _creating || _phase != PreparationPhase.uncertain) {
      return;
    }
    if (_stopping) {
      _cleanupTask = null;
      _creating = true;
      // Reconcile only requests already sent. Never advance to a new connection
      // after stop, and never replace either original idempotency key.
      try {
        if (_practice == null && _practiceRequested) {
          _practice = await repository.createPractice(
            key: _practiceKey,
            difficulty: _difficulty,
          );
        }
        if (_connection == null && _connectionRequested && _practice != null) {
          _connection = await repository.createConnection(
            _practice!,
            key: _connectionKey,
            clientInstanceId: clientInstanceId,
          );
        }
        await _cleanup();
      } on Object catch (error) {
        final code = error is ApiException ? error.code : 'invalid_response';
        _publish(
          ['network_error', 'invalid_response'].contains(code)
              ? PreparationPhase.uncertain
              : PreparationPhase.blocked,
          error: code,
        );
        return;
      } finally {
        _creating = false;
      }
      return;
    }
    await _run();
  }

  Future<void> _run() async {
    final generation = ++_generation;
    _creating = true;
    _errorCode = null;
    _publish(PreparationPhase.preparing);
    try {
      if (!_active(generation)) return;
      if (_practice == null) {
        _practiceRequested = true;
        _practice = await repository.createPractice(
          key: _practiceKey,
          difficulty: _difficulty,
        );
      }
      if (!_active(generation)) {
        await _cleanup();
        return;
      }
      final practice = _practice!;
      if (practice.status != PracticeStatus.created) {
        _publish(PreparationPhase.blocked, error: 'preparation_state_changed');
        return;
      }
      // Retained across an ambiguous create response and an explicit idempotent replay.
      _connectionStarted ??= _elapsed();
      _connectionRequested = true;
      _connection = await repository.createConnection(
        practice,
        key: _connectionKey,
        clientInstanceId: clientInstanceId,
      );
      if (!_active(generation)) {
        await _cleanup();
        return;
      }
      if (!_connection!.canCancel) {
        _publish(PreparationPhase.blocked, error: 'connection_state_changed');
        return;
      }
      if (!_armLease(_connectionStarted!, _connection!, generation)) {
        await stop(reason: 'local_lease_expired');
        // stop defers cleanup while a creation request is pending.
        await _cleanup();
        return;
      }
      _publish(PreparationPhase.reserved);
    } on Object catch (error) {
      if (_stopping || _disposed) {
        await _cleanup();
      } else {
        final code = error is ApiException ? error.code : 'invalid_response';
        _publish(
          ['network_error', 'invalid_response'].contains(code)
              ? PreparationPhase.uncertain
              : PreparationPhase.blocked,
          error: code,
        );
      }
    } finally {
      _creating = false;
      if (_stopping || _disposed) await _cleanup();
    }
  }

  bool _armLease(
    Duration started,
    ConnectionReservation connection,
    int generation,
  ) {
    final remaining = started + connection.leaseDuration - _elapsed();
    if (remaining <= Duration.zero) return false;
    _cancelTimers();
    _localDeadline = started + connection.leaseDuration;
    _deadlineTimer = Timer(remaining, () {
      if (_active(generation)) unawaited(stop(reason: 'local_lease_expired'));
    });
    _renewTimer = Timer(
      const Duration(seconds: 15),
      () => unawaited(_renew(generation)),
    );
    return true;
  }

  Future<void> _renew(int generation) async {
    if (!_active(generation) ||
        _phase != PreparationPhase.reserved ||
        _renewing) {
      return;
    }
    if (_localDeadline == null || _elapsed() >= _localDeadline!) {
      await stop(reason: 'local_lease_expired');
      return;
    }
    _renewing = true;
    final original = _connection!;
    final started = _elapsed();
    try {
      final renewed = await repository.renewConnection(original);
      if (!_active(generation)) return;
      // A delayed event loop may deliver this future before a due watchdog timer.
      if (_elapsed() >= _localDeadline!) {
        await stop(reason: 'local_lease_expired');
        return;
      }
      _connection = renewed;
      if (!renewed.canCancel) {
        _cancelTimers();
        _publish(PreparationPhase.blocked, error: 'connection_state_changed');
        return;
      }
      if (!renewed.lastSeenAt.isAfter(original.lastSeenAt) ||
          !_armLease(started, renewed, generation)) {
        await stop(reason: 'local_lease_expired');
      }
    } on Object catch (error) {
      if (_active(generation)) {
        await stop(
          reason: error is ApiException ? error.code : 'invalid_response',
        );
      }
    } finally {
      _renewing = false;
    }
  }

  void _cancelTimers() {
    _renewTimer?.cancel();
    _deadlineTimer?.cancel();
  }

  /// Only server-confirmed safe cancellation can publish stopped.
  Future<void> stop({String? reason}) async {
    _stopping = true;
    _generation++;
    _cancelTimers();
    if (_phase == PreparationPhase.stopped) return;
    if (reason != null) _errorCode = reason;
    if (_creating) {
      _publish(PreparationPhase.uncertain);
      return;
    }
    await _cleanup();
  }

  Future<void> _cleanup() =>
      _cleanupTask ??= Future<void>.microtask(_performCleanup);

  Future<void> _performCleanup() async {
    _cancelTimers();
    if (!repository.hasCurrentAccount) {
      _publish(PreparationPhase.blocked, error: 'account_changed');
      return;
    }
    final practice = _practice;
    if (practice == null) {
      _publish(
        _practiceRequested
            ? PreparationPhase.uncertain
            : PreparationPhase.stopped,
      );
      return;
    }
    _publish(PreparationPhase.releasing);
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
              practice.id,
              target.id,
            );
          }
          _connection = connection;
        }
        if (!connection.safelyEnded ||
            connection.terminationStatus != TerminationStatus.notStarted) {
          _publish(PreparationPhase.blocked, error: 'connection_state_changed');
          return;
        }
      }
      final cancelled = await repository.cancelPractice(practice.id);
      _practice = cancelled;
      _publish(
        cancelled.status == PracticeStatus.cancelled
            ? PreparationPhase.stopped
            : PreparationPhase.blocked,
      );
    } on Object catch (error) {
      _publish(
        error is ApiException &&
                (error.code == 'account_changed' || error.statusCode == 401)
            ? PreparationPhase.blocked
            : PreparationPhase.uncertain,
        error: error is ApiException ? error.code : 'invalid_response',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(stop(reason: 'background'));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(stop(reason: 'disposed'));
    super.dispose();
  }
}
