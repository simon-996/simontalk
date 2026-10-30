import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/review/review_repository.dart';

import 'review_fixtures.dart';

void main() {
  late ApiClient api;
  late ReviewRepository repo;
  late List<http.Request> requests;
  late Map<String, dynamic> Function(http.Request) reply;
  setUp(() {
    requests = [];
    reply = (r) =>
        r.url.path.endsWith('review-input') ? inputJson() : jobJson();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((r) async {
        requests.add(r);
        return response(
          r.url.path.endsWith('csrf') ? {'csrf_token': 'test'} : reply(r),
        );
      }),
    )..expectedAccountId = accountId;
    repo = ReviewRepository(api, accountId: accountId);
  });
  tearDown(() => api.close());
  test(
    'repository sends exact original identity paths bodies and explicit keys',
    () async {
      final binding = await repo.createInput(target(), key: requestKey);
      await repo.readInput(target());
      await repo.createJob(binding, key: requestKey);
      await repo.readJob(binding);
      await repo.retryJob(
        binding,
        jobId: jobId,
        expectedAttempts: 0,
        key: requestKey,
      );
      final actual = requests
          .where((r) => !r.url.path.endsWith('csrf'))
          .toList();
      expect(actual.map((r) => r.method), [
        'POST',
        'GET',
        'POST',
        'GET',
        'POST',
      ]);
      expect(
        actual.map((r) => r.url.path),
        [
          'review-input',
          'review-input',
          'review',
          'review',
          'review/retry',
        ].map((p) => '/v1/practice-sessions/$practiceId/$p'),
      );
      expect(actual.every((r) => r.headers['X-Account-ID'] == accountId), true);
      expect(
        actual
            .where((r) => r.method == 'POST')
            .every(
              (r) =>
                  r.headers['Idempotency-Key'] == requestKey &&
                  r.headers['X-CSRF-Token'] == 'test',
            ),
        true,
      );
      expect(jsonDecode(actual[0].body), {
        'input_revision': 1,
        'input_hash': 'a' * 64,
      });
      expect(jsonDecode(actual[2].body), binding.toJobRequestJson());
      expect(jsonDecode(actual[4].body), {
        'job_id': jobId,
        'expected_attempts': 0,
      });
    },
  );
  test('repository validates outgoing UUID and account before HTTP', () async {
    await expectLater(
      () => repo.createInput(target(), key: 'bad'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'invalid_request'),
      ),
    );
    await expectLater(
      () => repo.retryJob(
        input(),
        jobId: jobId,
        expectedAttempts: 4,
        key: requestKey,
      ),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      () => ReviewRepository(api, accountId: requestKey).readInput(target()),
      throwsA(isA<ApiException>()),
    );
    expect(requests, isEmpty);
  });
  test(
    'invalid wire models become invalid_response and pure reads never get CSRF',
    () async {
      reply = (_) => {'private': 'bad'};
      await expectLater(
        repo.readInput(target()),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
        ),
      );
      await expectLater(
        repo.readJob(input()),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
        ),
      );
      expect(
        requests.every(
          (r) => r.method == 'GET' && !r.url.path.endsWith('csrf'),
        ),
        true,
      );
    },
  );
}
