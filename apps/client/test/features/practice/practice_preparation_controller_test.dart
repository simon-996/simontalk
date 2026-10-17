import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/practice/practice_preparation_controller.dart';

import 'practice_fixtures.dart';

void main() {
  late ApiClient api;
  late PracticePreparationController controller;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  late String instance;
  late DateTime origin;

  void setup(WidgetTester tester) {
    requests = [];
    instance = clientId;
    origin = tester.binding.clock.now();
    int seconds() => tester.binding.clock.now().difference(origin).inSeconds;
    handler = (r) async {
      if (r.url.path.endsWith('/connections')) {
        instance = jsonDecode(r.body)['client_instance_id'] as String;
        return response(
          connectionJson(instance: instance, second: seconds()),
          201,
        );
      }
      if (r.url.path.endsWith('/renew-lease')) {
        return response(connectionJson(instance: instance, second: seconds()));
      }
      if (r.url.path.contains('/connections/')) {
        return response(connectionJson(status: 'closed', instance: instance));
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
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      timeout: const Duration(minutes: 2),
      client: MockClient((r) async {
        if (r.url.path == '/v1/auth/csrf') {
          return response({'csrf_token': 'test'});
        }
        requests.add(r);
        return handler(r);
      }),
    )..expectedAccountId = accountId;
    controller = PracticePreparationController(
      repository: PracticeRepository(api, accountId: accountId),
      elapsed: () => tester.binding.clock.now().difference(origin),
    );
    addTearDown(() async {
      controller.dispose();
      await tester.pump();
      api.close();
    });
  }

  testWidgets(
    'begin reserves without media and duplicate clicks do not create twice',
    (tester) async {
      setup(tester);
      await Future.wait([controller.begin(), controller.begin()]);
      expect(controller.phase, PreparationPhase.reserved);
      expect(requests.length, 2);
      final ids = [
        requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key'],
        instance,
      ];
      expect(ids.toSet().length, 3);
      for (final id in ids) {
        expect(
          id,
          matches(
            RegExp(
              r'^[a-f0-9-]{14}4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
            ),
          ),
        );
      }
      expect(controller.connection!.epoch, 1);
      await controller.stop();
    },
  );

  testWidgets(
    'default 503 never creates a connection or retries automatically',
    (tester) async {
      setup(tester);
      handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
      await controller.begin();
      await tester.pump(const Duration(minutes: 2));
      expect(controller.errorCode, 'realtime_unavailable');
      expect(controller.phase, PreparationPhase.blocked);
      expect(requests.length, 1);
    },
  );

  testWidgets(
    'explicit retry after lost create response reuses original practice key',
    (tester) async {
      setup(tester);
      final normal = handler;
      handler = (_) async => throw http.ClientException('offline');
      await controller.begin();
      expect(controller.phase, PreparationPhase.uncertain);
      await controller.begin();
      expect(requests.length, 1);
      handler = normal;
      await controller.retry();
      expect(controller.phase, PreparationPhase.reserved);
      expect(
        requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key'],
      );
      expect(requests[0].body, requests[1].body);
      await controller.stop();
    },
  );

  testWidgets(
    'connection retry retains key, expected epoch, instance and original deadline',
    (tester) async {
      setup(tester);
      final normal = handler;
      handler = (r) => r.url.path.endsWith('/connections')
          ? Future.error(http.ClientException('lost'))
          : normal(r);
      await controller.begin();
      expect(controller.phase, PreparationPhase.uncertain);
      await tester.pump(const Duration(seconds: 40));
      handler = (r) async {
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          return response(connectionJson(instance: instance));
        }
        return normal(r);
      };
      await controller.retry();
      expect(controller.phase, PreparationPhase.reserved);
      expect(
        requests[1].headers['Idempotency-Key'],
        requests[2].headers['Idempotency-Key'],
      );
      expect(requests[1].body, requests[2].body);
      await tester.pump(const Duration(seconds: 5));
      expect(controller.phase, PreparationPhase.stopped);
      expect(
        requests.where((r) => r.url.path.endsWith('/renew-lease')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'renewal happens every 15 seconds then stop cancels connection before practice',
    (tester) async {
      setup(tester);
      await controller.begin();
      await tester.pump(const Duration(seconds: 15));
      expect(controller.phase, PreparationPhase.reserved);
      expect(controller.connection!.lastSeenAt.second, 15);
      await controller.stop();
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests[requests.length - 2].url.path, contains('/connections/'));
      expect(
        requests.last.url.path,
        '/v1/practice-sessions/$practiceId/cancel-preparation',
      );
      final count = requests.length;
      await tester.pump(const Duration(minutes: 1));
      expect(requests.length, count);
    },
  );

  testWidgets(
    'in-flight renewal cannot overlap or postpone original lease cutoff',
    (tester) async {
      setup(tester);
      await controller.begin();
      final pending = Completer<http.Response>();
      final normal = handler;
      handler = (r) =>
          r.url.path.endsWith('/renew-lease') ? pending.future : normal(r);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 29));
      expect(
        requests.where((r) => r.url.path.endsWith('/renew-lease')).length,
        1,
      );
      expect(controller.phase, PreparationPhase.reserved);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.phase, PreparationPhase.stopped);
      pending.complete(
        response(connectionJson(instance: instance, second: 44)),
      );
      await tester.pump();
      expect(controller.phase, PreparationPhase.stopped);
    },
  );

  testWidgets(
    'renewal network loss stops timers and safely cancels preparation',
    (tester) async {
      setup(tester);
      await controller.begin();
      final normal = handler;
      handler = (r) => r.url.path.endsWith('/renew-lease')
          ? Future.error(http.ClientException('lost'))
          : normal(r);
      await tester.pump(const Duration(seconds: 15));
      expect(controller.phase, PreparationPhase.stopped);
      expect(controller.errorCode, 'network_error');
    },
  );

  testWidgets(
    'background stops, return to foreground never automatically restarts',
    (tester) async {
      setup(tester);
      await controller.begin();
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(controller.phase, PreparationPhase.stopped);
      final count = requests.length;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(minutes: 1));
      expect(requests.length, count);
    },
  );

  testWidgets(
    'stop during practice creation cancels late practice without creating connection',
    (tester) async {
      setup(tester);
      final pending = Completer<http.Response>();
      final normal = handler;
      handler = (r) =>
          r.url.path == '/v1/practice-sessions' ? pending.future : normal(r);
      final begin = controller.begin();
      await tester.pump();
      await controller.stop();
      expect(controller.phase, PreparationPhase.uncertain);
      pending.complete(response(practiceJson(), 201));
      await begin;
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests.any((r) => r.url.path.contains('/connections')), isFalse);
    },
  );

  testWidgets(
    'dispose during connection creation safely cancels late registration without notifying',
    (tester) async {
      setup(tester);
      final pending = Completer<http.Response>();
      final normal = handler;
      handler = (r) {
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          return pending.future;
        }
        return normal(r);
      };
      final begin = controller.begin();
      await tester.pump();
      controller.dispose();
      pending.complete(response(connectionJson(instance: instance), 201));
      await begin;
      expect(
        requests
            .where((r) => r.url.path.endsWith('/cancel-preparation'))
            .length,
        2,
      );
    },
  );

  testWidgets(
    'account switch blocks late result and sends no cleanup under new identity',
    (tester) async {
      setup(tester);
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final begin = controller.begin();
      await tester.pump();
      api.expectedAccountId = 'changed';
      controller.dispose();
      pending.complete(response(practiceJson(), 201));
      await begin;
      expect(requests.length, 1);
    },
  );

  testWidgets(
    'unknown upstream state never becomes reserved or gets preparation cancel',
    (tester) async {
      setup(tester);
      final normal = handler;
      handler = (r) async {
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          return response(
            connectionJson(
              instance: instance,
              status: 'unknown',
              termination: 'unknown',
            ),
          );
        }
        return normal(r);
      };
      await controller.begin();
      expect(controller.phase, PreparationPhase.blocked);
      await controller.stop();
      expect(controller.phase, PreparationPhase.blocked);
      expect(requests.length, 2);
    },
  );

  testWidgets(
    'unconfirmed cancellation remains uncertain and does not cancel parent',
    (tester) async {
      setup(tester);
      await controller.begin();
      handler = (_) async => throw http.ClientException('offline');
      await controller.stop();
      expect(controller.phase, PreparationPhase.uncertain);
      expect(controller.connection!.status, ConnectionStatus.preparing);
      expect(requests.length, 3);
    },
  );

  testWidgets(
    'explicit retry can confirm cancellation after network recovery without new creation keys',
    (tester) async {
      setup(tester);
      await controller.begin();
      final normal = handler;
      handler = (_) async => throw http.ClientException('offline');
      await controller.stop();
      handler = normal;
      await Future.wait([controller.retry(), controller.retry()]);
      expect(controller.phase, PreparationPhase.stopped);
      expect(
        requests.where((r) => r.url.path.endsWith('/connections')).length,
        1,
      );
      expect(
        requests.where((r) => r.url.path == '/v1/practice-sessions').length,
        1,
      );
      expect(requests.length, 5);
    },
  );

  testWidgets(
    'expired cancellation reads authoritative terminal state before cancelling parent',
    (tester) async {
      setup(tester);
      await controller.begin();
      final normal = handler;
      handler = (r) async {
        if (r.url.path.contains('/connections/')) {
          return r.method == 'POST'
              ? response({'code': 'connection_lease_expired'}, 409)
              : response(connectionJson(instance: instance, status: 'failed'));
        }
        return normal(r);
      };
      await controller.stop();
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests[3].method, 'GET');
    },
  );

  testWidgets(
    'synchronous listener stop cannot leave a live reservation behind',
    (tester) async {
      setup(tester);
      controller.addListener(() {
        if (controller.phase == PreparationPhase.reserved) {
          unawaited(controller.stop());
        }
      });
      await controller.begin();
      expect(controller.phase, PreparationPhase.stopped);
      expect(
        requests
            .where((r) => r.url.path.endsWith('/cancel-preparation'))
            .length,
        2,
      );
    },
  );

  testWidgets(
    'stop from preparing listener sends no create and finishes stopped',
    (tester) async {
      setup(tester);
      controller.addListener(() {
        if (controller.phase == PreparationPhase.preparing) {
          unawaited(controller.stop());
        }
      });
      await controller.begin();
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'delayed event loop cannot accept renewal after the previous local deadline',
    (tester) async {
      setup(tester);
      controller.dispose();
      var elapsed = Duration.zero;
      controller = PracticePreparationController(
        repository: PracticeRepository(api, accountId: accountId),
        elapsed: () => elapsed,
      );
      await controller.begin();
      final pending = Completer<http.Response>();
      final normal = handler;
      handler = (r) =>
          r.url.path.endsWith('/renew-lease') ? pending.future : normal(r);
      elapsed = const Duration(seconds: 15);
      await tester.pump(const Duration(seconds: 15));
      // The monotonic clock has advanced, but the old watchdog callback has not run.
      elapsed = const Duration(seconds: 46);
      pending.complete(
        response(connectionJson(instance: instance, second: 15)),
      );
      await tester.pump();
      expect(controller.phase, PreparationPhase.stopped);
    },
  );

  testWidgets(
    'delayed renewal timer checks the local deadline before sending a request',
    (tester) async {
      setup(tester);
      controller.dispose();
      var elapsed = Duration.zero;
      controller = PracticePreparationController(
        repository: PracticeRepository(api, accountId: accountId),
        elapsed: () => elapsed,
      );
      await controller.begin();
      elapsed = const Duration(seconds: 46);
      await tester.pump(const Duration(seconds: 15));
      expect(controller.phase, PreparationPhase.stopped);
      expect(
        requests.where((r) => r.url.path.endsWith('/renew-lease')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'reentrant stop while releasing shares one cancellation operation',
    (tester) async {
      setup(tester);
      await controller.begin();
      controller.addListener(() {
        if (controller.phase == PreparationPhase.releasing) {
          unawaited(controller.stop());
        }
      });
      await controller.stop();
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests.length, 4);
    },
  );

  testWidgets(
    'retry after background recovers a lost practice create with its original key then only cancels',
    (tester) async {
      setup(tester);
      final normal = handler;
      handler = (_) async =>
          throw http.ClientException('response lost after commit');
      await controller.begin();
      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(controller.phase, PreparationPhase.uncertain);
      handler = normal;
      await controller.retry();
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests.length, 3);
      expect(
        requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key'],
      );
      expect(requests[0].body, requests[1].body);
      expect(requests.any((r) => r.url.path.contains('/connections')), isFalse);
    },
  );

  testWidgets(
    'retry after stop recovers a lost connection create before cancelling connection and parent',
    (tester) async {
      setup(tester);
      var connectionRegistered = false;
      var connectionClosed = false;
      handler = (r) async {
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          if (!connectionRegistered) {
            connectionRegistered = true;
            throw http.ClientException('response lost after commit');
          }
          return response(connectionJson(instance: instance));
        }
        if (r.url.path.contains('/connections/')) {
          connectionClosed = true;
          return response(connectionJson(instance: instance, status: 'closed'));
        }
        if (r.url.path.endsWith('/cancel-preparation')) {
          return connectionRegistered && !connectionClosed
              ? response({'code': 'preparation_not_cancellable'}, 409)
              : response(practiceJson(status: 'cancelled'));
        }
        return response(practiceJson());
      };
      await controller.begin();
      await controller.stop();
      expect(controller.phase, PreparationPhase.uncertain);
      await controller.retry();
      expect(controller.phase, PreparationPhase.stopped);
      expect(requests.length, 6);
      expect(
        requests[1].headers['Idempotency-Key'],
        requests[3].headers['Idempotency-Key'],
      );
      expect(requests[1].body, requests[3].body);
      expect(requests.any((r) => r.url.path.endsWith('/renew-lease')), isFalse);
    },
  );
}
