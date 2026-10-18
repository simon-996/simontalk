import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/api_realtime_signaller.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';
import 'api_realtime_signaller_test.dart'
    show TrackedClient, offerSdp, answerSdp;
import 'media_fixtures.dart';

void main() {
  late MediaHarness h;
  late TrackedClient owned;
  late List<http.Request> offerRequests;
  late Future<http.Response> Function(http.Request) answer;

  void setup(WidgetTester tester) {
    h = MediaHarness(tester);
    h.controller.dispose();
    offerRequests = [];
    answer = (_) async => response({
      'session_id': practiceId,
      'connection_id': connectionId,
      'client_instance_id': h.instance,
      'epoch': 1,
      'answer': answerSdp,
    });
    owned = TrackedClient((request) async {
      if (request.url.path.endsWith('/csrf')) {
        fail('The signaller must reuse the account family CSRF token.');
      }
      offerRequests.add(request);
      return answer(request);
    });
    h.controller = PracticeMediaController(
      repository: PracticeRepository(h.api, accountId: accountId),
      elapsed: () => tester.binding.clock.now().difference(h.origin),
      protocolFactory: (configuration, callbacks) =>
          h.protocol = TestProtocol(callbacks),
      transportFactory: () => h.transport,
      signallerFactory: (connection, instance) => ApiRealtimeSignaller(
        accountApi: h.api,
        accountId: accountId,
        clientInstanceId: instance,
        connection: connection,
        client: owned,
      ),
    );
    h.transport.onStart = () async {
      await h.transport.signaller.exchangeOffer(offerSdp);
      h.transport.observe(
        const RealtimeObservation('channel_open', 'channel-0'),
      );
      h.transport.receive(
        const RealtimeTransportEvent('{"type":"test.configured"}', 'channel-0'),
      );
      h.transport.connected.complete();
    };
    addTearDown(h.dispose);
  }

  testWidgets(
    'repository and real HTTP signaller compose with configuration and renewal',
    (tester) async {
      setup(tester);
      unawaited(h.controller.begin());
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(offerRequests.length, 1);
      final request = offerRequests.single;
      expect(request.headers['X-Account-ID'], accountId);
      expect(request.headers['X-CSRF-Token'], 'test-csrf');
      expect(jsonDecode(request.body), {
        'client_instance_id': h.instance,
        'epoch': 1,
        'offer': offerSdp,
      });
      await tester.pump(const Duration(seconds: 15));
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(h.controller.connection!.status.name, 'configuring');
      await h.controller.stop();
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
      expect(owned.closes, 1);
      expect(offerRequests.length, 1);
      expect(
        await h.api.request('GET', '/v1/me', accountId: accountId),
        isNotEmpty,
      );
      expect(
        h.requests.where((r) => r.url.path.endsWith('/cancel-preparation')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'stop during HTTP exchange settles begin and discards a late answer',
    (tester) async {
      setup(tester);
      final pending = Completer<http.Response>();
      final normal = answer;
      answer = (_) => pending.future;
      var finished = false;
      unawaited(h.controller.begin().then((_) => finished = true));
      await tester.pump();
      expect(offerRequests.length, 1);
      expect(finished, isFalse);
      await h.controller.stop();
      await tester.pump();
      expect(finished, isTrue);
      expect(owned.closes, 1);
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
      pending.complete(await normal(offerRequests.single));
      await tester.pump();
      expect(h.transport.activations, isEmpty);
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(
        await h.api.request('GET', '/v1/me', accountId: accountId),
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'HTTP offer failure remains unknown and never starts another attempt',
    (tester) async {
      setup(tester);
      answer = (_) async => response({'code': 'signalling_timeout'}, 504);
      await h.controller.begin();
      await tester.pump();
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.errorCode, 'signalling_timeout');
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
      expect(h.transport.stops, 1);
      await h.controller.begin();
      await tester.pump(const Duration(minutes: 2));
      expect(offerRequests.length, 1);
      expect(h.requests.length, 2);
    },
  );
}
