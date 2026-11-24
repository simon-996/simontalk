import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/qwen_guarded_protocol.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';
import 'package:simontalk_client/features/realtime/realtime_transport_factory.dart';

import '../features/practice/practice_fixtures.dart';

@JS('probe.waitForStart')
external JSPromise<JSBoolean> _waitForStart();
@JS('probe.exchange')
external JSPromise<JSString> _exchange(JSString offer);
@JS('probe.update')
external void _update(JSString value);
@JS('probe.setStop')
external void _setStop(JSFunction callback);
@JS('probe.finished')
external void _finished();

class _Signaller implements RealtimeSignaller {
  bool stopped = false;
  @override
  Future<String> exchangeOffer(String offer) async {
    if (stopped) throw StateError('cancelled');
    final answer = (await _exchange(offer.toJS).toDart).toDart;
    if (stopped) throw StateError('cancelled');
    return answer;
  }

  @override
  void cancel() {
    stopped = true;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!(await _waitForStart().toDart).toDart) return;
  const provider = {
    'provider': 'dashscope',
    'region': 'cn-beijing',
    'model': 'qwen3.8-omni-flash-realtime',
    'config_id': 'qwen-playback-probe-v1',
  };
  var instance = clientId;
  var renewalSecond = 0;
  final api = ApiClient(
    baseUrl: Uri.parse('http://localhost'),
    isWeb: true,
    tokenStore: TestTokenStore(),
    client: MockClient((request) async {
      if (request.url.path.endsWith('/csrf')) {
        return response({'csrf_token': 'test'});
      }
      if (request.url.path.endsWith('/connections')) {
        instance = jsonDecode(request.body)['client_instance_id'] as String;
        return response(
          connectionJson(instance: instance)..['configuration'] = {...provider},
          201,
        );
      }
      if (request.url.path.endsWith('/renew-lease')) {
        renewalSecond += 15;
        return response(
          connectionJson(
            instance: instance,
            status: 'ready',
            second: renewalSecond,
          )..['configuration'] = {...provider},
        );
      }
      if (request.url.path.contains('/connections/')) {
        return response(
          connectionJson(instance: instance, status: 'closed')
            ..['configuration'] = {...provider},
        );
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
    transportFactory: createRealtimeTransport,
    signallerFactory: (_, _) => _Signaller(),
    protocolFactory: QwenGuardedProtocol.new,
  );
  void observe() {
    final turns = controller.conversation?.turns ?? <ConversationTurn>[];
    final users = turns.where((t) => t.role == ConversationRole.user).toList();
    final assistants = turns
        .where((t) => t.role == ConversationRole.assistant)
        .toList();
    _update(
      jsonEncode({
        'phase': controller.phase.name,
        'playback': controller.playback.name,
        'error': controller.errorCode,
        'release': controller.releaseStatus.name,
        'users': users.length,
        'final_users': users.where((t) => t.isFinal).length,
        'assistants': assistants.length,
        'assistant_frozen': assistants.any((t) => t.frozenPrefix != null),
        'assistant_playback_unknown':
            assistants.isNotEmpty &&
            assistants.every((t) => t.playback.playedUntilMs == null),
      }).toJS,
    );
  }

  controller.addListener(observe);
  var stopping = false;
  _setStop(
    (() {
      if (stopping) return;
      stopping = true;
      unawaited(() async {
        await controller.stop();
        observe();
        controller.dispose();
        api.close();
        _finished();
      }());
    }).toJS,
  );
  try {
    await controller.begin();
    observe();
  } catch (_) {
    _update('{"entry_error":true}'.toJS);
  }
}
