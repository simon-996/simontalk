import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';

import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart'
    show ScopedAccountController, signedIn;
import 'media_fixtures.dart';

void main() {
  testWidgets('default account scope is lazy and 503 never creates media', (
    tester,
  ) async {
    final h = MediaHarness(tester);
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    var mediaCreates = 0;
    final container = ProviderContainer(
      overrides: [
        accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
        realtimeObservationJournalFactoryProvider.overrideWithValue(
          (_, _, _, _) => TestObservationJournal(),
        ),
        accountControllerProvider.overrideWith(ScopedAccountController.new),
        realtimeTransportFactoryProvider.overrideWithValue(() {
          mediaCreates++;
          return h.transport;
        }),
      ],
    );
    final subscription = container.listen(practiceMediaProvider, (_, _) {});
    final controller = container.read(practiceMediaProvider)!;
    expect(h.requests, isEmpty);
    await controller.begin();
    expect(controller.phase, PracticeMediaPhase.localClosed);
    expect(controller.errorCode, 'realtime_unavailable');
    expect(mediaCreates, 0);
    expect(h.requests.length, 1);
    subscription.close();
    container.dispose();
    await h.dispose();
  });

  testWidgets(
    'unavailable protocol rejects admitted fixture before media creation',
    (tester) async {
      final h = MediaHarness(tester);
      var mediaCreates = 0;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
          realtimeObservationJournalFactoryProvider.overrideWithValue(
            (_, _, _, _) => TestObservationJournal(),
          ),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
          realtimeTransportFactoryProvider.overrideWithValue(() {
            mediaCreates++;
            return h.transport;
          }),
        ],
      );
      final subscription = container.listen(practiceMediaProvider, (_, _) {});
      final controller = container.read(practiceMediaProvider)!;
      await controller.begin();
      await tester.pump();
      expect(controller.errorCode, 'realtime_unavailable');
      expect(controller.releaseStatus, MediaReleaseStatus.released);
      expect(mediaCreates, 0);
      expect(h.requests.length, 4);
      subscription.close();
      container.dispose();
      await h.dispose();
    },
  );

  testWidgets(
    'identity change disposes connecting media and busy updates keep scope',
    (tester) async {
      final h = MediaHarness(tester);
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
          realtimeObservationJournalFactoryProvider.overrideWithValue(
            (_, _, _, _) => TestObservationJournal(),
          ),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
          realtimeTransportFactoryProvider.overrideWithValue(() => h.transport),
          realtimeProtocolFactoryProvider.overrideWithValue(
            (configuration, callbacks) => TestProtocol(callbacks),
          ),
        ],
      );
      final subscription = container.listen(practiceMediaProvider, (_, _) {});
      final initial = container.read(practiceMediaProvider)!;
      final account = container.read(
        accountControllerProvider.notifier,
      ) as ScopedAccountController;
      account.change(signedIn(accountId, busy: true));
      await tester.pump();
      expect(container.read(practiceMediaProvider), same(initial));
      unawaited(initial.begin());
      await tester.pump();
      expect(initial.phase, PracticeMediaPhase.connecting);
      h.api.expectedAccountId = requestKey;
      account.change(signedIn(requestKey));
      await tester.pump();
      expect(h.transport.stops, 1);
      expect(initial.phase, PracticeMediaPhase.localClosed);
      final next = container.read(practiceMediaProvider)!;
      expect(next, isNot(same(initial)));
      expect(h.requests.length, 2);
      h.api.expectedAccountId = null;
      account.change(const AccountState(phase: SessionPhase.signedOut));
      await tester.pump();
      expect(container.read(practiceMediaProvider), isNull);
      subscription.close();
      container.dispose();
      await h.dispose();
    },
  );
}
