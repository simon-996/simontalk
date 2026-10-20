import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/final_transcript_journal.dart';

import '../practice/practice_fixtures.dart';
import '../realtime/api_realtime_signaller_test.dart' show TrackedClient;
import 'conversation_projection_test.dart' as fixtures;

void main() {
  late ApiClient account;
  late TrackedClient shared;
  late FinalTranscriptJournal journal;
  late List<TrackedClient> clients;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  Future<http.Response> Function()? csrf;
  void Function()? onClientCreate;
  final server = <int, Map<String, dynamic>>{};

  Map<String, dynamic> ack(http.Request request) {
    final events = (jsonDecode(request.body)['events'] as List)
        .cast<Map<String, dynamic>>();
    for (final event in events) {
      server[event['sequence'] as int] = event;
    }
    return {
      'source': 'client_reported',
      'account_id': accountId,
      'session_id': practiceId,
      'connection_id': connectionId,
      'client_instance_id': clientId,
      'epoch': 1,
      'last_sequence': server.keys.reduce((a, b) => a > b ? a : b),
      'total_events': server.length,
      'total_text_bytes': server.values.fold<int>(
        0,
        (n, e) => n + utf8.encode(e['text'] as String).length,
      ),
      'acknowledged_event_ids': events.map((e) => e['event_id']).toList(),
    };
  }

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
    server.clear();
    csrf = null;
    onClientCreate = null;
    handler = (request) async => response(ack(request));
    journal = FinalTranscriptJournal(
      accountApi: account,
      scope: fixtures.scope(),
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

  test('only applied final revisions are serialized with their original scope', () async {
    setup();
    expect(clients, isEmpty);
    journal.record(fixtures.user(finalText: false));
    journal.record(fixtures.user(revision: 2));
    journal.record(fixtures.user(revision: 2));
    journal.record(fixtures.user(revision: 1));
    journal.record(fixtures.ai());
    journal.record(fixtures.user(revision: 3, text: ''));
    await journal.retryPending();
    expect(
      requests.single.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/transcripts',
    );
    expect(requests.single.headers['X-Account-ID'], accountId);
    expect(requests.single.headers['X-CSRF-Token'], 'owned-csrf');
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body.keys.toSet(), {'client_instance_id', 'epoch', 'events'});
    expect(body['client_instance_id'], clientId);
    final events = body['events'] as List;
    expect(events.map((e) => e['sequence']), [1, 2, 3]);
    expect(events.map((e) => e['revision']), [2, 1, 3]);
    expect(events[1]['response_id'], fixtures.responseId);
    expect(events.last['text'], '');
    expect(
      events.every(
        (e) => !e.containsKey('is_final') && !e.containsKey('source'),
      ),
      isTrue,
    );
    expect(journal.pendingCount, 0);
    expect(journal.rejectedCount, 0);
    expect(clients.single.closes, 1);
    expect(shared.closes, 0);
  });

  test('failed batches pause and retain every original revision for explicit replay', () async {
    setup();
    handler = (_) async => response({'code': 'service_unavailable'}, 503);
    journal.record(fixtures.user());
    await journal.retryPending();
    final original = jsonDecode(requests.single.body)['events'][0];
    journal.record(fixtures.user(revision: 2, text: 'Revised'));
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 1);
    expect(journal.pendingCount, 2);
    expect(journal.errorCode, 'transcript_failed');
    handler = (request) async => response(ack(request));
    await journal.retryPending();
    expect(jsonDecode(requests.last.body)['events'][0], original);
    expect(journal.pendingCount, 0);
  });

  test(
    'serial batches contain at most four and in-flight records are not merged',
    () async {
      setup();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record(fixtures.user());
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      for (var i = 2; i <= 11; i++) {
        journal.record(fixtures.user(revision: i, text: 'Revision $i'));
      }
      expect(requests.length, 1);
      expect(journal.pendingCount, 11);
      handler = (request) async => response(ack(request));
      pending.complete(response(ack(requests.first)));
      await drain;
      expect(
        requests.map((r) => (jsonDecode(r.body)['events'] as List).length),
        [1, 4, 4, 2],
      );
      expect(journal.pendingCount, 0);
    },
  );

  test('a lost acknowledgement replays the same committed batch', () async {
    setup();
    handler = (request) async {
      ack(request);
      throw http.ClientException('private connection details');
    };
    journal.record(fixtures.user());
    journal.record(fixtures.ai());
    await journal.retryPending();
    final original = requests.single.body;
    expect(journal.pendingCount, 2);
    handler = (request) async => response(ack(request));
    await journal.retryPending();
    expect(requests.last.body, original);
    expect(journal.pendingCount, 0);
  });

  test('strict acknowledgement identity, order and budgets cannot falsely clear records', () async {
    final mutations = <Map<String, dynamic> Function(Map<String, dynamic>)>[
      for (final field in [
        'account_id',
        'session_id',
        'connection_id',
        'client_instance_id',
      ])
        (a) => {...a, field: requestKey},
      (a) => {...a, 'source': 'server_confirmed'},
      (a) => {...a, 'epoch': true},
      (a) => {...a, 'epoch': 1.0},
      (a) => {...a, 'last_sequence': 3},
      (a) => {...a, 'last_sequence': true},
      (a) => {...a, 'total_events': 1},
      (a) => {...a, 'total_events': 2.0},
      (a) => {...a, 'total_text_bytes': 0},
      (a) => {...a, 'total_text_bytes': 16.0},
      (a) => {
        ...a,
        'acknowledged_event_ids': (a['acknowledged_event_ids'] as List).reversed
            .toList(),
      },
      (a) => {...a, 'acknowledged_event_ids': <String>[]},
    ];
    for (final mutate in mutations) {
      setup();
      handler = (request) async => response(mutate(ack(request)));
      journal.record(fixtures.user());
      journal.record(fixtures.ai());
      await journal.retryPending();
      expect(journal.pendingCount, 2);
      expect(journal.errorCode, 'invalid_response');
      journal.abort();
      account.close();
    }
  });

  test(
    'invalid normalized input is rejected without retaining text in errors',
    () async {
      setup();
      for (final u in [
        fixtures.user(id: 'private-invalid-id'),
        fixtures.user(text: 'private\u0000text'),
        fixtures.user(text: String.fromCharCode(0xd800)),
        fixtures.user(text: '界' * 2731),
        TranscriptUpdate(
          turnId: fixtures.userTurn,
          turnIndex: 1,
          role: ConversationRole.user,
          revision: 1,
          text: 'private',
          isFinal: true,
          responseId: fixtures.responseId,
        ),
        TranscriptUpdate(
          turnId: fixtures.userTurn,
          turnIndex: 1,
          role: ConversationRole.user,
          revision: 1,
          text: 'private',
          isFinal: true,
          providerItemId: 'private\u0000item',
        ),
      ]) {
        journal.record(u);
      }
      await journal.retryPending();
      expect(requests, isEmpty);
      expect(journal.rejectedCount, 6);
      expect(journal.errorCode, 'transcript_invalid');
    },
  );

  test(
    'queue count is bounded without replacing unconfirmed records',
    () async {
      setup();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record(fixtures.user());
      await Future<void>.delayed(Duration.zero);
      for (var i = 2; i <= 66; i++) {
        journal.record(fixtures.user(revision: i, text: 'Revision $i'));
      }
      expect(journal.pendingCount, 64);
      expect(journal.rejectedCount, 2);
      expect(journal.errorCode, 'transcript_limit_reached');
      journal.abort();
      pending.complete(response(ack(requests.first)));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('pending UTF-8 budget and lifetime event, text and turn budgets are bounded', () async {
    setup();
    handler = (_) async => response({'code': 'service_unavailable'}, 503);
    for (var i = 1; i <= 33; i++) {
      journal.record(fixtures.user(revision: i, text: 'x' * 8192));
    }
    await journal.retryPending();
    expect(journal.pendingCount, 32);
    expect(journal.rejectedCount, 1);
    journal.abort();
    account.close();
    setup();
    for (var i = 1; i <= 513; i++) {
      journal.record(fixtures.user(revision: i, text: ''));
      await journal.retryPending();
    }
    expect(server.length, 512);
    expect(journal.rejectedCount, 1);
    journal.abort();
    account.close();
    setup();
    for (var i = 1; i <= 129; i++) {
      journal.record(fixtures.user(revision: i, text: 'x' * 8192));
      await journal.retryPending();
    }
    expect(server.length, 128);
    expect(journal.rejectedCount, 1);
    journal.abort();
    account.close();
    setup();
    for (var i = 1; i <= 257; i++) {
      journal.record(
        fixtures.user(
          id: '10000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          index: i,
          text: '',
        ),
      );
      await journal.retryPending();
    }
    expect(server.length, 256);
    expect(journal.rejectedCount, 1);
  });

  test(
    'finish seals input while preserving failed records for explicit retry',
    () async {
      setup();
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      journal.record(fixtures.user());
      journal.finish();
      await journal.retryPending();
      journal.record(fixtures.ai());
      expect(journal.pendingCount, 1);
      handler = (request) async => response(ack(request));
      await journal.retryPending();
      expect(journal.pendingCount, 0);
      expect(server.length, 1);
    },
  );

  test(
    'abort clears text, settles drain and ignores a late acknowledgement',
    () async {
      setup();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record(fixtures.user());
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      journal.abort();
      await drain;
      expect(journal.pendingCount, 0);
      expect(clients.single.closes, 1);
      expect(shared.closes, 0);
      pending.complete(response(ack(requests.single)));
      await Future<void>.delayed(Duration.zero);
      expect(journal.pendingCount, 0);
    },
  );

  test(
    'account changes before dispatch and during CSRF never send old text',
    () async {
      setup();
      journal.record(fixtures.user());
      account.expectedAccountId = requestKey;
      await journal.retryPending();
      expect(clients, isEmpty);
      expect(journal.pendingCount, 0);
      expect(journal.errorCode, 'account_changed');
      journal.abort();
      account.close();
      setup();
      final pending = Completer<http.Response>();
      csrf = () => pending.future;
      journal.record(fixtures.user());
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      account.expectedAccountId = requestKey;
      pending.complete(response({'csrf_token': 'late-new-account'}));
      await drain;
      expect(requests, isEmpty);
      expect(journal.pendingCount, 0);
      expect(journal.errorCode, 'account_changed');
    },
  );

  test('late response after account change cannot confirm old text', () async {
    setup();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    journal.record(fixtures.user());
    final drain = journal.retryPending();
    await Future<void>.delayed(Duration.zero);
    account.expectedAccountId = requestKey;
    pending.complete(response(ack(requests.single)));
    await drain;
    expect(journal.pendingCount, 0);
    expect(journal.errorCode, 'account_changed');
  });

  testWidgets(
    'eight seconds includes CSRF and a late response cannot clear pending text',
    (tester) async {
      setup();
      final pending = Completer<http.Response>();
      csrf = () => pending.future;
      journal.record(fixtures.user());
      final drain = journal.retryPending();
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      await drain;
      expect(journal.pendingCount, 1);
      expect(journal.errorCode, 'transcript_timeout');
      expect(clients.single.closes, 1);
      pending.complete(response({'csrf_token': 'late'}));
      await tester.pump();
      expect(requests, isEmpty);
    },
  );

  test(
    'elapsed deadline rejects a response before a delayed timer runs',
    () async {
      var elapsed = Duration.zero;
      setup(elapsed: () => elapsed);
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record(fixtures.user());
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      elapsed = const Duration(seconds: 9);
      pending.complete(response(ack(requests.single)));
      await drain;
      expect(journal.pendingCount, 1);
      expect(journal.errorCode, 'transcript_timeout');
    },
  );

  testWidgets(
    'POST timeout preserves the original batch when its acknowledgement arrives late',
    (tester) async {
      final origin = tester.binding.clock.now();
      setup(elapsed: () => tester.binding.clock.now().difference(origin));
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.record(fixtures.user());
      final drain = journal.retryPending();
      await tester.pump();
      final original = requests.single.body;
      await tester.pump(const Duration(seconds: 8));
      await drain;
      expect(journal.errorCode, 'transcript_timeout');
      expect(journal.pendingCount, 1);
      pending.complete(response(ack(requests.single)));
      await tester.pump();
      expect(journal.pendingCount, 1);
      handler = (request) async => response(ack(request));
      await journal.retryPending();
      expect(requests.last.body, original);
      expect(journal.pendingCount, 0);
    },
  );

  test('known server rejection codes remain safe and unauthorized clears retained text', () async {
    setup();
    handler = (_) async => response({'code': 'transcript_revision_stale'}, 409);
    journal.record(fixtures.user());
    await journal.retryPending();
    expect(journal.errorCode, 'transcript_revision_stale');
    expect(journal.pendingCount, 1);
    handler = (_) async => response({'code': 'unauthorized'}, 401);
    await journal.retryPending();
    expect(journal.errorCode, 'unauthorized');
    expect(journal.pendingCount, 0);
  });

  test('abort inside client creation cannot send and exception details stay private', () async {
    setup();
    onClientCreate = journal.abort;
    journal.record(fixtures.user());
    await journal.retryPending();
    expect(requests, isEmpty);
    expect(clients.single.closes, 1);
    journal.abort();
    account.close();
    setup();
    handler = (_) async => throw StateError('private-provider-url');
    journal.record(fixtures.user());
    await journal.retryPending();
    expect(journal.errorCode, 'transcript_failed');
  });
}
