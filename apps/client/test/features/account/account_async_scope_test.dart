import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/account/account_models.dart';

import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show signedIn;
import 'account_repository_test.dart' show MemoryTokenStore;
import 'preferences_action_guards_test.dart' show EditableAccount;

Map<String, dynamic> get prefs =>
    signedIn(accountId).session!.preferences.toJson();

class PendingDeletionStore extends MemoryTokenStore {
  final started = Completer<void>();
  final done = Completer<void>();
  @override
  Future<void> delete() async {
    started.complete();
    await done.future;
  }
}

void main() {
  for (final operation in ['save', 'logout']) {
    test(
      '$operation waiting for CSRF cannot write using the next account',
      () async {
        final waiting = Completer<void>();
        final csrf = Completer<http.Response>();
        final writes = <http.Request>[];
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: true,
          tokenStore: TestTokenStore(),
          client: MockClient((r) async {
            if (r.url.path == '/v1/auth/csrf') {
              waiting.complete();
              return csrf.future;
            }
            writes.add(r);
            return response({...prefs, 'version': 2});
          }),
        )..expectedAccountId = accountId;
        addTearDown(api.close);
        final repository = AccountRepository(api);
        final Future<Object?> action = operation == 'save'
            ? repository.savePreferences(
                signedIn(accountId).session!.preferences,
              )
            : repository.logout();
        final checked = expectLater(
          action,
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'account_changed',
            ),
          ),
        );
        await waiting.future;
        api.expectedAccountId = requestKey;
        csrf.complete(response({'csrf_token': 'test-only'}));
        await checked;
        expect(writes, isEmpty);
        expect(api.expectedAccountId, requestKey);
      },
    );
  }

  test(
    'preferences late GET cannot return data after identity changed',
    () async {
      final waiting = Completer<void>();
      final reply = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((r) async {
          waiting.complete();
          return reply.future;
        }),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final action = AccountRepository(api).loadPreferences();
      final checked = expectLater(
        action,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
      await waiting.future;
      api.expectedAccountId = requestKey;
      reply.complete(response(prefs));
      await checked;
      expect(api.expectedAccountId, requestKey);
    },
  );

  for (final operation in ['save', 'logout']) {
    for (final outcome in ['success', 'failure', 'unauthorized']) {
      test(
        'late $operation $outcome cannot overwrite a newer account state',
        () async {
          final waiting = Completer<void>();
          final reply = Completer<http.Response>();
          final api = ApiClient(
            baseUrl: Uri.parse('http://localhost'),
            isWeb: false,
            tokenStore: TestTokenStore(),
            client: MockClient((r) async {
              waiting.complete();
              return reply.future;
            }),
          )..expectedAccountId = accountId;
          addTearDown(api.close);
          final account = EditableAccount(signedIn(accountId));
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
          final action = operation == 'save'
              ? account.save(
                  signedIn(accountId).session!.preferences
                      .copyWith(difficulty: Difficulty.intermediate),
                )
              : account.logout();
          await waiting.future;
          api.expectedAccountId = requestKey;
          final next = signedIn(requestKey);
          account.change(next);
          reply.complete(
            outcome == 'success'
                ? response({
                    ...prefs,
                    'difficulty': 'intermediate',
                    'version': 2,
                  })
                : response({
                    'code': outcome == 'unauthorized'
                        ? 'unauthorized'
                        : 'service_unavailable',
                  }, outcome == 'unauthorized' ? 401 : 500),
          );
          expect(await action, isFalse);
          expect(container.read(accountControllerProvider), same(next));
          expect(api.expectedAccountId, requestKey);
        },
      );
    }
  }

  test(
    'conflict refresh cannot restore old preferences over a newer account',
    () async {
      final waiting = Completer<void>();
      final reply = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((r) async {
          if (r.method == 'PATCH') {
            return response({'code': 'preferences_conflict'}, 409);
          }
          waiting.complete();
          return reply.future;
        }),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final account = EditableAccount(signedIn(accountId));
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
        ],
      );
      addTearDown(container.dispose);
      container.read(accountControllerProvider);
      final action = account.save(signedIn(accountId).session!.preferences);
      await waiting.future;
      final next = signedIn(requestKey);
      api.expectedAccountId = requestKey;
      account.change(next);
      reply.complete(response({...prefs, 'version': 2}));
      expect(await action, isFalse);
      expect(container.read(accountControllerProvider), same(next));
    },
  );

  for (final operation in ['save', 'logout']) {
    test('disposed controller ignores pending $operation completion', () async {
      final waiting = Completer<void>();
      final reply = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((r) async {
          waiting.complete();
          return reply.future;
        }),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final account = EditableAccount(signedIn(accountId));
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
        ],
      );
      container.read(accountControllerProvider);
      final action = operation == 'save'
          ? account.save(signedIn(accountId).session!.preferences)
          : account.logout();
      await waiting.future;
      container.dispose();
      reply.complete(response({...prefs, 'version': 2}));
      expect(await action, isFalse);
    });
  }

  test(
    'native logout network failure cannot delete the newly active credential',
    () async {
      final waiting = Completer<void>();
      final reply = Completer<http.Response>();
      final store = MemoryTokenStore()..token = 'old-token';
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: store,
        client: MockClient((_) async {
          waiting.complete();
          return reply.future;
        }),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final action = AccountRepository(api).logout();
      final checked = expectLater(
        action,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
      await waiting.future;
      api.expectedAccountId = requestKey;
      store.token = 'new-token';
      reply.completeError(http.ClientException('network failure'));
      await checked;
      expect(store.token, 'new-token');
      expect(api.expectedAccountId, requestKey);
    },
  );

  for (final reason in ['unauthorized', 'account_changed']) {
    for (final next in ['new_identity', 'disposed']) {
      test('automatic $reason recovery cannot publish after $next', () async {
        final waiting = Completer<void>();
        final reply = Completer<http.Response>();
        final api = ApiClient(
          baseUrl: Uri.parse('http://localhost'),
          isWeb: false,
          tokenStore: TestTokenStore(),
          client: MockClient((r) async {
            if (r.method == 'PATCH') {
              return response({
                'code': reason,
              }, reason == 'unauthorized' ? 401 : 409);
            }
            if (r.url.path == '/v1/me') {
              waiting.complete();
              return reply.future;
            }
            return response(prefs);
          }),
        )..expectedAccountId = accountId;
        addTearDown(api.close);
        final account = EditableAccount(signedIn(accountId));
        final container = ProviderContainer(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(() => account),
          ],
        );
        container.read(accountControllerProvider);
        final action = account.save(signedIn(accountId).session!.preferences);
        await waiting.future;
        final newer = signedIn(requestKey);
        if (next == 'disposed') {
          container.dispose();
        } else {
          api.expectedAccountId = requestKey;
          account.change(newer);
        }
        reply.complete(
          response({
            'id': accountId,
            'username': 'test-only',
            'display_name': 'Test',
          }),
        );
        expect(await action, isFalse);
        if (next != 'disposed') {
          expect(container.read(accountControllerProvider), same(newer));
          expect(api.expectedAccountId, requestKey);
          container.dispose();
        }
      });
    }
  }

  test(
    'logout local cleanup completion cannot clear a newer API identity',
    () async {
      final store = PendingDeletionStore()..token = 'old-token';
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: store,
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final action = AccountRepository(api).logout();
      final checked = expectLater(
        action,
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
      await store.started.future;
      api.expectedAccountId = requestKey;
      store.done.complete();
      await checked;
      expect(api.expectedAccountId, requestKey);
    },
  );

  for (final initialOwner in [null, accountId]) {
    for (final order in ['old_first', 'new_first']) {
      test(
        'newest restore wins from $initialOwner with $order replies',
        () async {
          final started = Completer<void>();
          final replies = [
            Completer<http.Response>(),
            Completer<http.Response>(),
          ];
          var count = 0;
          final api = ApiClient(
            baseUrl: Uri.parse('http://localhost'),
            isWeb: true,
            tokenStore: TestTokenStore(),
            client: MockClient((r) async {
              if (r.url.path == '/v1/me') {
                final index = count++;
                if (count == 2) started.complete();
                return replies[index].future;
              }
              return response(prefs);
            }),
          )..expectedAccountId = initialOwner;
          addTearDown(api.close);
          final account = EditableAccount(signedIn(accountId));
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
          final first = account.restore();
          final second = account.restore();
          await started.future;
          final user = {
            'id': requestKey,
            'username': 'new-test-only',
            'display_name': 'New Test',
          };
          if (order == 'old_first') {
            replies[0].complete(response(user));
            await first;
            replies[1].complete(response(user));
            await second;
          } else {
            replies[1].complete(response(user));
            await second;
            replies[0].complete(
              response({
                'id': accountId,
                'username': 'old-test-only',
                'display_name': 'Old Test',
              }),
            );
            await first;
          }
          final current = container.read(accountControllerProvider);
          expect(current.phase, SessionPhase.signedIn);
          expect(current.session!.user.id, requestKey);
          expect(api.expectedAccountId, requestKey);
        },
      );
    }
  }
}
