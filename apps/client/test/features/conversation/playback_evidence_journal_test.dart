import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';
import 'package:simontalk_client/features/conversation/playback_evidence_journal.dart';
import 'package:simontalk_client/features/practice/submission_manifest.dart';

import '../practice/practice_fixtures.dart';
import '../realtime/api_realtime_signaller_test.dart' show TrackedClient;
import 'conversation_projection_test.dart' as f;

void main() {
  late ApiClient account;
  late PlaybackEvidenceJournal journal;
  late List<http.Request> requests;
  late List<TrackedClient> clients;
  late Future<http.Response> Function(http.Request) handler;
  Future<http.Response> Function()? csrf;
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
        (n, e) =>
            n +
            utf8.encode((e['generated_text'] as String?) ?? '').length +
            utf8.encode((e['played_text'] as String?) ?? '').length,
      ),
      'acknowledged_event_ids': events.map((e) => e['event_id']).toList(),
    };
  }

  void setup({Duration Function()? elapsed}) {
    account = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: TrackedClient((_) async => response({})),
    )..expectedAccountId = accountId;
    requests = [];
    clients = [];
    server.clear();
    csrf = null;
    handler = (request) async => response(ack(request));
    journal = PlaybackEvidenceJournal(
      accountApi: account,
      scope: f.scope(),
      elapsed: elapsed,
      clientFactory: () {
        final client = TrackedClient((request) async {
          if (request.url.path.endsWith('/csrf')) {
            return csrf?.call() ?? response({'csrf_token': 'csrf'});
          }
          requests.add(request);
          return handler(request);
        });
        clients.add(client);
        return client;
      },
    );
  }

  ConversationTurn turn({
    int revision = 1,
    int playback = 1,
    String generated = 'Hello there',
    String played = 'Hello',
    int until = 400,
  }) {
    final projection = ConversationProjection(f.scope())
      ..apply(f.ai(revision: revision, text: generated, finalText: false))
      ..apply(
        f.playback(
          revision: playback,
          transcriptRevision: revision,
          text: played,
          until: until,
        ),
      );
    return projection.snapshot.turns.single;
  }

  tearDown(() {
    journal.abort();
    account.close();
  });
  test(
    'playback manifest survives ACK and sealed missing events stop replay',
    () async {
      setup();
      journal.recordAlignment(turn());
      await journal.retryPending();
      final first = journal.submissionManifest!.events.single;
      handler = (_) async => response({'code': 'practice_input_sealed'}, 409);
      journal.recordRevoke(f.responseId);
      journal.finish();
      await journal.retryPending();
      expect(journal.errorCode, 'practice_input_sealed');
      journal.reconcileSealed(
        SubmissionManifest(
          ledger: SubmissionLedger.playback,
          events: [first],
          totalTextBytes: 0,
          pendingCountAtClose: 0,
        ),
      );
      expect(journal.pendingCount, 0);
      expect(journal.permanentlyUnsavedCount, 1);
      expect(journal.errorCode, 'sealed_unsaved');
      expect(journal.submissionManifest!.events.length, 2);
      final count = requests.length;
      await journal.retryPending();
      expect(requests.length, count);
      journal.abort();
      expect(journal.submissionManifest, isNull);
    },
  );
  test('self-contained source and frozen snapshot upload independently with stable replay', () async {
    setup();
    handler = (request) async {
      ack(request);
      throw http.ClientException('private');
    };
    journal.recordAlignment(turn());
    journal.recordFreeze(
      turn(),
      stopBoundaryMs: 450,
      reason: InterruptedPrefixReason.interrupted,
    );
    await journal.retryPending();
    final original = requests.single.body;
    expect(journal.pendingCount, 2);
    expect(journal.errorCode, 'network_error');
    handler = (request) async => response(ack(request));
    await journal.retryPending();
    expect(requests.last.body, original);
    expect(
      requests.last.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/playback-evidence',
    );
    final events = jsonDecode(original)['events'] as List;
    expect(events.first['generated_text'], 'Hello there');
    expect(events.first['transcript_final'], false);
    expect(events.last['stop_boundary_ms'], 450);
    expect(journal.pendingCount, 0);
    expect(clients.every((c) => c.closes == 1), isTrue);
  });
  test(
    'revoke retains its independent slot when ordinary pending queue is full',
    () async {
      setup();
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      for (var i = 1; i <= 64; i++) {
        journal.recordAlignment(turn(playback: i, until: 400 + i));
      }
      journal.recordAlignment(turn(playback: 65, until: 465));
      expect(journal.pendingCount, 64);
      expect(journal.rejectedCount, 1);
      journal.recordRevoke(f.responseId);
      expect(journal.pendingCount, 65);
      await journal.retryPending();
      handler = (request) async => response(ack(request));
      await journal.retryPending();
      final events = requests
          .skip(1)
          .expand((r) => (jsonDecode(r.body)['events'] as List));
      expect(events.last['kind'], 'revoke');
      expect(events.last.containsKey('generated_text'), isFalse);
      expect(events.last['sequence'], 65);
      expect(journal.pendingCount, 0);
    },
  );
  test(
    'strict acknowledgement cannot drop dependencies and account changes abort',
    () async {
      setup();
      handler = (request) async =>
          response({...ack(request), 'total_text_bytes': 0});
      journal.recordAlignment(turn());
      await journal.retryPending();
      expect(journal.pendingCount, 1);
      expect(journal.errorCode, 'invalid_response');
      account.expectedAccountId = requestKey;
      expect(journal.pendingCount, 0);
      expect(journal.errorCode, 'account_changed');
      account.expectedAccountId = accountId;
      journal.recordRevoke(f.responseId);
      expect(journal.pendingCount, 0);
    },
  );
  test(
    'finish prevents further capture and notifies pending completion',
    () async {
      setup();
      var notifications = 0;
      journal.addListener(() => notifications++);
      journal.recordAlignment(turn());
      journal.finish();
      journal.recordRevoke(f.responseId);
      await journal.retryPending();
      expect(journal.pendingCount, 0);
      expect(server.length, 1);
      expect(notifications, greaterThanOrEqualTo(3));
    },
  );
  test(
    'the elapsed cutoff rejects a response even before its timer runs',
    () async {
      var elapsed = Duration.zero;
      setup(elapsed: () => elapsed);
      handler = (request) async {
        elapsed = const Duration(seconds: 8);
        return response(ack(request));
      };
      journal.recordAlignment(turn());
      await journal.retryPending();
      expect(journal.pendingCount, 1);
      expect(journal.errorCode, 'playback_timeout');
      expect(clients.single.closes, 1);
    },
  );
  testWidgets('the eight second timeout covers a hung CSRF request', (
    tester,
  ) async {
    setup();
    final pending = Completer<http.Response>();
    csrf = () => pending.future;
    journal.recordAlignment(turn());
    final drain = journal.retryPending();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await drain;
    expect(journal.pendingCount, 1);
    expect(journal.errorCode, 'playback_timeout');
    expect(clients.single.closes, 1);
    pending.complete(response({'csrf_token': 'late'}));
    await tester.pump();
    expect(requests, isEmpty);
  });
  test('account loss during CSRF never dispatches old evidence', () async {
    setup();
    final pending = Completer<http.Response>();
    csrf = () => pending.future;
    journal.recordAlignment(turn());
    final drain = journal.retryPending();
    await Future<void>.delayed(Duration.zero);
    account.expectedAccountId = requestKey;
    pending.complete(response({'csrf_token': 'late'}));
    await drain;
    expect(requests, isEmpty);
    expect(journal.pendingCount, 0);
    expect(journal.errorCode, 'account_changed');
  });
  test(
    'abort settles an in-flight request and ignores its late acknowledgement',
    () async {
      setup();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      journal.recordAlignment(turn());
      final drain = journal.retryPending();
      await Future<void>.delayed(Duration.zero);
      journal.abort();
      await drain;
      expect(journal.pendingCount, 0);
      expect(clients.single.closes, 1);
      pending.complete(response(ack(requests.single)));
      await Future<void>.delayed(Duration.zero);
      expect(journal.pendingCount, 0);
    },
  );
  test(
    'ACK validates every identity, event order and integer counter',
    () async {
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
        (a) => {...a, 'last_sequence': 2.0},
        (a) => {...a, 'total_events': 3},
        (a) => {...a, 'total_text_bytes': 32.0},
        (a) => {
          ...a,
          'acknowledged_event_ids': (a['acknowledged_event_ids'] as List)
              .reversed
              .toList(),
        },
        (a) => {...a, 'private_extra': 'unused'},
      ];
      for (final mutate in mutations) {
        setup();
        handler = (request) async => response(mutate(ack(request)));
        journal.recordAlignment(turn());
        journal.recordFreeze(
          turn(),
          stopBoundaryMs: 500,
          reason: InterruptedPrefixReason.interrupted,
        );
        await journal.retryPending();
        expect(journal.pendingCount, 2);
        expect(journal.errorCode, 'invalid_response');
        journal.abort();
        account.close();
      }
    },
  );
  test(
    'a rejected over-budget input cannot consume its version or sequence',
    () async {
      setup();
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      for (var i = 1; i <= 17; i++) {
        journal.recordAlignment(
          turn(revision: i, generated: '界' * 2730, played: '界' * 2729),
        );
      }
      await journal.retryPending();
      expect(journal.pendingCount, 16);
      expect(journal.rejectedCount, 1);
      handler = (request) async => response(ack(request));
      await journal.retryPending();
      journal.recordAlignment(
        turn(revision: 17, generated: '界' * 2730, played: '界' * 2729),
      );
      await journal.retryPending();
      expect(server.length, 17);
      expect(server[17]!['transcript_revision'], 17);
    },
  );
  test('lifetime ordinary quota preserves room for revoke and suppresses duplicates', () async {
    setup();
    for (var i = 1; i <= 513; i++) {
      journal.recordAlignment(turn(revision: i));
      await journal.retryPending();
    }
    expect(server.length, 512);
    expect(journal.rejectedCount, 1);
    journal.recordRevoke(f.responseId);
    journal.recordRevoke(f.responseId);
    await journal.retryPending();
    expect(server.length, 513);
    expect(server[513]!['kind'], 'revoke');
    expect(journal.rejectedCount, 1);
  });
  test('lifetime byte budget counts both generated and aligned text', () async {
    setup();
    for (var i = 1; i <= 129; i++) {
      journal.recordAlignment(
        turn(revision: i, generated: 'x' * 8192, played: 'x' * 8191),
      );
      await journal.retryPending();
    }
    expect(server.length, 128);
    expect(journal.rejectedCount, 1);
    expect(journal.errorCode, 'playback_limit_reached');
  });
  test(
    'account-loss listeners can inspect cleared state without reentrant abort',
    () async {
      setup();
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      journal.recordAlignment(turn());
      await journal.retryPending();
      var notifications = 0;
      journal.addListener(() {
        notifications++;
        expect(journal.pendingCount, 0);
        expect(journal.errorCode, 'account_changed');
      });
      account.expectedAccountId = requestKey;
      expect(journal.pendingCount, 0);
      expect(notifications, 1);
      journal.abort();
      expect(notifications, 1);
    },
  );
}
