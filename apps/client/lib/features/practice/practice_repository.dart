import '../../core/api_client.dart';
import '../account/account_models.dart';
import 'connection_observation_models.dart';
import 'practice_models.dart';

/// An immutable account scope; never reuse this repository after an identity change.
class PracticeRepository {
  PracticeRepository(this.api, {required this.accountId});
  final ApiClient api;
  final String accountId;
  bool get hasCurrentAccount => api.hasCurrentAccount(accountId);

  static void _uuid(String value) {
    if (!isPracticeUuid(value)) {
      throw const ApiException('invalid_request', '请求标识无效。');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? key,
  }) => api.request(
    method,
    path,
    body: body,
    accountId: accountId,
    idempotencyKey: key,
  );

  T _read<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) parse,
    bool Function(T) matches,
  ) {
    try {
      final result = parse(data);
      if (!matches(result)) throw const FormatException();
      return result;
    } on Object {
      throw const ApiException('invalid_response', '练习状态响应异常，请确认当前状态。');
    }
  }

  Future<PracticePreparation> createPractice({
    required String key,
    Difficulty? difficulty,
  }) async {
    _uuid(key);
    return _read<PracticePreparation>(
      await _request(
        'POST',
        '/v1/practice-sessions',
        key: key,
        body: {
          'mode': 'free_chat',
          if (difficulty != null) 'difficulty_override': difficulty.name,
        },
      ),
      PracticePreparation.fromJson,
      (_) => true,
    );
  }

  Future<PracticePreparation> loadPractice(String id) => _practice('GET', id);
  Future<PracticeRecovery> loadCurrentPreparation() async =>
      _read<PracticeRecovery>(
        await _request('GET', '/v1/practice-sessions/current'),
        PracticeRecovery.fromJson,
        (_) => true,
      );
  Future<PracticePreparation> cancelPractice(String id) =>
      _practice('POST', id, '/cancel-preparation');

  Future<ConnectionObservationPage> loadConnectionObservations(
    ConnectionReservation connection, {
    int afterSequence = 0,
    int limit = 32,
  }) async {
    if (afterSequence < 0 ||
        afterSequence > 2147483647 ||
        limit < 1 ||
        limit > 32) {
      throw const ApiException('invalid_request', '记录查询范围无效。');
    }
    return _read<ConnectionObservationPage>(
      await _request(
        'GET',
        '/v1/practice-sessions/${connection.sessionId}/connections/${connection.id}/observations?after_sequence=$afterSequence&limit=$limit',
      ),
      (json) => ConnectionObservationPage.fromJson(
        json,
        connection: connection,
        afterSequence: afterSequence,
        limit: limit,
      ),
      (_) => true,
    );
  }

  Future<PracticePreparation> _practice(
    String method,
    String id, [
    String suffix = '',
  ]) async {
    _uuid(id);
    return _read<PracticePreparation>(
      await _request(method, '/v1/practice-sessions/$id$suffix'),
      PracticePreparation.fromJson,
      (p) => p.id == id,
    );
  }

  Future<ConnectionReservation> createConnection(
    PracticePreparation practice, {
    required String key,
    required String clientInstanceId,
  }) async {
    _uuid(key);
    _uuid(clientInstanceId);
    return _read<ConnectionReservation>(
      await _request(
        'POST',
        '/v1/practice-sessions/${practice.id}/connections',
        key: key,
        body: {
          'client_instance_id': clientInstanceId,
          'expected_epoch': practice.connectionEpoch,
        },
      ),
      ConnectionReservation.fromJson,
      (c) =>
          c.sessionId == practice.id &&
          c.clientInstanceId == clientInstanceId &&
          c.epoch == practice.connectionEpoch + 1 &&
          c.configuration.matches(practice.configuration.provider),
    );
  }

  Future<ConnectionReservation> loadConnection(
    String sessionId,
    String connectionId,
  ) async {
    _uuid(sessionId);
    _uuid(connectionId);
    return _read<ConnectionReservation>(
      await _request(
        'GET',
        '/v1/practice-sessions/$sessionId/connections/$connectionId',
      ),
      ConnectionReservation.fromJson,
      (c) => c.sessionId == sessionId && c.id == connectionId,
    );
  }

  Future<ConnectionReservation> renewConnection(
    ConnectionReservation connection,
  ) => _control(connection, 'renew-lease');
  Future<ConnectionReservation> cancelConnection(
    ConnectionReservation connection,
  ) => _control(connection, 'cancel-preparation');
  Future<ConnectionReservation> _control(
    ConnectionReservation original,
    String action,
  ) async => _read<ConnectionReservation>(
    await _request(
      'POST',
      '/v1/practice-sessions/${original.sessionId}/connections/${original.id}/$action',
      body: {
        'client_instance_id': original.clientInstanceId,
        'epoch': original.epoch,
      },
    ),
    ConnectionReservation.fromJson,
    (c) =>
        c.id == original.id &&
        c.sessionId == original.sessionId &&
        c.clientInstanceId == original.clientInstanceId &&
        c.epoch == original.epoch &&
        c.configuration.matches(original.configuration),
  );
}
