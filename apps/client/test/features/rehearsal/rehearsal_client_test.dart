import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_models.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_controller.dart';

import 'rehearsal_fixtures.dart';

void main() {
  late ApiClient api;
  late RehearsalController c;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  RehearsalController make({
    String? item = itemId,
    Duration Function()? elapsed,
  }) => RehearsalController(
    accountApi: api,
    accountId: accountId,
    sessionId: item == null ? childId : practiceId,
    itemId: item,
    keyFactory: () => requestKey,
    elapsed: elapsed,
    httpClientFactory: () => MockClient((r) {
      requests.add(r);
      return handler(r);
    }),
  );
  setUp(() {
    requests.clear();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (r) async => response(
      r.method == 'POST' ? rehearsalPreparationJson() : rehearsalTargetJson(),
    );
    c = make();
  });
  tearDown(() {
    c.dispose();
    api.close();
  });
  RehearsalTarget parsed(Map<String, dynamic> j) => RehearsalTarget.fromJson(
    j,
    accountId: accountId,
    sourceSessionId: practiceId,
    itemId: itemId,
  );
  test(
    'target retains complete original and deeply immutable safe context',
    () {
      final j = rehearsalTargetJson();
      final target = parsed(j);
      j['source_text'] = 'changed';
      expect(target.sourceText, 'Yes, I enjoy English.');
      expect(target.exactQuote, 'I enjoy English.');
      expect(target.targetHash, 'd' * 64);
      expect(
        () => target.toJson()['context_before'].add({}),
        throwsUnsupportedError,
      );
    },
  );
  for (final change in <Map<String, dynamic>>[
    {'account_id': childId},
    {'source_session_id': childId},
    {'source_kind': 'rehearsal'},
    {'item_id': childId},
    {'schema_version': 'future'},
    {'source': 'fixture'},
    {'revision': true},
    {'source_epoch': 0},
    {'input_revision': 2},
    {'target_hash': 'no'},
    {'result_hash': 'A' * 64},
    {'extra': 1},
    {'exact_quote': 'not in original'},
    {'source_text': '\u0000'},
    {'suggestion': '汉' * 3000},
    {'explanation': ' '},
    {
      'context_before': [{}],
    },
  ]) {
    test(
      'invalid target rejected ${change.keys.join(",")}',
      () => expect(
        () => parsed({...rehearsalTargetJson(), ...change}),
        throwsFormatException,
      ),
    );
  }
  test('read is silent before load and confirmation alone creates without connections', () async {
    expect(requests, isEmpty);
    await c.load();
    expect(c.state, RehearsalState.ready);
    expect(requests.single.method, 'GET');
    expect(c.canConfirm, isFalse);
    c.selectDifficulty(Difficulty.beginner);
    await c.confirm();
    expect(c.state, RehearsalState.prepared);
    expect(c.preparation!.id, childId);
    final r = requests.last;
    expect(
      r.url.path,
      '/v1/practice-sessions/$practiceId/review-items/$itemId/rehearsals',
    );
    expect(r.headers['Idempotency-Key'], requestKey);
    expect(r.headers['X-Account-ID'], accountId);
    expect(jsonDecode(r.body), {
      'target_hash': 'd' * 64,
      'difficulty_override': 'beginner',
    });
    expect(requests.where((r) => r.url.path.contains('/connections')), isEmpty);
  });
  test(
    'unknown keeps original key body and difficulty until explicit replay',
    () async {
      await c.load();
      c.selectDifficulty(Difficulty.beginner);
      handler = (_) async => throw http.ClientException('offline');
      await c.confirm();
      expect(c.state, RehearsalState.unconfirmed);
      expect(c.canReplay, isTrue);
      final original = requests.last;
      await c.load();
      c.selectDifficulty(Difficulty.advanced);
      expect(requests, hasLength(2));
      handler = (_) async => response(rehearsalPreparationJson(), 201);
      await c.replay();
      expect(requests.last.body, original.body);
      expect(
        requests.last.headers['Idempotency-Key'],
        original.headers['Idempotency-Key'],
      );
      expect(c.state, RehearsalState.prepared);
    },
  );
  test(
    'changed target reply is unknown and never displayed as a prepared success',
    () async {
      await c.load();
      c.selectDifficulty(Difficulty.beginner);
      handler = (_) async => response({
        ...rehearsalPreparationJson(),
        'target': {...rehearsalTargetJson(), 'suggestion': 'changed'},
      }, 201);
      await c.confirm();
      expect(c.state, RehearsalState.unconfirmed);
      expect(c.preparation, isNull);
    },
  );
  test('definite source conflict clears old text and requires fresh read confirmation', () async {
    await c.load();
    c.selectDifficulty(Difficulty.beginner);
    handler = (_) async => response({'code': 'rehearsal_source_changed'}, 409);
    await c.confirm();
    expect(c.target, isNull);
    expect(c.state, RehearsalState.failed);
    await c.confirm();
    expect(requests, hasLength(2));
  });
  test('default unavailable is truthful, no automatic replay', () async {
    await c.load();
    c.selectDifficulty(Difficulty.beginner);
    handler = (_) async => response({'code': 'realtime_unavailable'}, 503);
    await c.confirm();
    expect(c.state, RehearsalState.failed);
    expect(c.preparation, isNull);
    expect(c.canReplay, isFalse);
    expect(requests, hasLength(2));
  });
  test('explicit discard uses expected epoch and validates returned cancelled practice', () async {
    await c.load();
    c.selectDifficulty(Difficulty.beginner);
    await c.confirm();
    handler = (_) async => response(childJson(status: 'cancelled'));
    await c.discard();
    expect(
      requests.last.url.path,
      '/v1/practice-sessions/$childId/discard-preparation',
    );
    expect(jsonDecode(requests.last.body), {'expected_epoch': 0});
    expect(c.state, RehearsalState.cancelled);
  });
  test(
    'failed discard retains known practice and permits explicit safe retry',
    () async {
      await c.load();
      c.selectDifficulty(Difficulty.beginner);
      await c.confirm();
      handler = (_) async => throw http.ClientException('offline');
      await c.discard();
      expect(c.preparation!.id, childId);
      expect(c.state, RehearsalState.prepared);
      expect(c.errorCode, 'network_error');
    },
  );
  test('single flight gates duplicate create and suppresses late reply after dispose', () async {
    await c.load();
    c.selectDifficulty(Difficulty.beginner);
    final gate = Completer<http.Response>();
    handler = (_) => gate.future;
    final first = c.confirm(), second = c.confirm();
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    await first;
    gate.complete(response(rehearsalPreparationJson(), 201));
    await Future<void>.delayed(Duration.zero);
    expect(c.target, isNull);
    expect(c.preparation, isNull);
    expect(c.state, RehearsalState.aborted);
  });
  test(
    'identity change purges all text and suppresses late successful mutation',
    () async {
      await c.load();
      c.selectDifficulty(Difficulty.beginner);
      handler = (_) async {
        api.expectedAccountId = childId;
        return response(rehearsalPreparationJson(), 201);
      };
      await c.confirm();
      expect(c.state, RehearsalState.aborted);
      expect(c.target, isNull);
      expect(c.preparation, isNull);
      expect(c.errorCode, 'account_changed');
    },
  );
  test(
    'child address verifies metadata before fixed target and cannot create',
    () async {
      c.dispose();
      c = make(item: null);
      handler = (r) async => response(
        r.url.path.endsWith('/rehearsal-target')
            ? rehearsalTargetJson()
            : childJson(),
      );
      await c.load();
      expect(c.state, RehearsalState.ready);
      expect(requests, hasLength(2));
      c.selectDifficulty(Difficulty.beginner);
      await c.confirm();
      expect(c.canConfirm, isFalse);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );
  test('total monotonic deadline prevents child second GET', () async {
    c.dispose();
    var clock = Duration.zero;
    c = make(item: null, elapsed: () => clock);
    handler = (_) async {
      clock = const Duration(seconds: 8);
      return response(childJson());
    };
    await c.load();
    expect(c.errorCode, 'rehearsal_timeout');
    expect(requests, hasLength(1));
  });
  testWidgets('CSRF wait belongs to overall eight second create deadline', (
    tester,
  ) async {
    c.dispose();
    api.close();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    c = make();
    await c.load();
    c.selectDifficulty(Difficulty.beginner);
    final gate = Completer<http.Response>();
    handler = (_) => gate.future;
    final work = c.confirm();
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await work;
    expect(c.state, RehearsalState.unconfirmed);
    gate.complete(response({'csrf_token': 'late'}));
    await tester.pump();
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
}
