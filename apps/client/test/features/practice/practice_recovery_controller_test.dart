import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';

import 'practice_fixtures.dart';
import 'recovery_fixtures.dart';

class ReadClient extends MockClient {
  ReadClient(super.fn);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  late ApiClient source;
  late PracticeRecoveryController controller;
  late List<ReadClient> clients;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  var elapsed = Duration.zero;
  setUp(() {
    requests = [];
    clients = [];
    elapsed = Duration.zero;
    handler = (_) async => response({
      'practice': practiceJson(epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
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

  test(
    'construction is inert and refresh reads other client without control',
    () async {
      expect(requests, isEmpty);
      await controller.refresh();
      expect(controller.recovery!.connection!.clientInstanceId, clientId);
      expect(controller.recovery!.connection!.safelyEnded, isFalse);
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/v1/practice-sessions/current');
      expect(requests.single.headers['X-Account-ID'], accountId);
      expect(controller.events, isEmpty);
      expect(clients.single.closed, isTrue);
      expect(source.hasCurrentAccount(accountId), isTrue);
    },
  );

  test('empty current cannot fetch observations', () async {
    handler = (_) async => response({'practice': null, 'connection': null});
    await controller.refresh();
    await controller.loadObservations();
    expect(controller.recovery!.practice, isNull);
    expect(requests, hasLength(1));
  });

  test(
    'paging failure retries original cursor and keeps accepted facts',
    () async {
      await controller.refresh();
      handler = (r) async => response(
        pageJson(
          sequences: List.generate(32, (i) => i + 1),
          total: 33,
          last: 40,
          more: true,
        ),
      );
      await controller.loadObservations();
      expect(controller.events, hasLength(32));
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      await controller.loadObservations();
      expect(controller.observationErrorCode, 'service_unavailable');
      expect(controller.events, hasLength(32));
      expect(controller.recovery!.connection!.safelyEnded, isFalse);
      handler = (_) async =>
          response(pageJson(sequences: [40], total: 33, last: 40));
      await controller.loadObservations();
      expect(requests[2].url.queryParameters['after_sequence'], '32');
      expect(requests[3].url.queryParameters['after_sequence'], '32');
      expect(controller.events, hasLength(33));
      expect(controller.page!.hasMore, isFalse);
      expect(controller.observationErrorCode, isNull);
      await controller.loadObservations();
      expect(requests, hasLength(4));
      expect(() => controller.events.clear(), throwsUnsupportedError);
    },
  );

  test(
    'refresh clears facts and does not read new connection automatically',
    () async {
      await controller.refresh();
      handler = (_) async => response(pageJson());
      await controller.loadObservations();
      handler = (_) async => response({'practice': null, 'connection': null});
      await controller.refresh();
      expect(controller.events, isEmpty);
      expect(controller.page, isNull);
      expect(requests, hasLength(3));
    },
  );

  test(
    'rejects regressing page summary and cross-page duplicate event ID',
    () async {
      await controller.refresh();
      handler = (_) async => response(
        pageJson(
          sequences: List.generate(32, (i) => i + 1),
          total: 34,
          last: 40,
          more: true,
        ),
      );
      await controller.loadObservations();
      handler = (_) async => response(pageJson(sequences: [40], total: 33));
      await controller.loadObservations();
      expect(controller.observationErrorCode, 'invalid_response');
      expect(controller.events, hasLength(32));
      final next = pageJson(sequences: [39, 40], total: 34);
      next['events'][0]['event_id'] = observationJson(1)['event_id'];
      handler = (_) async => response(next);
      await controller.loadObservations();
      expect(controller.observationErrorCode, 'invalid_response');
      expect(controller.events, hasLength(32));
    },
  );

  test(
    '401 clears previous facts but network failure does not clear login',
    () async {
      await controller.refresh();
      handler = (_) async =>
          throw http.ClientException('private upstream text');
      await controller.loadObservations();
      expect(controller.recovery, isNotNull);
      expect(controller.observationErrorCode, 'network_error');
      expect(source.hasCurrentAccount(accountId), isTrue);
      handler = (_) async => response({'code': 'unauthorized'}, 401);
      await controller.loadObservations();
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'unauthorized');
      expect(controller.events, isEmpty);
    },
  );

  test('same in-flight future prevents duplicate requests', () async {
    final waiting = Completer<http.Response>();
    handler = (_) => waiting.future;
    final first = controller.refresh();
    expect(controller.loadObservations(), same(first));
    expect(controller.refresh(), same(first));
    waiting.complete(response({'practice': null, 'connection': null}));
    await first;
    expect(requests, hasLength(1));
  });

  test(
    'account change discards late result and forbids old data on retry',
    () async {
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final pending = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      source.expectedAccountId = requestKey;
      waiting.complete(
        response({'practice': practiceJson(), 'connection': null}),
      );
      await pending;
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'account_changed');
      await controller.refresh();
      expect(requests, hasLength(1));
    },
  );

  test(
    'dispose settles waiting read and closes only independent HTTP',
    () async {
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final pending = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      await pending;
      expect(clients.single.closed, isTrue);
      expect(source.hasCurrentAccount(accountId), isTrue);
      waiting.complete(
        response({'practice': practiceJson(), 'connection': null}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.recovery, isNull);
    },
  );

  testWidgets('8 second total deadline cancels stalled read', (tester) async {
    final waiting = Completer<http.Response>();
    handler = (_) => waiting.future;
    final pending = controller.refresh();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await pending;
    expect(controller.errorCode, 'network_error');
    expect(controller.busy, isFalse);
    expect(clients.single.closed, isTrue);
    waiting.complete(response({'practice': null, 'connection': null}));
    await tester.pump();
  });

  test(
    'monotonic deadline rejects ack before a delayed Timer callback',
    () async {
      handler = (_) async {
        elapsed = const Duration(seconds: 9);
        return response({'practice': practiceJson(), 'connection': null});
      };
      await controller.refresh();
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'network_error');
    },
  );

  test('reentrant disposal in HTTP factory cannot send', () async {
    controller.dispose();
    controller = PracticeRecoveryController(
      api: source,
      accountId: accountId,
      httpClientFactory: () {
        controller.dispose();
        final client = ReadClient((r) async {
          requests.add(r);
          return response({});
        });
        clients.add(client);
        return client;
      },
    );
    await controller.refresh();
    expect(requests, isEmpty);
    expect(clients.single.closed, isTrue);
  });

  test('cross-page total must leave a fact for has_more', () async {
    await controller.refresh();
    handler = (_) async => response(
      pageJson(
        sequences: List.generate(32, (i) => i + 1),
        total: 64,
        last: 100,
        more: true,
      ),
    );
    await controller.loadObservations();
    handler = (_) async => response(
      pageJson(
        sequences: List.generate(32, (i) => i + 33),
        total: 64,
        last: 100,
        more: true,
      ),
    );
    await controller.loadObservations();
    expect(controller.observationErrorCode, 'invalid_response');
    expect(controller.events, hasLength(32));
  });
}
