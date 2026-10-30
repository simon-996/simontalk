import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';
import 'package:simontalk_client/features/realtime/qwen_transcript_normalizer.dart';

import '../features/practice/practice_fixtures.dart';

void main() {
  test(
    'recorded synthetic provider events normalize into the scoped projection',
    () {
      final raw = jsonDecode(
        File('test/fixtures/qwen_synthetic_transcript_events.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final events = (raw['events'] as List).cast<Map<String, dynamic>>();
      final adapter = QwenTranscriptNormalizer();
      final projection = ConversationProjection(
        ConversationScope(
          accountId: accountId,
          sessionId: practiceId,
          connectionId: connectionId,
          clientInstanceId: clientId,
          epoch: 1,
        ),
      );
      var updates = 0;
      for (final event in events) {
        final normalized = adapter.accept(event);
        expect(normalized.whereType<PlaybackUpdate>(), isEmpty);
        for (final update in normalized) {
          expect(projection.apply(update), ConversationApplyResult.applied);
          updates++;
        }
      }
      expect(events.length, 33);
      expect(updates, greaterThan(20));
      expect(projection.snapshot.turns, hasLength(2));
      final assistant = projection.snapshot.turns.first;
      final user = projection.snapshot.turns.last;
      expect(assistant.role, ConversationRole.assistant);
      expect(assistant.isFinal, isTrue);
      expect(assistant.text, contains('twenty'));
      expect(assistant.playback.status, DeliveryStatus.unknown);
      expect(user.role, ConversationRole.user);
      expect(user.isFinal, isTrue);
      expect(
        user.text,
        'Yesterday I went to the park. What do you like to do outdoors?',
      );
      expect(projection.snapshot.context.entries.map((entry) => entry.text), [
        user.text,
      ]);
      for (final event in events) {
        expect(adapter.accept(event), isEmpty);
      }
      adapter.dispose();
    },
  );
}
