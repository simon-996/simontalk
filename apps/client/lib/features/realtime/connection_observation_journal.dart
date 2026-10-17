import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import '../practice/practice_models.dart';

abstract interface class RealtimeObservationJournal {
  int get pendingCount;
  int get droppedCount;
  String? get errorCode;
  void record(String code, {String? reason});
  Future<void> retryPending();
  void finish();
  void abort();
}

typedef ObservationJournalFactory = RealtimeObservationJournal Function(
  ConnectionReservation connection,
  String clientInstanceId,
);

typedef ObservationJournalCreator = RealtimeObservationJournal Function(
  ApiClient accountApi,
  String accountId,
  ConnectionReservation connection,
  String clientInstanceId,
);

/// Untrusted local facts, never a connection lease or upstream termination claim.
class ConnectionObservationJournal implements RealtimeObservationJournal {
  ConnectionObservationJournal({
    required ApiClient accountApi,
    required this._accountId,
    required ConnectionReservation connection,
    required String clientInstanceId,
    http.Client Function()? clientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _connection = connection,
       _clientFactory = clientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock() {
    if (connection.clientInstanceId != clientInstanceId) {
      throw ArgumentError('Observation ownership does not match connection');
    }
    _origin = _elapsed();
  }

  static const codes = {
    'requesting_microphone',
    'negotiating',
    'transport_connected',
    'configuration_confirmed',
    'microphone_active',
    'playback_waiting',
    'playback_blocked',
    'playback_playing',
    'playback_paused',
    'muted',
    'unmuted',
    'local_closed',
  };
  static const _reasons = {
    'user_stop',
    'background',
    'disposed',
    'account_changed',
    'lease_expired',
    'connection_failed',
    'configuration_failed',
    'other',
  };
  final ApiClient _source;
  final String _accountId;
  final ConnectionReservation _connection;
  final http.Client Function() _clientFactory;
  final Duration Function() _elapsed;
  late final Duration _origin;
  final _queue = <Map<String, Object>>[];
  final _inFlight = <String>{};
  int _sequence = 0;
  int _dropped = 0;
  String? _error;
  bool _paused = false;
  bool _finished = false;
  bool _disposed = false;
  Future<void>? _task;
  ApiClient? _activeApi;
  void Function()? _cancelBatch;

  @override
  int get pendingCount => _queue.length;
  @override
  int get droppedCount => _dropped;
  @override
  String? get errorCode => _error;

  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  static String closeReason(String? value) {
    if (_reasons.contains(value)) return value!;
    return switch (value) {
      'stopped' => 'user_stop',
      'local_lease_expired' => 'lease_expired',
      'configuration_timeout' ||
      'protocol_failed' ||
      'invalid_channel' ||
      'invalid_transport_state' ||
      'event_buffer_full' => 'configuration_failed',
      'network_error' ||
      'connection_timeout' ||
      'connection_lost' ||
      'signalling_failed' ||
      'signalling_timeout' ||
      'device_lost' ||
      'event_channel_failed' ||
      'event_channel_closed' => 'connection_failed',
      _ => 'other',
    };
  }

  @override
  void record(String code, {String? reason}) {
    if (_finished || _disposed) return;
    if (!codes.contains(code) || _sequence == 2147483647) {
      _dropped++;
      return;
    }
    final sequence = ++_sequence;
    if (_queue.length >= 64) {
      final replace = code == 'local_closed'
          ? _queue.lastIndexWhere((e) => !_inFlight.contains(e['event_id']))
          : -1;
      _dropped++;
      if (replace < 0) return;
      _queue.removeAt(replace);
    }
    _queue.add(
      Map.unmodifiable({
        'event_id': randomUuid(),
        'sequence': sequence,
        'code': code,
        'elapsed_ms': (_elapsed() - _origin).inMilliseconds
            .clamp(0, 86400000)
            .toInt(),
        if (code == 'local_closed') 'reason': closeReason(reason),
      }),
    );
    _schedule();
  }

  void _schedule() {
    if (_disposed || _paused || _queue.isEmpty || _task != null) return;
    _task = Future<void>.microtask(_drain);
  }

  @override
  Future<void> retryPending() {
    if (_disposed) return Future.value();
    if (_task != null) return _task!;
    _paused = false;
    _error = null;
    _schedule();
    return _task ?? Future.value();
  }

  void _loseAccount([String code = 'account_changed']) {
    _error = code;
    abort();
  }

  Future<void> _drain() async {
    try {
      while (!_disposed && !_paused && _queue.isNotEmpty) {
        if (!_source.hasCurrentAccount(_accountId)) {
          _loseAccount();
          return;
        }
        final batch = _queue.take(16).toList(growable: false);
        _inFlight.addAll(batch.map((e) => e['event_id'] as String));
        try {
          final data = await _exchange(batch);
          if (_disposed) return;
          if (!_source.hasCurrentAccount(_accountId)) {
            _loseAccount();
            return;
          }
          if (!_validAcknowledgement(data, batch)) {
            throw const ApiException('invalid_response', '观测确认响应异常。');
          }
          _queue.removeWhere((e) => _inFlight.contains(e['event_id']));
          _error = null;
        } on Object catch (error) {
          if (_disposed) return;
          if (!_source.hasCurrentAccount(_accountId) ||
              (error is ApiException && error.code == 'account_changed')) {
            _loseAccount();
          } else if (error is ApiException && error.code == 'unauthorized') {
            _loseAccount('unauthorized');
          } else {
            _paused = true;
            _error = _errorCode(error);
          }
        } finally {
          _inFlight.clear();
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
      accountId: _accountId,
      client: _clientFactory(),
    );
    final remaining = cutoff - _elapsed();
    if (_disposed || remaining <= Duration.zero) {
      _activeApi = null;
      api.close();
      throw ApiException(
        _disposed ? 'cancelled' : 'observation_timeout',
        '观测上报已停止。',
      );
    }
    final cancelled = Completer<Map<String, dynamic>>();
    final deadline = Completer<Map<String, dynamic>>();
    _cancelBatch = () {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const ApiException('cancelled', '观测上报已停止。'));
      }
    };
    final timer = Timer(remaining, () {
      deadline.completeError(
        const ApiException('observation_timeout', '观测上报超时。'),
      );
    });
    try {
      final result = await Future.any([
        api.request(
          'POST',
          '/v1/practice-sessions/${_connection.sessionId}/connections/${_connection.id}/observations',
          accountId: _accountId,
          body: {
            'client_instance_id': _connection.clientInstanceId,
            'epoch': _connection.epoch,
            'events': batch,
          },
        ),
        cancelled.future,
        deadline.future,
      ]);
      if (_elapsed() >= cutoff) {
        throw const ApiException('observation_timeout', '观测上报超时。');
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
  ) {
    final ids = data['acknowledged_event_ids'];
    final last = data['last_sequence'];
    final total = data['total_events'];
    return data['source'] == 'client_observed' &&
        data['connection_id'] == _connection.id &&
        data['client_instance_id'] == _connection.clientInstanceId &&
        data['epoch'] is int &&
        data['epoch'] == _connection.epoch &&
        last is int &&
        last >= (batch.last['sequence'] as int) &&
        last <= 2147483647 &&
        total is int &&
        total >= batch.length &&
        total <= 256 &&
        total <= last &&
        ids is List &&
        ids.length == batch.length &&
        List.generate(
          batch.length,
          (i) => ids[i] == batch[i]['event_id'],
        ).every((v) => v);
  }

  static String _errorCode(Object error) {
    const known = {
      'network_error',
      'observation_timeout',
      'observation_conflict',
      'observation_sequence_stale',
      'observation_limit_reached',
      'invalid_response',
      'csrf_invalid',
    };
    return error is ApiException && known.contains(error.code)
        ? error.code
        : 'observation_failed';
  }

  @override
  void finish() {
    _finished = true;
    _schedule();
  }

  @override
  void abort() {
    if (_disposed) return;
    _disposed = true;
    _cancelBatch?.call();
    _activeApi?.close();
    _queue.clear();
  }
}
