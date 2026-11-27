import '../../core/api_client.dart';
import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../conversation/final_transcript_read_models.dart';
import '../conversation/playback_evidence_read_models.dart';
import 'connection_observation_models.dart';
import 'daily_topic.dart';
import 'practice_models.dart';
import 'practice_completion_models.dart';
import 'termination_check_models.dart';

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

  void _completionScope(ConversationScope scope) {
    _uuid(accountId);
    if (scope.accountId != accountId) {
      throw const ApiException('invalid_request', '练习账号范围无效。');
    }
  }

  ConversationScope _completionOrigin(
    ConversationScope member,
    ConversationScope? expected,
  ) {
    final origin = expected ?? member;
    _completionScope(origin);
    if (origin.sessionId != member.sessionId) {
      throw const ApiException('invalid_request', '结束来源范围无效。');
    }
    return origin;
  }

  Future<PracticeCompletionSummary> endPracticeConnection(
    ConversationScope scope, {
    required String key,
  }) async {
    _completionScope(scope);
    _uuid(key);
    return _read(
      await _request(
        'POST',
        '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}/end',
        key: key,
        body: {
          'client_instance_id': scope.clientInstanceId,
          'epoch': scope.epoch,
        },
      ),
      (json) =>
          PracticeCompletionSummary.fromJson(json, scope: scope, endKey: key),
      (_) => true,
    );
  }

  Future<PracticeCompletionSummary> submitPracticeCompletionManifest(
    PracticeCompletionManifest manifest, {
    String? endKey,
    ConversationScope? expectedOriginScope,
  }) async {
    _completionScope(manifest.scope);
    final origin = _completionOrigin(manifest.scope, expectedOriginScope);
    if (endKey != null) _uuid(endKey);
    return _read(
      await _request(
        'POST',
        '/v1/practice-sessions/${manifest.scope.sessionId}/connections/${manifest.scope.connectionId}/completion-manifest',
        body: manifest.toRequestJson(),
      ),
      (json) => PracticeCompletionSummary.fromJson(
        json,
        scope: origin,
        endKey: endKey,
      ),
      (_) => true,
    );
  }

  Future<PracticeCompletionSummary> loadPracticeCompletion(
    ConversationScope scope, {
    String? endKey,
    ConversationScope? expectedOriginScope,
  }) async {
    _completionScope(scope);
    final origin = _completionOrigin(scope, expectedOriginScope);
    if (endKey != null) _uuid(endKey);
    return _read(
      await _request(
        'GET',
        '/v1/practice-sessions/${scope.sessionId}/completion',
      ),
      (json) => PracticeCompletionSummary.fromJson(
        json,
        scope: origin,
        endKey: endKey,
      ),
      (_) => true,
    );
  }

  Future<TerminationCheckSnapshot> loadTerminationCheck(
    ConversationScope scope,
  ) async {
    _completionScope(scope);
    return _read(
      await _request(
        'GET',
        '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}/termination-check',
      ),
      (json) => TerminationCheckSnapshot.fromJson(json, scope: scope),
      (_) => true,
    );
  }

  /// Recovery may show an older occupied connection than the ending origin.
  /// Resolve that origin against its own server connection before publishing.
  Future<PracticeCompletionSummary> loadRecoveryCompletion(
    PracticePreparation practice,
    ConnectionReservation queried, {
    void Function()? beforeNextRead,
  }) async {
    _uuid(accountId);
    if (queried.sessionId != practice.id ||
        queried.epoch > practice.connectionEpoch) {
      throw const ApiException('invalid_request', '练习连接范围无效。');
    }
    final queriedScope = ConversationScope(
      accountId: accountId,
      sessionId: queried.sessionId,
      connectionId: queried.id,
      clientInstanceId: queried.clientInstanceId,
      epoch: queried.epoch,
    );
    final data = await _request(
      'GET',
      '/v1/practice-sessions/${practice.id}/completion',
    );
    var originScope = queriedScope;
    if (queried.epoch < practice.connectionEpoch) {
      final claimed = _read<ConversationScope>(
        data,
        (json) {
          if (json['source'] != 'server_recorded' ||
              json['epoch'] is! int ||
              json['epoch'] != practice.connectionEpoch) {
            throw const FormatException();
          }
          return ConversationScope(
            accountId: json['account_id'] as String,
            sessionId: json['session_id'] as String,
            connectionId: json['origin_connection_id'] as String,
            clientInstanceId: json['client_instance_id'] as String,
            epoch: json['epoch'] as int,
          );
        },
        (scope) =>
            scope.accountId == accountId && scope.sessionId == practice.id,
      );
      beforeNextRead?.call();
      final actual = await loadConnection(practice.id, claimed.connectionId);
      originScope = _read<ConversationScope>(
        data,
        (_) => ConversationScope(
          accountId: accountId,
          sessionId: actual.sessionId,
          connectionId: actual.id,
          clientInstanceId: actual.clientInstanceId,
          epoch: actual.epoch,
        ),
        (scope) => sameCompletionScope(scope, claimed),
      );
    }
    return _read(
      data,
      (json) => PracticeCompletionSummary.fromJson(json, scope: originScope),
      (_) => true,
    );
  }

  Future<PracticeCompletionReceipt> loadPracticeCompletionReceipt(
    ConversationScope scope, {
    required String practiceInputHash,
  }) async {
    _completionScope(scope);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(practiceInputHash)) {
      throw const ApiException('invalid_request', '固化版本无效。');
    }
    return _read(
      await _request(
        'GET',
        '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}/completion-receipt',
      ),
      (json) => PracticeCompletionReceipt.fromJson(
        json,
        scope: scope,
        practiceInputHash: practiceInputHash,
      ),
      (_) => true,
    );
  }

  Future<PracticePreparation> createPractice({
    required String key,
    Difficulty? difficulty,
    DailyTopic? topic,
  }) async {
    _uuid(key);
    return _read<PracticePreparation>(
      await _request(
        'POST',
        '/v1/practice-sessions',
        key: key,
        body: {
          'mode': topic == null ? 'free_chat' : 'daily_topic',
          if (topic != null) 'topic_id': topic.id,
          if (difficulty != null) 'difficulty_override': difficulty.name,
        },
      ),
      PracticePreparation.fromJson,
      (practice) =>
          practice.kind == 'ordinary' &&
          practice.configuration.topic?.id == topic?.id,
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

  Future<PracticePreparation> discardPreparation(
    PracticePreparation original,
  ) async => _read<PracticePreparation>(
    await _request(
      'POST',
      '/v1/practice-sessions/${original.id}/discard-preparation',
      body: {'expected_epoch': original.connectionEpoch},
    ),
    PracticePreparation.fromJson,
    (p) =>
        p.id == original.id &&
        p.kind == original.kind &&
        p.sourceSessionId == original.sourceSessionId &&
        p.sourceReviewItemId == original.sourceReviewItemId &&
        p.connectionEpoch == original.connectionEpoch &&
        p.status == PracticeStatus.cancelled &&
        p.endedAt != null &&
        !p.endedAt!.isBefore(p.createdAt) &&
        p.createdAt == original.createdAt &&
        p.configuration.provider.matches(original.configuration.provider) &&
        p.configuration.effectiveDifficulty ==
            original.configuration.effectiveDifficulty &&
        p.configuration.preferences.version ==
            original.configuration.preferences.version &&
        p.configuration.preferences.sameValues(
          original.configuration.preferences,
        ),
  );

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

  Future<PlaybackEvidencePage> loadPlaybackEvidence(
    ConnectionReservation connection, {
    int afterSequence = 0,
    int limit = 16,
  }) async {
    _uuid(accountId);
    if (afterSequence < 0 ||
        afterSequence > 2147483647 ||
        limit < 1 ||
        limit > 16) {
      throw const ApiException('invalid_request', '播放依据查询范围无效。');
    }
    final scope = ConversationScope(
      accountId: accountId,
      sessionId: connection.sessionId,
      connectionId: connection.id,
      clientInstanceId: connection.clientInstanceId,
      epoch: connection.epoch,
    );
    return _read<PlaybackEvidencePage>(
      await _request(
        'GET',
        '/v1/practice-sessions/${connection.sessionId}/connections/${connection.id}/playback-evidence?after_sequence=$afterSequence&limit=$limit',
      ),
      (json) => PlaybackEvidencePage.fromJson(
        json,
        scope: scope,
        afterSequence: afterSequence,
        limit: limit,
      ),
      (_) => true,
    );
  }

  Future<FinalTranscriptPage> loadFinalTranscripts(
    ConnectionReservation connection, {
    int afterSequence = 0,
    int limit = 32,
  }) async {
    _uuid(accountId);
    if (afterSequence < 0 ||
        afterSequence > 2147483647 ||
        limit < 1 ||
        limit > 32) {
      throw const ApiException('invalid_request', '文字查询范围无效。');
    }
    final scope = ConversationScope(
      accountId: accountId,
      sessionId: connection.sessionId,
      connectionId: connection.id,
      clientInstanceId: connection.clientInstanceId,
      epoch: connection.epoch,
    );
    return _read<FinalTranscriptPage>(
      await _request(
        'GET',
        '/v1/practice-sessions/${connection.sessionId}/connections/${connection.id}/transcripts?after_sequence=$afterSequence&limit=$limit',
      ),
      (json) => FinalTranscriptPage.fromJson(
        json,
        scope: scope,
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
