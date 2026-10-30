import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';

import 'practice_fixtures.dart';
import 'practice_completion_test.dart' show completionSummary;
import 'practice_recovery_controller_test.dart' show ReadClient;

Map<String, dynamic> terminationSnapshot({bool blocked = true}) => {
  'source': 'server_recorded',
  'account_id': accountId,
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'status': blocked ? 'blocked' : 'not_requested',
  'reason': blocked ? 'capability_unavailable' : null,
  'attempts': 0,
  'created_at': blocked ? '2026-10-21T08:00:00Z' : null,
};
void main() {
  late ApiClient api;
  late PracticeRecoveryController controller;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  var elapsed = Duration.zero;
  setUp(() {
    requests = [];
    elapsed = Duration.zero;
    handler = (_) async => response({
      'practice': practiceJson(status: 'interrupted', epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    controller = PracticeRecoveryController(
      api: api,
      accountId: accountId,
      elapsed: () => elapsed,
      httpClientFactory: () => ReadClient((r) async {
        requests.add(r);
        return handler(r);
      }),
    );
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });
  Future<void> loaded() async {
    await controller.refresh();
    handler = (r) async => response(
      r.url.path.endsWith('/completion')
          ? completionSummary(sealed: true)
          : terminationSnapshot(),
    );
    await controller.loadSaveStatus();
  }

  test('a known end keeps preparation cleanup blocked after a failed local refresh', () async {
    handler = (_) async => response({
      'practice': practiceJson(status: 'connecting', epoch: 1),
      'connection': connectionJson(),
    });
    await controller.refresh();
    final original = controller.recovery!.practice!;
    handler = (r) async => response(
      r.url.path.endsWith('/completion')
          ? completionSummary(sealed: true)
          : terminationSnapshot(),
    );
    await controller.loadSaveStatus();
    expect(controller.endRegistered, isTrue);
    handler = (_) async => response({'code': 'service_unavailable'}, 503);
    await controller.loadSaveStatus(refresh: true);
    expect(controller.savedCompletion, isNull);
    expect(controller.endRegistered, isTrue);
    final count = requests.length;
    await controller.discardPreparation(original);
    expect(requests.length, count);
    api.expectedAccountId = requestKey;
    expect(controller.endRegistered, isFalse);
  });

  test('historical occupied connection reads the verified current origin and original check', () async {
    handler = (_) async => response({
      'practice': practiceJson(status: 'ending', epoch: 2),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    await controller.refresh();
    handler = (r) async {
      if (r.url.path.endsWith('/completion')) {
        return response({
          ...completionSummary(sealed: true),
          'origin_connection_id': requestKey,
          'epoch': 2,
        });
      }
      if (r.url.path.endsWith('/termination-check')) {
        return response(terminationSnapshot());
      }
      return response({
        ...connectionJson(status: 'unknown', termination: 'unknown'),
        'id': requestKey,
        'epoch': 2,
      });
    };
    await controller.loadSaveStatus();
    expect(controller.saveStatusLoaded, isTrue);
    expect(controller.savedCompletion!.scope.epoch, 2);
    expect(controller.terminationCheck!.scope.epoch, 1);
    expect(requests.length, 4);
  });

  test('only an explicit original-scope read can expose save status', () async {
    await controller.loadSaveStatus();
    expect(requests, isEmpty);
    await loaded();
    expect(controller.saveStatusLoaded, isTrue);
    expect(controller.savedCompletion!.gapCodes, ['tail_unconfirmed']);
    expect(controller.terminationCheck!.reason, 'capability_unavailable');
    expect(requests.length, 3);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(
      requests.last.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/termination-check',
    );
    await controller.loadSaveStatus();
    expect(requests.length, 3);
  });
  test(
    'a precise missing completion is an unregistered result with a real check',
    () async {
      await controller.refresh();
      handler = (r) async => r.url.path.endsWith('/completion')
          ? response({'code': 'completion_not_found'}, 404)
          : response(terminationSnapshot(blocked: false));
      await controller.loadSaveStatus();
      expect(controller.saveStatusLoaded, isTrue);
      expect(controller.savedCompletion, isNull);
      expect(controller.terminationCheck, isNotNull);
      expect(controller.saveStatusErrorCode, isNull);
    },
  );
  test(
    'a failed second GET cannot publish the first successful summary',
    () async {
      await controller.refresh();
      handler = (r) async => r.url.path.endsWith('/completion')
          ? response(completionSummary(sealed: true))
          : response({'code': 'service_unavailable'}, 503);
      await controller.loadSaveStatus();
      expect(controller.saveStatusLoaded, isFalse);
      expect(controller.savedCompletion, isNull);
      expect(controller.terminationCheck, isNull);
      expect(controller.saveStatusErrorCode, 'service_unavailable');
      expect(controller.endRegistered, isTrue);
      expect(api.expectedAccountId, accountId);
    },
  );
  test('refresh clears success first and serializes a second read', () async {
    await loaded();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    final read = controller.loadSaveStatus(refresh: true);
    expect(controller.savedCompletion, isNull);
    expect(controller.terminationCheck, isNull);
    expect(controller.loadingSaveStatus, isTrue);
    expect(controller.loadSaveStatus(refresh: true), same(read));
    pending.complete(response({'code': 'service_unavailable'}, 503));
    await read;
    expect(controller.saveStatusErrorCode, 'service_unavailable');
  });
  test('both GETs share one elapsed deadline', () async {
    await controller.refresh();
    handler = (r) async {
      elapsed += const Duration(seconds: 5);
      return response(
        r.url.path.endsWith('/completion')
            ? completionSummary(sealed: true)
            : terminationSnapshot(),
      );
    };
    await controller.loadSaveStatus();
    expect(controller.saveStatusLoaded, isFalse);
    expect(controller.savedCompletion, isNull);
    expect(controller.saveStatusErrorCode, 'network_error');
  });
  test('expired first GET never starts the next GET', () async {
    await controller.refresh();
    handler = (_) async {
      elapsed += const Duration(seconds: 8);
      return response(completionSummary(sealed: true));
    };
    await controller.loadSaveStatus();
    expect(requests.length, 2);
    expect(controller.saveStatusErrorCode, 'network_error');
    expect(controller.savedCompletion, isNull);
  });
  test(
    'observation parent 404 also clears the previously saved status',
    () async {
      await loaded();
      handler = (_) async => response({'code': 'connection_not_found'}, 404);
      await controller.loadObservations();
      expect(controller.savedCompletion, isNull);
      expect(controller.terminationCheck, isNull);
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'connection_not_found');
    },
  );
  test(
    'account change clears old saved status before any provider teardown',
    () async {
      await loaded();
      api.expectedAccountId = requestKey;
      expect(controller.savedCompletion, isNull);
      expect(controller.terminationCheck, isNull);
      expect(controller.saveStatusLoaded, isFalse);
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'account_changed');
    },
  );
  test(
    'late response after identity change cannot restore a saved summary',
    () async {
      await controller.refresh();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final read = controller.loadSaveStatus();
      api.expectedAccountId = requestKey;
      expect(controller.savedCompletion, isNull);
      await read;
      pending.complete(response(completionSummary(sealed: true)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.savedCompletion, isNull);
      expect(controller.terminationCheck, isNull);
      expect(requests.length, 2);
    },
  );
  test(
    'missing parent clears existing text and the query connection',
    () async {
      await loaded();
      handler = (_) async => response({'code': 'practice_not_found'}, 404);
      await controller.loadSaveStatus(refresh: true);
      expect(controller.savedCompletion, isNull);
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'practice_not_found');
    },
  );
}
