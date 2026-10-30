import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/realtime/qwen_guarded_protocol.dart';
import 'package:simontalk_client/features/realtime/realtime_session_protocol.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';

class Harness {
  Harness() {
    final json = practiceJson()['configuration'] as Map<String, dynamic>;
    json['provider'] = {
      'provider': 'dashscope',
      'region': 'cn-beijing',
      'model': 'qwen3.8-omni-flash-realtime',
      'config_id': 'qwen-private-v1',
    };
    final config = PracticeConfiguration.fromJson(json);
    projection = ConversationProjection(
      ConversationScope(
        accountId: accountId,
        sessionId: practiceId,
        connectionId: connectionId,
        clientInstanceId: clientId,
        epoch: 1,
      ),
    );
    protocol = QwenGuardedProtocol(
      config,
      RealtimeProtocolCallbacks(
        send: (json, channel) =>
            sent.add((jsonDecode(json) as Map<String, dynamic>, channel)),
        confirmConfigured: confirmed.add,
        fail: failures.add,
        emitConversation: (update, channel) {
          updates.add(update);
          projection.apply(update);
          onUpdate?.call(update);
        },
        sendDrainControl: (json, channel, kind, id) =>
            controls.add((json, channel, kind, id)),
        freezeResponse: (_, _, _) => fail('No verified playback'),
        revokeFrozenPrefix: (_, _) => fail('No playback to revoke'),
        prepareContext: (_) => null,
        sendContextControl: (_, _, _) => fail('No verified context'),
        confirmContextTruncated: (_, _) => fail('No verified context'),
      ),
    );
  }
  late final QwenGuardedProtocol protocol;
  late final ConversationProjection projection;
  final sent = <(Map<String, dynamic>, String)>[];
  final confirmed = <String>[];
  final failures = <String>[];
  final updates = <ConversationUpdate>[];
  final controls = <(String, String, RealtimeDrainControlKind, String?)>[];
  void Function(ConversationUpdate)? onUpdate;
  void receive(Map<String, Object?> event, [String channel = 'c0']) =>
      protocol.receive(RealtimeTransportEvent(jsonEncode(event), channel));
  void open() {
    protocol.channelOpened('c0');
    receive({
      'type': 'session.created',
      'session': {'id': 'sess_1', 'model': 'qwen3.8-omni-flash-realtime'},
    });
  }

  void configure() {
    open();
    final session = Map<String, dynamic>.from(sent.single.$1['session'] as Map);
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    receive({'type': 'session.updated', 'session': session});
  }

  void firstUser() {
    receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
  }

  void firstResponse() {
    receive({
      'type': 'response.created',
      'event_id': 'e4',
      'response': {'id': 'r1'},
    });
    receive({
      'type': 'response.output_item.added',
      'event_id': 'e5',
      'response_id': 'r1',
      'output_index': 0,
      'item': {'id': 'a1', 'type': 'message', 'role': 'assistant'},
    });
  }
}

