import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/playback_evidence_journal.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';

import '../conversation/conversation_projection_test.dart' as facts;
import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show ScopedAccountController;
import 'media_fixtures.dart';
import 'practice_media_transcripts_test.dart' show TestTranscriptJournal;

class TestPlaybackEvidenceJournal extends ChangeNotifier
    implements RealtimePlaybackEvidenceJournal {
  final alignments = <ConversationTurn>[];
  final freezes = <(ConversationTurn, int, InterruptedPrefixReason)>[];
  final revocations = <String>[];
  int finishes = 0;
  int aborts = 0;
  int pending = 0;
  void Function()? onRecord;
  @override
  int get pendingCount => pending;
  @override
  int get rejectedCount => 0;
  @override
  String? get errorCode => null;
  @override
  void recordAlignment(ConversationTurn turn) {
    onRecord?.call();
    alignments.add(turn);
    pending++;
    notifyListeners();
  }

  @override
  void recordFreeze(
    ConversationTurn turn, {
    required int stopBoundaryMs,
    required InterruptedPrefixReason reason,
  }) {
    onRecord?.call();
    freezes.add((turn, stopBoundaryMs, reason));
    pending++;
    notifyListeners();
  }

  @override
  void recordRevoke(String responseId) {
    onRecord?.call();
    revocations.add(responseId);
    pending++;
    notifyListeners();
  }

  void acknowledge() {
    pending = 0;
    notifyListeners();
  }

  @override
  Future<void> retryPending() async => acknowledge();
  @override
  void finish() => finishes++;
  @override
  void abort() {
    aborts++;
    alignments.clear();
    freezes.clear();
    revocations.clear();
    pending = 0;
    notifyListeners();
  }
}

