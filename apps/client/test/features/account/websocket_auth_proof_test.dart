import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';

import '../practice/practice_fixtures.dart';

const csrf = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq';

void main() {
  test('proof is single use, scoped, and never exposed by toString', () async {
    var requests = 0;
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((r) async {
        requests++;
        expect(r.url.path, '/v1/auth/csrf');
        return response({'csrf_token': csrf});
      }),
    )..expectedAccountId = accountId;
    try {
      final proof = await api.prepareWebSocketAuth(accountId: accountId);
      expect(proof.toString(), isNot(contains(csrf)));
      expect(jsonDecode(proof.consume()), {
        'type': 'authenticate',
        'account_id': accountId,
        'csrf': csrf,
      });
      expect(() => proof.consume(), throwsA(isA<ApiException>()));
      expect(requests, 1);
    } finally {
      api.close();
    }
  });

  test('account change during CSRF acquisition cannot issue a proof', () async {
    final pending = Completer<http.Response>();
    var current = accountId;
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) => pending.future),
      accountIdentity: () => current,
    );
    try {
      final result = api.prepareWebSocketAuth(accountId: accountId);
      current = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      pending.complete(response({'csrf_token': csrf}));
      await expectLater(
        result,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
    } finally {
      api.close();
    }
  });

  test('account changes or cancellation before consumption permanently invalidate proof', () async {
    var current = accountId;
    var valid = true;
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({'csrf_token': csrf})),
      accountIdentity: () => current,
    );
    try {
      final proof = await api.prepareWebSocketAuth(
        accountId: accountId,
        stillCurrent: () => valid,
      );
      current = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      expect(() => proof.consume(), throwsA(isA<ApiException>()));
      current = accountId;
      expect(() => proof.consume(), throwsA(isA<ApiException>()));
      final second = await api.prepareWebSocketAuth(
        accountId: accountId,
        stillCurrent: () => valid,
      );
      valid = false;
      expect(() => second.consume(), throwsA(isA<ApiException>()));
      valid = true;
      expect(() => second.consume(), throwsA(isA<ApiException>()));
    } finally {
      api.close();
    }
  });

  test(
    'concurrent proofs share one CSRF request but are independently single use',
    () async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) {
          calls++;
          return pending.future;
        }),
      )..expectedAccountId = accountId;
      try {
        final a = api.prepareWebSocketAuth(accountId: accountId);
        final b = api.prepareWebSocketAuth(accountId: accountId);
        pending.complete(response({'csrf_token': csrf}));
        final proofs = await Future.wait([a, b]);
        expect(calls, 1);
        expect(proofs[0].consume(), proofs[1].consume());
        expect(() => proofs[0].consume(), throwsA(isA<ApiException>()));
      } finally {
        api.close();
      }
    },
  );

  test('closing the client invalidates an already prepared proof', () async {
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({'csrf_token': csrf})),
    )..expectedAccountId = accountId;
    final proof = await api.prepareWebSocketAuth(accountId: accountId);
    api.close();
    expect(() => proof.consume(), throwsA(isA<ApiException>()));
    expect(() => proof.consume(), throwsA(isA<ApiException>()));
  });

  test(
    'invalid tokens, account IDs and non-Web clients fail before proof',
    () async {
      for (final token in ['bad', 'x' * 257, 'a' * 31 + '+']) {
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: true,
          tokenStore: TestTokenStore(),
          client: MockClient((_) async => response({'csrf_token': token})),
        )..expectedAccountId = accountId;
        try {
          await expectLater(
            api.prepareWebSocketAuth(accountId: accountId),
            throwsA(isA<ApiException>()),
          );
        } finally {
          api.close();
        }
      }
      final native = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      try {
        await expectLater(
          native.prepareWebSocketAuth(accountId: accountId),
          throwsA(isA<ApiException>()),
        );
      } finally {
        native.close();
      }
      var calls = 0;
      final invalid = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async {
          calls++;
          return response({'csrf_token': csrf});
        }),
      )..expectedAccountId = 'not-a-uuid';
      try {
        await expectLater(
          invalid.prepareWebSocketAuth(accountId: 'not-a-uuid'),
          throwsA(isA<ApiException>()),
        );
        expect(calls, 0);
      } finally {
        invalid.close();
      }
    },
  );
}
