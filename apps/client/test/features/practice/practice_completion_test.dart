import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_client.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/practice/submission_manifest.dart';

import '../conversation/conversation_projection_test.dart' as f;
import '../realtime/api_realtime_signaller_test.dart' show TrackedClient;
import 'practice_fixtures.dart';

Map<String, dynamic> completionSummary({bool sealed = false}) => {
  'source': 'server_recorded',
  'account_id': accountId,
  'session_id': practiceId,
  'origin_connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'end_key': requestKey,
  'status': sealed ? 'sealed' : 'ending',
  'accepted_at': '2026-10-21T08:00:00Z',
  'final_upload_deadline': '2026-10-21T08:00:30Z',
  'sealed_at': sealed ? '2026-10-21T08:00:03Z' : null,
  'input_revision': sealed ? 1 : 0,
  'input_hash': sealed ? 'a' * 64 : null,
  'coverage': sealed ? 'incomplete' : 'pending',
  'connection_count': 1,
  'gap_codes': sealed ? ['tail_unconfirmed'] : <String>[],
};

PracticeCompletionManifest emptyManifest() => PracticeCompletionManifest(
  scope: f.scope(),
  transcripts: SubmissionManifest.empty(SubmissionLedger.transcripts),
  playback: SubmissionManifest.empty(SubmissionLedger.playback),
  tailStatus: PracticeCompletionTailStatus.unconfirmed,
);

Map<String, dynamic> completionReceipt() => {
  'source': 'server_recorded',
  'account_id': accountId,
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'sealed': true,
  'recoverable': false,
  'input_revision': 1,
  'input_hash': 'b' * 64,
  'practice_input_hash': 'a' * 64,
  'transcript_events': <Object>[],
  'playback_events': <Object>[],
};

