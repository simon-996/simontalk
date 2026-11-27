import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/realtime/browser_media_session.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';
import 'package:simontalk_client/features/realtime/qwen_server_media_protocol.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_models.dart';
import 'package:simontalk_client/features/session/practice_session_screen.dart';

import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart'
    show ScopedAccountController, signedIn;
import '../rehearsal/rehearsal_fixtures.dart'
    show childId, childJson, rehearsalTargetJson;
import 'media_fixtures.dart';
import 'practice_media_completion_test.dart'
    show ReceiptTestTranscriptJournal, TestPracticeCompletion;

const _qwenProvider = {
  'provider': 'dashscope',
  'region': 'cn-beijing',
  'model': 'qwen3.8-omni-flash-realtime',
  'config_id': 'qwen-private-v1',
};

class TestBrowserMediaSession implements RealtimeMediaSession {
  TestBrowserMediaSession({
    required this.connection,
    required this.onEvent,
    required this.onClosed,
  });

  final ConnectionReservation connection;
  final void Function(String kind, String payload) onEvent;
  final void Function(String reason) onClosed;
  final _active = Completer<void>();
  final mutes = <bool>[];
  int slowPaceRequests = 0;
  int interrupts = 0;
  int starts = 0;
  int holds = 0;
  int drains = 0;
  int stops = 0;
  bool closed = false;

  @override
  Future<void> start() {
    starts++;
    return _active.future;
  }

  void emitOpening() => onEvent('opening', '');
  void emitReady() => onEvent('ready', '');
  void emitActive() {
    if (!_active.isCompleted) _active.complete();
    onEvent('active', '');
  }

  void emitProvider(Map<String, Object?> event) =>
      onEvent('provider_event', jsonEncode(event));

  void emitQuarantine(String responseId) => onEvent('quarantine', responseId);

  void emitPaceUpdated() => onEvent('pace_updated', 'slow');

  void emitPlayback(String state) => onEvent('playback', state);

  void closeWith(String reason) {
    if (closed) return;
    closed = true;
    if (!_active.isCompleted) {
      _active.completeError(RealtimeFailure(reason));
    }
    onClosed(reason);
  }

  @override
  bool setMuted(bool muted) {
    if (closed) return false;
    mutes.add(muted);
    return true;
  }

  @override
  bool requestSlowPace() {
    if (closed) return false;
    slowPaceRequests++;
    return true;
  }

  @override
  bool interruptPlayback() {
    if (closed) return false;
    interrupts++;
    return true;
  }

  @override
  void holdPlayback() {
    if (closed) throw const RealtimeFailure('cancelled');
    holds++;
  }

  @override
  void beginDrain() {
    if (closed) throw const RealtimeFailure('cancelled');
    drains++;
  }

  @override
  void stop() {
    stops++;
    closeWith('local_closed');
  }
}

