import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/final_transcript_journal.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../conversation/conversation_projection_test.dart' as fixtures;
import '../practice/practice_fixtures.dart';
import 'media_fixtures.dart';
import 'api_realtime_signaller_test.dart' show TrackedClient;

class TestTranscriptJournal implements RealtimeTranscriptJournal {
  final events = <TranscriptUpdate>[];
  int finishes = 0;
  int aborts = 0;
  void Function()? onRecord;
  @override
  int get pendingCount => events.length;
  @override
  int get rejectedCount => 2;
  @override
  String? get errorCode => 'transcript_failed';
  @override
  void record(TranscriptUpdate update) {
    onRecord?.call();
    events.add(update);
  }

  @override
  Future<void> retryPending() async {}
  @override
  void finish() => finishes++;
  @override
  void abort() {
    aborts++;
    events.clear();
  }
}

void main() {
  late MediaHarness h;
  late TestTranscriptJournal journal;
  ConversationScope? constructedScope;

  void setup(WidgetTester tester, {TranscriptJournalFactory? factory}) {
    h = MediaHarness(tester);
    h.controller.dispose();
    journal = TestTranscriptJournal();
    constructedScope = null;
    h.controller = PracticeMediaController(
      repository: PracticeRepository(h.api, accountId: accountId),
      elapsed: () => tester.binding.clock.now().difference(h.origin),
      transcriptJournalFactory:
          factory ??
          (scope) {
            constructedScope = scope;
            return journal;
          },
      protocolFactory: (_, callbacks) => h.protocol = TestProtocol(callbacks),
      signallerFactory: (_, _) => h.signaller,
      transportFactory: () {
        h.transportCreates++;
        return h.transport;
      },
    );
    addTearDown(h.dispose);
  }

  void emit(ConversationUpdate update, [String channel = 'channel-0']) =>
      h.protocol!.callbacks.emitConversation(update, channel);

  testWidgets('closed admission creates no transcript journal or media', (
    tester,
  ) async {
    setup(tester);
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await h.controller.begin();
    expect(constructedScope, isNull);
    expect(h.transportCreates, 0);
    expect(h.controller.transcriptJournal, isNull);
  });

  testWidgets(
    'only applied final revisions are reported with reserved connection scope',
    (tester) async {
      setup(tester);
      await h.configured();
      expect(constructedScope!.accountId, accountId);
      expect(constructedScope!.sessionId, practiceId);
      expect(constructedScope!.connectionId, connectionId);
      expect(constructedScope!.clientInstanceId, h.instance);
      expect(constructedScope!.epoch, 1);
      emit(fixtures.user(finalText: false));
      emit(fixtures.user(revision: 2));
      emit(fixtures.user(revision: 2));
      emit(fixtures.user(revision: 1));
      emit(fixtures.ai());
      emit(fixtures.playback());
      emit(fixtures.user(revision: 3, text: 'Hello again'));
      expect(journal.events.map((e) => e.revision), [2, 1, 3]);
      expect(h.controller.transcriptPendingCount, 3);
      expect(h.controller.transcriptRejectedCount, 2);
      expect(h.controller.transcriptErrorCode, 'transcript_failed');
      expect(h.controller.phase, PracticeMediaPhase.active);
      await h.controller.stop();
    },
  );

  testWidgets(
    'wrong channel and conflicting final revisions do not submit text',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(fixtures.user());
      emit(fixtures.user(text: 'private conflicting text'));
      await tester.pump();
      expect(journal.events.length, 1);
      expect(h.controller.errorCode, 'conversation_invalid');
      expect(journal.finishes, 1);
    },
  );

  testWidgets('another open channel never submits an otherwise valid final', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    h.transport.observe(const RealtimeObservation('channel_open', 'channel-1'));
    emit(fixtures.user(), 'channel-1');
    await tester.pump();
    expect(journal.events, isEmpty);
    expect(h.controller.errorCode, 'conversation_invalid');
  });

  testWidgets(
    'normal stop seals journal once and dispose aborts retained text',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(fixtures.user());
      await h.controller.stop();
      await h.controller.stop();
      emit(fixtures.user(revision: 2));
      expect(journal.finishes, 1);
      expect(journal.aborts, 0);
      expect(journal.events.length, 1);
      h.controller.dispose();
      expect(journal.aborts, 1);
      expect(journal.events, isEmpty);
    },
  );

  testWidgets(
    'account changes synchronously abort retained transcript queue even after stop',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(fixtures.user());
      await h.controller.stop();
      h.api.expectedAccountId = requestKey;
      expect(h.controller.conversation, isNull);
      expect(journal.events, isEmpty);
      expect(journal.aborts, 1);
      emit(fixtures.ai());
      expect(journal.events, isEmpty);
    },
  );

  testWidgets(
    'account change callback aborts without a finish or a new record',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(fixtures.user());
      h.api.expectedAccountId = requestKey;
      emit(fixtures.ai());
      await tester.pump();
      expect(journal.aborts, 1);
      expect(journal.finishes, 0);
      expect(journal.events, isEmpty);
      expect(h.controller.errorCode, 'account_changed');
    },
  );

  testWidgets(
    'journal construction stopped reentrantly aborts returned journal',
    (tester) async {
      setup(
        tester,
        factory: (_) {
          unawaited(h.controller.stop());
          return journal;
        },
      );
      await h.controller.begin();
      await tester.pump();
      expect(journal.aborts, 1);
      expect(h.transportCreates, 0);
    },
  );

  testWidgets(
    'journal failures expose a safe code while accepted projection and media survive',
    (tester) async {
      setup(tester);
      await h.configured();
      journal.onRecord = () => throw StateError('private-provider-secret');
      emit(fixtures.user());
      expect(h.controller.transcriptErrorCode, 'transcript_unavailable');
      expect(h.controller.conversation!.context.entries.single.text, 'Hello');
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(journal.aborts, 1);
      expect(h.controller.transcriptJournal, isNull);
      await h.controller.stop();
    },
  );

  testWidgets(
    'factory failure is isolated from media and never exposes exception text',
    (tester) async {
      setup(
        tester,
        factory: (_) => throw StateError('private-provider-secret'),
      );
      await h.configured();
      expect(h.controller.transcriptErrorCode, 'transcript_unavailable');
      emit(fixtures.user());
      expect(h.controller.conversation!.context.entries.single.text, 'Hello');
      expect(h.controller.phase, PracticeMediaPhase.active);
      await h.controller.stop();
    },
  );

  for (final firstFails in [false, true]) {
    testWidgets(
      'real HTTP journal ${firstFails ? 'failure and stopped retry' : 'success'} preserves media and delivery boundaries',
      (tester) async {
        late FinalTranscriptJournal real;
        final clients = <TrackedClient>[];
        final payloads = <Map<String, dynamic>>[];
        var fail = firstFails;
        setup(
          tester,
          factory: (scope) {
            return real = FinalTranscriptJournal(
              accountApi: h.api,
              scope: scope,
              clientFactory: () {
                final client = TrackedClient((request) async {
                  if (request.url.path.endsWith('/csrf')) {
                    return response({'csrf_token': 'transcript-csrf'});
                  }
                  final body = jsonDecode(request.body) as Map<String, dynamic>;
                  payloads.add(body);
                  expectSync(request.headers['X-Account-ID'], accountId);
                  expectSync(body['client_instance_id'], h.instance);
                  final events = body['events'] as List;
                  if (fail) {
                    return response({'code': 'service_unavailable'}, 503);
                  }
                  return response({
                    'source': 'client_reported',
                    'account_id': accountId,
                    'session_id': practiceId,
                    'connection_id': connectionId,
                    'client_instance_id': h.instance,
                    'epoch': 1,
                    'last_sequence': events.last['sequence'],
                    'total_events': events.length,
                    'total_text_bytes': events.fold<int>(
                      0,
                      (sum, e) => sum + utf8.encode(e['text'] as String).length,
                    ),
                    'acknowledged_event_ids': events
                        .map((e) => e['event_id'])
                        .toList(),
                  });
                });
                clients.add(client);
                return client;
              },
            );
          },
        );
        await h.configured();
        emit(fixtures.user(finalText: false));
        emit(fixtures.user(revision: 2));
        emit(fixtures.ai());
        emit(fixtures.playback());
        await real.retryPending();
        expect(h.controller.phase, PracticeMediaPhase.active);
        expect(real.pendingCount, firstFails ? 2 : 0);
        expect(h.requests.length, 2);
        final original = payloads.single;
        expect(
          (original['events'] as List).every(
            (e) =>
                !e.containsKey('delivery_status') &&
                !e.containsKey('played_text'),
          ),
          isTrue,
        );
        await h.controller.stop();
        expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
        if (firstFails) {
          fail = false;
          await real.retryPending();
          expect(payloads.last, original);
        }
        expect(real.pendingCount, 0);
        expect(clients.every((c) => c.closes == 1), isTrue);
      },
    );
  }
}