void main() {
  test(
    'manifest is immutable, bounded and allows legitimate sequence gaps',
    () {
      final events = [SubmissionEventRef(sequence: 3, eventId: requestKey)];
      final manifest = SubmissionManifest(
        ledger: SubmissionLedger.transcripts,
        events: events,
        totalTextBytes: 4,
        pendingCountAtClose: 1,
      );
      events.clear();
      expect(manifest.lastSequence, 3);
      expect(manifest.totalEvents, 1);
      expect(manifest.events.single.eventId, requestKey);
      expect(() => manifest.events.clear(), throwsUnsupportedError);
      final json = manifest.toRequestJson();
      expect(json, {
        'events': [
          {'sequence': 3, 'event_id': requestKey},
        ],
        'last_sequence': 3,
        'total_events': 1,
        'total_text_bytes': 4,
        'pending_count_at_close': 1,
      });
      for (final change in [
        {'total_events': 2},
        {'last_sequence': 2},
        {'total_text_bytes': true},
        {'pending_count_at_close': 2},
        {'extra': 'private'},
        {
          'events': [
            {'sequence': 3, 'event_id': requestKey},
            {'sequence': 4, 'event_id': requestKey},
          ],
          'total_events': 2,
          'last_sequence': 4,
        },
      ]) {
        expect(
          () => SubmissionManifest.fromJson({
            ...json,
            ...change,
          }, ledger: SubmissionLedger.transcripts),
          throwsFormatException,
        );
      }
    },
  );

  test('strict summary binds scope, fixed deadline and sealed version', () {
    final ending = PracticeCompletionSummary.fromJson(
      completionSummary(),
      scope: f.scope(),
      endKey: requestKey,
    );
    expect(ending.status, PracticeCompletionStatus.ending);
    final sealed = PracticeCompletionSummary.fromJson(
      completionSummary(sealed: true),
      scope: f.scope(),
      endKey: requestKey,
    );
    expect(sealed.coverage, PracticeCompletionCoverage.incomplete);
    for (final change in [
      {'account_id': requestKey},
      {'end_key': clientId},
      {'final_upload_deadline': '2026-10-21T08:00:31Z'},
      {'accepted_at': '2026-02-30T08:00:00Z'},
      {'input_revision': true},
      {'input_hash': 'A' * 64},
      {'coverage': 'pending'},
      {
        'gap_codes': ['tail_unconfirmed', 'tail_unconfirmed'],
      },
      {
        'gap_codes': ['private'],
      },
      {'extra': 'private'},
    ]) {
      expect(
        () => PracticeCompletionSummary.fromJson(
          {...completionSummary(sealed: true), ...change},
          scope: f.scope(),
          endKey: requestKey,
        ),
        throwsFormatException,
      );
    }
  });

  test('completion manifest freezes IDs and explicitly reports unavailable journal', () {
    final turns = [f.userTurn];
    final manifest = PracticeCompletionManifest(
      scope: f.scope(),
      transcripts: SubmissionManifest.empty(SubmissionLedger.transcripts),
      playback: SubmissionManifest.empty(SubmissionLedger.playback),
      tailStatus: PracticeCompletionTailStatus.aborted,
      unfinalizedTurnIds: turns,
      journalUnavailable: true,
    );
    turns.clear();
    expect(manifest.toRequestJson()['unfinalized_turn_ids'], [f.userTurn]);
    expect(manifest.toRequestJson()['journal_unavailable'], true);
    expect(manifest.toRequestJson()['tail_status'], 'aborted');
  });

  test('sealed receipt validates original scope, bounded refs and global input hash', () {
    final json = completionReceipt();
    expect(
      PracticeCompletionReceipt.fromJson(
        json,
        scope: f.scope(),
        practiceInputHash: 'a' * 64,
      ).recoverable,
      false,
    );
    for (final change in [
      {'connection_id': requestKey},
      {'epoch': true},
      {'sealed': false},
      {'recoverable': true},
      {'input_revision': 0},
      {'input_hash': 'A' * 64},
      {'practice_input_hash': 'c' * 64},
      {'extra': 'private'},
      {
        'transcript_events': [
          {'sequence': 2, 'event_id': requestKey},
          {'sequence': 3, 'event_id': requestKey},
        ],
      },
      {
        'playback_events': [
          {'sequence': true, 'event_id': requestKey},
        ],
      },
    ]) {
      expect(
        () => PracticeCompletionReceipt.fromJson(
          {...json, ...change},
          scope: f.scope(),
          practiceInputHash: 'a' * 64,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'submission declarations reject over-budget refs, bytes and identity lists',
    () {
      final json = SubmissionManifest.empty(SubmissionLedger.transcripts)
          .toRequestJson();
      for (final change in [
        {'total_text_bytes': 1},
        {
          'events': [
            {'sequence': 0, 'event_id': requestKey},
          ],
          'last_sequence': 0,
          'total_events': 1,
        },
        {
          'events': [
            {'sequence': 1, 'event_id': requestKey, 'text': 'private'},
          ],
          'last_sequence': 1,
          'total_events': 1,
        },
        {
          'events': [
            {'sequence': 1, 'event_id': requestKey},
          ],
          'last_sequence': 1,
          'total_events': 1,
          'total_text_bytes': 8193,
        },
      ]) {
        expect(
          () => SubmissionManifest.fromJson({
            ...json,
            ...change,
          }, ledger: SubmissionLedger.transcripts),
          throwsFormatException,
        );
      }
      expect(
        () => PracticeCompletionManifest(
          scope: f.scope(),
          transcripts: SubmissionManifest.empty(SubmissionLedger.transcripts),
          playback: SubmissionManifest.empty(SubmissionLedger.playback),
          tailStatus: PracticeCompletionTailStatus.unconfirmed,
          unfinalizedTurnIds: [f.userTurn, f.userTurn],
        ),
        throwsFormatException,
      );
      expect(
        () => PracticeCompletionManifest(
          scope: f.scope(),
          transcripts: SubmissionManifest.empty(SubmissionLedger.playback),
          playback: SubmissionManifest.empty(SubmissionLedger.playback),
          tailStatus: PracticeCompletionTailStatus.unconfirmed,
        ),
        throwsFormatException,
      );
    },
  );

  test('historical member manifests keep their own path and validate separate ending origin', () async {
    final calls = <http.Request>[];
    final origin = ConversationScope(
      accountId: accountId,
      sessionId: practiceId,
      connectionId: requestKey,
      clientInstanceId: f.aiTurn,
      epoch: 2,
    );
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: TrackedClient((request) async {
        if (request.url.path.endsWith('/csrf')) {
          return response({'csrf_token': 'csrf'});
        }
        calls.add(request);
        return response({
          ...completionSummary(),
          'origin_connection_id': origin.connectionId,
          'client_instance_id': origin.clientInstanceId,
          'epoch': 2,
          'connection_count': 2,
        });
      }),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    final repository = PracticeRepository(api, accountId: accountId);
    final result = await repository.submitPracticeCompletionManifest(
      emptyManifest(),
      endKey: requestKey,
      expectedOriginScope: origin,
    );
    expect(result.scope.connectionId, origin.connectionId);
    expect(
      calls.single.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/completion-manifest',
    );
    expect(jsonDecode(calls.single.body)['client_instance_id'], clientId);
    expect(jsonDecode(calls.single.body)['epoch'], 1);
    final read = await repository.loadPracticeCompletion(
      f.scope(),
      endKey: requestKey,
      expectedOriginScope: origin,
    );
    expect(read.scope.epoch, 2);
    expect(calls.last.method, 'GET');
    expect(calls.last.url.path, '/v1/practice-sessions/$practiceId/completion');
  });

  late ApiClient account;
  late PracticeCompletionClient client;
  late List<http.Request> requests;
  late List<TrackedClient> owned;
  late Future<http.Response> Function(http.Request) handler;
  Future<http.Response> Function()? csrf;
  void setup({Duration Function()? elapsed}) {
    requests = [];
    owned = [];
    csrf = null;
    account = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: TrackedClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (r) async => response(
      r.url.path.endsWith('/completion-receipt')
          ? completionReceipt()
          : completionSummary(),
    );
    client = PracticeCompletionClient(
      accountApi: account,
      scope: f.scope(),
      endKey: requestKey,
      elapsed: elapsed,
      clientFactory: () {
        final next = TrackedClient((request) async {
          if (request.url.path.endsWith('/csrf')) {
            return csrf?.call() ?? response({'csrf_token': 'csrf'});
          }
          requests.add(request);
          return handler(request);
        });
        owned.add(next);
        return next;
      },
    );
    addTearDown(() {
      client.abort();
      account.close();
    });
  }

  test('construction is inert, end and fixed manifest serialize then only GET', () async {
    setup();
    expect(owned, isEmpty);
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    client.requestEnd();
    client.finish(emptyManifest());
    client.requestEnd();
    final task = client.retryPending();
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 1);
    expect(requests.single.url.path.endsWith('/end'), true);
    expect(requests.single.headers['Idempotency-Key'], requestKey);
    expect(jsonDecode(requests.single.body), {
      'client_instance_id': clientId,
      'epoch': 1,
    });
    handler = (_) async => response(completionSummary());
    pending.complete(response(completionSummary()));
    await task;
    expect(requests.map((r) => r.method), ['POST', 'POST']);
    expect(jsonDecode(requests.last.body), emptyManifest().toRequestJson());
    handler = (r) async => response(
      r.url.path.endsWith('/completion-receipt')
          ? completionReceipt()
          : completionSummary(sealed: true),
    );
    await client.refresh();
    expect(requests.last.method, 'GET');
    expect(
      requests.last.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/completion-receipt',
    );
    expect(client.state, PracticeCompletionClientState.sealed);
    expect(client.receipt!.transcripts.events, isEmpty);
    expect(client.hasPendingWork, false);
    expect(owned.every((c) => c.closes == 1), true);
  });

  test(
    'failed end and lost manifest ACK require fixed explicit retry',
    () async {
      setup();
      handler = (_) async => throw http.ClientException('private');
      client.requestEnd();
      client.finish(emptyManifest());
      await client.retryPending();
      final original = requests.single.body;
      expect(client.errorCode, 'network_error');
      expect(client.hasPendingWork, true);
      await Future<void>.delayed(Duration.zero);
      expect(requests.length, 1);
      handler = (r) async {
        if (r.url.path.endsWith('/completion-manifest')) {
          throw http.ClientException('private');
        }
        return response(completionSummary());
      };
      await client.retryPending();
      expect(requests[1].body, original);
      final fixedManifest = requests.last.body;
      handler = (r) async => response(
        r.url.path.endsWith('/completion-receipt')
            ? completionReceipt()
            : completionSummary(sealed: true),
      );
      await client.retryPending();
      expect(requests[requests.length - 2].body, fixedManifest);
      expect(requests.last.headers['X-Account-ID'], accountId);
      expect(client.hasPendingWork, false);
    },
  );

  test(
    'changed manifest and regressing summary cannot replace fixed evidence',
    () async {
      setup();
      client.requestEnd();
      client.finish(emptyManifest());
      await client.retryPending();
      final changed = PracticeCompletionManifest(
        scope: f.scope(),
        transcripts: SubmissionManifest.empty(SubmissionLedger.transcripts),
        playback: SubmissionManifest.empty(SubmissionLedger.playback),
        tailStatus: PracticeCompletionTailStatus.aborted,
      );
      expect(() => client.finish(changed), throwsA(isA<ApiException>()));
      handler = (_) async => response({
        ...completionSummary(),
        'accepted_at': '2026-10-21T08:01:00Z',
        'final_upload_deadline': '2026-10-21T08:01:30Z',
      });
      await client.refresh();
      expect(client.errorCode, 'invalid_response');
      expect(client.summary!.acceptedAt, DateTime.utc(2026, 10, 21, 8));
    },
  );

  test(
    'repository rejects wrong scope and invalid response before exposing state',
    () async {
      setup();
      final repository = PracticeRepository(account, accountId: accountId);
      // Shared account HTTP remains independent from the completion owned clients.
      await expectLater(
        repository.endPracticeConnection(f.scope(), key: 'bad'),
        throwsA(isA<ApiException>()),
      );
      expect(requests, isEmpty);
    },
  );

  testWidgets(
    'eight seconds includes CSRF and abort rejects late old-account response',
    (tester) async {
      final origin = tester.binding.clock.now();
      setup(elapsed: () => tester.binding.clock.now().difference(origin));
      final pending = Completer<http.Response>();
      csrf = () => pending.future;
      client.requestEnd();
      final task = client.retryPending();
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));
      await task;
      expect(client.errorCode, 'completion_timeout');
      expect(client.hasPendingWork, true);
      expect(owned.single.closes, 1);
      pending.complete(response({'csrf_token': 'late'}));
      await tester.pump();
      expect(requests, isEmpty);
      account.expectedAccountId = requestKey;
      expect(client.summary, isNull);
      expect(client.hasPendingWork, false);
      expect(client.errorCode, 'account_changed');
    },
  );

  testWidgets('waiting uses only bounded GET refresh and remains retryable', (
    tester,
  ) async {
    final origin = tester.binding.clock.now();
    setup(elapsed: () => tester.binding.clock.now().difference(origin));
    client.requestEnd();
    client.finish(emptyManifest());
    await tester.pump();
    for (var i = 0; i < 22; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
    final count = requests.length;
    expect(requests.take(2).every((r) => r.method == 'POST'), true);
    expect(requests.skip(2).every((r) => r.method == 'GET'), true);
    expect(count, lessThanOrEqualTo(22));
    expect(client.errorCode, 'completion_pending');
    expect(client.hasPendingWork, true);
    await tester.pump(const Duration(minutes: 1));
    expect(requests.length, count);
    handler = (r) async => response(
      r.url.path.endsWith('/completion-receipt')
          ? completionReceipt()
          : completionSummary(sealed: true),
    );
    await client.retryPending();
    expect(requests.last.method, 'GET');
    expect(client.hasPendingWork, false);
  });

  test(
    'sealed summary cannot release retention until matching receipt is read',
    () async {
      setup();
      handler = (r) async => response(
        r.url.path.endsWith('/completion-receipt')
            ? {...completionReceipt(), 'practice_input_hash': 'c' * 64}
            : completionSummary(sealed: true),
      );
      client.requestEnd();
      client.finish(emptyManifest());
      await client.retryPending();
      expect(
        requests.any((r) => r.url.path.endsWith('/completion-manifest')),
        false,
      );
      expect(client.hasPendingWork, true);
      expect(client.errorCode, 'invalid_response');
      expect(client.receipt, isNull);
      handler = (_) async => response(completionReceipt());
      await client.retryPending();
      expect(requests.last.url.path.endsWith('/completion-receipt'), true);
      expect(client.hasPendingWork, false);
    },
  );

  test(
    'expired unaccepted manifest changes to read-only convergence',
    () async {
      setup();
      handler = (r) async => r.url.path.endsWith('/completion-manifest')
          ? response({'code': 'practice_input_sealed'}, 409)
          : response(completionSummary());
      client.requestEnd();
      client.finish(emptyManifest());
      await client.retryPending();
      final writes = requests.where((r) => r.method == 'POST').length;
      handler = (r) async => response(
        r.url.path.endsWith('/completion-receipt')
            ? completionReceipt()
            : completionSummary(sealed: true),
      );
      await client.retryPending();
      expect(requests.where((r) => r.method == 'POST').length, writes);
      expect(client.hasPendingWork, false);
    },
  );

  test('account change during request cancels state and cannot accept late response', () async {
    setup();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    client.requestEnd();
    final task = client.retryPending();
    await Future<void>.delayed(Duration.zero);
    account.expectedAccountId = requestKey;
    expect(client.hasPendingWork, false);
    await task;
    expect(client.state, PracticeCompletionClientState.aborted);
    expect(client.errorCode, 'account_changed');
    pending.complete(response(completionSummary(sealed: true)));
    await Future<void>.delayed(Duration.zero);
    expect(client.summary, isNull);
    expect(client.receipt, isNull);
    expect(requests.length, 1);
  });

  testWidgets('a delayed poll timer cannot read beyond its monotonic budget', (
    tester,
  ) async {
    var elapsed = Duration.zero;
    setup(elapsed: () => elapsed);
    client.requestEnd();
    client.finish(emptyManifest());
    await tester.pump();
    expect(requests.length, 2);
    elapsed = const Duration(minutes: 1);
    await tester.pump(const Duration(seconds: 2));
    expect(requests.length, 2);
    expect(client.errorCode, 'completion_pending');
    expect(client.hasPendingWork, true);
  });

  test(
    'a manifest fixed during a read is submitted after that read completes',
    () async {
      setup();
      client.requestEnd();
      await client.retryPending();
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final read = client.refresh();
      await Future<void>.delayed(Duration.zero);
      client.finish(emptyManifest());
      handler = (_) async => response(completionSummary());
      pending.complete(response(completionSummary()));
      await read;
      await Future<void>.delayed(Duration.zero);
      expect(requests.last.url.path.endsWith('/completion-manifest'), true);
    },
  );

  test('read-only refresh cannot retry a rejected manifest write', () async {
    setup();
    handler = (request) async =>
        request.url.path.endsWith('/completion-manifest')
        ? response({'code': 'service_unavailable'}, 503)
        : response(completionSummary());
    client.requestEnd();
    client.finish(emptyManifest());
    await client.retryPending();
    final writes = requests.where((r) => r.method == 'POST').length;
    await client.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(requests.last.method, 'GET');
    expect(requests.where((r) => r.method == 'POST').length, writes);
  });
}
