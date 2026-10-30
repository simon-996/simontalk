import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';
import 'package:simontalk_client/features/realtime/realtime_session_protocol.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import '../conversation/conversation_projection_test.dart' as facts;
import '../practice/practice_fixtures.dart';
import 'media_fixtures.dart';
import 'practice_media_transcripts_test.dart' show TestTranscriptJournal;

void main() {
  late MediaHarness h;
  void setup(
    WidgetTester tester, {
    Duration timeout = const Duration(seconds: 3),
    TestTranscriptJournal? journal,
  }) {
    h = MediaHarness(
      tester,
      drainTimeout: timeout,
      transcriptJournalFactory: journal == null ? null : (_) => journal,
    );
    addTearDown(h.dispose);
  }

  Future<void> end() => h.controller.end();
  void emit(ConversationUpdate update, [String channel = 'channel-0']) =>
      h.protocol!.callbacks.emitConversation(update, channel);

  testWidgets(
    'end synchronously silences media while retaining original channel',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.user(finalText: false));
      final done = end();
      expect(h.controller.phase.name, 'draining');
      expect(h.transport.drains, 1);
      expect(h.protocol!.drains, 1);
      expect(h.transport.stops, 0);
      expect(h.controller.conversation!.isSealed, isFalse);
      emit(facts.user(revision: 2, text: 'Last sentence'));
      expect(
        h.controller.conversation!.context.entries.single.text,
        'Last sentence',
      );
      await tester.pump(const Duration(seconds: 3));
      await done;
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'tail_unconfirmed');
      expect(h.transport.stops, 1);
      expect(h.controller.conversation!.isSealed, isTrue);
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
    },
  );

  testWidgets(
    'repeated end shares operation and never slides original cutoff',
    (tester) async {
      setup(tester);
      await h.configured();
      final first = end();
      await tester.pump(const Duration(seconds: 2));
      expect(end(), same(first));
      expect(h.transport.drains, 1);
      expect(h.protocol!.drains, 1);
      await tester.pump(const Duration(seconds: 1));
      await first;
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(end(), same(first));
    },
  );

  testWidgets(
    'drain freezes original turns and final only on confirmed channel',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.user(finalText: false));
      emit(facts.ai(finalText: false));
      final done = end();
      emit(facts.user(revision: 2, text: 'ignored interim', finalText: false));
      emit(facts.user(id: requestKey, index: 3, text: 'new turn'));
      emit(facts.user(revision: 2, text: 'wrong channel'), 'channel-other');
      expect(h.controller.conversation!.turns.length, 2);
      expect(h.controller.conversation!.turns.first.text, 'Hello');
      emit(facts.user(revision: 2, text: 'User final'));
      expect(h.controller.phase.name, 'draining');
      emit(facts.ai(revision: 2, text: 'Assistant final'));
      expect(h.controller.conversation!.turns.last.text, 'Assistant final');
      expect(
        h.controller.conversation!.turns.last.playback.status,
        DeliveryStatus.unknown,
      );
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets('callback cutoff rejects final even before timer gets CPU', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    emit(facts.user(finalText: false));
    final done = end();
    h.manualElapsed = const Duration(seconds: 3);
    emit(facts.user(revision: 2, text: 'too late'));
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.conversation!.turns.single.text, 'Hello');
    await done;
  });

  testWidgets('muting and playback resume cannot reenable draining media', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    final done = end();
    final mutes = h.transport.mutes.length;
    h.controller.setMuted(false);
    await h.controller.resumePlayback();
    h.protocol!.callbacks.confirmConfigured('channel-0');
    h.transport.observe(const RealtimeObservation('playback_playing', ''));
    expect(h.transport.mutes.length, mutes);
    expect(h.transport.resumes, 0);
    expect(h.transport.activations.length, 1);
    expect(h.controller.playback, MediaPlayback.idle);
    await h.controller.stop();
    await done;
  });

  for (final reason in [
    'background',
    'account_changed',
    'connection_failed',
    'disposed',
  ]) {
    testWidgets('$reason exits drain immediately and closes callbacks', (
      tester,
    ) async {
      setup(tester);
      await h.configured();
      emit(facts.user(finalText: false));
      final done = end();
      if (reason == 'background') {
        h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      } else if (reason == 'account_changed') {
        h.api.expectedAccountId = requestKey;
        emit(facts.user(revision: 2));
      } else if (reason == 'disposed') {
        h.controller.dispose();
      } else {
        h.transport.observe(RealtimeObservation('local_closed', reason));
      }
      await done;
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.transport.stops, 1);
      if (reason == 'account_changed' || reason == 'disposed') {
        expect(h.controller.conversation?.turns ?? [], isEmpty);
      } else {
        emit(facts.user(revision: 2, text: 'late'));
        expect(h.controller.conversation!.turns.single.text, 'Hello');
      }
      await tester.pump(const Duration(seconds: 4));
      expect(h.transport.stops, 1);
    });
  }

  testWidgets('end before active uses immediate stop without opening a drain', (
    tester,
  ) async {
    setup(tester);
    await h.connecting();
    final done = end();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.transport.drains, 0);
    await done;
  });

  testWidgets(
    'empty frozen set still waits without a verified completion signal',
    (tester) async {
      setup(tester);
      await h.configured();
      final done = end();
      await tester.pump(const Duration(seconds: 2));
      expect(h.controller.phase.name, 'draining');
      await tester.pump(const Duration(seconds: 1));
      await done;
      expect(h.controller.errorCode, 'tail_unconfirmed');
    },
  );

  testWidgets(
    'drain transition exceptions still immediately release all media',
    (tester) async {
      setup(tester);
      await h.configured();
      h.transport.onDrain = () => throw const RealtimeFailure('drain_failed');
      await end();
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.transport.stops, 1);
      expect(h.protocol!.disposes, 1);
      expect(h.controller.errorCode, 'drain_failed');
    },
  );

  testWidgets(
    'registered speech without any subtitle accepts original late item final',
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
      final done = end();
      emit(
        const TranscriptUpdate(
          turnId: facts.userTurn,
          turnIndex: 1,
          role: ConversationRole.user,
          revision: 1,
          text: 'Last sentence without interim',
          isFinal: true,
          providerItemId: 'late-provider-item',
        ),
      );
      expect(
        h.controller.conversation!.turns.single.providerItemId,
        'late-provider-item',
      );
      expect(
        h.controller.conversation!.context.entries.single.text,
        'Last sentence without interim',
      );
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets(
    'registered AI response without text can finish during the same window',
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
      final done = end();
      emit(facts.ai());
      expect(h.controller.conversation!.turns.single.isFinal, isTrue);
      expect(h.controller.conversation!.context.entries, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets(
    'end retains original aligned interim prefix when final revises text',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      final done = end();
      emit(facts.ai(revision: 2, text: 'Hello there!'));
      final turn = h.controller.conversation!.turns.single;
      expect(turn.playback.status, DeliveryStatus.unknown);
      expect(turn.frozenPrefix!.transcriptRevision, 1);
      final context = h.controller.conversation!.context.entries.single;
      expect(context.kind, ConversationContextKind.interruptedPrefix);
      expect(context.transcriptRevision, 1);
      expect(context.text, 'Hello');
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets('final synchronously delivered by drain protocol is retained', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    emit(facts.user(finalText: false));
    h.protocol!.onDrain = () =>
        emit(facts.user(revision: 2, text: 'Synchronous final'));
    final done = end();
    expect(h.controller.conversation!.turns.single.text, 'Synchronous final');
    await h.controller.stop();
    await done;
  });

  testWidgets(
    'drain controls are deduplicated and ordinary send is prohibited',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai());
      final sent = h.transport.sent.length;
      h.protocol!.onDrain = () {
        for (var i = 0; i < 2; i++) {
          h.protocol!.callbacks.sendDrainControl(
            '{"type":"finish"}',
            'channel-0',
            RealtimeDrainControlKind.finishInput,
            null,
          );
          h.protocol!.callbacks.sendDrainControl(
            '{"type":"cancel"}',
            'channel-0',
            RealtimeDrainControlKind.cancelResponse,
            facts.responseId,
          );
        }
      };
      final done = end();
      expect(h.transport.sent.length, sent + 2);
      h.protocol!.callbacks.send('{"type":"generate"}', 'channel-0');
      await done;
      expect(h.controller.errorCode, 'drain_protocol_violation');
      expect(h.transport.sent.length, sent + 2);
    },
  );

  for (final invalidTarget in [null, requestKey]) {
    testWidgets('cancel cannot target unknown response $invalidTarget', (
      tester,
    ) async {
      setup(tester);
      await h.configured();
      h.protocol!.onDrain = () => h.protocol!.callbacks.sendDrainControl(
        '{"type":"cancel"}',
        'channel-0',
        RealtimeDrainControlKind.cancelResponse,
        invalidTarget,
      );
      await end();
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'drain_protocol_violation');
    });
  }

  testWidgets(
    'accepted final journal is finished after drain and remains retryable',
    (tester) async {
      final journal = TestTranscriptJournal();
      setup(tester, journal: journal);
      await h.configured();
      emit(facts.user(finalText: false));
      final done = end();
      expect(journal.finishes, 0);
      emit(facts.user(revision: 2));
      expect(journal.events.single.revision, 2);
      await tester.pump(const Duration(seconds: 3));
      await done;
      expect(journal.finishes, 1);
      expect(journal.aborts, 0);
      expect(h.controller.transcriptPendingCount, 1);
      emit(facts.user(revision: 3));
      expect(journal.events.length, 1);
    },
  );

  testWidgets('drain uses earlier original lease and never starts a renewal', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    h.manualElapsed = const Duration(seconds: 44);
    final done = end();
    expect(h.controller.drainDeadline, const Duration(seconds: 45));
    await tester.pump(const Duration(seconds: 1));
    await done;
    expect(
      h.requests.where((r) => r.url.path.endsWith('/renew-lease')),
      isEmpty,
    );
  });

  testWidgets(
    'in flight renewal cannot extend frozen cutoff or replace connection',
    (tester) async {
      setup(tester);
      await h.configured();
      final renewed = Completer<http.Response>();
      h.handler = (request) => request.url.path.endsWith('/renew-lease')
          ? renewed.future
          : h.normalResponse(request);
      await tester.pump(const Duration(seconds: 15));
      final original = h.controller.connection;
      final done = end();
      final deadline = h.controller.drainDeadline;
      renewed.complete(
        response(
          connectionJson(
            instance: h.instance,
            second: 15,
            status: 'configuring',
            termination: 'unknown',
          ),
        ),
      );
      await tester.pump();
      expect(h.controller.connection, same(original));
      expect(h.controller.drainDeadline, deadline);
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets(
    'in flight renewal failure does not preempt healthy drain channel',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.user(finalText: false));
      final renewed = Completer<http.Response>();
      h.handler = (request) => request.url.path.endsWith('/renew-lease')
          ? renewed.future
          : h.normalResponse(request);
      await tester.pump(const Duration(seconds: 15));
      final done = end();
      renewed.completeError(const RealtimeFailure('network_error'));
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.draining);
      emit(facts.user(revision: 2, text: 'Final after renewal failure'));
      expect(
        h.controller.conversation!.turns.single.text,
        'Final after renewal failure',
      );
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets('end settling pending playback resume does not preempt drain', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    emit(facts.user(finalText: false));
    h.transport.playbackResume = Completer<void>();
    final resume = h.controller.resumePlayback();
    final done = end();
    h.transport.playbackResume!.completeError(
      const RealtimeFailure('draining'),
    );
    await resume;
    expect(h.controller.phase, PracticeMediaPhase.draining);
    emit(facts.user(revision: 2, text: 'Final after playback stopped'));
    expect(
      h.controller.conversation!.turns.single.text,
      'Final after playback stopped',
    );
    await tester.pump(const Duration(seconds: 3));
    await done;
  });

  for (final seconds in [1, 5]) {
    testWidgets('configured ${seconds}s drain is bounded from first end', (
      tester,
    ) async {
      setup(tester, timeout: Duration(seconds: seconds));
      await h.configured();
      final done = end();
      await tester.pump(Duration(milliseconds: seconds * 1000 - 1));
      expect(h.controller.phase.name, 'draining');
      await tester.pump(const Duration(milliseconds: 1));
      await done;
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
    });
  }

  testWidgets('drain configuration outside 1 to 5 seconds is rejected', (
    tester,
  ) async {
    setup(tester);
    for (final timeout in [
      Duration.zero,
      const Duration(milliseconds: 999),
      const Duration(milliseconds: 5001),
    ]) {
      expect(
        () => PracticeMediaController(
          repository: PracticeRepository(h.api, accountId: accountId),
          transportFactory: () => h.transport,
          signallerFactory: (_, _) => h.signaller,
          drainTimeout: timeout,
        ),
        throwsArgumentError,
      );
    }
  });

  testWidgets(
    'verified alignment invalidation revokes frozen context through protocol',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      final done = end();
      expect(h.controller.conversation!.context.entries.single.text, 'Hello');
      h.protocol!.callbacks.revokeFrozenPrefix(facts.responseId, 'channel-0');
      expect(h.controller.conversation!.context.entries, isEmpty);
      expect(h.controller.conversation!.turns.single.frozenPrefix, isNull);
      emit(facts.ai(revision: 2));
      emit(facts.playback(transcriptRevision: 2));
      expect(h.controller.conversation!.context.entries, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      await done;
    },
  );

  testWidgets(
    'interrupted output blocks ordinary generation until context is confirmed',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      h.protocol!.callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      final sent = h.transport.sent.length;
      h.protocol!.callbacks.send('{"type":"generate"}', 'channel-0');
      expect(h.transport.sent.length, sent);
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'context_unconfirmed');
    },
  );

  testWidgets(
    'exact context acknowledgement fixes supplied version while accepting original tail facts',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      final callbacks = h.protocol!.callbacks;
      callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      emit(facts.user());
      final candidate = callbacks.prepareContext('channel-0')!;
      expect(candidate.context.entries.map((e) => e.text), ['Hello', 'Hello']);
      final sent = h.transport.sent.length;
      callbacks.sendContextControl(
        '{"type":"replace_context"}',
        'channel-0',
        candidate,
      );
      callbacks.sendContextControl(
        '{"type":"replace_context"}',
        'channel-0',
        candidate,
      );
      expect(h.transport.sent.length, sent + 1);
      callbacks.confirmContextTruncated(candidate, 'channel-0');
      emit(
        const TurnStartedUpdate(
          turnId: requestKey,
          turnIndex: 3,
          role: ConversationRole.assistant,
          responseId: clientId,
        ),
      );
      expect(h.controller.conversation!.turns.length, 3);
      emit(facts.ai(revision: 2, text: 'Old late suffix'));
      expect(
        h.controller.conversation!.turns
            .where((t) => t.turnId == facts.aiTurn)
            .single
            .revision,
        2,
      );
      expect(candidate.context.entries.last.text, 'Hello');
      expect(candidate.context.entries.last.transcriptRevision, 1);
      await h.controller.stop();
    },
  );

  testWidgets(
    'context acknowledgement before control or after changed input cannot open gate',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      final callbacks = h.protocol!.callbacks;
      callbacks.freezeResponse(facts.responseId, 0, 'channel-0');
      final candidate = callbacks.prepareContext('channel-0')!;
      callbacks.confirmContextTruncated(candidate, 'channel-0');
      callbacks.sendContextControl(
        '{"type":"replace_context"}',
        'channel-0',
        candidate,
      );
      emit(facts.user());
      callbacks.confirmContextTruncated(candidate, 'channel-0');
      emit(
        const TurnStartedUpdate(
          turnId: requestKey,
          turnIndex: 3,
          role: ConversationRole.assistant,
          responseId: clientId,
        ),
      );
      expect(h.controller.errorCode, 'context_unconfirmed');
      expect(h.controller.conversation!.turns.length, 2);
    },
  );

  testWidgets(
    'copied context capabilities and other channel acknowledgements cannot open gate',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      final callbacks = h.protocol!.callbacks;
      callbacks.freezeResponse(facts.responseId, 0, 'channel-0');
      final candidate = callbacks.prepareContext('channel-0')!;
      final copied = RealtimeContextSnapshot(
        revision: candidate.revision,
        context: candidate.context,
      );
      final sent = h.transport.sent.length;
      callbacks.sendContextControl('{"type":"replace"}', 'channel-0', copied);
      callbacks.confirmContextTruncated(copied, 'channel-0');
      expect(h.transport.sent.length, sent);
      expect(callbacks.prepareContext('channel-0'), same(candidate));
      callbacks.sendContextControl(
        '{"type":"replace"}',
        'channel-0',
        candidate,
      );
      callbacks.confirmContextTruncated(candidate, 'channel-other');
      expect(callbacks.prepareContext('channel-0'), same(candidate));
      callbacks.confirmContextTruncated(candidate, 'channel-0');
      expect(callbacks.prepareContext('channel-0'), isNull);
      await h.controller.stop();
    },
  );

  testWidgets(
    'repeated interruption cannot extend old response acceptance window',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      final callbacks = h.protocol!.callbacks;
      callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      await tester.pump(const Duration(seconds: 2));
      callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      h.manualElapsed = const Duration(seconds: 3);
      emit(facts.ai(revision: 2, text: 'Late old reply'));
      callbacks.revokeFrozenPrefix(facts.responseId, 'channel-0');
      expect(h.controller.conversation!.turns.single.revision, 1);
      expect(h.controller.conversation!.context.entries.single.text, 'Hello');
      await h.controller.stop();
    },
  );

  testWidgets(
    'synchronous drain callback buffer is bounded before projection acceptance',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.user(finalText: false));
      h.protocol!.onDrain = () {
        for (var revision = 2; revision <= 34; revision++) {
          emit(facts.user(revision: revision));
        }
      };
      await end();
      expect(h.controller.errorCode, 'conversation_limit_reached');
      expect(h.transport.stops, 1);
      expect(h.controller.conversation!.turns.single.revision, 1);
    },
  );

  testWidgets(
    'revoking evidence already used by confirmed context stops further response safely',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(facts.ai(finalText: false));
      emit(facts.playback());
      final callbacks = h.protocol!.callbacks;
      callbacks.freezeResponse(facts.responseId, 400, 'channel-0');
      final candidate = callbacks.prepareContext('channel-0')!;
      callbacks.sendContextControl(
        '{"type":"replace"}',
        'channel-0',
        candidate,
      );
      callbacks.confirmContextTruncated(candidate, 'channel-0');
      callbacks.revokeFrozenPrefix(facts.responseId, 'channel-0');
      expect(h.controller.errorCode, 'context_invalidated');
      expect(h.controller.conversation!.context.entries, isEmpty);
      expect(h.transport.stops, 1);
      expect(candidate.context.entries.single.text, 'Hello');
    },
  );
}
