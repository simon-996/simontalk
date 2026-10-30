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
import 'practice_media_completion_test.dart' show NoPendingTestCompletion;
import 'practice_media_transcripts_test.dart' show TestTranscriptJournal;
import '../conversation/conversation_projection_test.dart' as facts;

ProviderContainer createMediaContainer(
  MediaHarness h,
  TestTranscriptJournal journal,
) => ProviderContainer(
  overrides: [
    practiceCompletionClientFactoryProvider.overrideWithValue(
      (_, _) => NoPendingTestCompletion(),
    ),
    accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
    realtimeObservationJournalFactoryProvider.overrideWithValue(
      (_, _, _, _) => TestObservationJournal(),
    ),
    realtimeTranscriptJournalFactoryProvider.overrideWithValue(
      (_, _) => journal,
    ),
    accountControllerProvider.overrideWith(ScopedAccountController.new),
    realtimeTransportFactoryProvider.overrideWithValue(() => h.transport),
    realtimeProtocolFactoryProvider.overrideWithValue(
      (_, callbacks) => h.protocol = TestProtocol(callbacks),
    ),
    realtimeSignallerCreatorProvider.overrideWithValue(
      (_, _, _, _) => h.signaller,
    ),
  ],
);

void main() {
  testWidgets(
    'normal end retains original account drain and pending journal after page leaves',
    (tester) async {
      final h = MediaHarness(tester);
      h.controller.dispose();
      final journal = TestTranscriptJournal();
      final container = ProviderContainer(
        overrides: [
          practiceCompletionClientFactoryProvider.overrideWithValue(
            (_, _) => NoPendingTestCompletion(),
          ),
          accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
          realtimeObservationJournalFactoryProvider.overrideWithValue(
            (_, _, _, _) => TestObservationJournal(),
          ),
          realtimeTranscriptJournalFactoryProvider.overrideWithValue(
            (_, _) => journal,
          ),
          accountControllerProvider.overrideWith(ScopedAccountController.new),
          realtimeTransportFactoryProvider.overrideWithValue(() => h.transport),
          realtimeProtocolFactoryProvider.overrideWithValue(
            (_, callbacks) => h.protocol = TestProtocol(callbacks),
          ),
          realtimeSignallerCreatorProvider.overrideWithValue(
            (_, _, _, _) => h.signaller,
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await h.dispose();
      });
      final subscription = container.listen(practiceMediaProvider, (_, _) {});
      h.controller = container.read(practiceMediaProvider)!;
      await h.configured();
      h.protocol!.callbacks.emitConversation(
        facts.user(finalText: false),
        'channel-0',
      );
      final done = h.controller.end();
      subscription.close();
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.draining);
      expect(journal.aborts, 0);
      h.protocol!.callbacks.emitConversation(
        facts.user(revision: 2),
        'channel-0',
      );
      await tester.pump(const Duration(seconds: 3));
      await done;
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(journal.finishes, 1);
      expect(journal.pendingCount, 1);
      expect(journal.aborts, 0);
      expect(container.read(practiceMediaProvider), same(h.controller));
      h.api.expectedAccountId = requestKey;
      final account = container.read(
        accountControllerProvider.notifier,
      ) as ScopedAccountController;
      account.change(signedIn(requestKey));
      await tester.pump(Duration.zero);
      expect(journal.aborts, 1);
      expect(journal.events, isEmpty);
      expect(h.controller.conversation, isNull);
    },
  );

  testWidgets('last acknowledgement releases an unwatched normal end scope', (
    tester,
  ) async {
    final h = MediaHarness(tester);
    h.controller.dispose();
    final journal = TestTranscriptJournal();
    final container = createMediaContainer(h, journal);
    addTearDown(() async {
      container.dispose();
      await h.dispose();
    });
    final subscription = container.listen(practiceMediaProvider, (_, _) {});
    h.controller = container.read(practiceMediaProvider)!;
    await h.configured();
    h.protocol!.callbacks.emitConversation(facts.user(), 'channel-0');
    final done = h.controller.end();
    subscription.close();
    await tester.pump(const Duration(seconds: 3));
    await done;
    expect(journal.pendingCount, 1);
    expect(journal.aborts, 0);
    journal.confirmPending();
    await tester.pump(Duration.zero);
    expect(journal.aborts, 1);
    expect(h.controller.conversation, isNull);
    expect(container.exists(practiceMediaProvider), isFalse);
  });

  testWidgets('a confirmed end remains readable until its last page leaves', (
    tester,
  ) async {
    final h = MediaHarness(tester);
    h.controller.dispose();
    final journal = TestTranscriptJournal();
    final container = createMediaContainer(h, journal);
    addTearDown(() async {
      container.dispose();
      await h.dispose();
    });
    final subscription = container.listen(practiceMediaProvider, (_, _) {});
    h.controller = container.read(practiceMediaProvider)!;
    await h.configured();
    h.protocol!.callbacks.emitConversation(facts.user(), 'channel-0');
    final done = h.controller.end();
    await tester.pump(const Duration(seconds: 3));
    await done;
    journal.confirmPending();
    await tester.pump();
    expect(journal.aborts, 0);
    expect(h.controller.conversation!.turns, isNotEmpty);
    subscription.close();
    await tester.pump(Duration.zero);
    expect(journal.aborts, 1);
    expect(h.controller.conversation, isNull);
    expect(container.exists(practiceMediaProvider), isFalse);
  });

  testWidgets(
    'leaving active media stops capture but retains failed pending text',
    (tester) async {
      final h = MediaHarness(tester);
      h.controller.dispose();
      final journal = TestTranscriptJournal();
      final container = createMediaContainer(h, journal);
      addTearDown(() async {
        container.dispose();
        await h.dispose();
      });
      final subscription = container.listen(practiceMediaProvider, (_, _) {});
      h.controller = container.read(practiceMediaProvider)!;
      await h.configured();
      h.protocol!.callbacks.emitConversation(facts.user(), 'channel-0');
      subscription.close();
      expect(h.transport.stops, 1);
      await tester.pump();
      expect(h.transport.stops, 1);
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(journal.finishes, 1);
      expect(journal.pendingCount, 1);
      expect(journal.aborts, 0);
      expect(journal.retries, 0);
      journal.onRetry = () async => journal.confirmPending();
      await h.controller.transcriptJournal!.retryPending();
      await tester.pump(Duration.zero);
      expect(journal.retries, 1);
      expect(journal.aborts, 1);
      expect(h.controller.conversation, isNull);
      expect(container.exists(practiceMediaProvider), isFalse);
    },
  );

  testWidgets('an unwatched empty drain releases only after local closure', (
    tester,
  ) async {
    final h = MediaHarness(tester);
    h.controller.dispose();
    final journal = TestTranscriptJournal();
    final container = createMediaContainer(h, journal);
    addTearDown(() async {
      container.dispose();
      await h.dispose();
    });
    final subscription = container.listen(practiceMediaProvider, (_, _) {});
    h.controller = container.read(practiceMediaProvider)!;
    await h.configured();
    final done = h.controller.end();
    subscription.close();
    await tester.pump(const Duration(seconds: 2));
    expect(h.controller.phase, PracticeMediaPhase.draining);
    expect(journal.pendingCount, 0);
    expect(journal.aborts, 0);
    await tester.pump(const Duration(seconds: 1));
    await done;
    await tester.pump(Duration.zero);
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(journal.finishes, 1);
    expect(journal.aborts, 1);
    expect(container.exists(practiceMediaProvider), isFalse);
  });

  testWidgets(
    'leaving active media after acknowledgement clears retained body',
    (tester) async {
      final h = MediaHarness(tester);
      h.controller.dispose();
      final journal = TestTranscriptJournal();
      final container = createMediaContainer(h, journal);
      addTearDown(() async {
        container.dispose();
        await h.dispose();
      });
      final subscription = container.listen(practiceMediaProvider, (_, _) {});
      h.controller = container.read(practiceMediaProvider)!;
      await h.configured();
      h.protocol!.callbacks.emitConversation(facts.user(), 'channel-0');
      journal.confirmPending();
      expect(journal.aborts, 0);
      expect(h.controller.conversation!.turns, isNotEmpty);
      subscription.close();
      expect(h.transport.stops, 1);
      await tester.pump(Duration.zero);
      expect(journal.finishes, 1);
      expect(journal.aborts, 1);
      expect(h.controller.conversation, isNull);
      expect(container.exists(practiceMediaProvider), isFalse);
    },
  );

  testWidgets(
    'journal notification after account loss clears retained scope without recursion',
    (tester) async {
      final h = MediaHarness(tester);
      h.controller.dispose();
      final journal = TestTranscriptJournal();
      final container = createMediaContainer(h, journal);
      addTearDown(() async {
        container.dispose();
        await h.dispose();
      });
      final subscription = container.listen(practiceMediaProvider, (_, _) {});
      h.controller = container.read(practiceMediaProvider)!;
      await h.configured();
      h.protocol!.callbacks.emitConversation(facts.user(), 'channel-0');
      final done = h.controller.end();
      subscription.close();
      await tester.pump(const Duration(seconds: 3));
      await done;
      expect(journal.aborts, 0);
      h.api.expectedAccountId = requestKey;
      journal.confirmPending();
      expect(journal.aborts, 1);
      expect(h.controller.conversation, isNull);
      await tester.pump(Duration.zero);
      expect(journal.aborts, 1);
      expect(container.exists(practiceMediaProvider), isFalse);
    },
  );

  testWidgets('default account scope is lazy and 503 never creates media', (
    tester,
  ) async {
    final h = MediaHarness(tester);
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    var mediaCreates = 0;
    final container = ProviderContainer(
      overrides: [
        practiceCompletionClientFactoryProvider.overrideWithValue(
          (_, _) => NoPendingTestCompletion(),
        ),
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
    expect(controller.transcriptJournalFactory, isNotNull);
    expect(controller.transcriptJournal, isNull);
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
      final journal = TestTranscriptJournal();
      var mediaCreates = 0;
      final container = ProviderContainer(
        overrides: [
          practiceCompletionClientFactoryProvider.overrideWithValue(
            (_, _) => NoPendingTestCompletion(),
          ),
          accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
          realtimeObservationJournalFactoryProvider.overrideWithValue(
            (_, _, _, _) => TestObservationJournal(),
          ),
          realtimeTranscriptJournalFactoryProvider.overrideWithValue(
            (_, _) => journal,
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
      final journal = TestTranscriptJournal();
      final container = ProviderContainer(
        overrides: [
          practiceCompletionClientFactoryProvider.overrideWithValue(
            (_, _) => NoPendingTestCompletion(),
          ),
          accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
          realtimeObservationJournalFactoryProvider.overrideWithValue(
            (_, _, _, _) => TestObservationJournal(),
          ),
          realtimeTranscriptJournalFactoryProvider.overrideWithValue(
            (_, _) => journal,
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
      expect(initial.transcriptJournal, same(journal));
      h.api.expectedAccountId = requestKey;
      account.change(signedIn(requestKey));
      await tester.pump();
      expect(h.transport.stops, 1);
      expect(initial.phase, PracticeMediaPhase.localClosed);
      expect(journal.aborts, 1);
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
