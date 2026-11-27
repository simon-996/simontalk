import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/final_transcript_journal.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/browser_media_session.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/connection_observation_journal.dart';
import 'package:simontalk_client/features/realtime/realtime_session_protocol.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';

class TestObservationJournal implements RealtimeObservationJournal {
  final events = <Map<String, String>>[];
  int finishes = 0;
  int aborts = 0;
  void Function(String)? onRecord;
  @override
  int get pendingCount => 0;
  @override
  int get droppedCount => 0;
  @override
  String? get errorCode => null;
  @override
  void record(String code, {String? reason}) {
    onRecord?.call(code);
    events.add({'code': code, 'reason': ?reason});
  }

  @override
  Future<void> retryPending() async {}
  @override
  void finish() => finishes++;
  @override
  void abort() => aborts++;
}

class TestSignaller implements RealtimeSignaller {
  int cancels = 0;
  int offers = 0;
  @override
  Future<String> exchangeOffer(String offer) async {
    offers++;
    return 'v=0\r\n';
  }

  @override
  void cancel() => cancels++;
}

class TestTransport implements RealtimeTransport {
  final connected = Completer<void>();
  Completer<void>? activation;
  Completer<void>? playbackResume;
  late RealtimeSignaller signaller;
  late void Function(RealtimeObservation) observe;
  late void Function(RealtimeTransportEvent) receive;
  final sent = <String>[];
  final activations = <String>[];
  final mutes = <bool>[];
  int starts = 0;
  int stops = 0;
  int resumes = 0;
  int drains = 0;
  int holds = 0;
  Object? holdError;
  void Function()? onHold;
  void Function()? onDrain;
  Future<void> Function()? onStart;
  @override
  Future<void> start({
    required RealtimeSignaller signaller,
    required void Function(RealtimeObservation) onObservation,
    required void Function(RealtimeTransportEvent) onEvent,
  }) async {
    starts++;
    this.signaller = signaller;
    observe = onObservation;
    receive = onEvent;
    await onStart?.call();
    await connected.future;
  }

  @override
  Future<void> activate(String channelId) async {
    activations.add(channelId);
    await activation?.future;
  }

  @override
  void send(String json, String channelId) => sent.add('$channelId:$json');
  @override
  void setMuted(bool muted) => mutes.add(muted);
  @override
  Future<void> resumePlayback() async {
    resumes++;
    await playbackResume?.future;
  }

  @override
  void holdPlayback() {
    holds++;
    onHold?.call();
    if (holdError case final error?) throw error;
  }

  @override
  Future<void> releasePlayback() async {}

  @override
  void beginDrain() {
    drains++;
    onDrain?.call();
  }

  @override
  void stop() => stops++;
}

class TestProtocol implements RealtimeSessionProtocol {
  TestProtocol(this.callbacks);
  final RealtimeProtocolCallbacks callbacks;
  final channels = <String>[];
  final events = <String>[];
  int disposes = 0;
  int drains = 0;
  void Function()? onDrain;
  @override
  void beginDrain() {
    drains++;
    onDrain?.call();
  }

  @override
  void channelOpened(String channelId) {
    channels.add(channelId);
    callbacks.send('{"type":"test.configure"}', channelId);
  }

  @override
  void receive(RealtimeTransportEvent event) {
    events.add(event.json);
    if (event.json == '{"type":"test.configured"}') {
      callbacks.confirmConfigured(event.channelId);
    }
  }

  @override
  void dispose() => disposes++;
}

class MediaHarness {
  MediaHarness(
    this.tester, {
    Duration drainTimeout = const Duration(seconds: 3),
    TranscriptJournalFactory? transcriptJournalFactory,
    RealtimeMediaSessionFactory? mediaSessionFactory,
  }) {
    origin = tester.binding.clock.now();
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
        return handler(request);
      }),
    )..expectedAccountId = accountId;
    handler = normalResponse;
    controller = PracticeMediaController(
      repository: PracticeRepository(api, accountId: accountId),
      mediaSessionFactory: mediaSessionFactory,
      drainTimeout: drainTimeout,
      transcriptJournalFactory: transcriptJournalFactory,
      elapsed: () =>
          manualElapsed ?? tester.binding.clock.now().difference(origin),
      transportFactory: () {
        transportCreates++;
        return transport;
      },
      signallerFactory: (connection, instance) {
        signallerCreates++;
        return signaller;
      },
      protocolFactory: (configuration, callbacks) {
        protocolCreates++;
        expectSync(configuration.provider.configId, 'test-v1');
        return protocol = TestProtocol(callbacks);
      },
    );
  }
  final WidgetTester tester;
  late DateTime origin;
  Duration? manualElapsed;
  late ApiClient api;
  late PracticeMediaController controller;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  final transport = TestTransport();
  final signaller = TestSignaller();
  TestProtocol? protocol;
  String instance = clientId;
  int transportCreates = 0;
  int signallerCreates = 0;
  int protocolCreates = 0;
  int get seconds => tester.binding.clock.now().difference(origin).inSeconds;

  Future<http.Response> normalResponse(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/connections')) {
      instance = jsonDecode(request.body)['client_instance_id'] as String;
      return response(connectionJson(instance: instance, second: seconds), 201);
    }
    if (path.endsWith('/renew-lease')) {
      return response(
        connectionJson(
          instance: instance,
          second: seconds,
          status: controller.signallingAttempted ? 'configuring' : 'preparing',
          termination: controller.signallingAttempted
              ? 'unknown'
              : 'not_started',
        ),
      );
    }
    if (path.contains('/connections/')) {
      return response(connectionJson(instance: instance, status: 'closed'));
    }
    return response(
      practiceJson(
        status: path.endsWith('/cancel-preparation') ? 'cancelled' : 'created',
      ),
      201,
    );
  }

  Future<void> connecting() async {
    unawaited(controller.begin());
    await tester.pump();
    expect(
      controller.phase,
      PracticeMediaPhase.connecting,
      reason:
          '${controller.errorCode}; factories=$protocolCreates/$signallerCreates/$transportCreates',
    );
  }

  Future<void> configured({bool sendOffer = true}) async {
    await connecting();
    if (sendOffer) await transport.signaller.exchangeOffer('v=0\r\n');
    transport.observe(const RealtimeObservation('channel_open', 'channel-0'));
    transport.connected.complete();
    await tester.pump();
    transport.receive(
      const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
    );
    await tester.pump();
    expect(controller.phase, PracticeMediaPhase.active);
  }

  Future<void> dispose() async {
    controller.dispose();
    if (!transport.connected.isCompleted) transport.connected.complete();
    if (transport.activation case final pending? when !pending.isCompleted) {
      pending.complete();
    }
    await tester.pump();
    api.close();
  }
}
