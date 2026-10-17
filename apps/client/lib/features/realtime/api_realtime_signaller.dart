import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../practice/practice_models.dart';
import 'realtime_transport.dart';

/// One independent HTTP exchange per reserved attempt. No upstream retry.
class ApiRealtimeSignaller implements RealtimeSignaller {
  factory ApiRealtimeSignaller({
    required ApiClient accountApi,
    required String accountId,
    required String clientInstanceId,
    required ConnectionReservation connection,
    http.Client? client,
    Duration timeout = const Duration(seconds: 12),
  }) {
    if (!connection.canCancel ||
        connection.clientInstanceId != clientInstanceId) {
      throw const RealtimeFailure('connection_identity_changed');
    }
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    return ApiRealtimeSignaller._(
      accountApi.forkForAccount(
        accountId: accountId,
        client: client ?? createHttpClient(),
      ),
      accountId,
      connection,
      timeout,
    );
  }

  ApiRealtimeSignaller._(
    this._api,
    this._accountId,
    this._connection,
    this._timeout,
  );
  final ApiClient _api;
  final String _accountId;
  final ConnectionReservation _connection;
  final Duration _timeout;
  Completer<String>? _result;
  Timer? _timer;
  bool _used = false;
  bool _cancelled = false;
  bool _finished = false;

  static bool _validSdp(Object? value) =>
      value is String &&
      (value.startsWith('v=0\r\n') || value.startsWith('v=0\n')) &&
      !value.contains('\u0000') &&
      utf8.encode(value).length <= 65536;

  @override
  Future<String> exchangeOffer(String offer) {
    if (_cancelled) return Future.error(const RealtimeFailure('cancelled'));
    if (_used) {
      return Future.error(
        const RealtimeFailure('signalling_already_attempted'),
      );
    }
    _used = true;
    final result = _result = Completer<String>();
    if (!_validSdp(offer)) {
      _finish(error: const RealtimeFailure('invalid_offer'));
      return result.future;
    }
    _timer = Timer(
      _timeout,
      () => _finish(error: const RealtimeFailure('signalling_timeout')),
    );
    unawaited(_exchange(offer));
    return result.future;
  }

  Future<void> _exchange(String offer) async {
    try {
      final data = await _api.request(
        'POST',
        '/v1/practice-sessions/${_connection.sessionId}/connections/${_connection.id}/offer',
        accountId: _accountId,
        body: {
          'client_instance_id': _connection.clientInstanceId,
          'epoch': _connection.epoch,
          'offer': offer,
        },
      );
      if (_finished) return;
      final answer = data['answer'];
      if (data['session_id'] != _connection.sessionId ||
          data['connection_id'] != _connection.id ||
          data['client_instance_id'] != _connection.clientInstanceId ||
          data['epoch'] is! int ||
          data['epoch'] != _connection.epoch ||
          !_validSdp(answer)) {
        _finish(error: const RealtimeFailure('invalid_response'));
      } else {
        _finish(answer: answer as String);
      }
    } on ApiException catch (error) {
      _finish(error: RealtimeFailure(error.code));
    } on Object {
      _finish(error: const RealtimeFailure('signalling_failed'));
    }
  }

  void _finish({String? answer, RealtimeFailure? error}) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _api.close();
    final result = _result;
    if (result != null) {
      if (error != null) {
        result.completeError(error);
      } else {
        result.complete(answer!);
      }
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _finish(error: const RealtimeFailure('cancelled'));
  }
}
