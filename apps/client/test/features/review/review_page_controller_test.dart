import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/review/review_page_controller.dart';
import 'package:simontalk_client/features/review/review_models.dart';

import '../practice/practice_completion_test.dart' show completionSummary;
import '../realtime/api_realtime_signaller_test.dart' show TrackedClient;
import 'review_fixtures.dart';

void main() {
  late ApiClient api;
  late ReviewPageController controller;
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) handler;
  setUp(() {
    requests.clear();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (r) async => response(
      r.url.path.endsWith('completion')
          ? completionSummary(sealed: true)
          : r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(),
    );
    controller = ReviewPageController(
      accountApi: api,
      accountId: accountId,
      sessionId: practiceId,
      httpClientFactory: () => MockClient((r) {
        requests.add(r);
        return handler(r);
      }),
    );
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });
  test(
    'constructing and listening is silent; refresh owner source then GETs only',
    () async {
      controller.addListener(() {});
      expect(requests, isEmpty);
      await controller.refresh();
      expect(requests.map((r) => r.url.path.split('/').last), [
        'completion',
        'review-input',
        'review',
      ]);
      expect(
        requests.every(
          (r) => r.method == 'GET' && r.headers['X-Account-ID'] == accountId,
        ),
        isTrue,
      );
      expect(controller.state, ReviewPageState.ready);
      expect(controller.job?.status, ReviewJobStatus.blocked);
      expect(controller.canRetryGeneration, isTrue);
    },
  );
  test('saved text and exact item navigation recheck source, current item and busy identity', () async {
    handler = (r) async => response(
      r.url.path.endsWith('completion')
          ? completionSummary(sealed: true)
          : r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(status: 'succeeded'),
    );
    await controller.refresh();
    expect(controller.canReadSavedText, isTrue);
    expect(controller.canLocateItem(itemId), isTrue);
    expect(controller.canLocateItem(requestKey), isFalse);
    final wait = Completer<http.Response>();
    handler = (_) => wait.future;
    final task = controller.refresh();
    expect(controller.canReadSavedText, isFalse);
    expect(controller.canLocateItem(itemId), isFalse);
    await Future<void>.delayed(Duration.zero);
    wait.completeError(http.ClientException('offline'));
    await task;
    expect(controller.canReadSavedText, isFalse);
    api.expectedAccountId = requestKey;
    expect(controller.canLocateItem(itemId), isFalse);
  });
  test('ending and missing completion never create a review client', () async {
    handler = (_) async => response(completionSummary());
    await controller.refresh();
    expect(controller.state, ReviewPageState.saving);
    await controller.requestReview();
    await controller.retryGeneration();
    expect(requests, hasLength(1));
    handler = (_) async =>
        http.Response('{"code":"completion_not_found"}', 404);
    await controller.refresh();
    expect(controller.state, ReviewPageState.notSaved);
    expect(controller.completion, isNull);
    expect(controller.hasPendingAction, isFalse);
  });
  for (final change in [
    {'account_id': requestKey},
    {'session_id': requestKey},
    {'origin_connection_id': 'wrong'},
    {'client_instance_id': 'wrong'},
    {'epoch': true},
    {'epoch': 0},
    {'source': 'wrong'},
    {'extra': true},
  ]) {
    test('source rejects malformed or mismatched binding $change', () async {
      handler = (_) async =>
          response({...completionSummary(sealed: true), ...change});
      await controller.refresh();
      expect(controller.errorCode, 'invalid_response');
      expect(controller.completion, isNull);
      expect(controller.job, isNull);
      expect(requests, hasLength(1));
      await controller.requestReview();
      expect(requests, hasLength(1));
    });
  }
  test('invalid URL makes no HTTP', () async {
    controller.dispose();
    controller = ReviewPageController(
      accountApi: api,
      accountId: accountId,
      sessionId: 'not-uuid',
      httpClientFactory: () => throw StateError('HTTP forbidden'),
    );
    await controller.refresh();
    expect(controller.state, ReviewPageState.unavailable);
    expect(controller.errorCode, 'invalid_source');
  });
  test(
    'source refresh removes old result immediately and failures keep it hidden',
    () async {
      handler = (r) async => response(
        r.url.path.endsWith('completion')
            ? completionSummary(sealed: true)
            : r.url.path.endsWith('review-input')
            ? inputJson()
            : jobJson(status: 'succeeded'),
      );
      await controller.refresh();
      expect(controller.job?.result?.items, hasLength(1));
      final wait = Completer<http.Response>();
      handler = (_) => wait.future;
      final work = controller.refresh();
      expect(controller.job, isNull);
      expect(controller.completion, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(controller.job, isNull);
      expect(controller.completion, isNull);
      expect(controller.busy, isTrue);
      expect(identical(work, controller.requestReview()), isTrue);
      wait.completeError(http.ClientException('offline'));
      await work;
      expect(controller.errorCode, 'network_error');
      expect(controller.job, isNull);
    },
  );
  test('same target preserves a pending key across failed source and read confirmation', () async {
    handler = (r) async {
      if (r.url.path.endsWith('completion')) {
        return response(completionSummary(sealed: true));
      }
      if (r.method == 'GET') {
        return http.Response('{"code":"review_input_not_found"}', 404);
      }
      throw http.ClientException('lost reply');
    };
    await controller.refresh();
    expect(controller.canRequestReview, isTrue);
    await controller.requestReview();
    final original = requests.last.headers['Idempotency-Key'];
    expect(controller.hasPendingAction, isTrue);
    handler = (_) async => throw http.ClientException('offline');
    await controller.refresh();
    expect(controller.hasPendingAction, isFalse);
    handler = (r) async => response(
      r.url.path.endsWith('completion')
          ? completionSummary(sealed: true)
          : r.url.path.endsWith('review-input')
          ? inputJson()
          : jobJson(),
    );
    await controller.refresh();
    expect(controller.hasPendingAction, isTrue);
    expect(controller.canRetryGeneration, isFalse);
    await controller.retryPending();
    final writes = requests.where((r) => r.method == 'POST').toList();
    expect(writes, hasLength(3));
    expect(
      writes.every((r) => r.headers['Idempotency-Key'] == original),
      isTrue,
    );
    expect(controller.hasPendingAction, isFalse);
  });
  test('new target clears original pending; missing source and identity clear data', () async {
    handler = (r) async {
      if (r.url.path.endsWith('completion')) {
        return response(completionSummary(sealed: true));
      }
      if (r.method == 'GET') {
        return http.Response('{"code":"review_input_not_found"}', 404);
      }
      throw http.ClientException('lost reply');
    };
    await controller.refresh();
    await controller.requestReview();
    expect(controller.hasPendingAction, isTrue);
    handler = (r) async => r.url.path.endsWith('completion')
        ? response({...completionSummary(sealed: true), 'input_hash': 'd' * 64})
        : http.Response('{"code":"review_input_not_found"}', 404);
    await controller.refresh();
    expect(controller.hasPendingAction, isFalse);
    expect(controller.canRequestReview, isTrue);
    handler = (_) async => http.Response('{"code":"practice_not_found"}', 404);
    await controller.refresh();
    expect(controller.state, ReviewPageState.unavailable);
    expect(controller.canRequestReview, isFalse);
    api.expectedAccountId = requestKey;
    expect(controller.job, isNull);
    expect(controller.completion, isNull);
    expect(controller.state, ReviewPageState.aborted);
    expect(controller.errorCode, 'account_changed');
  });
  testWidgets(
    'source has its own eight second cancellation and ignores a late response',
    (tester) async {
      controller.dispose();
      final wait = Completer<http.Response>();
      final owned = TrackedClient((r) {
        requests.add(r);
        return wait.future;
      });
      controller = ReviewPageController(
        accountApi: api,
        accountId: accountId,
        sessionId: practiceId,
        httpClientFactory: () => owned,
      );
      final work = controller.refresh();
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      await work;
      expect(controller.errorCode, 'source_timeout');
      expect(owned.closes, 1);
      wait.complete(response(completionSummary(sealed: true)));
      await tester.pump();
      expect(controller.completion, isNull);
      expect(requests, hasLength(1));
    },
  );
  test('source and review have independent eight second deadlines', () async {
    controller.dispose();
    var elapsed = Duration.zero;
    controller = ReviewPageController(
      accountApi: api,
      accountId: accountId,
      sessionId: practiceId,
      elapsed: () => elapsed,
      httpClientFactory: () => MockClient((r) async {
        requests.add(r);
        if (r.url.path.endsWith('completion')) {
          elapsed = const Duration(seconds: 7);
          return response(completionSummary(sealed: true));
        }
        elapsed = const Duration(seconds: 14);
        return response(
          r.url.path.endsWith('review-input') ? inputJson() : jobJson(),
        );
      }),
    );
    await controller.refresh();
    expect(controller.job?.status, ReviewJobStatus.blocked);
    expect(controller.errorCode, isNull);
    expect(requests, hasLength(3));
  });
  test(
    'elapsed deadline prevents review followup after late source response',
    () async {
      controller.dispose();
      var elapsed = Duration.zero;
      controller = ReviewPageController(
        accountApi: api,
        accountId: accountId,
        sessionId: practiceId,
        elapsed: () => elapsed,
        httpClientFactory: () => MockClient((r) async {
          requests.add(r);
          elapsed = const Duration(seconds: 8);
          return response(completionSummary(sealed: true));
        }),
      );
      await controller.refresh();
      expect(controller.errorCode, 'source_timeout');
      expect(requests, hasLength(1));
    },
  );
  for (final loseAccount in [true, false]) {
    test(
      'account loss/dispose cancels source and late data never starts review: $loseAccount',
      () async {
        final wait = Completer<http.Response>();
        handler = (_) => wait.future;
        final work = controller.refresh();
        await Future<void>.delayed(Duration.zero);
        if (loseAccount) {
          api.expectedAccountId = requestKey;
          expect(controller.job, isNull);
        } else {
          controller.dispose();
        }
        await work;
        wait.complete(response(completionSummary(sealed: true)));
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1));
        expect(controller.job, isNull);
      },
    );
  }
  test('409 requires read before any new action', () async {
    handler = (r) async {
      if (r.url.path.endsWith('completion')) {
        return response(completionSummary(sealed: true));
      }
      if (r.method == 'GET') {
        return http.Response('{"code":"review_input_not_found"}', 404);
      }
      return http.Response('{"code":"idempotency_conflict"}', 409);
    };
    await controller.refresh();
    await controller.requestReview();
    expect(controller.errorCode, 'idempotency_conflict');
    final count = requests.length;
    await controller.requestReview();
    await controller.retryPending();
    await controller.retryGeneration();
    expect(requests, hasLength(count));
    await controller.refresh();
    expect(controller.canRequestReview, isTrue);
  });
}
