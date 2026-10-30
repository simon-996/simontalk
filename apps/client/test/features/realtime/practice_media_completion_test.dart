import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_client.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/practice/submission_manifest.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';

import '../conversation/conversation_projection_test.dart' as facts;
import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show ScopedAccountController;
import 'media_fixtures.dart';
import 'practice_media_transcripts_test.dart' show TestTranscriptJournal;

class TestPracticeCompletion extends ChangeNotifier
    implements RealtimePracticeCompletion {
  int requests = 0, aborts = 0, retries = 0;
  bool pending = false;
  final manifests = <PracticeCompletionManifest>[];
  PracticeCompletionReceipt? sealedReceipt;
  void Function()? onRequest;
  @override
  String? get errorCode => null;
  @override
  bool get hasPendingWork => pending;
  @override
  PracticeCompletionSummary? get summary => null;
  @override
  PracticeCompletionReceipt? get receipt => sealedReceipt;
  @override
  PracticeCompletionClientState get state => pending
      ? PracticeCompletionClientState.waiting
      : PracticeCompletionClientState.idle;
  @override
  void requestEnd() {
    requests++;
    pending = true;
    onRequest?.call();
    notifyListeners();
  }

  @override
  void finish(PracticeCompletionManifest manifest) {
    manifests.add(manifest);
    notifyListeners();
  }

  void confirm() {
    pending = false;
    notifyListeners();
  }

  void confirmReceipt(PracticeCompletionReceipt receipt) {
    sealedReceipt = receipt;
    confirm();
  }

  @override
  Future<void> retryPending() async {
    retries++;
  }

  @override
  Future<void> refresh() async {}
  @override
  void abort() {
    aborts++;
    pending = false;
    manifests.clear();
    sealedReceipt = null;
    notifyListeners();
  }
}

/// Keeps earlier media/provider tests focused on their own journal lifecycle.
class NoPendingTestCompletion extends TestPracticeCompletion {
  @override
  void requestEnd() {
    requests++;
    notifyListeners();
  }
}

class ReceiptTestTranscriptJournal extends TestTranscriptJournal
    implements SubmissionManifestProvider, SealedSubmissionReconciler {
  int reconciliations = 0;
  int missing = 0;
  @override
  int get rejectedCount => 0;
  @override
  int get permanentlyUnsavedCount => missing;
  @override
  SubmissionManifest? get submissionManifest => SubmissionManifest(
    ledger: SubmissionLedger.transcripts,
    events: [
      for (var i = 0; i < events.length; i++)
        SubmissionEventRef(sequence: i + 1, eventId: events[i].turnId),
    ],
    totalTextBytes: 0,
    pendingCountAtClose: events.length,
  );
  @override
  void reconcileSealed(SubmissionManifest received) {
    reconciliations++;
    final ids = received.events.map((e) => e.eventId).toSet();
    missing = events.where((e) => !ids.contains(e.turnId)).length;
    confirmPending();
  }
}

