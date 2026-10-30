import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/qwen_guarded_protocol.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';
import 'media_fixtures.dart';

void main() {
  testWidgets(
    'configured channel gates microphone and later speech closes media',
    (tester) async {
      const provider = {
        'provider': 'dashscope',
        'region': 'cn-beijing',
        'model': 'qwen3.8-omni-flash-realtime',
        'config_id': 'qwen-private-v1',
      };
      final transport = TestTransport();
      final signaller = TestSignaller();
      late ApiClient api;
      var instance = clientId;
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/csrf')) {
            return response({'csrf_token': 'test'});
          }
          if (request.url.path.endsWith('/connections')) {
            instance = jsonDecode(request.body)['client_instance_id'] as String;
            final item = connectionJson(instance: instance);
            item['configuration'] = {...provider};
            return response(item, 201);
          }
          if (request.url.path.contains('/connections/')) {
            final item = connectionJson(instance: instance, status: 'closed');
            item['configuration'] = {...provider};
            return response(item);
          }
          final item = practiceJson();
          (item['configuration'] as Map<String, dynamic>)['provider'] = {
            ...provider,
          };
          return response(item, 201);
        }),
      )..expectedAccountId = accountId;
      final controller = PracticeMediaController(
        repository: PracticeRepository(api, accountId: accountId),
        transportFactory: () => transport,
        signallerFactory: (_, _) => signaller,
        protocolFactory: QwenGuardedProtocol.new,
      );
      unawaited(controller.begin());
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.connecting);
      await transport.signaller.exchangeOffer('v=0\r\n');
      transport.observe(const RealtimeObservation('channel_open', 'c0'));
      transport.connected.complete();
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.configuring);
      expect(transport.activations, isEmpty);
      void send(Map<String, Object?> data) =>
          transport.receive(RealtimeTransportEvent(jsonEncode(data), 'c0'));
      send({
        'type': 'session.created',
        'session': {'id': 's1', 'model': provider['model']},
      });
      expect(transport.activations, isEmpty);
      final outbound = transport.sent.single.substring(3);
      final update = jsonDecode(outbound) as Map<String, dynamic>;
      final session = Map<String, dynamic>.from(update['session'] as Map);
      session['id'] = 's1';
      session['model'] = provider['model'];
      send({'type': 'session.updated', 'session': session});
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.active);
      expect(transport.activations, ['c0']);
      send({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      });
      send({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e2',
        'item_id': 'u1',
      });
      send({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e2c',
        'item_id': 'u1',
      });
      send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e3',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 'Hello',
      });
      expect(transport.sent.last, 'c0:{"type":"response.create"}');
      send({
        'type': 'response.created',
        'event_id': 'e4',
        'response': {'id': 'r1'},
      });
      send({
        'type': 'response.output_item.added',
        'event_id': 'e5',
        'response_id': 'r1',
        'output_index': 0,
        'item': {'id': 'a1', 'type': 'message', 'role': 'assistant'},
      });
      send({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e6',
        'item_id': 'u2',
      });
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.localClosed);
      expect(transport.stops, 1);
      expect(controller.conversation?.turns, hasLength(2));
      controller.dispose();
      await tester.pump();
      api.close();
    },
  );
  testWidgets('drain only accepts committed user tail and sends no reply', (
    tester,
  ) async {
    const provider = {
      'provider': 'dashscope',
      'region': 'cn-beijing',
      'model': 'qwen3.8-omni-flash-realtime',
      'config_id': 'qwen-private-v1',
    };
    final transport = TestTransport();
    final signaller = TestSignaller();
    late ApiClient api;
    var instance = clientId;
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/csrf')) {
          return response({'csrf_token': 'test'});
        }
        if (request.url.path.endsWith('/connections')) {
          instance = jsonDecode(request.body)['client_instance_id'] as String;
          final item = connectionJson(instance: instance);
          item['configuration'] = {...provider};
          return response(item, 201);
        }
        if (request.url.path.contains('/connections/')) {
          final item = connectionJson(instance: instance, status: 'closed');
          item['configuration'] = {...provider};
          return response(item);
        }
        final item = practiceJson();
        (item['configuration'] as Map<String, dynamic>)['provider'] = {
          ...provider,
        };
        return response(item, 201);
      }),
    )..expectedAccountId = accountId;
    final controller = PracticeMediaController(
      repository: PracticeRepository(api, accountId: accountId),
      transportFactory: () => transport,
      signallerFactory: (_, _) => signaller,
      protocolFactory: QwenGuardedProtocol.new,
    );
    unawaited(controller.begin());
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.connecting);
    await transport.signaller.exchangeOffer('v=0\r\n');
    transport.observe(const RealtimeObservation('channel_open', 'c0'));
    transport.connected.complete();
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.configuring);
    expect(transport.activations, isEmpty);
    void send(Map<String, Object?> data) =>
        transport.receive(RealtimeTransportEvent(jsonEncode(data), 'c0'));
    send({
      'type': 'session.created',
      'session': {'id': 's1', 'model': provider['model']},
    });
    expect(transport.activations, isEmpty);
    final outbound = transport.sent.single.substring(3);
    final update = jsonDecode(outbound) as Map<String, dynamic>;
    final session = Map<String, dynamic>.from(update['session'] as Map);
    session['id'] = 's1';
    session['model'] = provider['model'];
    send({'type': 'session.updated', 'session': session});
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.active);
    expect(transport.activations, ['c0']);
    send({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    unawaited(controller.end());
    expect(controller.phase, PracticeMediaPhase.draining);
    send({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'early',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(controller.conversation!.turns.single.isFinal, isFalse);
    send({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    send({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    send({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(controller.conversation!.turns.single.isFinal, isTrue);
    expect(controller.conversation!.turns.single.text, 'Hello');
    expect(transport.sent, hasLength(1));
    await tester.pump(const Duration(seconds: 4));
    controller.dispose();
    await tester.pump();
    api.close();
  });
  testWidgets('late created response closes media without a new turn', (
    tester,
  ) async {
    const provider = {
      'provider': 'dashscope',
      'region': 'cn-beijing',
      'model': 'qwen3.8-omni-flash-realtime',
      'config_id': 'qwen-private-v1',
    };
    final transport = TestTransport();
    final signaller = TestSignaller();
    late ApiClient api;
    var instance = clientId;
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/csrf')) {
          return response({'csrf_token': 'test'});
        }
        if (request.url.path.endsWith('/connections')) {
          instance = jsonDecode(request.body)['client_instance_id'] as String;
          final item = connectionJson(instance: instance);
          item['configuration'] = {...provider};
          return response(item, 201);
        }
        if (request.url.path.contains('/connections/')) {
          final item = connectionJson(instance: instance, status: 'closed');
          item['configuration'] = {...provider};
          return response(item);
        }
        final item = practiceJson();
        (item['configuration'] as Map<String, dynamic>)['provider'] = {
          ...provider,
        };
        return response(item, 201);
      }),
    )..expectedAccountId = accountId;
    final controller = PracticeMediaController(
      repository: PracticeRepository(api, accountId: accountId),
      transportFactory: () => transport,
      signallerFactory: (_, _) => signaller,
      protocolFactory: QwenGuardedProtocol.new,
    );
    unawaited(controller.begin());
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.connecting);
    await transport.signaller.exchangeOffer('v=0\r\n');
    transport.observe(const RealtimeObservation('channel_open', 'c0'));
    transport.connected.complete();
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.configuring);
    expect(transport.activations, isEmpty);
    void send(Map<String, Object?> data) =>
        transport.receive(RealtimeTransportEvent(jsonEncode(data), 'c0'));
    send({
      'type': 'session.created',
      'session': {'id': 's1', 'model': provider['model']},
    });
    expect(transport.activations, isEmpty);
    final outbound = transport.sent.single.substring(3);
    final update = jsonDecode(outbound) as Map<String, dynamic>;
    final session = Map<String, dynamic>.from(update['session'] as Map);
    session['id'] = 's1';
    session['model'] = provider['model'];
    send({'type': 'session.updated', 'session': session});
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.active);
    expect(transport.activations, ['c0']);
    send({
      'type': 'input_audio_buffer.speech_started',
      'event_id': 'e1',
      'item_id': 'u1',
    });
    send({
      'type': 'input_audio_buffer.speech_stopped',
      'event_id': 'e2',
      'item_id': 'u1',
    });
    send({
      'type': 'input_audio_buffer.committed',
      'event_id': 'e2c',
      'item_id': 'u1',
    });
    send({
      'type': 'conversation.item.input_audio_transcription.completed',
      'event_id': 'e3',
      'item_id': 'u1',
      'content_index': 0,
      'transcript': 'Hello',
    });
    expect(transport.sent.last, 'c0:{"type":"response.create"}');
    final done = controller.end();
    expect(controller.phase, PracticeMediaPhase.draining);
    send({
      'type': 'response.created',
      'event_id': 'late-response',
      'response': {'id': 'r1'},
    });
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.localClosed);
    expect(controller.errorCode, 'qwen_protocol_unavailable');
    expect(controller.releaseStatus, MediaReleaseStatus.unconfirmed);
    expect(controller.conversation!.turns, hasLength(1));
    expect(transport.stops, 1);
    expect(transport.sent, hasLength(2));
    await done;
    controller.dispose();
    await tester.pump();
    api.close();
  });
  testWidgets(
    'response during transport drain does not publish or cancel an unfrozen turn',
    (tester) async {
      const provider = {
        'provider': 'dashscope',
        'region': 'cn-beijing',
        'model': 'qwen3.8-omni-flash-realtime',
        'config_id': 'qwen-private-v1',
      };
      final transport = TestTransport();
      final signaller = TestSignaller();
      late ApiClient api;
      var instance = clientId;
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/csrf')) {
            return response({'csrf_token': 'test'});
          }
          if (request.url.path.endsWith('/connections')) {
            instance = jsonDecode(request.body)['client_instance_id'] as String;
            final item = connectionJson(instance: instance);
            item['configuration'] = {...provider};
            return response(item, 201);
          }
          if (request.url.path.contains('/connections/')) {
            final item = connectionJson(instance: instance, status: 'closed');
            item['configuration'] = {...provider};
            return response(item);
          }
          final item = practiceJson();
          (item['configuration'] as Map<String, dynamic>)['provider'] = {
            ...provider,
          };
          return response(item, 201);
        }),
      )..expectedAccountId = accountId;
      final controller = PracticeMediaController(
        repository: PracticeRepository(api, accountId: accountId),
        transportFactory: () => transport,
        signallerFactory: (_, _) => signaller,
        protocolFactory: QwenGuardedProtocol.new,
      );
      unawaited(controller.begin());
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.connecting);
      await transport.signaller.exchangeOffer('v=0\r\n');
      transport.observe(const RealtimeObservation('channel_open', 'c0'));
      transport.connected.complete();
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.configuring);
      expect(transport.activations, isEmpty);
      void send(Map<String, Object?> data) =>
          transport.receive(RealtimeTransportEvent(jsonEncode(data), 'c0'));
      send({
        'type': 'session.created',
        'session': {'id': 's1', 'model': provider['model']},
      });
      expect(transport.activations, isEmpty);
      final outbound = transport.sent.single.substring(3);
      final update = jsonDecode(outbound) as Map<String, dynamic>;
      final session = Map<String, dynamic>.from(update['session'] as Map);
      session['id'] = 's1';
      session['model'] = provider['model'];
      send({'type': 'session.updated', 'session': session});
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.active);
      expect(transport.activations, ['c0']);
      send({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      });
      send({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e2',
        'item_id': 'u1',
      });
      send({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e2c',
        'item_id': 'u1',
      });
      send({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e3',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 'Hello',
      });
      expect(transport.sent.last, 'c0:{"type":"response.create"}');
      transport.onDrain = () => send({
        'type': 'response.created',
        'event_id': 'concurrent-response',
        'response': {'id': 'r1'},
      });
      final done = controller.end();
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.localClosed);
      expect(controller.errorCode, 'drain_protocol_violation');
      expect(controller.releaseStatus, MediaReleaseStatus.unconfirmed);
      expect(controller.conversation!.turns, hasLength(1));
      expect(transport.stops, 1);
      expect(transport.sent, hasLength(2));
      await done;
      controller.dispose();
      await tester.pump();
      api.close();
    },
  );
  testWidgets(
    'configuration uses the server event channel with another channel open',
    (tester) async {
      const provider = {
        'provider': 'dashscope',
        'region': 'cn-beijing',
        'model': 'qwen3.8-omni-flash-realtime',
        'config_id': 'qwen-private-v1',
      };
      final transport = TestTransport();
      final signaller = TestSignaller();
      late ApiClient api;
      var instance = clientId;
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/csrf')) {
            return response({'csrf_token': 'test'});
          }
          if (request.url.path.endsWith('/connections')) {
            instance = jsonDecode(request.body)['client_instance_id'] as String;
            final item = connectionJson(instance: instance);
            item['configuration'] = {...provider};
            return response(item, 201);
          }
          if (request.url.path.contains('/connections/')) {
            final item = connectionJson(instance: instance, status: 'closed');
            item['configuration'] = {...provider};
            return response(item);
          }
          final item = practiceJson();
          (item['configuration'] as Map<String, dynamic>)['provider'] = {
            ...provider,
          };
          return response(item, 201);
        }),
      )..expectedAccountId = accountId;
      final controller = PracticeMediaController(
        repository: PracticeRepository(api, accountId: accountId),
        transportFactory: () => transport,
        signallerFactory: (_, _) => signaller,
        protocolFactory: QwenGuardedProtocol.new,
      );
      unawaited(controller.begin());
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.connecting);
      await transport.signaller.exchangeOffer('v=0\r\n');
      transport.observe(const RealtimeObservation('channel_open', 'client'));
      transport.observe(const RealtimeObservation('channel_open', 'server'));
      transport.connected.complete();
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.configuring);
      expect(transport.activations, isEmpty);
      void send(Map<String, Object?> data) =>
          transport.receive(RealtimeTransportEvent(jsonEncode(data), 'server'));
      send({
        'type': 'session.created',
        'session': {'id': 's1', 'model': provider['model']},
      });
      expect(transport.activations, isEmpty);
      final outbound = transport.sent.single.substring('server:'.length);
      final update = jsonDecode(outbound) as Map<String, dynamic>;
      final session = Map<String, dynamic>.from(update['session'] as Map);
      session['id'] = 's1';
      session['model'] = provider['model'];
      send({'type': 'session.updated', 'session': session});
      await tester.pump();
      expect(controller.phase, PracticeMediaPhase.active);
      expect(transport.activations, ['server']);
      expect(controller.phase, PracticeMediaPhase.active);
      expect(transport.sent.single.startsWith('server:'), isTrue);
      await controller.stop();
      controller.dispose();
      await tester.pump();
      api.close();
    },
  );
}
