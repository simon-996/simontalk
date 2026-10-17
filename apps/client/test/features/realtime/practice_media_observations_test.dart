import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/realtime/connection_observation_journal.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/realtime_transport.dart';

import '../practice/practice_fixtures.dart';
import 'api_realtime_signaller_test.dart' show TrackedClient;
import 'media_fixtures.dart';

void main() {
  late MediaHarness h;
  late TestObservationJournal journal;
  void setup(WidgetTester tester, {ObservationJournalFactory? factory}) {
    h = MediaHarness(tester);
    h.controller.dispose();
    journal = TestObservationJournal();
    h.controller = PracticeMediaController(
      repository: PracticeRepository(h.api, accountId: accountId),
      elapsed: () => tester.binding.clock.now().difference(h.origin),
      observationJournalFactory:
          factory ??
          (connection, instance) {
            expectSync(connection.clientInstanceId, instance);
            return journal;
          },
      protocolFactory: (configuration, callbacks) {
        h.protocolCreates++;
        return h.protocol = TestProtocol(callbacks);
      },
      signallerFactory: (connection, instance) => h.signaller,
      transportFactory: () {
        h.transportCreates++;
        return h.transport;
      },
    );
    addTearDown(h.dispose);
  }

  testWidgets('default refusal never constructs an observation journal', (
    tester,
  ) async {
    var creates = 0;
    setup(
      tester,
      factory: (_, _) {
        creates++;
        return journal;
      },
    );
    h.handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await h.controller.begin();
    expect(creates, 0);
    expect(journal.events, isEmpty);
  });

  testWidgets(
    'configured facts and explicit mute/playback stay distinct from one local close',
    (tester) async {
      setup(tester);
      await h.configured();
      h.controller.setMuted(true);
      h.transport.observe(const RealtimeObservation('playback_blocked', ''));
      await h.controller.stop();
      await h.controller.stop();
      expect(journal.events.map((e) => e['code']), [
        'transport_connected',
        'configuration_confirmed',
        'microphone_active',
        'muted',
        'playback_blocked',
        'local_closed',
      ]);
      expect(journal.finishes, 1);
      expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
    },
  );

  testWidgets(
    'journal factory failure cannot prevent media or expose the thrown text',
    (tester) async {
      setup(
        tester,
        factory: (_, _) => throw StateError('private-sdk-credential'),
      );
      await h.configured();
      expect(h.controller.phase, PracticeMediaPhase.active);
      expect(h.controller.observationErrorCode, 'observation_unavailable');
      await h.controller.stop();
    },
  );

  testWidgets(
    'local resources are released before a failing close observation',
    (tester) async {
      setup(tester);
      await h.configured();
      journal.onRecord = (code) {
        if (code == 'local_closed') {
          expectSync(h.transport.stops, 1);
          throw StateError('private-observation-error');
        }
      };
      await h.controller.stop();
      expect(h.controller.phase, PracticeMediaPhase.localClosed);
      expect(h.controller.observationErrorCode, 'observation_unavailable');
      expect(journal.aborts, 1);
    },
  );

  testWidgets(
    'account change aborts old observations without recording under the new identity',
    (tester) async {
      setup(tester);
      await h.configured();
      final count = journal.events.length;
      h.api.expectedAccountId = requestKey;
      await h.controller.stop();
      expect(journal.aborts, 1);
      expect(journal.events.length, count);
      expect(journal.finishes, 0);
      expect(h.transport.stops, 1);
    },
  );

  testWidgets(
    'journal returned after a factory stop is aborted before any media',
    (tester) async {
      setup(
        tester,
        factory: (_, _) {
          unawaited(h.controller.stop());
          return journal;
        },
      );
      await h.controller.begin();
      await tester.pump();
      expect(journal.aborts, 1);
      expect(h.transportCreates, 0);
      expect(h.protocolCreates, 0);
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'real HTTP journal ${fail ? 'failure' : 'success'} never controls media or termination',
      (tester) async {
        late ConnectionObservationJournal real;
        final clients = <TrackedClient>[];
        final payloads = <Map<String, dynamic>>[];
        setup(
          tester,
          factory: (connection, instance) {
            return real = ConnectionObservationJournal(
              accountApi: h.api,
              accountId: accountId,
              connection: connection,
              clientInstanceId: instance,
              clientFactory: () {
                final client = TrackedClient((request) async {
                  if (request.url.path.endsWith('/csrf')) {
                    return response({'csrf_token': 'observation-csrf'});
                  }
                  final body = jsonDecode(request.body) as Map<String, dynamic>;
                  payloads.add(body);
                  expectSync(request.headers['X-Account-ID'], accountId);
                  expectSync(body['client_instance_id'], h.instance);
                  expectSync(body['epoch'], 1);
                  final events = body['events'] as List;
                  if (events.any((e) => e['code'] == 'local_closed')) {
                    expectSync(h.transport.stops, 1);
                  }
                  if (fail) {
                    return response({'code': 'service_unavailable'}, 503);
                  }
                  return response({
                    'source': 'client_observed',
                    'connection_id': connection.id,
                    'client_instance_id': instance,
                    'epoch': connection.epoch,
                    'acknowledged_event_ids': events
                        .map((e) => e['event_id'])
                        .toList(),
                    'last_sequence': events.last['sequence'],
                    'total_events': events.last['sequence'],
                  });
                });
                clients.add(client);
                return client;
              },
            );
          },
        );
        await h.configured();
        await real.retryPending();
        expect(h.controller.phase, PracticeMediaPhase.active);
        await h.controller.stop();
        await real.retryPending();
        expect(h.controller.releaseStatus, MediaReleaseStatus.unconfirmed);
        expect(clients.every((c) => c.closes == 1), isTrue);
        expect(
          payloads.every((body) => !body.containsKey('termination_status')),
          isTrue,
        );
        if (!fail) {
          expect((payloads.last['events'] as List).last['reason'], 'user_stop');
          expect(real.pendingCount, 0);
        } else {
          expect(real.pendingCount, greaterThan(0));
          expect(h.controller.observationErrorCode, 'observation_failed');
        }
        expect(
          await h.api.request('GET', '/v1/me', accountId: accountId),
          isNotEmpty,
        );
        real.abort();
      },
    );
  }
}
