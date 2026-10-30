import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_list_models.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_list_controller.dart';

import 'rehearsal_list_fixtures.dart';

void main() {
  late ApiClient api;
  late RehearsalListController c;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  RehearsalListController make({
    Duration Function()? elapsed,
    String sid = practiceId,
  }) => RehearsalListController(
    accountApi: api,
    accountId: accountId,
    sourceSessionId: sid,
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
    handler = (r) async {
      final cursor = r.url.queryParameters['before_id'];
      return response(
        relatedPage(
          cursor == historyId(12)
              ? 1
              : cursor == historyId(2)
              ? 2
              : 0,
        ),
      );
    };
    c = make();
  });
  tearDown(() {
    c.dispose();
    api.close();
  });
  RehearsalListPage parse(Map<String, dynamic> j, {RelatedRehearsal? before}) =>
      RehearsalListPage.fromJson(
        j,
        accountId: accountId,
        sourceSessionId: practiceId,
        before: before,
      );
  test('immutable page validates same-time UUID order and cursor boundary', () {
    final j = relatedPage();
    final first = parse(j);
    (j['items'] as List).clear();
    expect(first.items, hasLength(10));
    expect(() => first.items.clear(), throwsUnsupportedError);
    final second = parse(relatedPage(1), before: first.items.last);
    expect(second.items.first.id, historyId(11));
    expect(
      () => parse(relatedPage(), before: first.items.last),
      throwsFormatException,
    );
  });
  var caseNumber = 0;
  for (final change in <Map<String, dynamic>>[
    {'account_id': practiceId},
    {'source_session_id': accountId},
    {'schema_version': 'future'},
    {'source': 'fixture'},
    {'limit': 20},
    {'extra': 1},
    {'next_before_id': historyId(13)},
    {'items': <dynamic>[], 'next_before_id': historyId(12)},
    {
      'items': [relatedRow(21), relatedRow(21)],
      'next_before_id': null,
    },
    {
      'items': [relatedRow(20), relatedRow(21)],
      'next_before_id': null,
    },
    {
      'items': [
        {...relatedRow(21), 'source_session_id': accountId},
      ],
      'next_before_id': null,
    },
    {
      'items': [
        {...relatedRow(21), 'kind': 'ordinary'},
      ],
      'next_before_id': null,
    },
    {
      'items': [
        {...relatedRow(21), 'source_review_item_id': 'bad'},
      ],
      'next_before_id': null,
    },
    {
      'items': [
        {...relatedRow(21), 'status': 'invented'},
      ],
      'next_before_id': null,
    },
    {
      'items': [
        {...relatedRow(21), 'created_at': '2026-02-30T00:00:00Z'},
      ],
      'next_before_id': null,
    },
    {
      'items': [
        {...relatedRow(21), 'ended_at': '2026-10-22T00:00:00Z'},
      ],
      'next_before_id': null,
    },
  ]) {
    test(
      'invalid envelope or row ${change.keys.join(',')} #${++caseNumber}',
      () => expect(
        () => parse({...relatedPage(), ...change}),
        throwsFormatException,
      ),
    );
  }
  test(
    'silent construction and listening; pure owner GET three pages and return',
    () async {
      c.addListener(() {});
      expect(requests, isEmpty);
      final initial = c.refresh();
      expect(identical(initial, c.refresh()), isTrue);
      await initial;
      expect(c.page!.items.first.id, historyId(21));
      await c.next();
      expect(c.pageNumber, 2);
      await c.next();
      expect(c.pageNumber, 3);
      expect(c.page!.items.single.id, historyId(1));
      expect(c.canNext, isFalse);
      await c.previous();
      expect(c.pageNumber, 2);
      expect(c.page!.items.first.id, historyId(11));
      expect(
        requests.every(
          (r) => r.method == 'GET' && r.headers['X-Account-ID'] == accountId,
        ),
        isTrue,
      );
      expect(
        requests.every(
          (r) =>
              r.url.path == '/v1/practice-sessions/$practiceId/rehearsals' &&
              r.url.queryParameters['limit'] == '10',
        ),
        isTrue,
      );
      expect(requests[1].url.queryParameters['before_id'], historyId(12));
    },
  );
  test('network paging failure retains original page and refresh clears it synchronously', () async {
    await c.refresh();
    final original = c.page;
    handler = (_) async => throw http.ClientException('offline');
    await c.next();
    expect(c.state, RehearsalListState.failed);
    expect(c.page, original);
    expect(c.pageNumber, 1);
    expect(c.canNext, isTrue);
    final work = c.refresh();
    expect(c.page, isNull);
    await work;
    expect(c.page, isNull);
  });
  test(
    'cursor deletion refusal clears page and positions, refresh starts at head',
    () async {
      await c.refresh();
      handler = (_) async =>
          response({'code': 'rehearsal_cursor_not_found'}, 404);
      await c.next();
      expect(c.page, isNull);
      expect(c.canNext, isFalse);
      expect(c.canPrevious, isFalse);
      handler = (_) async => response(relatedPage());
      await c.refresh();
      expect(
        requests.last.url.queryParameters.containsKey('before_id'),
        isFalse,
      );
      expect(c.pageNumber, 1);
    },
  );
  for (final status in [401, 404, 409, 200]) {
    test('nontransient $status clears accepted old page', () async {
      await c.refresh();
      handler = (_) async => response({
        'code': status == 409
            ? 'rehearsal_source_changed'
            : 'practice_not_found',
      }, status);
      await c.next();
      expect(c.page, isNull);
    });
  }
  test('bad cross-boundary next response clears old page', () async {
    await c.refresh();
    handler = (_) async => response(relatedPage());
    await c.next();
    expect(c.errorCode, 'invalid_response');
    expect(c.page, isNull);
  });
  test(
    'identity change removes metadata and late replies cannot publish',
    () async {
      await c.refresh();
      final gate = Completer<http.Response>();
      handler = (_) => gate.future;
      final pending = c.next();
      await Future<void>.delayed(Duration.zero);
      api.expectedAccountId = practiceId;
      expect(c.page, isNull);
      await pending;
      gate.complete(response(relatedPage(1)));
      await Future<void>.delayed(Duration.zero);
      expect(c.state, RehearsalListState.aborted);
      expect(c.errorCode, 'account_changed');
      expect(c.page, isNull);
    },
  );
  test(
    'dispose cancels pending independent read without closing account api',
    () async {
      final gate = Completer<http.Response>();
      handler = (_) => gate.future;
      final work = c.refresh();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      await work;
      gate.complete(response(relatedPage()));
      await Future<void>.delayed(Duration.zero);
      expect(c.page, isNull);
      expect(api.hasCurrentAccount(accountId), isTrue);
    },
  );
  test('invalid parent URL is refused without I/O', () async {
    c.dispose();
    c = make(sid: 'bad');
    await c.refresh();
    expect(requests, isEmpty);
    expect(c.errorCode, 'invalid_source');
  });
  testWidgets(
    'eight-second deadline settles pending read and ignores a late success',
    (t) async {
      final gate = Completer<http.Response>();
      handler = (_) => gate.future;
      final work = c.refresh();
      await t.pump();
      await t.pump(const Duration(seconds: 8));
      await work;
      expect(c.errorCode, 'rehearsals_timeout');
      expect(c.page, isNull);
      gate.complete(response(relatedPage()));
      await t.pump();
      expect(c.page, isNull);
    },
  );
  test('monotonic deadline checked after response even before delayed timer executes', () async {
    c.dispose();
    var clock = Duration.zero;
    c = make(elapsed: () => clock);
    handler = (_) async {
      clock = const Duration(seconds: 8);
      return response(relatedPage());
    };
    await c.refresh();
    expect(c.errorCode, 'rehearsals_timeout');
    expect(c.page, isNull);
  });
}