void main() {
  late MediaHarness h;
  late TestPlaybackEvidenceJournal journal;
  ConversationScope? createdScope;
  void setup(WidgetTester tester, {PlaybackEvidenceJournalFactory? factory}) {
    h = MediaHarness(tester);
    h.controller.dispose();
    journal = TestPlaybackEvidenceJournal();
    createdScope = null;
    h.controller = PracticeMediaController(
      repository: PracticeRepository(h.api, accountId: accountId),
      elapsed: () =>
          h.manualElapsed ?? tester.binding.clock.now().difference(h.origin),
      playbackEvidenceJournalFactory:
          factory ??
          (scope) {
            createdScope = scope;
            return journal;
          },
      protocolFactory: (_, callbacks) => h.protocol = TestProtocol(callbacks),
      transportFactory: () => h.transport,
      signallerFactory: (_, _) => h.signaller,
    );
    addTearDown(h.dispose);
  }

  void emit(ConversationUpdate update, [String channel = 'channel-0']) =>
      h.protocol!.callbacks.emitConversation(update, channel);

  testWidgets('closed admission constructs no playback ledger or media', (
    tester,
  ) async {
    setup(tester);
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await h.controller.begin();
    expect(createdScope, isNull);
    expect(h.transport.starts, 0);
  });

  testWidgets(
    'only applied alignment is captured with exact original source version',
    (tester) async {
      setup(tester);
      await h.configured();
      expect(createdScope!.connectionId, connectionId);
      expect(createdScope!.epoch, 1);
      emit(facts.user());
      emit(facts.ai(finalText: false));
      expect(journal.alignments, isEmpty);
      emit(facts.playback(revision: 2));
      emit(facts.playback(revision: 2));
      emit(facts.playback());
      expect(journal.alignments.length, 1);
      expect(journal.alignments.single.text, 'Hello there');
      expect(journal.alignments.single.isFinal, isFalse);
      expect(journal.alignments.single.playback.playedText, 'Hello');
      await h.controller.stop();
    },
  );

  testWidgets(
    'first freeze captures original version before late final and repeats add nothing',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      h.protocol!.callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      h.protocol!.callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      expect(journal.freezes.length, 1);
      expect(journal.freezes.single.$1.revision, 1);
      expect(journal.freezes.single.$1.text, 'Hello there');
      expect(journal.freezes.single.$2, 400);
      emit(facts.ai(revision: 2, text: 'A revised final'));
      expect(journal.freezes.single.$1.revision, 1);
      expect(journal.alignments.single.revision, 1);
      expect(
        h.controller.conversation!.turns.single.playback.status,
        DeliveryStatus.unknown,
      );
      await h.controller.stop();
    },
  );

  testWidgets(
    'normal end records unknown started response at zero revision and finishes after cutoff',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(
        const TurnStartedUpdate(
          turnId: facts.aiTurn,
          turnIndex: 2,
          role: ConversationRole.assistant,
          responseId: facts.responseId,
        ),
      );
      final done = h.controller.end();
      expect(journal.freezes.single.$1.revision, 0);
      expect(journal.freezes.single.$2, 0);
      expect(journal.freezes.single.$3, InterruptedPrefixReason.normalEnd);
      expect(journal.finishes, 0);
      await tester.pump(const Duration(seconds: 3));
      await done;
      expect(journal.finishes, 1);
      expect(journal.aborts, 0);
      expect(h.controller.playbackEvidencePendingCount, 1);
    },
  );

  testWidgets(
    'normal end fallback retains playback history after a final source resets alignment',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback(until: 400));
      emit(facts.ai(revision: 2));
      expect(
        h.controller.conversation!.turns.single.playback.status,
        DeliveryStatus.unknown,
      );
      // A stale source callback never raises the accepted output boundary.
      emit(facts.playback(revision: 2, until: 900));
      expect(journal.alignments.length, 1);
      final done = h.controller.end();
      expect(journal.freezes.single.$1.revision, 2);
      expect(journal.freezes.single.$1.playback.status, DeliveryStatus.unknown);
      expect(journal.freezes.single.$2, 400);
      expect(h.controller.phase, PracticeMediaPhase.draining);
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets(
    'an explicit boundary cannot contradict playback recorded before a source reset',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback(until: 400));
      emit(facts.ai(revision: 2));
      h.protocol!.callbacks.freezeResponse(facts.responseId, 399, 'channel-0');
      expect(journal.freezes, isEmpty);
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'conversation_invalid');
      expect(h.transport.stops, 1);
    },
  );

  testWidgets(
    'an explicit valid boundary remains authoritative after a source reset',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback(until: 400));
      emit(facts.ai(revision: 2));
      h.protocol!.onDrain = () => h.protocol!.callbacks.freezeResponse(
        facts.responseId,
        550,
        'channel-0',
      );
      final done = h.controller.end();
      expect(journal.freezes.single.$2, 550);
      expect(journal.freezes.single.$3, InterruptedPrefixReason.normalEnd);
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets(
    'applied revocation is captured before context-invalidated stop',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      final callbacks = h.protocol!.callbacks;
      callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      final context = callbacks.prepareContext('channel-0')!;
      callbacks.sendContextControl('{"type":"replace"}', 'channel-0', context);
      callbacks.confirmContextTruncated(context, 'channel-0');
      callbacks.revokeFrozenPrefix(facts.responseId, 'channel-0');
      expect(journal.revocations, [facts.responseId]);
      expect(journal.finishes, 1);
      expect(h.controller.errorCode, 'context_invalidated');
    },
  );

  testWidgets(
    'wrong channel or expired callback never becomes persistent evidence',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai());
      final done = h.controller.end();
      emit(facts.playback(), 'other-channel');
      h.manualElapsed = const Duration(seconds: 3);
      emit(facts.playback());
      await done;
      expect(journal.alignments, isEmpty);
    },
  );

  testWidgets(
    'record failure is visible and never blocks local media release',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai());
      journal.onRecord = () => throw StateError('private evidence body');
      emit(facts.playback());
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(
        h.controller.playbackEvidenceErrorCode,
        'playback_evidence_unavailable',
      );
      expect(journal.aborts, 1);
      await h.controller.stop();
      expect(h.transport.stops, 1);
    },
  );

  testWidgets(
    'account change synchronously aborts old evidence instead of reusing identity',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai());
      emit(facts.playback());
      h.api.expectedAccountId = requestKey;
      emit(facts.playback(revision: 2));
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(journal.aborts, 1);
      expect(journal.alignments, isEmpty);
      expect(journal.pending, 0);
    },
  );

  testWidgets(
    'evidence factory account switch aborts returned journal before media creation',
    (tester) async {
      setup(
        tester,
        factory: (_) {
          h.api.expectedAccountId = requestKey;
          return journal;
        },
      );
      await h.controller.begin();
      expect(journal.aborts, 1);
      expect(h.transport.starts, 0);
      expect(h.controller.errorCode, 'account_changed');
    },
  );

  testWidgets(
    'unwatched scope retains evidence pending independently of final text queue',
    (tester) async {
      h = MediaHarness(tester);
      h.controller.dispose();
      journal = TestPlaybackEvidenceJournal();
      final transcript = TestTranscriptJournal();
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
          realtimeTranscriptJournalFactoryProvider.overrideWithValue(
            (_, _) => transcript,
          ),
          realtimePlaybackEvidenceJournalFactoryProvider.overrideWithValue(
            (_, _) => journal,
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
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      await h.controller.stop();
      expect(transcript.pendingCount, 0);
      subscription.close();
      await tester.pump(Duration.zero);
      expect(h.controller.conversation, isNotNull);
      expect(journal.aborts, 0);
      journal.acknowledge();
      await tester.pump(Duration.zero);
      expect(h.controller.conversation, isNull);
      expect(journal.aborts, 1);
    },
  );
}
