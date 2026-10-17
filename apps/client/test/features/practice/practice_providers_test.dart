import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/practice_preparation_controller.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';

import 'practice_fixtures.dart';

AccountState signedIn(String id, {bool busy = false}) => AccountState(
  phase: SessionPhase.signedIn,
  busy: busy,
  session: AccountSession(
    AccountUser(id: id, username: 'test-only', displayName: 'Test'),
    const AccountPreferences(
      difficulty: Difficulty.beginner,
      speechPace: 'normal',
      subtitleDefault: true,
      chineseHintsEnabled: true,
      version: 1,
    ),
  ),
);

class ScopedAccountController extends AccountController {
  @override
  AccountState build() => signedIn(accountId);
  void change(AccountState value) => state = value;
}

void main() {
  testWidgets(
    'account scope is stable for preferences and disposed on identity changes',
    (tester) async {
      var requests = 0;
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async {
          requests++;
          return response({});
        }),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
        ],
      );
      try {
        final subscription = container.listen(
          practicePreparationProvider,
          (_, _) {},
        );
        final initial = container.read(practicePreparationProvider)!;
        final account = container.read(
          accountControllerProvider.notifier,
        ) as ScopedAccountController;
        account.change(signedIn(accountId, busy: true));
        await tester.pump();
        expect(container.read(practicePreparationProvider), same(initial));
        api.expectedAccountId = requestKey;
        account.change(signedIn(requestKey));
        await tester.pump();
        final next = container.read(practicePreparationProvider)!;
        expect(next, isNot(same(initial)));
        await initial.begin();
        expect(requests, 0);
        api.expectedAccountId = null;
        account.change(const AccountState(phase: SessionPhase.signedOut));
        await tester.pump();
        expect(container.read(practicePreparationProvider), isNull);
        await next.begin();
        expect(requests, 0);
        subscription.close();
      } finally {
        container.dispose();
        await tester.pump();
        api.close();
      }
    },
  );

  testWidgets(
    'scope disposal stops an outstanding reservation and cancels server preparation',
    (tester) async {
      final paths = <String>[];
      var instance = clientId;
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/csrf')) {
            return response({'csrf_token': 'test'});
          }
          paths.add(r.url.path);
          if (r.url.path.endsWith('/connections')) {
            // Each provider has a fresh secure client UUID.
            instance = jsonDecode(r.body)['client_instance_id'] as String;
            return response(connectionJson(instance: instance));
          }
          if (r.url.path.contains('/connections/')) {
            return response(
              connectionJson(instance: instance, status: 'closed'),
            );
          }
          return response(
            practiceJson(
              status: r.url.path.endsWith('/cancel-preparation')
                  ? 'cancelled'
                  : 'created',
            ),
          );
        }),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
        ],
      );
      final subscription = container.listen(
        practicePreparationProvider,
        (_, _) {},
      );
      final preparation = container.read(practicePreparationProvider)!;
      await preparation.begin();
      expect(preparation.phase, PreparationPhase.reserved);
      subscription.close();
      container.dispose();
      await tester.pump();
      expect(paths.where((p) => p.endsWith('/cancel-preparation')).length, 2);
      api.close();
    },
  );
}
