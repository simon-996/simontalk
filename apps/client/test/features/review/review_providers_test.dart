import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/review/practice_review_client.dart';
import 'package:simontalk_client/features/review/review_providers.dart';

import '../practice/practice_providers_test.dart'
    show signedIn, ScopedAccountController;
import 'review_fixtures.dart';
import '../realtime/api_realtime_signaller_test.dart' show TrackedClient;

void main() {
  testWidgets(
    'provider is silent value keyed reactive and clears on account loss',
    (tester) async {
      var requests = 0;
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
          reviewHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((r) async {
              requests++;
              return response(
                r.url.path.endsWith('review-input') ? inputJson() : jobJson(),
              );
            }),
          ),
        ],
      );
      final changes = <PracticeReviewClient?>[];
      final subscription = container.listen(
        practiceReviewProvider(target()),
        (_, next) => changes.add(next),
      );
      try {
        final initial = container.read(practiceReviewProvider(target()))!;
        expect(container.read(practiceReviewProvider(target())), same(initial));
        expect(requests, 0);
        final account = container.read(
          accountControllerProvider.notifier,
        ) as ScopedAccountController;
        account.change(signedIn(accountId, busy: true));
        await tester.pump();
        expect(container.read(practiceReviewProvider(target())), same(initial));
        await initial.refresh();
        await tester.pump();
        expect(changes, isNotEmpty);
        expect(initial.job, isNotNull);
        api.expectedAccountId = requestKey;
        expect(initial.job, isNull);
        account.change(signedIn(requestKey));
        await tester.pump();
        expect(container.read(practiceReviewProvider(target())), isNull);
        final count = requests;
        await initial.requestReview();
        expect(requests, count);
        account.change(const AccountState(phase: SessionPhase.unreachable));
        await tester.pump();
        expect(container.read(practiceReviewProvider(target())), isNull);
      } finally {
        subscription.close();
        container.dispose();
        api.close();
        await tester.pump();
      }
    },
  );
  test(
    'autoDispose stops an unfinished operation and closes owned HTTP',
    () async {
      final wait = Completer<http.Response>();
      final owned = TrackedClient((_) => wait.future);
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
          reviewHttpClientFactoryProvider.overrideWithValue(() => owned),
        ],
      );
      final subscription = container.listen(
        practiceReviewProvider(target()),
        (_, _) {},
      );
      final initial = container.read(practiceReviewProvider(target()))!;
      final task = initial.requestReview();
      await Future<void>.delayed(Duration.zero);
      subscription.close();
      await container.pump();
      await task;
      expect(initial.state, PracticeReviewClientState.aborted);
      expect(owned.closes, 1);
      await initial.requestReview();
      wait.complete(response(inputJson()));
      await Future<void>.delayed(Duration.zero);
      expect(initial.job, isNull);
      container.dispose();
      api.close();
    },
  );
}