void main() {
  test('recorded configuration without search echo fails closed', () {
    final raw = jsonDecode(
      File('test/fixtures/qwen_guarded_synthetic_events.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final events = (raw['events'] as List).cast<Map<String, dynamic>>();
    final h = Harness();
    h.protocol.channelOpened('c0');
    h.receive(events[0]);
    h.receive(events[1]);
    expect(h.confirmed, isEmpty);
    expect(h.failures, hasLength(1));
    expect(h.sent.map((item) => item.$1['type']), ['session.update']);
    h.protocol.dispose();
  });

  test('synthetic replay with simulated search echo drives the protocol', () {
    final raw = jsonDecode(
      File('test/fixtures/qwen_guarded_synthetic_events.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final events = (raw['events'] as List).cast<Map<String, dynamic>>();
    final h = Harness();
    h.protocol.channelOpened('c0');
    for (final event in events) {
      if (event['type'] == 'session.updated') {
        // The captured response omitted search; this echo is simulated.
        (event['session'] as Map<String, dynamic>)['enable_search'] = false;
      }
      h.receive(event);
      expect(h.failures, isEmpty, reason: 'event type ${event['type']}');
    }
    expect(events, hasLength(39));
    expect(h.confirmed, ['c0']);
    expect(h.sent.map((item) => item.$1['type']), [
      'session.update',
      'response.create',
    ]);
    expect(h.projection.snapshot.turns, hasLength(2));
    expect(
      h.projection.snapshot.turns.first.text,
      'Yesterday I went to the park. What do you like to do outdoors?',
    );
    expect(h.projection.snapshot.turns.last.isFinal, isTrue);
    expect(h.projection.snapshot.turns.last.text, isNotEmpty);
    expect(
      h.projection.snapshot.turns.last.playback.status,
      DeliveryStatus.unknown,
    );
    expect(h.projection.snapshot.context.entries, hasLength(1));
    h.protocol.dispose();
  });
  test(
    'binds configuration to session channel when multiple channels open',
    () {
      final h = Harness();
      h.protocol.channelOpened('client');
      h.protocol.channelOpened('server');
      expect(h.failures, isEmpty);
      h.receive({
        'type': 'session.created',
        'session': {'id': 'sess_1', 'model': 'qwen3.8-omni-flash-realtime'},
      }, 'server');
      expect(h.sent, hasLength(1));
      expect(h.sent.single.$2, 'server');
      final session = Map<String, dynamic>.from(
        h.sent.single.$1['session'] as Map,
      );
      session['id'] = 'sess_1';
      session['model'] = 'qwen3.8-omni-flash-realtime';
      h.receive({'type': 'session.updated', 'session': session}, 'server');
      expect(h.confirmed, ['server']);
      h.protocol.channelOpened('another');
      expect(h.failures, isEmpty);
      h.receive({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      }, 'client');
      expect(h.failures, hasLength(1));
      expect(h.updates, isEmpty);
    },
  );

  test(
    'channel discovery remains bounded and cannot bind unopened channels',
    () {
      final h = Harness();
      for (var i = 0; i < 8; i++) {
        h.protocol.channelOpened('channel-$i');
      }
      h.protocol.channelOpened('channel-0');
      expect(h.failures, isEmpty);
      h.protocol.channelOpened('channel-8');
      expect(h.failures, hasLength(1));
      final other = Harness();
      other.protocol.channelOpened('client');
      other.receive({
        'type': 'session.created',
        'session': {'id': 'sess_1', 'model': 'qwen3.8-omni-flash-realtime'},
      }, 'unopened');
      expect(other.failures, hasLength(1));
      expect(other.sent, isEmpty);
    },
  );

  test('an uninitialized channel cannot send a business event', () {
    final h = Harness();
    h.protocol.channelOpened('client');
    h.receive({
      'type': 'response.created',
      'response': {'id': 'r1'},
    }, 'client');
    expect(h.failures, hasLength(1));
    expect(h.sent, isEmpty);
    expect(h.updates, isEmpty);
  });

  test('no tool request allows a missing tools echo', () {
    final h = Harness();
    h.open();
    final session = Map<String, dynamic>.from(
      h.sent.single.$1['session'] as Map,
    );
    expect(session.containsKey('tools'), isFalse);
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    h.receive({'type': 'session.updated', 'session': session});
    expect(h.confirmed, ['c0']);
    expect(h.failures, isEmpty);
  });

  test('missing tools in configured session does not prevent readiness', () {
    final h = Harness();
    h.open();
    final session = Map<String, dynamic>.from(
      h.sent.single.$1['session'] as Map,
    );
    session.remove('tools');
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    h.receive({'type': 'session.updated', 'session': session});
    expect(h.confirmed, ['c0']);
    expect(h.failures, isEmpty);
  });

  test('an explicitly empty tools echo remains safe', () {
    final h = Harness();
    h.open();
    final session = Map<String, dynamic>.from(
      h.sent.single.$1['session'] as Map,
    );
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    session['tools'] = <Object>[];
    h.receive({'type': 'session.updated', 'session': session});
    expect(h.confirmed, ['c0']);
    expect(h.failures, isEmpty);
  });

  test('configuration echo on original channel gates readiness', () {
    final h = Harness();
    h.protocol.channelOpened('c0');
    expect(h.sent, isEmpty);
    expect(h.confirmed, isEmpty);
    h.receive({
      'type': 'session.created',
      'session': {'id': 'sess_1', 'model': 'qwen3.8-omni-flash-realtime'},
    });
    expect(h.sent, hasLength(1));
    expect(h.confirmed, isEmpty);
    final session = Map<String, dynamic>.from(
      h.sent.single.$1['session'] as Map,
    );
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    h.receive({'type': 'session.updated', 'session': session});
    expect(h.confirmed, ['c0']);
    expect(h.failures, isEmpty);
  });
  test('wrong channel or altered VAD settings fail without activating', () {
    final h = Harness();
    h.open();
    final session = Map<String, dynamic>.from(
      h.sent.single.$1['session'] as Map,
    );
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    (session['turn_detection'] as Map)['create_response'] = true;
    h.receive({'type': 'session.updated', 'session': session});
    expect(h.confirmed, isEmpty);
    expect(h.failures, hasLength(1));
    final other = Harness();
    other.open();
    other.receive({'type': 'session.updated', 'session': session}, 'c1');
    expect(other.confirmed, isEmpty);
    expect(other.failures, hasLength(1));
  });

  test('configuration requires the requested response token limit', () {
    final h = Harness();
    h.open();
    final session = Map<String, dynamic>.from(
      h.sent.single.$1['session'] as Map,
    );
    expect(session['max_tokens'], 128);
    session['id'] = 'sess_1';
    session['model'] = 'qwen3.8-omni-flash-realtime';
    session['max_tokens'] = 129;
    h.receive({'type': 'session.updated', 'session': session});
    expect(h.confirmed, isEmpty);
    expect(h.failures, hasLength(1));
  });

  test('unexpected search or tools prevent media activation', () {
    for (final changed in ['search', 'tools', 'null_tools', 'wrong_type']) {
      final h = Harness();
      h.open();
      final session = Map<String, dynamic>.from(
        h.sent.single.$1['session'] as Map,
      );
      expect(session['enable_search'], false);
      expect(session.containsKey('tools'), isFalse);
      session['id'] = 'sess_1';
      session['model'] = 'qwen3.8-omni-flash-realtime';
      if (changed == 'search') session['enable_search'] = true;
      if (changed == 'tools') {
        session['tools'] = [
          {'type': 'function'},
        ];
      }
      if (changed == 'null_tools') session['tools'] = null;
      if (changed == 'wrong_type') session['tools'] = 'none';
      h.receive({'type': 'session.updated', 'session': session});
      expect(h.confirmed, isEmpty);
      expect(h.failures, hasLength(1));
    }
  });
  test(
    'one user final requests one reply and assistant output stays unplayed',
    () {
      final h = Harness();
      h.configure();
      h.firstUser();
      expect(h.sent.map((s) => s.$1['type']), [
        'session.update',
        'response.create',
      ]);
      h.firstResponse();
      h.receive({
        'type': 'response.audio_transcript.delta',
        'event_id': 'e6',
        'response_id': 'r1',
        'item_id': 'a1',
        'output_index': 0,
        'content_index': 0,
        'delta': 'Hi',
      });
      h.receive({
        'type': 'response.audio_transcript.done',
        'event_id': 'e7',
        'response_id': 'r1',
        'item_id': 'a1',
        'output_index': 0,
        'content_index': 0,
        'transcript': 'Hi there',
      });
      h.receive({
        'type': 'response.done',
        'response': {'id': 'r1', 'status': 'completed'},
      });
      expect(h.projection.snapshot.turns.map((t) => t.text), [
        'Hello',
        'Hi there',
      ]);
      expect(
        h.projection.snapshot.turns.last.playback.status,
        DeliveryStatus.unknown,
      );
      expect(h.projection.snapshot.context.entries.map((e) => e.text), [
        'Hello',
      ]);
      expect(h.failures, isEmpty);
    },
  );
  test('new speech after a reply request stops before new turn or reply', () {
    final h = Harness();
    h.configure();
    h.firstUser();
    h.firstResponse();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e8',
      'item_id': 'u2',
    });
    expect(h.failures, hasLength(1));
    expect(h.projection.snapshot.turns, hasLength(2));
    expect(
      h.sent.map((s) => s.$1['type']).where((t) => t == 'response.create'),
      hasLength(1),
    );
  });
  test('unsolicited reply and invalid event fail with no output', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'response.created',
      'event_id': 'e4',
      'response': {'id': 'r1'},
    });
    expect(h.failures, hasLength(1));
    expect(h.updates, isEmpty);
    final x = Harness();
    x.configure();
    x.protocol.receive(const RealtimeTransportEvent('not json', 'c0'));
    expect(x.failures, hasLength(1));
  });

  test('an empty final transcript cannot request a paid reply', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': '   ',
    });
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
    expect(h.failures, hasLength(1));
  });

  test('final transcription without matching committed audio does not start a reply', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
    expect(h.failures, hasLength(1));
  });

  test(
    'reentrant end when response is published still cancels that response',
    () {
      final h = Harness();
      h.configure();
      h.firstUser();
      h.onUpdate = (update) {
        if (update is TurnStartedUpdate &&
            update.role == ConversationRole.assistant) {
          h.protocol.beginDrain();
        }
      };
      h.receive({
        'type': 'response.created',
        'event_id': 'e4',
        'response': {'id': 'r1'},
      });
      expect(h.controls, hasLength(1));
      expect(h.controls.single.$3, RealtimeDrainControlKind.cancelResponse);
      expect(
        h.controls.single.$4,
        h.updates.whereType<TurnStartedUpdate>().last.responseId,
      );
    },
  );
  test('ending while user final is published never starts a late response', () {
    final h = Harness();
    h.configure();
    h.onUpdate = (update) {
      if (update is TranscriptUpdate &&
          update.role == ConversationRole.user &&
          update.isFinal) {
        h.protocol.beginDrain();
      }
    };
    h.firstUser();
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
    expect(h.controls, isEmpty);
  });

  test(
    'late response creation during drain closes without publishing a turn',
    () {
      final h = Harness();
      h.configure();
      h.firstUser();
      h.protocol.beginDrain();
      h.receive({
        'type': 'response.created',
        'event_id': 'late-response',
        'response': {'id': 'r1'},
      });
      expect(h.failures, ['qwen_protocol_unavailable']);
      expect(h.projection.snapshot.turns, hasLength(1));
      expect(h.controls, isEmpty);
      expect(h.sent.map((s) => s.$1['type']), [
        'session.update',
        'response.create',
      ]);
    },
  );

  test('drain ignores the same response but closes on another response', () {
    final h = Harness();
    h.configure();
    h.firstUser();
    h.firstResponse();
    h.protocol.beginDrain();
    expect(h.controls, hasLength(1));
    h.receive({
      'type': 'response.created',
      'event_id': 'duplicate',
      'response': {'id': 'r1'},
    });
    expect(h.failures, isEmpty);
    h.receive({
      'type': 'response.created',
      'event_id': 'unexpected',
      'response': {'id': 'r2'},
    });
    expect(h.failures, ['qwen_protocol_unavailable']);
    expect(h.controls, hasLength(1));
    expect(h.projection.snapshot.turns, hasLength(2));
  });

  test('drain rejects user final without matching committed audio', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.protocol.beginDrain();
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.updates.whereType<TranscriptUpdate>(), isEmpty);
    expect(h.projection.snapshot.turns.single.isFinal, isFalse);
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
  });

  test('drain requires a matching stopped and committed item for the tail', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.protocol.beginDrain();
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'other-stop',
      'item_id': 'u2',
    });
    h.receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'other-commit',
      'item_id': 'u2',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'early-final',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.updates.whereType<TranscriptUpdate>(), isEmpty);
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.projection.snapshot.turns.single.isFinal, isTrue);
    expect(h.projection.snapshot.turns.single.text, 'Hello');
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
  });

  test('drain ignores a commit that precedes speech stop', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.protocol.beginDrain();
    h.receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'early-commit',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'early-final',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.updates.whereType<TranscriptUpdate>(), isEmpty);
  });

  test('drain accepts commit after speech stopped before drain', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    h.protocol.beginDrain();
    h.receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.projection.snapshot.turns.single.isFinal, isTrue);
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
  });

  test('drain accepts same user item stopped and committed before final', () {
    final h = Harness();
    h.configure();
    h.receive({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    h.protocol.beginDrain();
    h.receive({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    h.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(h.projection.snapshot.turns.single.isFinal, isTrue);
    expect(h.projection.snapshot.turns.single.text, 'Hello');
    expect(h.sent.map((s) => s.$1['type']), ['session.update']);
    expect(h.controls, isEmpty);
  });

  test('drain cancels an existing response only once and keeps final tail', () {
    final h = Harness();
    h.configure();
    h.firstUser();
    h.firstResponse();
    h.protocol.beginDrain();
    h.protocol.beginDrain();
    expect(h.controls, hasLength(1));
    expect(h.controls.single.$3, RealtimeDrainControlKind.cancelResponse);
    final response = (h.updates.whereType<TurnStartedUpdate>().last).responseId;
    expect(h.controls.single.$4, response);
    h.receive({
      'type': 'response.audio_transcript.done',
      'event_id': 'e7',
      'response_id': 'r1',
      'item_id': 'a1',
      'output_index': 0,
      'content_index': 0,
      'transcript': 'Hi',
    });
    expect(h.projection.snapshot.turns.last.text, 'Hi');
    expect(
      h.projection.snapshot.turns.last.playback.status,
      DeliveryStatus.unknown,
    );
    h.protocol.dispose();
    h.receive({
      'type': 'response.audio_transcript.done',
      'event_id': 'e8',
      'response_id': 'r1',
      'item_id': 'a1',
      'output_index': 0,
      'content_index': 0,
      'transcript': 'late',
    });
    expect(h.projection.snapshot.turns.last.text, 'Hi');
  });
}
