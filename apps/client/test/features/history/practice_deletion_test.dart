import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/history/deletion_controller.dart';
import 'package:simontalk_client/features/history/deletion_models.dart';

import 'deletion_fixtures.dart';

void main() {
  late ApiClient api;
  late DeletionController c;
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) handler;
  DeletionController make({Duration Function()? elapsed}) => DeletionController(
    accountApi: api,
    accountId: accountId,
    sessionId: practiceId,
    keyFactory: () => deletionKey,
    elapsed: elapsed,
    httpClientFactory: () => MockClient((r) {
      requests.add(r);
      return handler(r);
    }),
  );
  setUp(() {
    requests.clear();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (r) async =>
        response(r.method == 'DELETE' ? deletionReceipt() : deletionScope());
    c = make();
  });
  tearDown(() {
    c.dispose();
    api.close();
  });

  test(
    'scope and receipt strictly bind owner target key counts and digest',
    () {
      final scope = DeletionScope.fromJson(
        deletionScope(),
        accountId: accountId,
        sessionId: practiceId,
      );
      expect(scope.recordCount, 3);
      expect(
        DeletionReceipt.fromJson(
          deletionReceipt(),
          scope: scope,
          requestKey: deletionKey,
        ).recordCount,
        3,
      );
      for (final change in [
        {'account_id': practiceId},
        {'session_id': accountId},
        {'record_count': 9},
        {'rehearsal_count': -1},
        {'scope_version': 'bad'},
        {'connection_pending': 1},
        {'kind': 'rehearsal'},
      ]) {
        expect(
          () => DeletionScope.fromJson(
            {...deletionScope(), ...change},
            accountId: accountId,
            sessionId: practiceId,
          ),
          throwsFormatException,
        );
      }
      for (final change in [
        {'request_key': accountId},
        {'scope_version': 'b' * 64},
        {'record_count': 4},
        {'deleted_at': '2026-10-23'},
        {'source': 'fixture'},
      ]) {
        expect(
          () => DeletionReceipt.fromJson(
            {...deletionReceipt(), ...change},
            scope: scope,
            requestKey: deletionKey,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('construction zero requests; explicit scope only GET then fixed confirmed DELETE', () async {
    expect(requests, isEmpty);
    await c.load();
    expect(c.state, DeletionState.ready);
    expect(requests.single.method, 'GET');
    await c.confirm();
    expect(c.state, DeletionState.deleted);
    final r = requests.last;
    expect(r.method, 'DELETE');
    expect(r.headers['X-Account-ID'], accountId);
    expect(r.headers['Idempotency-Key'], deletionKey);
    expect(jsonDecode(r.body), {'scope_version': scopeVersion});
    await c.confirm();
    expect(requests, hasLength(2));
  });
  test('confirmation without read never writes', () async {
    await c.confirm();
    expect(requests, isEmpty);
  });
  test(
    'singleflight scope and delete and late timer uses one operation',
    () async {
      final gate = Completer<http.Response>();
      handler = (_) => gate.future;
      final a = c.load(), b = c.load();
      expect(identical(a, b), isTrue);
      gate.complete(response(deletionScope()));
      await a;
      final write = Completer<http.Response>();
      handler = (_) => write.future;
      final x = c.confirm(), y = c.confirm();
      expect(identical(x, y), isTrue);
      write.complete(response(deletionReceipt()));
      await x;
      expect(requests, hasLength(2));
      expect(c.state, DeletionState.deleted);
    },
  );
  test('write response lost stays unconfirmed; check receipt then succeeds without another delete', () async {
    await c.load();
    handler = (_) async => throw http.ClientException('lost');
    await c.confirm();
    expect(c.state, DeletionState.unconfirmed);
    handler = (_) async => response(deletionReceipt());
    await c.check();
    expect(requests.last.method, 'GET');
    expect(requests.last.url.queryParameters['key'], deletionKey);
    expect(c.state, DeletionState.deleted);
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
  });
  test('missing receipt is not success; explicit replay preserves exact key and body', () async {
    await c.load();
    handler = (_) async => throw http.ClientException('lost');
    await c.confirm();
    handler = (_) async =>
        response({'code': 'deletion_receipt_not_found'}, 404);
    await c.check();
    expect(c.state, DeletionState.unconfirmed);
    expect(c.canReplay, isTrue);
    handler = (_) async => response(deletionReceipt());
    await c.replay();
    final writes = requests.where((r) => r.method == 'DELETE').toList();
    expect(writes, hasLength(2));
    expect(
      writes[1].headers['Idempotency-Key'],
      writes[0].headers['Idempotency-Key'],
    );
    expect(writes[1].body, writes[0].body);
    expect(c.state, DeletionState.deleted);
  });
  test('scope change clears confirmation; fresh range must be read and confirmed again', () async {
    await c.load();
    handler = (_) async => response({'code': 'deletion_scope_changed'}, 409);
    await c.confirm();
    expect(c.scope, isNull);
    expect(c.state, DeletionState.failed);
    await c.confirm();
    expect(requests, hasLength(2));
    handler = (_) async => response(deletionScope(children: 3));
    await c.load();
    expect(c.scope!.recordCount, 4);
    expect(requests.last.method, 'GET');
  });
  test('malformed successful write response remains unknown and cannot clear pending with load', () async {
    await c.load();
    handler = (_) async => response({'wrong': true});
    await c.confirm();
    expect(c.state, DeletionState.unconfirmed);
    await c.load();
    expect(requests, hasLength(2));
  });
  test('source account changes clear scope and never send write', () async {
    await c.load();
    api.expectedAccountId = practiceId;
    await c.confirm();
    expect(c.scope, isNull);
    expect(c.state, DeletionState.aborted);
    expect(requests, hasLength(1));
  });
  test('disposal suppresses late successful write publication', () async {
    await c.load();
    final gate = Completer<http.Response>();
    handler = (_) => gate.future;
    final pending = c.confirm();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    gate.complete(response(deletionReceipt()));
    await pending;
    expect(c.receipt, isNull);
  });
  testWidgets('real eight second deadline fences late delete result', (
    t,
  ) async {
    await t.runAsync(c.load);
    final gate = Completer<http.Response>();
    handler = (_) => gate.future;
    final pending = c.confirm();
    await t.pump();
    await t.pump(const Duration(seconds: 8));
    await pending;
    expect(c.state, DeletionState.unconfirmed);
    gate.complete(response(deletionReceipt()));
    await t.pump();
    expect(c.receipt, isNull);
  });
  test('elapsed deadline covers delayed token and CSRF boundaries', () async {
    var elapsed = Duration.zero;
    c.dispose();
    c = make(elapsed: () => elapsed);
    await c.load();
    handler = (_) async {
      elapsed = const Duration(seconds: 8);
      return response(deletionReceipt());
    };
    await c.confirm();
    expect(c.state, DeletionState.unconfirmed);
  });

  testWidgets(
    'CSRF waiting counts inside eight seconds and cannot send a late DELETE',
    (t) async {
      c.dispose();
      api.close();
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      c = make();
      await t.runAsync(c.load);
      final csrf = Completer<http.Response>();
      handler = (r) => csrf.future;
      final pending = c.confirm();
      await t.pump();
      expect(requests.last.url.path, '/v1/auth/csrf');
      await t.pump(const Duration(seconds: 8));
      await pending;
      expect(c.state, DeletionState.unconfirmed);
      csrf.complete(response({'csrf_token': 'safe-test-token'}));
      await t.pump();
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    },
  );
}
