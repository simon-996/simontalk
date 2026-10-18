import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';

import '../practice/practice_fixtures.dart';

void main() {
  test('late CSRF rejection cannot invalidate a fresh family token', () async {
    var issued = 0;
    final late = Completer<http.Response>();
    Future<http.Response> server(http.Request r) async {
      if (r.url.path.endsWith('/csrf')) {
        return response({'csrf_token': 'token-${++issued}'});
      }
      if (r.url.path == '/old') return late.future;
      if (r.url.path == '/invalidate') {
        return response({'code': 'csrf_invalid'}, 403);
      }
      return response({});
    }

    final source = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient(server),
    )..expectedAccountId = accountId;
    final fork = source.forkForAccount(
      accountId: accountId,
      client: MockClient(server),
    );
    try {
      await source.request('POST', '/primer', accountId: accountId);
      final pending = expectLater(
        fork.request('POST', '/old', accountId: accountId),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        source.request('POST', '/invalidate', accountId: accountId),
        throwsA(isA<ApiException>()),
      );
      await source.request('POST', '/fresh', accountId: accountId);
      late.complete(response({'code': 'csrf_invalid'}, 403));
      await pending;
      await source.request('POST', '/later', accountId: accountId);
      expect(issued, 2);
    } finally {
      source.close();
      fork.close();
    }
  });
  test('independent account HTTP clients share CSRF so cleanup does not break logout', () async {
    var cookie = '';
    var issued = 0;
    Future<http.Response> server(http.Request request) async {
      if (request.url.path.endsWith('/csrf')) {
        cookie = 'test-csrf-${++issued}';
        return response({'csrf_token': cookie});
      }
      return request.headers['X-CSRF-Token'] == cookie
          ? response({})
          : response({'code': 'csrf_invalid'}, 403);
    }

    final source = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient(server),
    )..expectedAccountId = accountId;
    final fork = source.forkForAccount(
      accountId: accountId,
      client: MockClient(server),
    );
    try {
      await source.request('POST', '/login', accountId: accountId);
      await fork.request('POST', '/discard-preparation', accountId: accountId);
      fork.close();
      await source.request('POST', '/logout', accountId: accountId);
      expect(issued, 1);
      expect(source.hasCurrentAccount(accountId), isTrue);
    } finally {
      source.close();
      fork.close();
    }
  });

  test('concurrent family mutations wait for one CSRF issuance', () async {
    var issued = 0;
    final pending = Completer<http.Response>();
    Future<http.Response> server(http.Request r) async {
      if (r.url.path.endsWith('/csrf')) {
        issued++;
        return pending.future;
      }
      expect(r.headers['X-CSRF-Token'], 'single-token');
      return response({});
    }

    final source = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient(server),
    )..expectedAccountId = accountId;
    final fork = source.forkForAccount(
      accountId: accountId,
      client: MockClient(server),
    );
    try {
      final first = source.request('POST', '/first', accountId: accountId);
      final second = fork.request('POST', '/second', accountId: accountId);
      await Future<void>.delayed(Duration.zero);
      pending.complete(response({'csrf_token': 'single-token'}));
      await Future.wait([first, second]);
      expect(issued, 1);
    } finally {
      source.close();
      fork.close();
    }
  });

  test(
    'CSRF rejection invalidates family cache but never replays a mutation',
    () async {
      var issued = 0;
      var writes = 0;
      String? lastHeader;
      Future<http.Response> server(http.Request r) async {
        if (r.url.path.endsWith('/csrf')) {
          return response({'csrf_token': 'token-${++issued}'});
        }
        writes++;
        lastHeader = r.headers['X-CSRF-Token'];
        return writes == 2
            ? response({'code': 'csrf_invalid'}, 403)
            : response({});
      }

      final source = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient(server),
      )..expectedAccountId = accountId;
      final fork = source.forkForAccount(
        accountId: accountId,
        client: MockClient(server),
      );
      try {
        await source.request('POST', '/first', accountId: accountId);
        await expectLater(
          fork.request('POST', '/rejected', accountId: accountId),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'csrf_invalid'),
          ),
        );
        expect(writes, 2);
        await source.request('POST', '/explicit', accountId: accountId);
        expect(issued, 2);
        expect(writes, 3);
        expect(lastHeader, 'token-2');
      } finally {
        source.close();
        fork.close();
      }
    },
  );
}
