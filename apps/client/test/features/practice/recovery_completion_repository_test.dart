import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import 'practice_completion_test.dart' show completionSummary;
import 'practice_fixtures.dart';

const latestClientId = '66666666-6666-4666-8666-666666666666';

void main() {
  late List<http.Request> requests;
  late Map<String, dynamic> summary;
  late Map<String, dynamic> origin;
  late PracticeRepository repository;

  void setup() {
    requests = [];
    summary = {
      ...completionSummary(sealed: true),
      'origin_connection_id': requestKey,
      'client_instance_id': latestClientId,
      'epoch': 2,
      'connection_count': 2,
    };
    origin = {
      ...connectionJson(
        status: 'closed',
        termination: 'not_started',
        instance: latestClientId,
      ),
      'id': requestKey,
      'epoch': 2,
    };
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        requests.add(request);
        return response(
          request.url.path.endsWith('/completion') ? summary : origin,
        );
      }),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    repository = PracticeRepository(api, accountId: accountId);
  }

  test('historical occupied connection verifies latest completion origin independently', () async {
    setup();
    var beforeNext = 0;
    final result = await repository.loadRecoveryCompletion(
      PracticePreparation.fromJson(practiceJson(status: 'completed', epoch: 2)),
      ConnectionReservation.fromJson(
        connectionJson(status: 'unknown', termination: 'unknown'),
      ),
      beforeNextRead: () => beforeNext++,
    );
    expect(result.scope.connectionId, requestKey);
    expect(result.scope.clientInstanceId, latestClientId);
    expect(result.scope.epoch, 2);
    expect(beforeNext, 1);
    expect(requests.map((r) => r.url.path), [
      '/v1/practice-sessions/$practiceId/completion',
      '/v1/practice-sessions/$practiceId/connections/$requestKey',
    ]);
    expect(
      requests.every(
        (r) => r.method == 'GET' && r.headers['X-Account-ID'] == accountId,
      ),
      true,
    );
  });

  test('same epoch completion needs no additional origin read', () async {
    setup();
    summary = completionSummary();
    final result = await repository.loadRecoveryCompletion(
      PracticePreparation.fromJson(practiceJson(epoch: 1)),
      ConnectionReservation.fromJson(connectionJson()),
      beforeNextRead: () => fail('unexpected additional read'),
    );
    expect(result.scope.connectionId, connectionId);
    expect(requests.length, 1);
  });

  test(
    'forged global identities are rejected before any additional HTTP',
    () async {
      for (final change in [
        {'account_id': requestKey},
        {'session_id': requestKey},
        {'epoch': 1},
        {'epoch': 3},
        {'epoch': 2.0},
        {'epoch': true},
        {'origin_connection_id': 'bad'},
        {'client_instance_id': 'bad'},
      ]) {
        setup();
        summary = {...summary, ...change};
        await expectLater(
          repository.loadRecoveryCompletion(
            PracticePreparation.fromJson(
              practiceJson(status: 'completed', epoch: 2),
            ),
            ConnectionReservation.fromJson(connectionJson()),
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
        expect(requests.length, 1, reason: '$change');
      }
    },
  );

  test(
    'origin detail must independently match latest epoch instance and parent',
    () async {
      for (final change in [
        {'epoch': 1},
        {'id': connectionId},
        {'session_id': requestKey},
        {'client_instance_id': clientId},
      ]) {
        setup();
        origin = {...origin, ...change};
        await expectLater(
          repository.loadRecoveryCompletion(
            PracticePreparation.fromJson(
              practiceJson(status: 'completed', epoch: 2),
            ),
            ConnectionReservation.fromJson(connectionJson()),
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
        expect(requests.length, 2, reason: '$change');
      }
    },
  );

  test(
    'deadline or account guard can refuse an extra read after first GET',
    () async {
      setup();
      await expectLater(
        repository.loadRecoveryCompletion(
          PracticePreparation.fromJson(
            practiceJson(status: 'completed', epoch: 2),
          ),
          ConnectionReservation.fromJson(connectionJson()),
          beforeNextRead: () =>
              throw const ApiException('account_changed', 'changed'),
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
      expect(requests.length, 1);
    },
  );

  test('unrelated queried connection is rejected without HTTP', () async {
    setup();
    await expectLater(
      repository.loadRecoveryCompletion(
        PracticePreparation.fromJson(practiceJson(epoch: 2)),
        ConnectionReservation.fromJson({
          ...connectionJson(),
          'session_id': requestKey,
        }),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'invalid_request'),
      ),
    );
    expect(requests, isEmpty);
  });
}