void main() {
  late MediaHarness h;
  late TestPracticeCompletion completion;
  void setup(WidgetTester tester, {PracticeCompletionFactory? factory}) {
    h = MediaHarness(tester);
    h.controller.dispose();
    completion = TestPracticeCompletion();
    h.controller = PracticeMediaController(
      repository: PracticeRepository(h.api, accountId: accountId),
      elapsed: () => tester.binding.clock.now().difference(h.origin),
      practiceCompletionFactory: factory ?? (_) => completion,
      protocolFactory: (_, cb) => h.protocol = TestProtocol(cb),
      transportFactory: () => h.transport,
      signallerFactory: (_, _) => h.signaller,
    );
    addTearDown(h.dispose);
  }

  void emit(ConversationUpdate update) =>
      h.protocol!.callbacks.emitConversation(update, 'channel-0');
  testWidgets(
    'constructing an accepted scope and ordinary stop do not request product end',
    (tester) async {
      setup(tester);
      await h.configured();
      expect(h.controller.practiceCompletion, same(completion));
      expect(completion.requests, 0);
      await h.controller.stop();
      expect(completion.requests, 0);
      expect(completion.manifests, isEmpty);
    },
  );
  testWidgets(
    'normal end captures empty input and unknown output without extending media',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(
        const TurnStartedUpdate(
          turnId: facts.userTurn,
          turnIndex: 1,
          role: ConversationRole.user,
        ),
      );
      emit(facts.ai());
      final done = h.controller.end();
      expect(h.transport.drains, 1);
      expect(completion.requests, 1);
      expect(completion.manifests, isEmpty);
      expect(h.controller.completionHasPendingWork, isTrue);
      await tester.pump(const Duration(seconds: 3));
      await done;
      final manifest = completion.manifests.single;
      expect(manifest.unfinalizedTurnIds, [facts.userTurn]);
      expect(manifest.unconfirmedResponseIds, [facts.responseId]);
      expect(manifest.tailStatus, PracticeCompletionTailStatus.unconfirmed);
      expect(manifest.journalUnavailable, isTrue);
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
      expect(h.controller.end(), same(done));
      expect(completion.requests, 1);
      completion.confirm();
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
    },
  );
  testWidgets(
    'transport drain failure still records end and an aborted manifest',
    (tester) async {
      setup(tester);
      await h.configured();
      h.transport.onDrain = () => throw StateError('device failure');
      await h.controller.end();
      expect(completion.requests, 1);
      expect(
        completion.manifests.single.tailStatus,
        PracticeCompletionTailStatus.aborted,
      );
      expect(h.transport.stops, 1);
    },
  );
  testWidgets(
    'account loss clears end without submitting as the next identity',
    (tester) async {
      setup(tester);
      await h.configured();
      final done = h.controller.end();
      h.api.expectedAccountId = requestKey;
      emit(facts.user());
      await done;
      expect(completion.aborts, 1);
      expect(completion.manifests, isEmpty);
      expect(h.controller.completionHasPendingWork, isFalse);
    },
  );
  testWidgets('a reentrant identity change in end cannot continue old input', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    completion.onRequest = () => h.api.expectedAccountId = requestKey;
    await h.controller.end();
    expect(completion.aborts, 1);
    expect(completion.manifests, isEmpty);
    expect(h.transport.stops, 1);
  });
  testWidgets('factory failure remains retryable without retaining media', (
    tester,
  ) async {
    var fail = true;
    setup(
      tester,
      factory: (_) {
        if (fail) throw StateError('factory');
        return completion;
      },
    );
    await h.configured();
    final done = h.controller.end();
    await tester.pump(const Duration(seconds: 3));
    await done;
    expect(h.transport.stops, 1);
    expect(h.controller.completionErrorCode, 'completion_unavailable');
    expect(h.controller.completionHasPendingWork, isTrue);
    fail = false;
    await h.controller.retryCompletion();
    expect(completion.requests, 1);
    expect(completion.manifests.length, 1);
  });
  testWidgets('factory account switch aborts returned owner before media', (
    tester,
  ) async {
    setup(
      tester,
      factory: (_) {
        h.api.expectedAccountId = requestKey;
        return completion;
      },
    );
    await h.controller.begin();
    expect(completion.aborts, 1);
    expect(completion.requests, 0);
    expect(h.transport.starts, 0);
  });
  testWidgets('unwatched closed scope retains completion until confirmation', (
    tester,
  ) async {
    h = MediaHarness(tester);
    h.controller.dispose();
    completion = TestPracticeCompletion();
    final container = ProviderContainer(
      overrides: [
        accountRepositoryProvider.overrideWithValue(AccountRepository(h.api)),
        accountControllerProvider.overrideWith(ScopedAccountController.new),
        realtimeTransportFactoryProvider.overrideWithValue(() => h.transport),
        realtimeProtocolFactoryProvider.overrideWithValue(
          (_, cb) => h.protocol = TestProtocol(cb),
        ),
        realtimeSignallerCreatorProvider.overrideWithValue(
          (_, _, _, _) => h.signaller,
        ),
        practiceCompletionClientFactoryProvider.overrideWithValue(
          (_, _) => completion,
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
    final done = h.controller.end();
    await tester.pump(const Duration(seconds: 3));
    await done;
    subscription.close();
    await tester.pump(Duration.zero);
    expect(h.controller.conversation, isNotNull);
    expect(completion.aborts, 0);
    completion.confirm();
    await tester.pump(Duration.zero);
    expect(h.controller.conversation, isNull);
    expect(completion.aborts, 1);
  });
  testWidgets(
    'synchronous final reaches manifest and sealed receipt settles missing without another capture',
    (tester) async {
      setup(tester);
      h.controller.dispose();
      final journal = ReceiptTestTranscriptJournal();
      h.controller = PracticeMediaController(
        repository: PracticeRepository(h.api, accountId: accountId),
        elapsed: () => tester.binding.clock.now().difference(h.origin),
        transcriptJournalFactory: (_) => journal,
        practiceCompletionFactory: (_) => completion,
        protocolFactory: (_, cb) => h.protocol = TestProtocol(cb),
        transportFactory: () => h.transport,
        signallerFactory: (_, _) => h.signaller,
      );
      await h.configured();
      emit(facts.user(finalText: false));
      h.protocol!.onDrain = () => emit(facts.user(revision: 2));
      final done = h.controller.end();
      await tester.pump(const Duration(seconds: 3));
      await done;
      final manifest = completion.manifests.single;
      expect(manifest.unfinalizedTurnIds, isEmpty);
      expect(manifest.transcripts.totalEvents, 1);
      expect(manifest.transcripts.pendingCountAtClose, 1);
      final scope = manifest.scope;
      final receipt = PracticeCompletionReceipt.fromJson(
        {
          'source': 'server_recorded',
          'account_id': scope.accountId,
          'session_id': scope.sessionId,
          'connection_id': scope.connectionId,
          'client_instance_id': scope.clientInstanceId,
          'epoch': scope.epoch,
          'sealed': true,
          'recoverable': false,
          'input_revision': 1,
          'input_hash': 'a' * 64,
          'practice_input_hash': 'b' * 64,
          'transcript_events': <Object>[],
          'playback_events': <Object>[],
        },
        scope: scope,
        practiceInputHash: 'b' * 64,
      );
      completion.confirmReceipt(receipt);
      expect(journal.reconciliations, 1);
      expect(journal.permanentlyUnsavedCount, 1);
      expect(journal.pendingCount, 0);
      expect(h.controller.completionHasPendingWork, isFalse);
      expect(completion.manifests.single, same(manifest));
      completion.notifyListeners();
      expect(journal.reconciliations, 1);
      expect(manifest.transcripts.pendingCountAtClose, 1);
    },
  );
}
