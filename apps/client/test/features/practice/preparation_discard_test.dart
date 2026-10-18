import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';

import 'practice_fixtures.dart';
import 'practice_recovery_controller_test.dart' show ReadClient;

Map<String, dynamic> candidateJson({int epoch = 1}) => {
  'practice': practiceJson(
    status: epoch == 0 ? 'created' : 'connecting',
    epoch: epoch,
  ),
  'connection': epoch == 0 ? null : {...connectionJson(), 'epoch': epoch},
};

void main() {
  late ApiClient source;
  late PracticeRecoveryController controller;
  late List<http.Request> requests;
  late List<ReadClient> clients;
  late Future<http.Response> Function(http.Request) handler;
  var elapsed = Duration.zero;
  setUp(() {
    elapsed = Duration.zero;
    requests = [];
    clients = [];
    handler = (r) async => response(
      r.url.path.endsWith('/discard-preparation')
          ? practiceJson(status: 'cancelled', epoch: 1)
          : candidateJson(),
    );
    source = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    controller = PracticeRecoveryController(
      api: source,
      accountId: accountId,
      elapsed: () => elapsed,
      httpClientFactory: () {
        final client = ReadClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/csrf')) {
            return response({'csrf_token': 'test-csrf'});
          }
          return handler(r);
        });
        clients.add(client);
        return client;
      },
    );
  });
  tearDown(() {
    controller.dispose();
    source.close();
  });

  test('cleanup binds owner and epoch; only confirmed original preparation is successful', () async {
    await controller.refresh();
    final original = controller.recovery!.practice!;
    expect(controller.recovery!.canDiscardPreparation, isTrue);
    await controller.discardPreparation(original);
    final mutation = requests
        .where((r) => r.url.path.endsWith('/discard-preparation'))
        .single;
    expect(mutation.method, 'POST');
    expect(
      mutation.url.path,
      '/v1/practice-sessions/$practiceId/discard-preparation',
    );
    expect(mutation.headers['X-Account-ID'], accountId);
    expect(mutation.headers['X-CSRF-Token'], 'test-csrf');
    expect(mutation.body, '{"expected_epoch":1}');
    expect(controller.cleanupStatus, PreparationCleanupStatus.succeeded);
    expect(controller.recovery, isNull);
    expect(controller.events, isEmpty);
    expect(clients.every((c) => c.closed), isTrue);
    expect(source.hasCurrentAccount(accountId), isTrue);
    await controller.discardPreparation(original);
    expect(
      requests,
      hasLength(3),
    ); // GET current, GET csrf, POST original once.
  });

  test(
    'empty, unknown and historical-media parents never offer cleanup',
    () async {
      final candidates = [
        {'practice': null, 'connection': null},
        {
          'practice': practiceJson(epoch: 1),
          'connection': connectionJson(
            status: 'unknown',
            termination: 'unknown',
          ),
        },
        {
          'practice': practiceJson(status: 'interrupted', epoch: 1),
          'connection': connectionJson(
            status: 'closed',
            termination: 'confirmed',
          ),
        },
        {'practice': practiceJson(epoch: 1), 'connection': null},
      ];
      for (final json in candidates) {
        handler = (_) async => response(json);
        await controller.refresh();
        expect(controller.recovery!.canDiscardPreparation, isFalse);
        final original = controller.recovery!.practice;
        if (original != null) await controller.discardPreparation(original);
      }
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  test(
    'never-started empty practice and safely closed latest are candidates',
    () {
      expect(
        PracticeRecovery.fromJson(candidateJson(epoch: 0))
            .canDiscardPreparation,
        isTrue,
      );
      expect(
        PracticeRecovery.fromJson({
          'practice': practiceJson(epoch: 1),
          'connection': connectionJson(status: 'failed'),
        }).canDiscardPreparation,
        isTrue,
      );
    },
  );

  test('stale dialog snapshot cannot discard a newly observed epoch', () async {
    await controller.refresh();
    final original = controller.recovery!.practice!;
    handler = (_) async => response(candidateJson(epoch: 2));
    await controller.refresh();
    await controller.discardPreparation(original);
    expect(requests, hasLength(2));
    expect(controller.recovery!.practice!.connectionEpoch, 2);
  });

  for (final status in [409, 503]) {
    test(
      '$status outcome clears stale controls and requires explicit refresh',
      () async {
        await controller.refresh();
        final original = controller.recovery!.practice!;
        handler = (_) async => response({
          'code': status == 409 ? 'preparation_changed' : 'service_unavailable',
        }, status);
        await controller.discardPreparation(original);
        expect(
          controller.cleanupStatus,
          status == 409
              ? PreparationCleanupStatus.refused
              : PreparationCleanupStatus.unconfirmed,
        );
        expect(controller.recovery, isNull);
        final count = requests.length;
        await controller.discardPreparation(original);
        await controller.loadObservations();
        expect(requests, hasLength(count));
      },
    );
  }

  test(
    'malformed success cannot claim cleanup or expose response text',
    () async {
      await controller.refresh();
      final original = controller.recovery!.practice!;
      handler = (_) async =>
          response(practiceJson(status: 'cancelled', epoch: 2));
      await controller.discardPreparation(original);
      expect(controller.cleanupStatus, PreparationCleanupStatus.unconfirmed);
      expect(controller.cleanupErrorCode, 'invalid_response');
      expect(controller.recovery, isNull);
    },
  );

  test(
    'account changes clear old result without resubmitting under new identity',
    () async {
      await controller.refresh();
      final original = controller.recovery!.practice!;
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final action = controller.discardPreparation(original);
      await Future<void>.delayed(Duration.zero);
      source.expectedAccountId = requestKey;
      pending.complete(response(practiceJson(status: 'cancelled', epoch: 1)));
      await action;
      expect(controller.errorCode, 'account_changed');
      expect(
        controller.cleanupStatus,
        isNot(PreparationCleanupStatus.succeeded),
      );
      expect(controller.recovery, isNull);
      await controller.discardPreparation(original);
      expect(requests, hasLength(3));
    },
  );

  test('in-flight cleanup cannot enqueue a refresh, observation or duplicate mutation', () async {
    await controller.refresh();
    final original = controller.recovery!.practice!;
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    final action = controller.discardPreparation(original);
    expect(controller.cleanupStatus, PreparationCleanupStatus.working);
    expect(controller.refresh(), same(action));
    expect(controller.loadObservations(), same(action));
    expect(controller.discardPreparation(original), same(action));
    pending.complete(response(practiceJson(status: 'cancelled', epoch: 1)));
    await action;
    expect(requests, hasLength(3));
  });

  testWidgets(
    'deadline prevents late mutation acknowledgement becoming success',
    (tester) async {
      await controller.refresh();
      final original = controller.recovery!.practice!;
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final action = controller.discardPreparation(original);
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      await action;
      expect(controller.cleanupStatus, PreparationCleanupStatus.unconfirmed);
      expect(clients.last.closed, isTrue);
      pending.complete(response(practiceJson(status: 'cancelled', epoch: 1)));
      await tester.pump();
      expect(controller.cleanupStatus, PreparationCleanupStatus.unconfirmed);
    },
  );

  test(
    'monotonic deadline rejects late success before Timer is delivered',
    () async {
      await controller.refresh();
      final original = controller.recovery!.practice!;
      handler = (_) async {
        elapsed = const Duration(seconds: 9);
        return response(practiceJson(status: 'cancelled', epoch: 1));
      };
      await controller.discardPreparation(original);
      expect(controller.cleanupStatus, PreparationCleanupStatus.unconfirmed);
    },
  );

  testWidgets('CSRF timeout never sends the cleanup POST', (tester) async {
    controller.dispose();
    final pendingCsrf = Completer<http.Response>();
    controller = PracticeRecoveryController(
      api: source,
      accountId: accountId,
      httpClientFactory: () => ReadClient((r) async {
        requests.add(r);
        return r.url.path.endsWith('/csrf')
            ? pendingCsrf.future
            : response(candidateJson());
      }),
    );
    await controller.refresh();
    final action = controller.discardPreparation(
      controller.recovery!.practice!,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await action;
    expect(controller.cleanupStatus, PreparationCleanupStatus.unconfirmed);
    pendingCsrf.complete(response({'csrf_token': 'late-csrf'}));
    await tester.pump();
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test('repository rejects changed snapshot, missing end and wrong terminal result', () async {
    final original = PracticePreparation.fromJson(practiceJson(epoch: 1));
    for (final change in <void Function(Map<String, dynamic>)>[
      (j) => j['status'] = 'created',
      (j) => j['ended_at'] = null,
      (j) => j['id'] = requestKey,
      (j) => j['configuration']['effective_difficulty'] = 'advanced',
      (j) => j['configuration']['preferences']['version'] = 2,
      (j) => j['created_at'] = '2026-10-16T00:00:00Z',
    ]) {
      final data = practiceJson(status: 'cancelled', epoch: 1);
      change(data);
      final api = source.forkForAccount(
        accountId: accountId,
        client: MockClient(
          (r) async => response(
            r.url.path.endsWith('/csrf') ? {'csrf_token': 'test'} : data,
          ),
        ),
      );
      try {
        await expectLater(
          PracticeRepository(
            api,
            accountId: accountId,
          ).discardPreparation(original),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      } finally {
        api.close();
      }
    }
  });
}
