import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';
import 'media_fixtures.dart';

void main() {
  late MediaHarness h;
  void setup(WidgetTester tester) {
    h = MediaHarness(tester);
    addTearDown(h.dispose);
  }

  testWidgets('default 503 never constructs media or retries', (tester) async {
    setup(tester);
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await h.controller.begin();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.errorCode, 'realtime_unavailable');
    expect(h.transportCreates + h.signallerCreates + h.protocolCreates, 0);
    await tester.pump(const Duration(minutes: 2));
    expect(h.requests.length, 1);
  });

  testWidgets(
    'duplicate begin shares one attempt and waits for configuration',
    (tester) async {
      setup(tester);
      var completed = false;
      unawaited(h.controller.begin().then((_) => completed = true));
      unawaited(h.controller.begin());
      await tester.pump();
      expect(h.requests.length, 2);
      expect(h.transport.starts, 1);
      await h.transport.signaller.exchangeOffer('v=0\r\n');
      h.transport.observe(
        const RealtimeObservation('channel_open', 'channel-0'),
      );
      h.transport.connected.complete();
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.configuring);
      expect(h.transport.activations, isEmpty);
      expect(completed, isFalse);
      h.transport.receive(
        const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
      );
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(completed, isTrue);
      expect(h.transport.activations, ['channel-0']);
      expect(
        h.requests
            .take(2)
            .map((r) => r.headers['Idempotency-Key'])
            .toSet()
            .length,
        2,
      );
      await h.controller.stop();
    },
  );

  testWidgets(
    'events arriving before start resolves wait behind channel setup',
    (tester) async {
      setup(tester);
      await h.connecting();
      await h.transport.signaller.exchangeOffer('v=0\r\n');
      h.transport.observe(
        const RealtimeObservation('channel_open', 'channel-0'),
      );
      h.transport.receive(
        const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
      );
      expect(h.protocol!.channels, isEmpty);
      expect(h.transport.activations, isEmpty);
      h.transport.connected.complete();
      await tester.pump();
      expect(h.protocol!.channels, ['channel-0']);
      expect(h.transport.sent.length, 1);
      expect(h.controller.phase, PracticeMediaPhase.active);
      await h.controller.stop();
    },
  );

  testWidgets('stop before offer cancels connection then practice', (
    tester,
  ) async {
    setup(tester);
    await h.connecting();
    await h.controller.stop();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.releaseStatus, MediaReleaseStatus.released);
    expect(h.transport.stops, 1);
    expect(h.signaller.cancels, 1);
    expect(h.protocol!.disposes, 1);
    expect(
      h.requests[h.requests.length - 2].url.path,
      contains('/connections/'),
    );
    expect(
      h.requests.last.url.path,
      '/v1/practice-sessions/$practiceId/cancel-preparation',
    );
  });

  testWidgets('stop after offer never sends preparation cancellation', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    await h.controller.stop();
    expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
    expect(h.requests.length, 2);
    h.protocol!.callbacks.confirmConfigured('channel-0');
    h.transport.receive(
      const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
    );
    await tester.pump();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.transport.activations.length, 1);
    await expectLater(
      h.transport.signaller.exchangeOffer('v=0\r\n'),
      throwsA(isA<RealtimeFailure>()),
    );
    expect(h.signaller.offers, 1);
  });

  testWidgets('stop resolves begin immediately while activate is pending', (
    tester,
  ) async {
    setup(tester);
    h.transport.activation = Completer<void>();
    var finished = false;
    unawaited(h.controller.begin().then((_) => finished = true));
    await tester.pump();
    await h.transport.signaller.exchangeOffer('v=0\r\n');
    h.transport.observe(const RealtimeObservation('channel_open', 'channel-0'));
    h.transport.connected.complete();
    await tester.pump();
    h.transport.receive(
      const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
    );
    await tester.pump();
    expect(finished, isFalse);
    await h.controller.stop();
    await tester.pump();
    expect(finished, isTrue);
    h.transport.activation!.complete();
    await tester.pump();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
  });

  testWidgets('late practice create after stop only cancels practice', (
    tester,
  ) async {
    setup(tester);
    final pending = Completer<http.Response>();
    h.handler = (r) => r.url.path == '/v1/practice-sessions'
        ? pending.future
        : h.normalResponse(r);
    var finished = false;
    unawaited(h.controller.begin().then((_) => finished = true));
    await tester.pump();
    await h.controller.stop();
    await tester.pump();
    expect(finished, isTrue);
    pending.complete(response(practiceJson(), 201));
    await tester.pump();
    expect(h.controller.releaseStatus, MediaReleaseStatus.released);
    expect(h.requests.length, 2);
    expect(h.requests.any((r) => r.url.path.endsWith('/connections')), isFalse);
    expect(h.transportCreates, 0);
  });

  testWidgets(
    'late connection create after dispose safely cancels registration',
    (tester) async {
      setup(tester);
      final pending = Completer<http.Response>();
      h.handler = (r) => r.url.path.endsWith('/connections')
          ? pending.future
          : h.normalResponse(r);
      unawaited(h.controller.begin());
      await tester.pump();
      h.controller.dispose();
      h.instance = h.controller.clientInstanceId;
      pending.complete(
        response(connectionJson(instance: h.controller.clientInstanceId), 201),
      );
      await tester.pump();
      expect(h.controller.releaseStatus, MediaReleaseStatus.released);
      expect(
        h.requests
            .where((r) => r.url.path.endsWith('/cancel-preparation'))
            .length,
        2,
      );
      expect(h.transportCreates, 0);
    },
  );

  testWidgets(
    'background releases active media and foreground does not restart',
    (tester) async {
      setup(tester);
      await h.configured();
      h.controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(h.transport.stops, 1);
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(minutes: 2));
      await h.controller.begin();
      expect(h.transport.starts, 1);
      expect(h.requests.length, 2);
    },
  );

  testWidgets(
    'account switch discards callback and sends no cleanup as new user',
    (tester) async {
      setup(tester);
      await h.configured();
      h.api.expectedAccountId = 'other-account';
      h.protocol!.callbacks.send('{"type":"stale"}', 'channel-0');
      expect(h.transport.stops, 1);
      expect(h.transport.sent.length, 1);
      expect(h.controller.errorCode, 'account_changed');
      expect(h.requests.length, 2);
    },
  );

  testWidgets('closed source API cannot keep media alive', (tester) async {
    setup(tester);
    await h.configured();
    h.api.close();
    h.controller.setMuted(true);
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.transport.stops, 1);
  });

  testWidgets(
    'transport local_closed stops without protocol or callback revival',
    (tester) async {
      setup(tester);
      await h.configured();
      h.transport.observe(
        const RealtimeObservation('local_closed', 'connection_lost'),
      );
      expect(h.controller.errorCode, 'connection_lost');
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
      h.transport.observe(const RealtimeObservation('playback_playing', ''));
      expect(h.controller.playback, MediaPlayback.idle);
    },
  );

  testWidgets('playback observations and user mute remain independent', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    h.controller.setMuted(true);
    h.transport.observe(const RealtimeObservation('playback_playing', ''));
    expect(h.controller.playback, MediaPlayback.playing);
    expect(h.controller.muted, isTrue);
    expect(h.transport.mutes.last, isTrue);
    h.transport.observe(const RealtimeObservation('playback_blocked', ''));
    await h.controller.resumePlayback();
    expect(h.transport.resumes, 1);
    expect(h.controller.phase, PracticeMediaPhase.active);
    await h.controller.stop();
  });

  testWidgets(
    'a delayed resume failure cannot overwrite a playing observation',
    (tester) async {
      setup(tester);
      await h.configured();
      h.transport.playbackResume = Completer<void>();
      final resume = h.controller.resumePlayback();
      h.transport.observe(const RealtimeObservation('playback_playing', ''));
      h.transport.playbackResume!.completeError(
        const RealtimeFailure('playback_waiting'),
      );
      await resume;
      expect(h.controller.playback, MediaPlayback.playing);
      expect(h.controller.phase, PracticeMediaPhase.active);
      await h.controller.stop();
    },
  );

  testWidgets('an earlier resume cannot overwrite a later resume result', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    final first = Completer<void>();
    final second = Completer<void>();
    h.transport.playbackResume = first;
    final firstResume = h.controller.resumePlayback();
    h.transport.playbackResume = second;
    final secondResume = h.controller.resumePlayback();
    second.completeError(const RealtimeFailure('playback_blocked'));
    await secondResume;
    expect(h.controller.playback, MediaPlayback.blocked);
    first.completeError(const RealtimeFailure('playback_waiting'));
    await firstResume;
    expect(h.controller.playback, MediaPlayback.blocked);
    await h.controller.stop();
  });

  testWidgets('a delayed fatal resume failure still closes the connection', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    h.transport.playbackResume = Completer<void>();
    final resume = h.controller.resumePlayback();
    h.transport.observe(const RealtimeObservation('playback_playing', ''));
    h.transport.playbackResume!.completeError(
      const RealtimeFailure('playback_failed'),
    );
    await resume;
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.errorCode, 'playback_failed');
  });

  testWidgets('early events are bounded before transport readiness', (
    tester,
  ) async {
    setup(tester);
    await h.connecting();
    h.transport.observe(const RealtimeObservation('channel_open', 'channel-0'));
    for (var index = 0; index < 33; index++) {
      h.transport.receive(
        const RealtimeTransportEvent('{"type":"test.event"}', 'channel-0'),
      );
    }
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.errorCode, 'event_buffer_full');
    expect(h.protocol!.events, isEmpty);
  });

  testWidgets('configuration confirmation cannot select an unknown channel', (
    tester,
  ) async {
    setup(tester);
    await h.connecting();
    await h.transport.signaller.exchangeOffer('v=0\r\n');
    h.transport.connected.complete();
    await tester.pump();
    h.protocol!.callbacks.confirmConfigured('other-channel');
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.transport.activations, isEmpty);
  });

  testWidgets('reentrant listener stop before create prevents all requests', (
    tester,
  ) async {
    setup(tester);
    h.controller.addListener(() {
      if (h.controller.phase == PracticeMediaPhase.preparing) {
        unawaited(h.controller.stop());
      }
    });
    await h.controller.begin();
    expect(h.requests, isEmpty);
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
  });

  for (final stage in ['protocol', 'signaller', 'transport']) {
    testWidgets(
      'stop inside $stage factory still releases its returned resource',
      (tester) async {
        setup(tester);
        h.controller.dispose();
        h.controller = PracticeMediaController(
          repository: PracticeRepository(h.api, accountId: accountId),
          protocolFactory: (configuration, callbacks) {
            if (stage == 'protocol') callbacks.fail('protocol_failed');
            return h.protocol = TestProtocol(callbacks);
          },
          signallerFactory: (connection, instance) {
            if (stage == 'signaller') unawaited(h.controller.stop());
            return h.signaller;
          },
          transportFactory: () {
            if (stage == 'transport') unawaited(h.controller.stop());
            return h.transport;
          },
        );
        await h.controller.begin();
        await tester.pump();
        expect(h.protocol!.disposes, 1);
        if (stage != 'protocol') expect(h.signaller.cancels, 1);
        if (stage == 'transport') expect(h.transport.stops, 1);
        expect(h.transport.starts, 0);
      },
    );
  }
}
