import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../conversation/conversation_projection_test.dart' as conversation;
import '../practice/practice_fixtures.dart';
import 'media_fixtures.dart';

void main() {
  late MediaHarness h;
  void setup(WidgetTester tester) {
    h = MediaHarness(tester);
    addTearDown(h.dispose);
  }

  void emit(ConversationUpdate update, [String channel = 'channel-0']) =>
      h.protocol!.callbacks.emitConversation(update, channel);

  testWidgets('closed admission never constructs a conversation or media', (
    tester,
  ) async {
    setup(tester);
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await h.controller.begin();
    expect(h.controller.conversation, isNull);
    expect(h.protocolCreates + h.transportCreates, 0);
  });

  testWidgets(
    'normalized conversation is scoped and generated text is not playback',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(conversation.user());
      emit(conversation.ai());
      final snapshot = h.controller.conversation!;
      expect(snapshot.scope.accountId, accountId);
      expect(snapshot.scope.sessionId, practiceId);
      expect(snapshot.scope.connectionId, connectionId);
      expect(snapshot.scope.clientInstanceId, h.instance);
      expect(snapshot.scope.epoch, 1);
      expect(snapshot.turns.length, 2);
      h.transport.observe(
        const RealtimeObservation('playback_playing', 'local'),
      );
      expect(h.controller.conversation!.context.entries.length, 1);
      emit(conversation.playback());
      expect(h.controller.conversation!.context.entries.map((e) => e.text), [
        'Hello',
        'Hello',
      ]);
      expect(h.requests.length, 2);
      await h.controller.stop();
    },
  );

  testWidgets(
    'events before confirmed configuration close locally without accepting text',
    (tester) async {
      setup(tester);
      await h.connecting();
      emit(conversation.user());
      await tester.pump();
      expect(h.controller.errorCode, 'conversation_invalid');
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.conversation!.turns, isEmpty);
      expect(h.transport.stops, 1);
    },
  );

  testWidgets(
    'another open channel cannot inject conversation into confirmed channel',
    (tester) async {
      setup(tester);
      await h.configured();
      h.transport.observe(
        const RealtimeObservation('channel_open', 'channel-1'),
      );
      emit(conversation.user(), 'channel-1');
      await tester.pump();
      expect(h.controller.errorCode, 'conversation_invalid');
      expect(h.controller.conversation!.turns, isEmpty);
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
    },
  );

  testWidgets(
    'configured events may arrive while microphone activation is pending',
    (tester) async {
      setup(tester);
      h.transport.activation = Completer<void>();
      await h.connecting();
      await h.transport.signaller.exchangeOffer('v=0\r\n');
      h.transport.observe(
        const RealtimeObservation('channel_open', 'channel-0'),
      );
      h.transport.connected.complete();
      await tester.pump();
      h.transport.receive(
        const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
      );
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.configuring);
      emit(conversation.user());
      expect(h.controller.conversation!.context.entries.single.text, 'Hello');
      h.transport.activation!.complete();
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.active);
      await h.controller.stop();
    },
  );

  testWidgets('normal stop seals accepted text and rejects late callbacks', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    emit(conversation.user());
    await h.controller.stop();
    emit(conversation.user(revision: 2, text: 'late'));
    expect(h.controller.conversation!.isSealed, isTrue);
    expect(h.controller.conversation!.context.entries.single.text, 'Hello');
    h.controller.dispose();
    emit(conversation.user(revision: 3, text: 'later'));
    expect(h.controller.conversation, isNull);
  });

  testWidgets(
    'account changes clear accepted text before an old callback can publish',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(conversation.user());
      h.api.expectedAccountId = conversation.responseId;
      expect(h.controller.conversation, isNull);
      emit(conversation.ai());
      await tester.pump();
      expect(h.controller.errorCode, 'account_changed');
      expect(h.controller.conversation, isNull);
      h.api.expectedAccountId = accountId;
      expect(h.controller.conversation!.turns, isEmpty);
    },
  );

  testWidgets(
    'projection failure retains accepted snapshot and releases media',
    (tester) async {
      setup(tester);
      await h.configured();
      emit(conversation.user());
      emit(conversation.user(text: 'conflicting private words'));
      await tester.pump();
      expect(h.controller.errorCode, 'conversation_invalid');
      expect(h.transport.stops, 1);
      expect(h.controller.conversation!.context.entries.single.text, 'Hello');
      expect(h.controller.conversation!.isSealed, isTrue);
    },
  );

  testWidgets('text capacity failure stops without evicting accepted turns', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    for (var i = 0; i < 32; i++) {
      emit(
        conversation.user(
          id: '10000000-0000-4000-8000-${(i + 10).toString().padLeft(12, '0')}',
          index: i + 1,
          text: 'x' * 8192,
        ),
      );
    }
    emit(conversation.user(index: 40));
    await tester.pump();
    expect(h.controller.errorCode, 'conversation_limit_reached');
    expect(h.controller.conversation!.turns.length, 32);
    expect(h.transport.stops, 1);
  });
}
