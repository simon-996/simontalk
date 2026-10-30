import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/practice/termination_check_models.dart';

import 'practice_fixtures.dart';
import 'termination_check_models_test.dart'
    show terminationJson, terminationScope;

void main() {
  test('termination check is one original scope GET without CSRF or body', () async {
    final calls = <http.Request>[];
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        calls.add(request);
        return response(terminationJson(blocked: true));
      }),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    final result = await PracticeRepository(
      api,
      accountId: accountId,
    ).loadTerminationCheck(terminationScope());
    expect(result.status, TerminationCheckStatus.blocked);
    expect(calls.length, 1);
    expect(calls.single.method, 'GET');
    expect(
      calls.single.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/termination-check',
    );
    expect(calls.single.url.hasQuery, false);
    expect(calls.single.body, isEmpty);
    expect(calls.single.headers['X-Account-ID'], accountId);
    expect(calls.single.headers.containsKey('Idempotency-Key'), false);
  });

  test(
    'wrong requested account never issues HTTP and mismatched wire is refused',
    () async {
      var calls = 0;
      Map<String, dynamic> payload = terminationJson();
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          calls++;
          return response(payload);
        }),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final repository = PracticeRepository(api, accountId: accountId);
      await expectLater(
        repository.loadTerminationCheck(
          ConversationScope(
            accountId: requestKey,
            sessionId: practiceId,
            connectionId: connectionId,
            clientInstanceId: clientId,
            epoch: 1,
          ),
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_request'),
        ),
      );
      expect(calls, 0);
      for (final change in [
        {'connection_id': requestKey},
        {'epoch': 2},
        {'attempts': 1},
      ]) {
        payload = {...terminationJson(), ...change};
        await expectLater(
          repository.loadTerminationCheck(terminationScope()),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      }
    },
  );

  test(
    '404 and identity errors remain errors without retrying writes',
    () async {
      var code = 'connection_not_found';
      var status = 404;
      final calls = <http.Request>[];
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          calls.add(request);
          return response({'code': code}, status);
        }),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final repository = PracticeRepository(api, accountId: accountId);
      await expectLater(
        repository.loadTerminationCheck(terminationScope()),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
      );
      code = 'account_changed';
      status = 409;
      await expectLater(
        repository.loadTerminationCheck(terminationScope()),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
      );
      expect(calls.length, 2);
      expect(calls.every((r) => r.method == 'GET'), true);
    },
  );

  test('late old account response cannot become a snapshot', () async {
    final pending = Completer<http.Response>();
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) => pending.future),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    final task = PracticeRepository(
      api,
      accountId: accountId,
    ).loadTerminationCheck(terminationScope());
    api.expectedAccountId = requestKey;
    pending.complete(response(terminationJson()));
    await expectLater(
      task,
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
      ),
    );
  });
}
