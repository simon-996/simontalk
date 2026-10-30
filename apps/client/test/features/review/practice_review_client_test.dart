import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/review/review_models.dart';
import 'package:simontalk_client/features/review/practice_review_client.dart';

import '../realtime/api_realtime_signaller_test.dart'
    show TrackedClient, StreamingAbortClient;
import 'review_fixtures.dart';

void main() {
  late ApiClient api;
  late PracticeReviewClient client;
  late List<http.Request> requests;
  late List<TrackedClient> owned;
  late Future<http.Response> Function(http.Request) handler;
  Future<http.Response> Function()? csrf;
  void setup({
    Duration Function()? elapsed,
    bool web = false,
    http.Client Function()? factory,
  }) {
    requests = [];
    owned = [];
    csrf = null;
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: web,
      tokenStore: TestTokenStore(),
      client: TrackedClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (r) async =>
        response(r.url.path.endsWith('review-input') ? inputJson() : jobJson());
    client = PracticeReviewClient(
      accountApi: api,
      target: target(),
      elapsed: elapsed,
      httpClientFactory:
          factory ??
          () {
            final c = TrackedClient((r) async {
              requests.add(r);
              if (r.url.path.endsWith('csrf')) {
                return csrf != null
                    ? csrf!()
                    : response({'csrf_token': 'test'});
              }
              return handler(r);
            });
            owned.add(c);
            return c;
          },
    );
    addTearDown(client.dispose);
    addTearDown(api.close);
  }

  test(
    'construction is silent and request writes input then one job',
    () async {
      setup();
      expect(requests, isEmpty);
      await client.requestReview();
      expect(requests.map((r) => r.method), ['POST', 'POST']);
      expect(client.job!.status, ReviewJobStatus.blocked);
      expect(client.hasPendingAction, false);
      expect(owned.single.closes, 1);
      await client.requestReview();
      expect(requests.length, 2);
    },
  );
  test(
    'refresh is only GET and missing objects never synthesize feedback',
    () async {
      setup();
      handler = (r) async => response({'code': 'review_input_not_found'}, 404);
      await client.refresh();
      expect(client.state, PracticeReviewClientState.notCreated);
      expect(client.job, isNull);
      expect(requests.single.method, 'GET');
      handler = (r) async => r.url.path.endsWith('review-input')
          ? response(inputJson())
          : response({'code': 'review_job_not_found'}, 404);
      await client.refresh();
      expect(client.state, PracticeReviewClientState.notCreated);
      expect(client.input, isNotNull);
      expect(client.job, isNull);
      expect(requests.every((r) => r.method == 'GET'), true);
    },
  );
  test('network error and invalid response retain exact action through read refresh', () async {
    setup();
    handler = (_) async => throw http.ClientException('private');
    await client.requestReview();
    final first = requests.single;
    expect(client.hasPendingAction, true);
    expect(client.errorCode, 'network_error');
    handler = (r) async => response({'code': 'review_input_not_found'}, 404);
    await client.refresh();
    expect(client.hasPendingAction, true);
    handler = (r) async => response(
      r.url.path.endsWith('review-input') ? inputJson() : {'bad': 'response'},
    );
    await client.retryPending();
    expect(requests[2].body, first.body);
    expect(
      requests[2].headers['Idempotency-Key'],
      first.headers['Idempotency-Key'],
    );
    final pending = requests.last;
    expect(client.errorCode, 'invalid_response');
    expect(client.hasPendingAction, true);
    handler = (r) async =>
        response(r.url.path.endsWith('review-input') ? inputJson() : jobJson());
    await client.retryPending();
    expect(requests.last.body, pending.body);
    expect(
      requests.last.headers['Idempotency-Key'],
      pending.headers['Idempotency-Key'],
    );
    expect(client.hasPendingAction, false);
  });
  test(
    'duplicate clicks share one operation and never queue a second write',
    () async {
      setup();
      final wait = Completer<http.Response>();
      handler = (_) => wait.future;
      final one = client.requestReview(),
          two = client.requestReview(),
          three = client.retryPending(),
          four = client.refresh();
      expect(identical(one, two), true);
      expect(identical(one, three), true);
      expect(identical(one, four), true);
      await Future<void>.delayed(Duration.zero);
      expect(requests.length, 1);
      handler = (r) async => response(jobJson());
      wait.complete(response(inputJson()));
      await one;
      expect(requests.length, 2);
    },
  );
  test('generation retry gate allows only explicit known bounded failed or blocked', () async {
    setup();
    await client.retryGeneration();
    expect(requests, isEmpty);
    for (final state in [
      'queued',
      'running',
      'retry_wait',
      'succeeded',
      'no_suggestions',
      'no_evaluable_content',
      'invalidated',
      'failed',
      'blocked',
    ]) {
      final empty = state == 'no_evaluable_content';
      handler = (r) async => response(
        r.url.path.endsWith('review-input')
            ? inputJson(empty: empty)
            : jobJson(
                status: state,
                unknown: [
                  'queued',
                  'running',
                  'retry_wait',
                  'failed',
                  'blocked',
                ].contains(state),
              ),
      );
      // New client isolates immutable identity anchors between independent cases.
      client.dispose();
      client = PracticeReviewClient(
        accountApi: api,
        target: target(),
        httpClientFactory: () => TrackedClient((r) async {
          requests.add(r);
          return handler(r);
        }),
      );
      await client.refresh();
      final count = requests.length;
      await client.retryGeneration();
      expect(requests.length, count, reason: state);
    }
  });
  test(
    'retry generation freezes job and expected attempts and replays same key',
    () async {
      setup();
      await client.refresh();
      handler = (_) async => throw http.ClientException('private');
      await client.retryGeneration();
      final retry = requests.last;
      expect(jsonDecode(retry.body), {'job_id': jobId, 'expected_attempts': 0});
      await client.retryGeneration();
      expect(
        requests.last.headers['Idempotency-Key'],
        retry.headers['Idempotency-Key'],
      );
      handler = (_) async => response(jobJson(status: 'queued'));
      await client.retryPending();
      expect(requests.last.body, retry.body);
      expect(
        requests.last.headers['Idempotency-Key'],
        retry.headers['Idempotency-Key'],
      );
      expect(client.hasPendingAction, false);
    },
  );
  test(
    'creation keeps its first key across uncertain input and later job POST',
    () async {
      setup();
      handler = (_) async => throw http.ClientException('private');
      await client.requestReview();
      final key = requests.single.headers['Idempotency-Key'];
      handler = (r) async => response(
        r.url.path.endsWith('review-input') ? inputJson() : jobJson(),
      );
      await client.retryPending();
      expect(
        requests
            .where((r) => r.method == 'POST')
            .every((r) => r.headers['Idempotency-Key'] == key),
        true,
      );
    },
  );
  test(
    'server invalidated job clears prior successful anchors and content',
    () async {
      setup();
      handler = (r) async => response(
        r.url.path.endsWith('review-input')
            ? inputJson()
            : jobJson(status: 'succeeded'),
      );
      await client.refresh();
      handler = (r) async => response(
        r.url.path.endsWith('review-input')
            ? inputJson()
            : jobJson(status: 'invalidated', attempts: 1),
      );
      await client.refresh();
      expect(client.state, PracticeReviewClientState.aborted);
      expect(client.job, isNull);
      expect(client.hasPendingAction, false);
    },
  );
  test('definite retry conflict releases action and needs read before new explicit retry', () async {
    for (final code in ['review_retry_changed', 'idempotency_conflict']) {
      setup();
      await client.refresh();
      handler = (_) async => response({'code': code}, 409);
      await client.retryGeneration();
      final rejected = requests.last;
      expect(client.hasPendingAction, false);
      expect(client.job, isNull);
      final count = requests.length;
      await client.retryPending();
      await client.retryGeneration();
      expect(requests.length, count);
      handler = (r) async => response(
        r.url.path.endsWith('review-input')
            ? inputJson()
            : jobJson(status: 'failed', attempts: 1),
      );
      await client.refresh();
      await client.retryGeneration();
      expect(
        requests.last.headers['Idempotency-Key'],
        isNot(rejected.headers['Idempotency-Key']),
      );
      expect(jsonDecode(requests.last.body), {
        'job_id': jobId,
        'expected_attempts': 1,
      });
    }
  });
  test(
    'initial create conflict requires a completed read before any new action',
    () async {
      setup();
      handler = (_) async => response({'code': 'idempotency_conflict'}, 409);
      await client.requestReview();
      expect(client.hasPendingAction, false);
      final count = requests.length;
      await client.requestReview();
      await client.retryPending();
      await client.retryGeneration();
      expect(requests.length, count);
      handler = (_) async => throw http.ClientException('private');
      await client.refresh();
      final failedReadCount = requests.length;
      await client.requestReview();
      expect(requests.length, failedReadCount);
      handler = (_) async => response({'code': 'review_input_not_found'}, 404);
      await client.refresh();
      handler = (r) async => response(
        r.url.path.endsWith('review-input') ? inputJson() : jobJson(),
      );
      await client.requestReview();
      expect(client.job, isNotNull);
    },
  );
  test('pending retry confirms original action after refresh observes unknown and a higher count', () async {
    setup();
    await client.refresh();
    handler = (_) async => throw http.ClientException('private');
    await client.retryGeneration();
    final original = requests.last;
    handler = (r) async => response(
      r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(status: 'failed', attempts: 3, unknown: true),
    );
    await client.refresh();
    expect(client.hasPendingAction, true);
    expect(client.canRetryGeneration, false);
    final count = requests.length;
    await client.retryGeneration();
    expect(requests.length, count);
    await client.retryPending();
    expect(requests.last.body, original.body);
    expect(
      requests.last.headers['Idempotency-Key'],
      original.headers['Idempotency-Key'],
    );
    expect(client.hasPendingAction, false);
  });
  test('exhausted known failed state cannot create a new retry', () async {
    setup();
    handler = (r) async => response(
      r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(status: 'failed', attempts: 3),
    );
    await client.refresh();
    final count = requests.length;
    await client.retryGeneration();
    expect(requests.length, count);
  });
  test(
    'CSRF failure retains pending action and same identity for explicit replay',
    () async {
      setup(web: true);
      handler = (_) async => response({'code': 'csrf_invalid'}, 403);
      await client.requestReview();
      final original = requests.last;
      expect(client.errorCode, 'csrf_invalid');
      expect(client.hasPendingAction, true);
      expect(api.hasCurrentAccount(accountId), true);
      handler = (r) async => response(
        r.url.path.endsWith('review-input') ? inputJson() : jobJson(),
      );
      await client.retryPending();
      final replay = requests
          .where((r) => r.url.path.endsWith('review-input'))
          .last;
      expect(replay.body, original.body);
      expect(
        replay.headers['Idempotency-Key'],
        original.headers['Idempotency-Key'],
      );
      expect(client.job, isNotNull);
    },
  );
  testWidgets('one deadline includes both POST steps after slow CSRF', (
    tester,
  ) async {
    final origin = tester.binding.clock.now();
    setup(
      web: true,
      elapsed: () => tester.binding.clock.now().difference(origin),
    );
    final csrfWait = Completer<http.Response>(),
        inputWait = Completer<http.Response>();
    csrf = () => csrfWait.future;
    handler = (_) => inputWait.future;
    final task = client.requestReview();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    csrfWait.complete(response({'csrf_token': 'test'}));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    inputWait.complete(response(inputJson()));
    final jobWait = Completer<http.Response>();
    handler = (_) => jobWait.future;
    await tester.pump();
    expect(requests.last.url.path.endsWith('/review'), true);
    await tester.pump(const Duration(seconds: 1));
    await task;
    expect(client.errorCode, 'review_timeout');
    expect(owned.single.closes, 1);
    expect(client.hasPendingAction, true);
    jobWait.complete(response(jobJson()));
    await tester.pump();
    expect(client.job, isNull);
  });
  test('refresh removes visible old success and retains immutable identity anchors', () async {
    setup();
    handler = (r) async => response(
      r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(status: 'succeeded'),
    );
    await client.refresh();
    expect(client.job!.result!.items.length, 1);
    final wait = Completer<http.Response>();
    handler = (_) => wait.future;
    final refresh = client.refresh();
    expect(client.job, isNull);
    expect(client.input, isNull);
    await Future<void>.delayed(Duration.zero);
    wait.completeError(http.ClientException('private'));
    await refresh;
    expect(client.job, isNull);
    for (final change in <Map<String, dynamic>>[
      {'id': requestKey},
      {'attempt_count': 0},
      {'status': 'blocked', 'result': null},
      {
        'result': {...resultJson(), 'result_hash': 'd' * 64},
      },
      {
        'result': {
          ...resultJson(),
          'items': [
            {...itemJson(), 'id': requestKey},
          ],
        },
      },
    ]) {
      handler = (r) async => response(
        r.url.path.endsWith('review-input')
            ? inputJson()
            : {...jobJson(status: 'succeeded'), ...change},
      );
      await client.refresh();
      expect(client.errorCode, 'invalid_response');
      expect(client.job, isNull);
    }
  });
  test('anchors reject input hash changes and decreasing attempts without keeping text', () async {
    setup();
    handler = (r) async => response(
      r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(status: 'failed', attempts: 2),
    );
    await client.refresh();
    handler = (r) async => response(
      r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(status: 'failed', attempts: 1),
    );
    await client.refresh();
    expect(client.errorCode, 'invalid_response');
    handler = (r) async =>
        response({...inputJson(), 'review_input_hash': 'd' * 64});
    await client.refresh();
    expect(client.errorCode, 'review_input_changed');
    expect(client.state, PracticeReviewClientState.aborted);
    expect(client.hasPendingAction, false);
    expect(client.input, isNull);
  });
  test(
    'source invalidation auth and account errors abort pending content',
    () async {
      for (final code in [
        'unauthorized',
        'account_changed',
        'practice_not_found',
        'review_input_changed',
        'review_input_invalid',
        'review_result_invalid',
        'completion_not_found',
        'completion_not_sealed',
      ]) {
        setup();
        handler = (_) async => throw http.ClientException('private');
        await client.requestReview();
        handler = (_) async => response(
          {'code': code},
          code == 'unauthorized'
              ? 401
              : code.endsWith('not_found')
              ? 404
              : 409,
        );
        await client.refresh();
        expect(client.state, PracticeReviewClientState.aborted, reason: code);
        expect(client.hasPendingAction, false);
        expect(client.job, isNull);
      }
    },
  );
  testWidgets('total eight second budget spans CSRF and both writes', (
    tester,
  ) async {
    final origin = tester.binding.clock.now();
    setup(
      web: true,
      elapsed: () => tester.binding.clock.now().difference(origin),
    );
    final wait = Completer<http.Response>();
    csrf = () => wait.future;
    final task = client.requestReview();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await task;
    expect(client.errorCode, 'review_timeout');
    expect(client.hasPendingAction, true);
    expect(owned.single.closes, 1);
    wait.complete(response({'csrf_token': 'late'}));
    await tester.pump();
    expect(requests.length, 1);
  });
  testWidgets(
    'multi step cutoff prevents dispatch after input consumes budget',
    (tester) async {
      var elapsed = Duration.zero;
      setup(elapsed: () => elapsed);
      handler = (r) async {
        elapsed = const Duration(seconds: 8);
        return response(inputJson());
      };
      await client.requestReview();
      expect(requests.length, 1);
      expect(client.errorCode, 'review_timeout');
      expect(client.hasPendingAction, true);
    },
  );
  test('account switch getter clears immediately and old late response cannot start next request', () async {
    setup();
    final wait = Completer<http.Response>();
    handler = (_) => wait.future;
    final task = client.requestReview();
    await Future<void>.delayed(Duration.zero);
    api.expectedAccountId = requestKey;
    expect(client.job, isNull);
    expect(client.input, isNull);
    expect(client.hasPendingAction, false);
    await task;
    wait.complete(response(inputJson()));
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 1);
    expect(client.errorCode, 'account_changed');
  });
  test('dispose settles unfinished request and ignores late result', () async {
    setup();
    final wait = Completer<http.Response>();
    handler = (_) => wait.future;
    final task = client.requestReview();
    await Future<void>.delayed(Duration.zero);
    client.dispose();
    await task;
    expect(owned.single.closes, 1);
    wait.complete(response(inputJson()));
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 1);
    expect(client.job, isNull);
  });
  testWidgets('timeout cancels unfinished response body', (tester) async {
    final stream = StreamingAbortClient(false);
    final origin = tester.binding.clock.now();
    setup(
      factory: () => stream,
      elapsed: () => tester.binding.clock.now().difference(origin),
    );
    final task = client.requestReview();
    await tester.pump();
    expect(stream.reading, true);
    await tester.pump(const Duration(seconds: 8));
    await task;
    await tester.pump();
    expect(stream.aborted, true);
    expect(stream.closes, 1);
    expect(client.errorCode, 'review_timeout');
  });
}
