import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';

import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show signedIn;
import 'account_repository_test.dart' show MemoryTokenStore;
import 'preferences_action_guards_test.dart' show EditableAccount;

class WaitingReadStore extends MemoryTokenStore {
  final entered = Completer<void>();
  final reply = Completer<String?>();
  @override
  Future<String?> read() {
    if (!entered.isCompleted) entered.complete();
    return reply.future;
  }
}

void main() {
  Future<bool> begin(EditableAccount account, String operation) =>
      switch (operation) {
        'login' => account.authenticate(
          (r) => r.login('test-user', 'test-password'),
        ),
        'register' => account.authenticate(
          (r) => r.register(
            inviteCode: 'test-only',
            username: 'test-user',
            password: 'test-password',
            displayName: 'Test',
          ),
        ),
        _ => account.resetPassword('test-only', 'test-password'),
      };
  for (final operation in ['login', 'register', 'reset']) {
    for (final stage in ['csrf', 'success', 'failure', 'disposed']) {
      test('$operation ignores obsolete $stage completion', () async {
        final entered = Completer<void>();
        final reply = Completer<http.Response>();
        final writes = <http.Request>[];
        final store = MemoryTokenStore()..token = 'original';
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: stage == 'csrf',
          tokenStore: store,
          client: MockClient((r) async {
            if (r.url.path == '/v1/me/preferences') {
              return response(
                signedIn(accountId).session!.preferences.toJson(),
              );
            }
            if (r.method != 'GET') writes.add(r);
            if (!entered.isCompleted) entered.complete();
            return reply.future;
          }),
        );
        addTearDown(api.close);
        final account = EditableAccount(
          const AccountState(phase: SessionPhase.signedOut),
        );
        final container = ProviderContainer(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(() => account),
          ],
        );
        container.read(accountControllerProvider);
        final action = begin(account, operation);
        await entered.future;
        final newer = signedIn(requestKey);
        if (stage == 'disposed') {
          container.dispose();
        } else {
          api.expectedAccountId = requestKey;
          store.token = 'new-credential';
          account.change(newer);
        }
        reply.complete(
          stage == 'csrf'
              ? response({'csrf_token': 'test-only'})
              : stage == 'failure'
              ? response({'code': 'service_unavailable'}, 500)
              : response({
                  'user': {
                    'id': accountId,
                    'username': 'test-only',
                    'display_name': 'Test',
                  },
                  'access_token': 'old-credential',
                }),
        );
        expect(await action, isFalse);
        if (stage != 'disposed') {
          expect(container.read(accountControllerProvider), same(newer));
          expect(api.expectedAccountId, requestKey);
          expect(store.token, 'new-credential');
          if (stage == 'csrf') expect(writes, isEmpty);
          container.dispose();
        }
      });
    }
  }

  for (final operation in ['login', 'register', 'reset']) {
    test(
      'clearError cannot release an in-flight $operation or allow a duplicate',
      () async {
        final entered = Completer<void>();
        final reply = Completer<http.Response>();
        var calls = 0;
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: false,
          tokenStore: MemoryTokenStore(),
          client: MockClient((r) async {
            calls++;
            if (!entered.isCompleted) entered.complete();
            return reply.future;
          }),
        );
        addTearDown(api.close);
        final account = EditableAccount(
          const AccountState(phase: SessionPhase.signedOut),
        );
        final container = ProviderContainer(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(() => account),
          ],
        );
        addTearDown(container.dispose);
        container.read(accountControllerProvider);
        final first = begin(account, operation);
        await entered.future;
        account.clearError();
        expect(container.read(accountControllerProvider).busy, isTrue);
        expect(await begin(account, operation), isFalse);
        reply.complete(response({'code': 'service_unavailable'}, 500));
        expect(await first, isFalse);
        expect(calls, 1);
      },
    );
  }

  for (final operation in ['login', 'register']) {
    test(
      '$operation preference read cannot publish after a newer identity',
      () async {
        final entered = Completer<void>();
        final reply = Completer<http.Response>();
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: true,
          tokenStore: MemoryTokenStore(),
          client: MockClient((r) async {
            if (r.url.path == '/v1/auth/csrf') {
              return response({'csrf_token': 'test-only'});
            }
            if (r.method == 'POST') {
              return response({
                'user': {
                  'id': accountId,
                  'username': 'test-only',
                  'display_name': 'Test',
                },
              });
            }
            entered.complete();
            return reply.future;
          }),
        );
        addTearDown(api.close);
        final account = EditableAccount(
          const AccountState(phase: SessionPhase.signedOut),
        );
        final container = ProviderContainer(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(() => account),
          ],
        );
        addTearDown(container.dispose);
        container.read(accountControllerProvider);
        final action = begin(account, operation);
        await entered.future;
        api.expectedAccountId = requestKey;
        final newer = signedIn(requestKey);
        account.change(newer);
        reply.complete(
          response(signedIn(accountId).session!.preferences.toJson()),
        );
        expect(await action, isFalse);
        expect(container.read(accountControllerProvider), same(newer));
        expect(api.expectedAccountId, requestKey);
      },
    );
  }

  for (final token in [null, '']) {
    test(
      'malformed mobile token $token does not publish an API identity',
      () async {
        final store = MemoryTokenStore();
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: false,
          tokenStore: store,
          client: MockClient(
            (_) async => response({
              'user': {
                'id': accountId,
                'username': 'test-only',
                'display_name': 'Test',
              },
              'access_token': token,
            }),
          ),
        );
        addTearDown(api.close);
        await expectLater(
          AccountRepository(api).login('test-only', 'test-password'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
        expect(api.expectedAccountId, isNull);
        expect(store.token, isNull);
      },
    );
  }

  for (final operation in ['login', 'register', 'reset']) {
    for (final stage in ['csrf', 'token']) {
      test(
        '$operation freezes null owner through $stage with API-only identity change',
        () async {
          final csrfEntered = Completer<void>();
          final csrfReply = Completer<http.Response>();
          final store = WaitingReadStore();
          final writes = <http.Request>[];
          final api = ApiClient(
            baseUrl: Uri.parse('http://localhost'),
            isWeb: stage == 'csrf',
            tokenStore: store,
            client: MockClient((r) async {
              if (r.url.path == '/v1/auth/csrf') {
                csrfEntered.complete();
                return csrfReply.future;
              }
              writes.add(r);
              return response({'code': 'service_unavailable'}, 500);
            }),
          );
          addTearDown(api.close);
          final account = EditableAccount(
            const AccountState(phase: SessionPhase.signedOut),
          );
          final container = ProviderContainer(
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                AccountRepository(api),
              ),
              accountControllerProvider.overrideWith(() => account),
            ],
          );
          addTearDown(container.dispose);
          container.read(accountControllerProvider);
          final action = begin(account, operation);
          if (stage == 'csrf') {
            await csrfEntered.future;
          } else {
            await store.entered.future;
          }
          api.expectedAccountId = requestKey;
          if (stage == 'csrf') {
            csrfReply.complete(response({'csrf_token': 'test-only'}));
          } else {
            store.reply.complete('new-token');
          }
          expect(await action, isFalse);
          expect(writes, isEmpty);
          expect(api.expectedAccountId, requestKey);
          expect(
            container.read(accountControllerProvider).phase,
            SessionPhase.unreachable,
          );
        },
      );
    }
  }
}
