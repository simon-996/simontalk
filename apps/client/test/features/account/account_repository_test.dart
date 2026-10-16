import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/account/account_repository.dart';

class MemoryTokenStore implements TokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> delete() async => token = null;
}

const user = {
  'id': 'user-one',
  'username': 'learner_one',
  'display_name': '练习者',
};
const preferences = {
  'difficulty': null,
  'speech_pace': 'normal',
  'subtitle_default': true,
  'chinese_hints_enabled': true,
  'translation_mode': 'on_demand',
  'version': 1,
};

http.Response jsonResponse(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('successful authentication with failed preference load can recover without registering again', () async {
    final store = MemoryTokenStore();
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: store,
      client: MockClient(
        (request) async => request.url.path.endsWith('/login')
            ? jsonResponse({'user': user, 'access_token': 'valid'}, 200)
            : throw http.ClientException('offline'),
      ),
    );
    await expectLater(
      AccountRepository(api).login('learner_one', 'a-long-test-password'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'session_pending'),
      ),
    );
    expect(store.token, 'valid');
  });

  test(
    'mobile logout clears local credential when remote revocation fails',
    () async {
      final store = MemoryTokenStore()..token = 'valid';
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: store,
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(await AccountRepository(api).logout(), isFalse);
      expect(store.token, isNull);
    },
  );

  test('web logout failure remains an error because HttpOnly cookie cannot be cleared locally', () async {
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: MemoryTokenStore(),
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      AccountRepository(api).logout(),
      throwsA(isA<ApiException>()),
    );
  });

  test('timeout covers waiting for response headers as well as body', () async {
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: MemoryTokenStore(),
      timeout: const Duration(milliseconds: 5),
      client: MockClient((_) => Completer<http.Response>().future),
    );
    await expectLater(
      api.request('GET', '/health/live'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'network_error'),
      ),
    );
  });

  test(
    'mobile login stores token and authenticates subsequent requests',
    () async {
      final store = MemoryTokenStore();
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost:8000'),
        isWeb: false,
        tokenStore: store,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/login')) {
            expect(jsonDecode(request.body)['platform'], 'mobile');
            return jsonResponse({
              'user': user,
              'access_token': 'opaque-token',
            }, 200);
          }
          expect(request.headers['authorization'], 'Bearer opaque-token');
          return jsonResponse(preferences, 200);
        }),
      );
      final repository = AccountRepository(api);
      final session = await repository.login(
        'learner_one',
        'a-long-test-password',
      );
      expect(session.user.username, 'learner_one');
      expect(session.preferences.difficulty, isNull);
      expect(store.token, 'opaque-token');
      expect(requests.length, 2);
    },
  );

  test(
    'web obtains CSRF for mutations and never writes a bearer token',
    () async {
      final store = MemoryTokenStore();
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost:8000'),
        isWeb: true,
        tokenStore: store,
        client: MockClient((request) async {
          expect(request.headers.containsKey('authorization'), isFalse);
          if (request.url.path.endsWith('/csrf')) {
            return http.Response('{"csrf_token":"csrf-value"}', 200);
          }
          if (request.url.path.endsWith('/login')) {
            expect(request.headers['X-CSRF-Token'], 'csrf-value');
            expect(jsonDecode(request.body)['platform'], 'web');
            return jsonResponse({'user': user}, 200);
          }
          return jsonResponse(preferences, 200);
        }),
      );
      await AccountRepository(api).login('learner_one', 'a-long-test-password');
      expect(store.token, isNull);
    },
  );

  test('restore keeps mobile credentials on a connection failure', () async {
    final store = MemoryTokenStore()..token = 'still-valid';
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost:8000'),
      isWeb: false,
      tokenStore: store,
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    await expectLater(
      AccountRepository(api).restore(),
      throwsA(isA<ApiException>()),
    );
    expect(store.token, 'still-valid');
  });

  test('restore clears a rejected credential and returns signed out', () async {
    final store = MemoryTokenStore()..token = 'revoked';
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost:8000'),
      isWeb: false,
      tokenStore: store,
      client: MockClient(
        (_) async => jsonResponse({'code': 'unauthorized'}, 401),
      ),
    );
    expect(await AccountRepository(api).restore(), isNull);
    expect(store.token, isNull);
  });

  test(
    'preference update submits expected version and reports conflicts',
    () async {
      final store = MemoryTokenStore()..token = 'valid';
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost:8000'),
        isWeb: false,
        tokenStore: store,
        client: MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['version'], 1);
          expect(body['difficulty'], 'beginner');
          return jsonResponse({'code': 'preferences_conflict'}, 409);
        }),
      );
      final prefs = AccountPreferences.fromJson(preferences)
          .copyWith(difficulty: Difficulty.beginner);
      await expectLater(
        AccountRepository(api).savePreferences(prefs),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'preferences_conflict',
          ),
        ),
      );
    },
  );

  test('malformed successful response becomes a readable API error', () async {
    final store = MemoryTokenStore()..token = 'valid';
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost:8000'),
      isWeb: false,
      tokenStore: store,
      client: MockClient(
        (_) async => http.Response('<html>gateway</html>', 200),
      ),
    );
    await expectLater(
      AccountRepository(api).restore(),
      throwsA(isA<ApiException>()),
    );
    expect(store.token, 'valid');
  });
}
