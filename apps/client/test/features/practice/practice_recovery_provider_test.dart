import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';

import 'practice_fixtures.dart';
import 'practice_providers_test.dart' show ScopedAccountController, signedIn;
import 'practice_recovery_controller_test.dart' show ReadClient;

void main() {
  testWidgets(
    'read scope is inert, stable on save and disposed on account switch',
    (tester) async {
      final waiting = Completer<http.Response>();
      final requests = <http.Request>[];
      final clients = <ReadClient>[];
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
          recoveryHttpClientFactoryProvider.overrideWithValue(() {
            final client = ReadClient((r) {
              requests.add(r);
              return waiting.future;
            });
            clients.add(client);
            return client;
          }),
        ],
      );
      final subscription = container.listen(
        practiceRecoveryProvider,
        (_, _) {},
      );
      try {
        final first = container.read(practiceRecoveryProvider)!;
        final account = container.read(
          accountControllerProvider.notifier,
        ) as ScopedAccountController;
        expect(requests, isEmpty);
        account.change(signedIn(accountId, busy: true));
        await tester.pump();
        expect(container.read(practiceRecoveryProvider), same(first));
        final pending = first.refresh();
        await tester.pump();
        api.expectedAccountId = requestKey;
        account.change(signedIn(requestKey));
        await tester.pump();
        await pending;
        expect(clients.single.closed, isTrue);
        expect(first.recovery, isNull);
        expect(container.read(practiceRecoveryProvider), isNot(same(first)));
        waiting.complete(
          response({'practice': practiceJson(), 'connection': null}),
        );
        await tester.pump();
        await first.refresh();
        expect(requests, hasLength(1));
        api.expectedAccountId = null;
        account.change(const AccountState(phase: SessionPhase.signedOut));
        await tester.pump();
        expect(container.read(practiceRecoveryProvider), isNull);
      } finally {
        subscription.close();
        container.dispose();
        api.close();
        await tester.pump();
      }
    },
  );
}
