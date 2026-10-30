import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/practice/practice_entry_controller.dart';
import 'package:simontalk_client/features/practice/practice_preparation_controller.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import 'practice_fixtures.dart';

void main() {
  late ApiClient api;
  late PracticeEntryController entry;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  void setup(WidgetTester tester) {
    requests = [];
    handler = (r) async {
      if (r.url.path.endsWith('/current')) {
        return response({'practice': null, 'connection': null});
      }
      if (r.url.path.endsWith('/connections')) {
        return response(
          connectionJson(instance: jsonDecode(r.body)['client_instance_id']),
          201,
        );
      }
      if (r.url.path.contains('/connections/')) {
        return response(
          connectionJson(
            status: 'closed',
            instance: entry.preparation.clientInstanceId,
          ),
        );
      }
      return response(
        practiceJson(
          status: r.url.path.endsWith('/cancel-preparation')
              ? 'cancelled'
              : 'created',
        ),
        201,
      );
    };
    Future<http.Response> dispatch(http.Request r) async {
      requests.add(r);
      return handler(r);
    }

    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient(dispatch),
    )..expectedAccountId = accountId;
    entry = PracticeEntryController(
      recovery: PracticeRecoveryController(
        api: api,
        accountId: accountId,
        httpClientFactory: () => MockClient(dispatch),
      ),
      preparation: PracticePreparationController(
        repository: PracticeRepository(api, accountId: accountId),
      ),
    );
    addTearDown(() async {
      entry.dispose();
      await tester.pump();
      api.close();
    });
  }

  testWidgets(
    'construction is inert; begin reads current before one preparation',
    (t) async {
      setup(t);
      expect(requests, isEmpty);
      await Future.wait([
        entry.begin(Difficulty.beginner),
        entry.begin(Difficulty.beginner),
      ]);
      expect(requests.map((r) => r.method), ['GET', 'POST', 'POST']);
      expect(requests.first.url.path, '/v1/practice-sessions/current');
      expect(entry.preparation.phase, PreparationPhase.reserved);
      await entry.cancel();
      expect(entry.preparation.phase, PreparationPhase.stopped);
    },
  );
  testWidgets(
    'default unavailable is terminal and never creates a connection',
    (t) async {
      setup(t);
      final normal = handler;
      handler = (r) => r.method == 'POST'
          ? Future.value(response({'code': 'realtime_unavailable'}, 503))
          : normal(r);
      await entry.begin(Difficulty.beginner);
      await entry.begin(Difficulty.beginner);
      await t.pump(const Duration(seconds: 45));
      expect(requests.length, 2);
      expect(entry.preparation.errorCode, 'realtime_unavailable');
      expect(entry.canStart, isFalse);
    },
  );
  testWidgets('unknown occupancy blocks creation; explicit refresh stays GET', (
    t,
  ) async {
    setup(t);
    handler = (_) async => response({
      'practice': practiceJson(epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    await entry.begin(Difficulty.beginner);
    expect(entry.canStart, isFalse);
    await entry.refresh();
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(
      entry.recovery.recovery!.connection!.terminationStatus.name,
      'unknown',
    );
  });
  testWidgets('failed current read requires a read-only refresh before begin', (
    t,
  ) async {
    setup(t);
    final normal = handler;
    handler = (_) async => throw http.ClientException('offline');
    await entry.begin(Difficulty.beginner);
    expect(entry.canStart, isFalse);
    handler = normal;
    await entry.refresh();
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(entry.canStart, isTrue);
    await entry.begin(Difficulty.beginner);
    expect(entry.preparation.phase, PreparationPhase.reserved);
    await entry.cancel();
  });
  testWidgets(
    'ambiguous create confirmation reuses the original key and body',
    (t) async {
      setup(t);
      final normal = handler;
      var lost = true;
      handler = (r) {
        if (r.method == 'POST' && lost) {
          lost = false;
          throw http.ClientException('lost');
        }
        return normal(r);
      };
      await entry.begin(Difficulty.beginner);
      expect(entry.preparation.phase, PreparationPhase.uncertain);
      expect(entry.canStart, isFalse);
      await entry.retry();
      final creates = requests
          .where((r) => r.url.path == '/v1/practice-sessions')
          .toList();
      expect(creates.length, 2);
      expect(
        creates.first.headers['Idempotency-Key'],
        creates.last.headers['Idempotency-Key'],
      );
      expect(creates.first.body, creates.last.body);
      expect(entry.preparation.phase, PreparationPhase.reserved);
      await entry.cancel();
    },
  );
  for (final action in ['cancel', 'background', 'identity', 'dispose']) {
    testWidgets('late empty current after $action cannot create', (t) async {
      setup(t);
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final task = entry.begin(Difficulty.beginner);
      await t.pump();
      switch (action) {
        case 'cancel':
          await entry.cancel();
        case 'background':
          entry.didChangeAppLifecycleState(AppLifecycleState.paused);
        case 'identity':
          api.expectedAccountId = requestKey;
        case 'dispose':
          entry.dispose();
      }
      pending.complete(response({'practice': null, 'connection': null}));
      await task;
      await t.pump();
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(entry.canStart, isFalse);
    });
  }
}
