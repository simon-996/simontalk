import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/realtime/connection_observation_journal.dart';

import '../practice/practice_fixtures.dart';
import 'api_realtime_signaller_test.dart' show TrackedClient;

Map<String, dynamic> acknowledgement(http.Request request) {
  final data = jsonDecode(request.body) as Map<String, dynamic>;
  final events = data['events'] as List;
  return {
    'source': 'client_observed',
    'connection_id': connectionId,
    'client_instance_id': clientId,
    'epoch': 1,
    'acknowledged_event_ids': events.map((e) => e['event_id']).toList(),
    'last_sequence': events.last['sequence'],
    'total_events': events.last['sequence'],
  };
}

void main() {
  late ApiClient account;
  late TrackedClient shared;
  late ConnectionObservationJournal journal;
  late List<TrackedClient> clients;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  Future<http.Response> Function()? csrf;
  void Function()? onClientCreate;

  void setup({Duration Function()? elapsed}) {
    shared = TrackedClient((_) async => response({}));
    account = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: shared,
    )..expectedAccountId = accountId;
    clients = [];
    requests = [];
    csrf = null;
    onClientCreate = null;
    handler = (request) async => response(acknowledgement(request));
    journal = ConnectionObservationJournal(
      accountApi: account,
      accountId: accountId,
      connection: ConnectionReservation.fromJson(connectionJson()),
      clientInstanceId: clientId,
      elapsed: elapsed,
      clientFactory: () {
        final client = TrackedClient((request) async {
          if (request.url.path.endsWith('/csrf')) {
            return csrf?.call() ?? response({'csrf_token': 'owned-csrf'});
          }
          requests.add(request);
          return handler(request);
        });
        clients.add(client);
        onClientCreate?.call();
        return client;
      },
    );
  }

  tearDown(() {
    journal.abort();
    account.close();
  });

  test(
    'construction is lazy and acknowledgement clears only recorded fixed facts',
    () async {
      setup();
      expect(clients, isEmpty);
      for (final code in [
        'transport_connected',
        'configuration_confirmed',
        'microphone_active',
      ]) {
        journal.record(code);
      }
      await journal.retryPending();
      expect(requests.length, 1);
      final request = requests.single;
      expect(request.headers['X-Account-ID'], accountId);
      expect(request.headers['X-CSRF-Token'], 'owned-csrf');
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'client_instance_id', 'epoch', 'events'});
      final events = body['events'] as List;
      expect(events.map((e) => e['sequence']), [1, 2, 3]);
      expect(events.map((e) => e['event_id']).toSet().length, 3);
      expect(journal.pendingCount, 0);
      expect(journal.errorCode, isNull);
      expect(clients.single.closes, 1);
      expect(shared.closes, 0);
      expect(
        await account.request('GET', '/v1/me', accountId: accountId),
        isEmpty,
      );
    },
  );

  test('batches are serial while events added in flight stay queued', () async {
    setup();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    journal.record('muted');
    await Future<void>.delayed(Duration.zero);
    for (var index = 0; index < 19; index++) {
      journal.record('unmuted');
    }
    expect(requests.length, 1);
    expect(journal.pendingCount, 20);
    handler = (request) async => response(acknowledgement(request));
    pending.complete(response(acknowledgement(requests.single)));
    await journal.retryPending();
    expect(requests.map((r) => (jsonDecode(r.body)['events'] as List).length), [
      1,
      16,
      3,
    ]);
    expect(journal.pendingCount, 0);
    expect(clients.every((c) => c.closes == 1), isTrue);
  });

  test('failed batch pauses and explicit retry preserves original IDs and sequences', () async {
    setup();
    handler = (_) async => response({'code': 'service_unavailable'}, 503);
    journal.record('transport_connected');
    await journal.retryPending();
    final original =
        (jsonDecode(requests.single.body)['events'] as List).single;
    expect(journal.pendingCount, 1);
    journal.record('microphone_active');
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 1);
    handler = (request) async => response(acknowledgement(request));
    await journal.retryPending();
    expect((jsonDecode(requests.last.body)['events'] as List).first, original);
    expect(journal.pendingCount, 0);
  });

  test('queue is bounded, in-flight events survive, and close can replace pending tail', () async {
    setup();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    journal.record('muted');
    await Future<void>.delayed(Duration.zero);
    for (var index = 0; index < 65; index++) {
      journal.record('unmuted');
    }
    journal.record('local_closed', reason: 'stopped');
    journal.finish();
    expect(journal.pendingCount, 64);
    expect(journal.droppedCount, 3);
    handler = (request) async => response(acknowledgement(request));
    pending.complete(response(acknowledgement(requests.first)));
    await journal.retryPending();
    final all = requests
        .expand((r) => jsonDecode(r.body)['events'] as List)
        .toList();
    expect(all.first['sequence'], 1);
    expect(all.last['code'], 'local_closed');
    expect(all.last['reason'], 'user_stop');
    expect(journal.pendingCount, 0);
  });

  test('abort settles the active drain, closes only its client, and ignores a late ack', () async {
    setup();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    journal.record('muted');
    final drain = journal.retryPending();
    await Future<void>.delayed(Duration.zero);
    journal.abort();
    await drain;
    expect(journal.pendingCount, 0);
    expect(clients.single.closes, 1);
    expect(shared.closes, 0);
    pending.complete(response(acknowledgement(requests.single)));
    await Future<void>.delayed(Duration.zero);
    expect(journal.pendingCount, 0);
  });

  test(
    'finish records no further events and completes one best-effort drain',
    () async {
      setup();
      journal.record('local_closed', reason: 'background');
      journal.finish();
      journal.record('microphone_active');
      await journal.retryPending();
      expect((jsonDecode(requests.single.body)['events'] as List).length, 1);
      expect(clients.single.closes, 1);
    },
  );

  test('account change before dispatch prevents every owned request', () async {
    setup();
    journal.record('muted');
    account.expectedAccountId = requestKey;
    await journal.retryPending();
    expect(requests, isEmpty);
    expect(clients, isEmpty);
    expect(journal.pendingCount, 0);
    expect(journal.errorCode, 'account_changed');
  });

  test(
    'account switch during CSRF wait cannot post facts under new cookies',
    () async {
      setup();
      final pending = Completer<http.Response>();
      csrf = () => pending.future;
      journal.record('muted');
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      account.expectedAccountId = requestKey;
      pending.complete(response({'csrf_token': 'new-account'}));
      await drain;
      expect(requests, isEmpty);
      expect(journal.pendingCount, 0);
      expect(journal.errorCode, 'account_changed');
      expect(clients.single.closes, 1);
    },
  );

  test(
    'a late ack after account change cannot confirm the old queue',
    () async {
      setup();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record('muted');
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      account.expectedAccountId = requestKey;
      pending.complete(response(acknowledgement(requests.single)));
      await drain;
      expect(journal.errorCode, 'account_changed');
      expect(journal.pendingCount, 0);
      expect(shared.closes, 0);
    },
  );

  testWidgets(
    'eight-second total deadline includes CSRF and releases the owned client',
    (tester) async {
      setup();
      final pending = Completer<http.Response>();
      csrf = () => pending.future;
      journal.record('muted');
      final drain = journal.retryPending();
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      await drain;
      expect(journal.errorCode, 'observation_timeout');
      expect(journal.pendingCount, 1);
      expect(clients.single.closes, 1);
      expect(shared.closes, 0);
      pending.complete(response({'csrf_token': 'late'}));
      await tester.pump();
      expect(requests, isEmpty);
    },
  );

  test(
    'bad response identity or acknowledgement cannot remove queued events',
    () async {
      for (final change in [
        {'connection_id': requestKey},
        {'client_instance_id': requestKey},
        {'epoch': 2},
        {'source': 'server_confirmed'},
        {'acknowledged_event_ids': <String>[]},
        {'last_sequence': 0},
        {'total_events': 0},
      ]) {
        setup();
        handler = (request) async =>
            response({...acknowledgement(request), ...change});
        journal.record('muted');
        await journal.retryPending();
        expect(journal.errorCode, 'invalid_response');
        expect(journal.pendingCount, 1);
        journal.abort();
        account.close();
      }
    },
  );

  test('raw reasons, unsupported events and SDK exception text never enter records or errors', () async {
    setup();
    journal.record('private-model-json');
    journal.record('local_closed', reason: 'private-provider-url');
    handler = (_) async => throw StateError('private-secret-sdk-error');
    await journal.retryPending();
    expect(journal.errorCode, 'observation_failed');
    expect(requests.single.body.contains('private'), isFalse);
    expect(
      (jsonDecode(requests.single.body)['events'] as List).single['reason'],
      'other',
    );
  });

  test(
    'closing the source account invalidates queued observation ownership',
    () async {
      setup();
      journal.record('muted');
      account.close();
      await journal.retryPending();
      expect(journal.errorCode, 'account_changed');
      expect(requests, isEmpty);
    },
  );

  test(
    'abort inside client creation closes returned client without sending',
    () async {
      setup();
      onClientCreate = journal.abort;
      journal.record('muted');
      await journal.retryPending();
      expect(requests, isEmpty);
      expect(clients.single.closes, 1);
    },
  );

  test(
    'late acknowledgement cannot outrun a delayed total timeout timer',
    () async {
      var elapsed = Duration.zero;
      setup(elapsed: () => elapsed);
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record('muted');
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      elapsed = const Duration(seconds: 9);
      pending.complete(response(acknowledgement(requests.single)));
      await drain;
      expect(journal.errorCode, 'observation_timeout');
      expect(journal.pendingCount, 1);
    },
  );
}
