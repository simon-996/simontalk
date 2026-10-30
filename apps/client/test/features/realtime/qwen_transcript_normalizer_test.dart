import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';
import 'package:simontalk_client/features/realtime/qwen_transcript_normalizer.dart';

import '../practice/practice_fixtures.dart';

String eventId(int n) => 'event_$n';
Map<String, Object?> event(
  int n,
  String type, [
  Map<String, Object?> fields = const {},
]) => {'event_id': eventId(n), 'type': type, ...fields};

void main() {
  late QwenTranscriptNormalizer normalizer;
  late ConversationProjection projection;
  var nextId = 0;
  String uuid() =>
      '10000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';
  List<ConversationUpdate> accept(Map<String, Object?> value) {
    final updates = normalizer.accept(value);
    for (final update in updates) {
      projection.apply(update);
    }
    return updates;
  }

  void startUser() => accept(
    event(1, 'input_audio_buffer.speech_started', {'item_id': 'item_user'}),
  );
  void startAssistant() {
    accept(
      event(10, 'response.created', {
        'response': {'id': 'resp_1'},
      }),
    );
    accept(
      event(11, 'response.output_item.added', {
        'response_id': 'resp_1',
        'output_index': 0,
        'item': {
          'id': 'item_assistant',
          'type': 'message',
          'role': 'assistant',
        },
      }),
    );
  }

  Map<String, Object?> userDelta(int n, String text, String stash) => event(
    n,
    'conversation.item.input_audio_transcription.delta',
    {'item_id': 'item_user', 'content_index': 0, 'text': text, 'stash': stash},
  );
  Map<String, Object?> userFinal(int n, String text) => event(
    n,
    'conversation.item.input_audio_transcription.completed',
    {'item_id': 'item_user', 'content_index': 0, 'transcript': text},
  );
  Map<String, Object?> aiEvent(int n, String kind, String text) =>
      event(n, 'response.audio_transcript.$kind', {
        'response_id': 'resp_1',
        'item_id': 'item_assistant',
        'output_index': 0,
        'content_index': 0,
        kind == 'delta' ? 'delta' : 'transcript': text,
      });
  setUp(() {
    nextId = 0;
    normalizer = QwenTranscriptNormalizer(idFactory: uuid);
    projection = ConversationProjection(
      ConversationScope(
        accountId: accountId,
        sessionId: practiceId,
        connectionId: connectionId,
        clientInstanceId: clientId,
        epoch: 1,
      ),
    );
  });

  test('user transcript uses replacement snapshots and completed final', () {
    startUser();
    accept(userDelta(2, '', 'Hello'));
    accept(userDelta(3, 'Hello', ' there'));
    expect(projection.snapshot.turns.single.text, 'Hello there');
    expect(projection.snapshot.turns.single.isFinal, isFalse);
    accept(userFinal(4, 'Hello there!'));
    final turn = projection.snapshot.turns.single;
    expect(turn.text, 'Hello there!');
    expect(turn.isFinal, isTrue);
    expect(turn.revision, 3);
    expect(projection.snapshot.context.entries.single.text, 'Hello there!');
  });

  test(
    'assistant output is accumulated but final is not treated as playback',
    () {
      startUser();
      accept(userFinal(2, 'Hello'));
      startAssistant();
      accept(aiEvent(12, 'delta', 'Hi'));
      accept(aiEvent(13, 'delta', ' there'));
      accept(aiEvent(14, 'done', 'Hi there!'));
      final turn = projection.snapshot.turns.last;
      expect(turn.text, 'Hi there!');
      expect(turn.isFinal, isTrue);
      expect(turn.playback.status, DeliveryStatus.unknown);
      expect(projection.snapshot.context.entries.length, 1);
      expect(turn.providerItemId, 'item_assistant');
    },
  );

  test('identical event and final replay are ignored, conflicting ID stops instance', () {
    startUser();
    final delta = userDelta(2, 'Hello', '');
    expect(accept(delta), hasLength(1));
    expect(accept(delta), isEmpty);
    accept(userFinal(3, 'Hello'));
    expect(accept(userFinal(4, 'Hello')), isEmpty);
    expect(
      () => accept(userFinal(4, 'changed')),
      throwsA(isA<QwenTranscriptFailure>()),
    );
    expect(
      () => accept(userFinal(5, 'Hello')),
      throwsA(isA<QwenTranscriptFailure>()),
    );
  });

  test('unknown item, unsupported index and delta after final fail closed', () {
    startUser();
    expect(
      () => accept(
        event(2, 'conversation.item.input_audio_transcription.completed', {
          'item_id': 'other',
          'content_index': 0,
          'transcript': 'bad',
        }),
      ),
      throwsA(isA<QwenTranscriptFailure>()),
    );
    expect(
      () => accept(userFinal(3, 'late')),
      throwsA(isA<QwenTranscriptFailure>()),
    );
  });

  test(
    'assistant binding rejects mismatched item and does not generate playback',
    () {
      startAssistant();
      expect(
        () => accept(
          event(12, 'response.audio_transcript.delta', {
            'response_id': 'resp_1',
            'item_id': 'other',
            'output_index': 0,
            'content_index': 0,
            'delta': 'wrong',
          }),
        ),
        throwsA(isA<QwenTranscriptFailure>()),
      );
      expect(
        projection.snapshot.turns.single.playback.status,
        DeliveryStatus.unknown,
      );
    },
  );

  test('finalized user and assistant reject later deltas', () {
    startUser();
    accept(userFinal(2, 'Hello'));
    expect(
      () => accept(userDelta(3, 'late', '')),
      throwsA(isA<QwenTranscriptFailure>()),
    );
  });

  test(
    'invalid text, unsupported events and disposed instance cannot emit',
    () {
      startUser();
      expect(
        () => accept(userDelta(2, 'x' * 8193, '')),
        throwsA(isA<QwenTranscriptFailure>()),
      );
      normalizer.dispose();
      expect(
        () => accept(userFinal(3, 'late')),
        throwsA(isA<QwenTranscriptFailure>()),
      );
      final other = QwenTranscriptNormalizer(idFactory: uuid);
      expect(
        () => other.accept(event(1, 'response.done')),
        throwsA(isA<QwenTranscriptFailure>()),
      );
    },
  );

  test('same assistant delta event does not append its text twice', () {
    startAssistant();
    final delta = aiEvent(12, 'delta', 'Hello');
    accept(delta);
    expect(accept(delta), isEmpty);
    expect(projection.snapshot.turns.single.text, 'Hello');
    accept(aiEvent(13, 'done', 'Hello'));
    expect(accept(aiEvent(14, 'done', 'Hello')), isEmpty);
    expect(
      () => accept(aiEvent(15, 'delta', 'late')),
      throwsA(isA<QwenTranscriptFailure>()),
    );
  });

  test('user and assistant items cannot share provider identity', () {
    startUser();
    accept(
      event(10, 'response.created', {
        'response': {'id': 'resp_1'},
      }),
    );
    expect(
      () => accept(
        event(11, 'response.output_item.added', {
          'response_id': 'resp_1',
          'output_index': 0,
          'item': {'id': 'item_user', 'type': 'message', 'role': 'assistant'},
        }),
      ),
      throwsA(isA<QwenTranscriptFailure>()),
    );
    expect(projection.snapshot.turns, hasLength(2));
  });

  test('content indexes, malformed Unicode and null bytes fail closed', () {
    for (final value in [
      event(2, 'conversation.item.input_audio_transcription.completed', {
        'item_id': 'item_user',
        'content_index': 1,
        'transcript': 'hello',
      }),
      userFinal(2, String.fromCharCode(0xd800)),
      userFinal(2, 'hello\u0000'),
    ]) {
      final instance = QwenTranscriptNormalizer(idFactory: uuid);
      instance.accept(
        event(1, 'input_audio_buffer.speech_started', {'item_id': 'item_user'}),
      );
      expect(
        () => instance.accept(value),
        throwsA(isA<QwenTranscriptFailure>()),
      );
      expect(
        () => instance.accept(userFinal(3, 'valid')),
        throwsA(isA<QwenTranscriptFailure>()),
      );
    }
  });

  test(
    'event count is bounded without silently evicting prior deduplication',
    () {
      for (var i = 1; i <= 1024; i++) {
        normalizer.accept(
          event(i, 'input_audio_buffer.speech_started', {'item_id': 'one'}),
        );
      }
      expect(
        () => normalizer.accept(
          event(1025, 'input_audio_buffer.speech_started', {'item_id': 'one'}),
        ),
        throwsA(isA<QwenTranscriptFailure>()),
      );
    },
  );

  test(
    'the event byte budget fails closed before unbounded text is retained',
    () {
      startUser();
      var rejected = false;
      for (var i = 2; i < 1024; i++) {
        try {
          normalizer.accept(userDelta(i, '', 'x' * 2000));
        } on QwenTranscriptFailure {
          rejected = true;
          break;
        }
      }
      expect(rejected, isTrue);
      expect(
        () => normalizer.accept(userFinal(1025, 'late')),
        throwsA(isA<QwenTranscriptFailure>()),
      );
    },
  );

  test('turn count and generated UUID uniqueness are enforced', () {
    for (var i = 1; i <= 256; i++) {
      normalizer.accept(
        event(i, 'input_audio_buffer.speech_started', {'item_id': 'item_$i'}),
      );
    }
    expect(
      () => normalizer.accept(
        event(257, 'input_audio_buffer.speech_started', {
          'item_id': 'item_257',
        }),
      ),
      throwsA(isA<QwenTranscriptFailure>()),
    );
    final duplicate = QwenTranscriptNormalizer(
      idFactory: () => '10000000-0000-4000-8000-000000000001',
    );
    duplicate.accept(
      event(1, 'input_audio_buffer.speech_started', {'item_id': 'first'}),
    );
    expect(
      () => duplicate.accept(
        event(2, 'input_audio_buffer.speech_started', {'item_id': 'second'}),
      ),
      throwsA(isA<QwenTranscriptFailure>()),
    );
  });

  test(
    'overlapping input keeps the initial turn order when results arrive late',
    () {
      startUser();
      accept(userFinal(2, 'Hello'));
      startAssistant();
      accept(aiEvent(12, 'delta', 'Good'));
      accept(
        event(20, 'input_audio_buffer.speech_started', {
          'item_id': 'item_second',
        }),
      );
      accept(
        event(21, 'conversation.item.input_audio_transcription.completed', {
          'item_id': 'item_second',
          'content_index': 0,
          'transcript': 'Excuse me',
        }),
      );
      accept(aiEvent(13, 'done', 'Good morning'));
      expect(projection.snapshot.turns.map((turn) => turn.text), [
        'Hello',
        'Good morning',
        'Excuse me',
      ]);
      expect(projection.snapshot.context.entries.map((entry) => entry.text), [
        'Hello',
        'Excuse me',
      ]);
      expect(
        projection.snapshot.turns[1].playback.status,
        DeliveryStatus.unknown,
      );
    },
  );
}