class _WebSocketCallHarness {
  _WebSocketCallHarness(this.tester) {
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      timeout: const Duration(minutes: 2),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/csrf')) {
          return response({'csrf_token': 'test-csrf'});
        }
        requests.add(request);
        final path = request.url.path;
        final segments = request.url.pathSegments;
        final sid = segments.length >= 3 && segments[1] == 'practice-sessions'
            ? segments[2]
            : practiceId;
        if (path.endsWith('/connections')) {
          instance = jsonDecode(request.body)['client_instance_id'] as String;
          final item = connectionJson(instance: instance, second: seconds);
          item['session_id'] = sid;
          item['configuration'] = {..._qwenProvider};
          return response(item, 201);
        }
        if (path.endsWith('/renew-lease')) {
          final item = connectionJson(
            instance: instance,
            second: seconds,
            status: session != null && session!.starts > 0
                ? 'configuring'
                : 'preparing',
            termination: session != null && session!.starts > 0
                ? 'unknown'
                : 'not_started',
          );
          item['session_id'] = sid;
          item['configuration'] = {..._qwenProvider};
          return response(item);
        }
        if (path.contains('/connections/')) {
          final item = connectionJson(instance: instance, status: 'closed');
          item['session_id'] = sid;
          item['configuration'] = {..._qwenProvider};
          return response(item);
        }
        final status = path.endsWith('/cancel-preparation')
            ? 'cancelled'
            : 'created';
        final item = sid == childId
            ? childJson(status: status)
            : practiceJson(status: status);
        if (initialSpeechPace != null) {
          ((item['configuration'] as Map<String, dynamic>)['preferences']
                  as Map<String, dynamic>)['speech_pace'] =
              initialSpeechPace;
        }
        (item['configuration'] as Map<String, dynamic>)['provider'] = {
          ..._qwenProvider,
        };
        return response(item, 201);
      }),
    )..expectedAccountId = accountId;

    container = ProviderContainer(
      overrides: [
        accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
        accountControllerProvider.overrideWith(ScopedAccountController.new),
        realtimeObservationJournalFactoryProvider.overrideWithValue(
          (_, _, _, _) => observations,
        ),
        realtimeTranscriptJournalFactoryProvider.overrideWithValue(
          (_, _) => transcripts,
        ),
        practiceCompletionClientFactoryProvider.overrideWithValue(
          (_, _) => completion,
        ),
        realtimeTransportFactoryProvider.overrideWithValue(() {
          transportCreates++;
          return TestTransport();
        }),
        realtimeSignallerCreatorProvider.overrideWithValue((_, _, _, _) {
          signallerCreates++;
          return TestSignaller();
        }),
        realtimeMediaSessionCreatorProvider.overrideWithValue(({
          required accountApi,
          required accountId,
          required connection,
          required onEvent,
          required onClosed,
        }) {
          expect(accountApi, same(api));
          expect(accountId, accountId);
          sessionCreates++;
          return session = TestBrowserMediaSession(
            connection: connection,
            onEvent: onEvent,
            onClosed: onClosed,
          );
        }),
        realtimeProtocolFactoryProvider.overrideWithValue(
          QwenServerMediaProtocol.new,
        ),
      ],
    );
  }

  final WidgetTester tester;
  late final DateTime origin = tester.binding.clock.now();
  late final ApiClient api;
  late final ProviderContainer container;
  final requests = <http.Request>[];
  final observations = TestObservationJournal();
  final transcripts = ReceiptTestTranscriptJournal();
  final completion = TestPracticeCompletion();
  TestBrowserMediaSession? session;
  String? initialSpeechPace;
  String instance = clientId;
  int transportCreates = 0;
  int signallerCreates = 0;
  int sessionCreates = 0;

  int get seconds => tester.binding.clock.now().difference(origin).inSeconds;
  PracticeMediaController get controller =>
      container.read(practiceMediaProvider)!;

  Future<void> openCallScreen({RehearsalSessionLaunch? rehearsal}) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PracticeSessionScreen(rehearsal: rehearsal),
                  ),
                ),
                child: const Text('打开通话'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开通话'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> activateCall() async {
    await openCallScreen();
    expect(controller.phase, PracticeMediaPhase.connecting);
    session!.emitOpening();
    session!.emitReady();
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.configuring);
    expect(find.text('正在确认语音配置，尚未开始收音…'), findsOneWidget);
    session!.emitActive();
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.active);
    expect(find.text('正在听你说'), findsOneWidget);
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.binding.setSurfaceSize(null);
    container.dispose();
    api.close();
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'live call screen activates server-owned WebSocket session without SDP or client session.update',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);

      await h.activateCall();

      expect(h.sessionCreates, 1);
      expect(h.signallerCreates, 0);
      expect(h.transportCreates, 0);
      expect(h.requests.where((r) => r.url.path.endsWith('/offer')), isEmpty);
      expect(h.session!.connection.id, connectionId);
      expect(h.session!.mutes, [false]);
      expect(h.observations.events.map((e) => e['code']).toList(), [
        'negotiating',
        'transport_connected',
        'configuration_confirmed',
        'requesting_microphone',
        'microphone_active',
      ]);
    },
  );

  testWidgets(
    'cancelling before opening releases reservation while cancelling after opening stays unconfirmed',
    (tester) async {
      final before = _WebSocketCallHarness(tester);
      addTearDown(before.dispose);
      await before.openCallScreen();
      final beforeController = before.controller;
      expect(beforeController.signallingAttempted, isFalse);
      await tester.tap(find.text('取消这次尝试'));
      await tester.pumpAndSettle();
      expect(beforeController.releaseStatus, MediaReleaseStatus.released);
      expect(before.requests.last.url.path, endsWith('/cancel-preparation'));

      final after = _WebSocketCallHarness(tester);
      addTearDown(after.dispose);
      await after.openCallScreen();
      final afterController = after.controller;
      after.session!.emitOpening();
      expect(afterController.signallingAttempted, isTrue);
      await tester.tap(find.text('取消这次尝试'));
      await tester.pumpAndSettle();
      expect(afterController.releaseStatus, MediaReleaseStatus.unconfirmed);
      expect(
        after.requests.where((r) => r.url.path.contains('/cancel-')),
        isEmpty,
      );
    },
  );

  for (final earlyDelta in [false, true]) {
    testWidgets(
      'active call handles mute, turn projection and server quarantine (earlyDelta: $earlyDelta)',
      (tester) async {
        final h = _WebSocketCallHarness(tester);
        addTearDown(h.dispose);
        await h.activateCall();

        await tester.tap(find.text('静音麦克风'));
        await tester.pump();
        expect(h.session!.mutes.last, isTrue);
        expect(find.text('麦克风已关闭'), findsOneWidget);

        await tester.tap(find.text('打开麦克风'));
        await tester.pump();
        expect(h.session!.mutes.last, isFalse);
        expect(find.text('正在听你说'), findsOneWidget);

        h.session!.emitProvider({
          'type': 'input_audio_buffer.speech_started',
          'event_id': 'e1',
          'item_id': 'u1',
        });
        h.session!.emitProvider({
          'type': 'input_audio_buffer.speech_stopped',
          'event_id': 'e2',
          'item_id': 'u1',
        });
        h.session!.emitProvider({
          'type': 'input_audio_buffer.committed',
          'event_id': 'e3',
          'item_id': 'u1',
        });
        h.session!.emitProvider({
          'type': 'conversation.item.input_audio_transcription.completed',
          'event_id': 'e4',
          'item_id': 'u1',
          'content_index': 0,
          'transcript': 'Hello from browser',
        });
        h.session!.emitProvider({
          'type': 'response.created',
          'event_id': 'e5',
          'response': {'id': 'resp_1'},
        });
        h.session!.emitProvider({
          'type': 'response.output_item.added',
          'event_id': 'e6',
          'response_id': 'resp_1',
          'output_index': 0,
          'item': {'id': 'item_1', 'type': 'message', 'role': 'assistant'},
        });
        h.session!.emitProvider({
          'type': 'response.audio_transcript.delta',
          'event_id': 'e7',
          'response_id': 'resp_1',
          'item_id': 'item_1',
          'output_index': 0,
          'content_index': 0,
          'delta': 'Hi there',
        });
        await tester.pump();
        expect(find.text('Hello from browser'), findsOneWidget);
        expect(find.text('Hi there'), findsOneWidget);

        h.session!.emitQuarantine('resp_1');
        if (earlyDelta) {
          h.session!.emitProvider({
            'type': 'conversation.item.input_audio_transcription.delta',
            'event_id': 'e8',
            'item_id': 'u2',
            'content_index': 0,
            'text': 'Wait ',
            'stash': 'a second',
          });
          h.session!.emitProvider({
            'type': 'input_audio_buffer.speech_started',
            'event_id': 'e9',
            'item_id': 'u2',
          });
        } else {
          h.session!.emitProvider({
            'type': 'input_audio_buffer.speech_started',
            'event_id': 'e8',
            'item_id': 'u2',
          });
        }
        h.session!.emitProvider({
          'type': 'input_audio_buffer.speech_stopped',
          'event_id': 'e10',
          'item_id': 'u2',
        });
        h.session!.emitProvider({
          'type': 'input_audio_buffer.committed',
          'event_id': 'e11',
          'item_id': 'u2',
        });
        h.session!.emitProvider({
          'type': 'conversation.item.input_audio_transcription.completed',
          'event_id': 'e12',
          'item_id': 'u2',
          'content_index': 0,
          'transcript': 'Wait a second',
        });
        h.session!.emitProvider({
          'type': 'response.done',
          'event_id': 'e13',
          'response': {'id': 'resp_1', 'status': 'cancelled'},
        });
        await tester.pump();

        expect(h.session!.holds, 1);
        expect(h.controller.interruptionNeedsEnd, isTrue);
        expect(find.text('对话已中断，暂时无法继续'), findsOneWidget);
        expect(find.text('Wait a second'), findsOneWidget);

        await tester.tap(find.text('静音麦克风'));
        await tester.pump();
        expect(find.text('麦克风已关闭，请结束并复盘。'), findsOneWidget);
        h.controller.setMuted(false);
        expect(h.controller.muted, isTrue);
      },
    );
  }

  testWidgets(
    'leaving the live call page stops WebSocket media without requesting completion',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();
      final activeController = h.controller;

      Navigator.of(tester.element(find.byType(PracticeSessionScreen))).pop();
      await tester.pumpAndSettle();

      expect(h.session!.stops, 1);
      expect(activeController.phase, PracticeMediaPhase.localClosed);
      expect(activeController.errorCode, 'page_left');
      expect(h.completion.requests, 0);
      expect(h.completion.manifests, isEmpty);
    },
  );

  testWidgets(
    'ending on the live call page drains WebSocket media, captures tail final and reconciles sealed save',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();

      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.delta',
        'event_id': 'e2',
        'item_id': 'u1',
        'content_index': 0,
        'text': 'Good ',
        'stash': 'morning',
      });
      await tester.pump();

      await tester.tap(find.text('结束并复盘'));
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.draining);
      expect(h.session!.drains, 1);
      expect(h.session!.stops, 0);
      expect(h.completion.requests, 1);
      expect(find.text('正在收尾，等待最后一句识别…'), findsOneWidget);

      h.session!.emitProvider({
        'type': 'response.created',
        'event_id': 'crossing_reply',
        'response': {'id': 'uncaptured_reply'},
      });
      h.session!.emitProvider({
        'type': 'response.done',
        'event_id': 'crossing_reply_done',
        'response': {'id': 'uncaptured_reply', 'status': 'completed'},
      });
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.draining);

      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e4',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e5',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 'Good morning!',
      });
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.session!.stops, 1);
      expect(h.transcripts.events.single.text, 'Good morning!');
      final manifest = h.completion.manifests.single;
      expect(manifest.unfinalizedTurnIds, isEmpty);
      expect(manifest.transcripts.totalEvents, 1);

      final scope = manifest.scope;
      h.completion.confirmReceipt(
        PracticeCompletionReceipt.fromJson(
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
            'transcript_events': [
              {'sequence': 1, 'event_id': h.transcripts.events.single.turnId},
            ],
            'playback_events': <Object>[],
          },
          scope: scope,
          practiceInputHash: 'b' * 64,
        ),
      );
      await tester.pump();

      expect(h.controller.completionHasPendingWork, isFalse);
      expect(find.text('本次练习已结束'), findsOneWidget);
      expect(find.text('查看本次记录'), findsOneWidget);
      expect(find.text('返回练习'), findsOneWidget);

      final activeController = h.controller;
      h.api.expectedAccountId = requestKey;
      (h.container.read(
        accountControllerProvider.notifier,
      ) as ScopedAccountController).change(signedIn(requestKey));
      await tester.pump();
      expect(activeController.conversation, isNull);
    },
  );

  testWidgets(
    'ending before the assistant item arrives saves the known reply tail',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();
      for (final type in [
        'input_audio_buffer.speech_started',
        'input_audio_buffer.speech_stopped',
        'input_audio_buffer.committed',
        'conversation.item.input_audio_transcription.completed',
      ]) {
        h.session!.emitProvider({
          'type': type,
          'event_id': type,
          'item_id': 'u1',
          'content_index': 0,
          'transcript': 'Good morning!',
        });
      }
      h.session!.emitProvider({
        'type': 'response.created',
        'event_id': 'known_response',
        'response': {'id': 'r1'},
      });
      await tester.pump();
      await tester.tap(find.text('结束并复盘'));
      await tester.pump();
      h.session!.emitProvider({
        'type': 'response.output_item.added',
        'event_id': 'late_item',
        'response_id': 'r1',
        'output_index': 0,
        'item': {'id': 'a1', 'type': 'message', 'role': 'assistant'},
      });
      h.session!.emitProvider({
        'type': 'response.audio_transcript.done',
        'event_id': 'late_transcript',
        'response_id': 'r1',
        'item_id': 'a1',
        'content_index': 0,
        'output_index': 0,
        'transcript': 'The frozen reply text',
      });
      h.session!.emitProvider({
        'type': 'response.done',
        'event_id': 'known_response_done',
        'response': {'id': 'r1', 'status': 'completed'},
      });
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.draining);
      await tester.pump(const Duration(seconds: 3));
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.transcripts.events.map((event) => event.text).toList(), [
        'Good morning!',
        'The frozen reply text',
      ]);
    },
  );

  for (final invalid in [
    {
      'kind': 'provider_event',
      'payload': jsonEncode({
        'type': 'session.created',
        'event_id': 'e1',
        'session': {'id': 's1', 'model': _qwenProvider['model']},
      }),
    },
    {'kind': 'quarantine', 'payload': 'missing_response'},
  ]) {
    testWidgets(
      'protocol violations fail closed on the WebSocket session (${invalid['kind']})',
      (tester) async {
        final h = _WebSocketCallHarness(tester);
        addTearDown(h.dispose);
        await h.activateCall();

        h.session!.onEvent(invalid['kind']!, invalid['payload']!);
        await tester.pump();

        expect(h.controller.phase, PracticeMediaPhase.localClosed);
        expect(h.controller.errorCode, 'qwen_protocol_unavailable');
        expect(h.session!.stops, 1);
      },
    );
  }

  testWidgets(
    'multi-turn WebSocket call projects consecutive turns and saves all on end',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();

      for (final (idx, uItem, userText, respId, aItem, aiText) in [
        (1, 'u1', 'First user turn', 'r1', 'a1', 'First AI reply'),
        (2, 'u2', 'Second user turn', 'r2', 'a2', 'Second AI reply'),
      ]) {
        h.session!.emitProvider({
          'type': 'input_audio_buffer.speech_started',
          'event_id': 'es_$idx',
          'item_id': uItem,
        });
        h.session!.emitProvider({
          'type': 'input_audio_buffer.speech_stopped',
          'event_id': 'et_$idx',
          'item_id': uItem,
        });
        h.session!.emitProvider({
          'type': 'input_audio_buffer.committed',
          'event_id': 'ec_$idx',
          'item_id': uItem,
        });
        h.session!.emitProvider({
          'type': 'conversation.item.input_audio_transcription.completed',
          'event_id': 'eu_$idx',
          'item_id': uItem,
          'content_index': 0,
          'transcript': userText,
        });
        h.session!.emitProvider({
          'type': 'response.created',
          'event_id': 'er_$idx',
          'response': {'id': respId},
        });
        h.session!.emitProvider({
          'type': 'response.output_item.added',
          'event_id': 'eo_$idx',
          'response_id': respId,
          'output_index': 0,
          'item': {'id': aItem, 'type': 'message', 'role': 'assistant'},
        });
        h.session!.emitProvider({
          'type': 'response.audio_transcript.done',
          'event_id': 'ea_$idx',
          'response_id': respId,
          'item_id': aItem,
          'output_index': 0,
          'content_index': 0,
          'transcript': aiText,
        });
        h.session!.emitProvider({
          'type': 'response.done',
          'event_id': 'ed_$idx',
          'response': {'id': respId, 'status': 'completed'},
        });
      }
      await tester.pump();
      expect(find.text('First user turn'), findsOneWidget);
      expect(find.text('First AI reply'), findsOneWidget);
      expect(find.text('Second user turn'), findsOneWidget);
      expect(find.text('Second AI reply'), findsOneWidget);

      await tester.tap(find.text('结束并复盘'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(h.transcripts.events.map((e) => e.text).toList(), [
        'First user turn',
        'First AI reply',
        'Second user turn',
        'Second AI reply',
      ]);
      expect(h.completion.manifests.single.transcripts.totalEvents, 4);
    },
  );

  testWidgets(
    'post-done playback overlap quarantine holds output and captures interrupting turn',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();

      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e2',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e3',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e4',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 'Tell me a story',
      });
      h.session!.emitProvider({
        'type': 'response.created',
        'event_id': 'e5',
        'response': {'id': 'r1'},
      });
      h.session!.emitProvider({
        'type': 'response.output_item.added',
        'event_id': 'e6',
        'response_id': 'r1',
        'output_index': 0,
        'item': {'id': 'a1', 'type': 'message', 'role': 'assistant'},
      });
      h.session!.emitProvider({
        'type': 'response.audio_transcript.done',
        'event_id': 'e7',
        'response_id': 'r1',
        'item_id': 'a1',
        'output_index': 0,
        'content_index': 0,
        'transcript': 'Long story already finished on wire',
      });
      h.session!.emitProvider({
        'type': 'response.done',
        'event_id': 'e8',
        'response': {'id': 'r1', 'status': 'completed'},
      });
      // User speaks before browser finished playing buffered audio.
      h.session!.emitQuarantine('r1');
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e9',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e10',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e11',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e12',
        'item_id': 'u2',
        'content_index': 0,
        'transcript': 'Hold on',
      });
      await tester.pump();

      expect(h.session!.holds, 1);
      expect(h.controller.interruptionNeedsEnd, isTrue);
      expect(find.text('对话已中断，暂时无法继续'), findsOneWidget);
      expect(find.text('Hold on'), findsOneWidget);
    },
  );

  testWidgets(
    'real Qwen post-stop deltas, early turn delta and post-quarantine output item succeed',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();

      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e2',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e3',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.delta',
        'event_id': 'e4',
        'item_id': 'u1',
        'content_index': 0,
        'text': 'Yesterday I went ',
        'stash': 'to the park.',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e5',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 'Yesterday I went to the park.',
      });
      h.session!.emitProvider({
        'type': 'response.created',
        'event_id': 'e6',
        'response': {'id': 'r1'},
      });
      h.session!.emitProvider({
        'type': 'response.output_item.added',
        'event_id': 'e7',
        'response_id': 'r1',
        'output_index': 0,
        'item': {'id': 'a1', 'type': 'message', 'role': 'assistant'},
      });
      h.session!.emitProvider({
        'type': 'response.audio_transcript.done',
        'event_id': 'e8',
        'response_id': 'r1',
        'item_id': 'a1',
        'output_index': 0,
        'content_index': 0,
        'transcript': 'Sounds relaxing!',
      });
      h.session!.emitProvider({
        'type': 'response.done',
        'event_id': 'e9',
        'response': {'id': 'r1', 'status': 'completed'},
      });

      // Turn 2 starts with streaming ASR delta arriving ahead of speech_started.
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.delta',
        'event_id': 'e10',
        'item_id': 'u2',
        'content_index': 0,
        'text': '',
        'stash': 'I like cycling',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e11',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e12',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e13',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e14',
        'item_id': 'u2',
        'content_index': 0,
        'transcript': 'I like cycling.',
      });
      h.session!.emitProvider({
        'type': 'response.created',
        'event_id': 'e15',
        'response': {'id': 'r2'},
      });
      // User interrupts before output_item.added arrives from Beijing.
      h.session!.emitQuarantine('r2');
      h.session!.emitProvider({
        'type': 'response.output_item.added',
        'event_id': 'e16',
        'response_id': 'r2',
        'output_index': 0,
        'item': {'id': 'a2', 'type': 'message', 'role': 'assistant'},
      });
      h.session!.emitProvider({
        'type': 'response.audio_transcript.done',
        'event_id': 'e17',
        'response_id': 'r2',
        'item_id': 'a2',
        'output_index': 0,
        'content_index': 0,
        'transcript': 'In-flight reply',
      });
      h.session!.emitProvider({
        'type': 'response.done',
        'event_id': 'e18',
        'response': {'id': 'r2', 'status': 'completed'},
      });
      await tester.pump();

      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(h.controller.interruptionNeedsEnd, isTrue);
      expect(find.text('Yesterday I went to the park.'), findsOneWidget);
      expect(find.text('Sounds relaxing!'), findsOneWidget);
      expect(find.text('I like cycling.'), findsOneWidget);
    },
  );

  testWidgets(
    'rehearsal launch adopts existing child preparation without creating ordinary practice, seals child and exposes review actions',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      final childData = childJson();
      final config = childData['configuration'] as Map<String, dynamic>;
      config['effective_difficulty'] = 'advanced';
      config['provider'] = {..._qwenProvider};
      final prep = PracticePreparation.fromJson(childData);
      final targetJson = rehearsalTargetJson();
      final target = RehearsalTarget.fromJson(
        targetJson,
        accountId: accountId,
        sourceSessionId: practiceId,
        itemId: targetJson['item_id'] as String,
      );
      final launch = RehearsalSessionLaunch(
        accountId: accountId,
        preparation: prep,
        target: target,
      );

      await h.openCallScreen(rehearsal: launch);
      expect(
        h.requests.where((r) => r.url.path == '/v1/practice-sessions'),
        isEmpty,
      );
      expect(
        h.requests.single.url.path,
        '/v1/practice-sessions/$childId/connections',
      );
      expect(find.text('重练：这一句表达'), findsOneWidget);
      expect(
        find.text('本次难度：${prep.configuration.effectiveDifficulty.label}'),
        findsOneWidget,
      );
      expect(find.text('重练片段：I enjoy English.'), findsOneWidget);
      expect(find.text('参考说法：I enjoy learning English.'), findsOneWidget);

      h.session!.emitOpening();
      h.session!.emitReady();
      await tester.pump();
      h.session!.emitActive();
      await tester.pump();

      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'r_e1',
        'item_id': 'u_rehearse',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'r_e2',
        'item_id': 'u_rehearse',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'r_e3',
        'item_id': 'u_rehearse',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'r_e4',
        'item_id': 'u_rehearse',
        'content_index': 0,
        'transcript': 'I really enjoy learning English.',
      });
      await tester.pump();

      await tester.tap(find.text('结束并复盘'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      final manifest = h.completion.manifests.single;
      expect(manifest.scope.sessionId, childId);
      h.completion.confirmReceipt(
        PracticeCompletionReceipt.fromJson(
          {
            'source': 'server_recorded',
            'account_id': accountId,
            'session_id': childId,
            'connection_id': connectionId,
            'client_instance_id': h.instance,
            'epoch': 1,
            'sealed': true,
            'recoverable': false,
            'input_revision': 1,
            'input_hash': 'a' * 64,
            'practice_input_hash': 'b' * 64,
            'transcript_events': [
              {'sequence': 1, 'event_id': h.transcripts.events.single.turnId},
            ],
            'playback_events': <Object>[],
          },
          scope: manifest.scope,
          practiceInputHash: 'b' * 64,
        ),
        summary: PracticeCompletionSummary.fromJson({
          'source': 'server_recorded',
          'account_id': accountId,
          'session_id': childId,
          'origin_connection_id': connectionId,
          'client_instance_id': h.instance,
          'epoch': 1,
          'end_key': requestKey,
          'status': 'sealed',
          'accepted_at': '2026-11-25T00:00:00Z',
          'final_upload_deadline': '2026-11-25T00:00:30Z',
          'sealed_at': '2026-11-25T00:00:02Z',
          'input_revision': 1,
          'input_hash': 'a' * 64,
          'coverage': 'complete',
          'connection_count': 1,
          'gap_codes': <Object>[],
        }, scope: manifest.scope),
      );
      await tester.pump();

      expect(find.text('查看重练评价'), findsOneWidget);
      expect(find.text('查看本次记录'), findsOneWidget);
      expect(find.text('回原复盘'), findsOneWidget);
      expect(find.text('再练一次'), findsOneWidget);
      expect(find.text('回到练习'), findsOneWidget);
    },
  );

  testWidgets(
    'cancelling adopted rehearsal preparation before opening cancels child reservation cleanly',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      final childData = childJson();
      (childData['configuration'] as Map<String, dynamic>)['provider'] = {
        ..._qwenProvider,
      };
      final targetJson = rehearsalTargetJson();
      final launch = RehearsalSessionLaunch(
        accountId: accountId,
        preparation: PracticePreparation.fromJson(childData),
        target: RehearsalTarget.fromJson(
          targetJson,
          accountId: accountId,
          sourceSessionId: practiceId,
          itemId: targetJson['item_id'] as String,
        ),
      );

      await h.openCallScreen(rehearsal: launch);
      final rehearsalController = h.controller;
      await tester.tap(find.text('取消这次尝试'));
      await tester.pumpAndSettle();

      expect(rehearsalController.releaseStatus, MediaReleaseStatus.released);
      expect(
        h.requests.last.url.path,
        '/v1/practice-sessions/$childId/cancel-preparation',
      );
    },
  );

  testWidgets(
    'coordinator rejects already-started preparation without cancelling server state',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      final sub = h.container.listen(practiceMediaProvider, (_, _) {});
      addTearDown(sub.close);
      final startedData = {
        ...childJson(status: 'connecting'),
        'connection_epoch': 1,
      };
      (startedData['configuration'] as Map<String, dynamic>)['provider'] = {
        ..._qwenProvider,
      };
      final started = PracticePreparation.fromJson(startedData);

      await h.controller.begin(preparation: started);
      await tester.pump();

      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'preparation_state_changed');
      expect(h.controller.releaseStatus, MediaReleaseStatus.notNeeded);
      expect(h.requests, isEmpty);
    },
  );

  testWidgets(
    'in-call slow pace requests once, updates UI after server confirmation, and leaves account preference untouched',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();

      expect(find.text('说慢一点'), findsOneWidget);
      expect(h.controller.speechPace, SessionSpeechPace.normal);
      await tester.tap(find.text('说慢一点'));
      await tester.pump();
      expect(h.session!.slowPaceRequests, 1);
      expect(h.controller.speechPace, SessionSpeechPace.slowing);
      expect(find.text('正在放慢语速…'), findsOneWidget);
      expect(h.controller.requestSlowPace(), isFalse);

      h.session!.emitPaceUpdated();
      await tester.pump();
      expect(h.controller.speechPace, SessionSpeechPace.slow);
      expect(find.text('本场已放慢语速'), findsOneWidget);
      expect(h.session!.holds, 0);
      expect(
        h.requests.where((r) => r.url.path.contains('/preferences')),
        isEmpty,
      );
      expect(
        h.container
            .read(accountControllerProvider)
            .session!
            .preferences
            .speechPace,
        'normal',
      );
    },
  );

  testWidgets(
    'session started with slow pace shows slow status immediately and unsolicited pace_updated fails closed',
    (tester) async {
      final slow = _WebSocketCallHarness(tester)..initialSpeechPace = 'slow';
      addTearDown(slow.dispose);
      await slow.activateCall();
      expect(slow.controller.speechPace, SessionSpeechPace.slow);
      expect(find.text('本场已放慢语速'), findsOneWidget);
      expect(find.text('说慢一点'), findsNothing);
      expect(slow.controller.requestSlowPace(), isFalse);
      expect(slow.session!.slowPaceRequests, 0);
      await slow.dispose();

      final unsolicited = _WebSocketCallHarness(tester);
      addTearDown(unsolicited.dispose);
      await unsolicited.activateCall();
      unsolicited.session!.emitPaceUpdated();
      await tester.pump();
      expect(unsolicited.controller.phase, PracticeMediaPhase.localClosed);
      expect(unsolicited.controller.errorCode, 'invalid_event');
      expect(unsolicited.session!.stops, 1);
    },
  );

  testWidgets(
    'WebSocket playback events drive thinking/speaking UI and explicit takeover respects mute before quarantining',
    (tester) async {
      final h = _WebSocketCallHarness(tester);
      addTearDown(h.dispose);
      await h.activateCall();

      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e1',
        'item_id': 'u1',
      });
      await tester.pump();
      expect(find.text('在听，请继续'), findsOneWidget);

      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e2',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e3',
        'item_id': 'u1',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e4',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 'Can I jump in?',
      });
      h.session!.emitProvider({
        'type': 'response.created',
        'event_id': 'e5',
        'response': {'id': 'r1'},
      });
      h.session!.emitPlayback('waiting');
      await tester.pump();
      expect(find.text('正在想怎么回应'), findsOneWidget);
      expect(find.text('我来说'), findsOneWidget);

      h.session!.emitProvider({
        'type': 'response.output_item.added',
        'event_id': 'e6',
        'response_id': 'r1',
        'output_index': 0,
        'item': {'id': 'a1', 'type': 'message', 'role': 'assistant'},
      });
      h.session!.emitPlayback('playing');
      await tester.pump();
      expect(find.text('正在说'), findsOneWidget);

      // Muting keeps AI speaking and disables takeover without unmuting.
      await tester.tap(find.text('静音麦克风'));
      await tester.pump();
      expect(find.text('正在说'), findsOneWidget);
      expect(find.text('我来说（先开启麦克风）'), findsOneWidget);
      expect(h.controller.requestTurnTakeover(), isFalse);
      expect(h.session!.interrupts, 0);

      await tester.tap(find.text('打开麦克风'));
      await tester.pump();
      expect(find.text('我来说'), findsOneWidget);

      await tester.tap(find.text('我来说'));
      await tester.pump();
      expect(h.session!.interrupts, 1);
      expect(find.text('我来说'), findsNothing);

      h.session!.emitQuarantine('r1');
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_started',
        'event_id': 'e7',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.speech_stopped',
        'event_id': 'e8',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'input_audio_buffer.committed',
        'event_id': 'e9',
        'item_id': 'u2',
      });
      h.session!.emitProvider({
        'type': 'conversation.item.input_audio_transcription.completed',
        'event_id': 'e10',
        'item_id': 'u2',
        'content_index': 0,
        'transcript': 'Here is my point.',
      });
      h.session!.emitProvider({
        'type': 'response.done',
        'event_id': 'e11',
        'response': {'id': 'r1', 'status': 'cancelled'},
      });
      await tester.pump();
      expect(find.text('对话已中断，暂时无法继续'), findsOneWidget);
      expect(find.text('Here is my point.'), findsOneWidget);
      expect(
        h.observations.events.map((e) => e['code']),
        containsAll(['playback_waiting', 'playback_playing']),
      );
    },
  );
}
