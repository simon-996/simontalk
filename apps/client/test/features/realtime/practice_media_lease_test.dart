import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

  testWidgets(
    'configuring and active leases renew without treating them as preparations',
    (tester) async {
      setup(tester);
      await h.configured();
      await tester.pump(const Duration(seconds: 15));
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(h.controller.connection!.status.name, 'configuring');
      await tester.pump(const Duration(seconds: 15));
      expect(
        h.requests.where((r) => r.url.path.endsWith('/renew-lease')).length,
        2,
      );
      await h.controller.stop();
    },
  );

  testWidgets('in-flight renewal never overlaps or postpones old deadline', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    final pending = Completer<http.Response>();
    h.handler = (r) => r.url.path.endsWith('/renew-lease')
        ? pending.future
        : h.normalResponse(r);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 29));
    expect(h.controller.phase, PracticeMediaPhase.active);
    expect(
      h.requests.where((r) => r.url.path.endsWith('/renew-lease')).length,
      1,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.transport.stops, 1);
    pending.complete(
      response(
        connectionJson(
          instance: h.instance,
          second: 44,
          status: 'configuring',
          termination: 'unknown',
        ),
      ),
    );
    await tester.pump();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(
      h.requests.where((r) => r.url.path.endsWith('/cancel-preparation')),
      isEmpty,
    );
  });

  testWidgets(
    'delayed event loop cannot accept renewal beyond original cutoff',
    (tester) async {
      setup(tester);
      h.manualElapsed = Duration.zero;
      await h.configured();
      final pending = Completer<http.Response>();
      h.handler = (r) => r.url.path.endsWith('/renew-lease')
          ? pending.future
          : h.normalResponse(r);
      h.manualElapsed = const Duration(seconds: 15);
      await tester.pump(const Duration(seconds: 15));
      h.manualElapsed = const Duration(seconds: 46);
      pending.complete(
        response(
          connectionJson(
            instance: h.instance,
            second: 15,
            status: 'configuring',
            termination: 'unknown',
          ),
        ),
      );
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'local_lease_expired');
    },
  );

  testWidgets('unknown lease response closes media immediately', (
    tester,
  ) async {
    setup(tester);
    await h.configured();
    h.handler = (r) async => response(
      connectionJson(
        instance: h.instance,
        second: 15,
        status: 'unknown',
        termination: 'unknown',
      ),
    );
    await tester.pump(const Duration(seconds: 15));
    expect(h.transport.stops, 1);
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
  });

  testWidgets(
    'renewal network failure closes and never automatically replays',
    (tester) async {
      setup(tester);
      await h.configured();
      h.handler = (_) async =>
          throw http.ClientException('offline-private-details');
      await tester.pump(const Duration(seconds: 15));
      expect(h.controller.errorCode, 'network_error');
      expect(h.transport.stops, 1);
      await tester.pump(const Duration(minutes: 2));
      expect(h.requests.length, 3);
    },
  );

  testWidgets(
    'configuration including pending activation has a total deadline',
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
      expect(h.transport.activations, ['channel-0']);
      await tester.pump(const Duration(seconds: 20));
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'configuration_timeout');
    },
  );

  testWidgets(
    'transport setup has a total deadline despite successful renewals',
    (tester) async {
      setup(tester);
      await h.connecting();
      for (var index = 0; index < 4; index++) {
        await tester.pump(const Duration(seconds: 15));
      }
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'connection_timeout');
    },
  );

  testWidgets('late activation cannot outrun a delayed configuration timer', (
    tester,
  ) async {
    setup(tester);
    h.manualElapsed = Duration.zero;
    h.transport.activation = Completer<void>();
    await h.connecting();
    await h.transport.signaller.exchangeOffer('v=0\r\n');
    h.transport.observe(const RealtimeObservation('channel_open', 'channel-0'));
    h.transport.connected.complete();
    await tester.pump();
    h.transport.receive(
      const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
    );
    await tester.pump();
    h.manualElapsed = const Duration(seconds: 21);
    h.transport.activation!.complete();
    await tester.pump();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.errorCode, 'configuration_timeout');
  });

  testWidgets('late transport connection cannot outrun a delayed setup timer', (
    tester,
  ) async {
    setup(tester);
    h.manualElapsed = Duration.zero;
    await h.connecting();
    await h.transport.signaller.exchangeOffer('v=0\r\n');
    for (final second in [15, 30, 45]) {
      h.manualElapsed = Duration(seconds: second);
      await tester.pump(const Duration(seconds: 15));
    }
    h.manualElapsed = const Duration(seconds: 61);
    h.transport.connected.complete();
    await tester.pump();
    expect(h.controller.phase, PracticeMediaPhase.localClosed);
    expect(h.controller.errorCode, 'connection_timeout');
  });
}
