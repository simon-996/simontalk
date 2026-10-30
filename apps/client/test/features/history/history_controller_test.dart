import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/history/history_controller.dart';

import 'history_fixtures.dart';

void main() {
  late ApiClient api;
  late HistoryController c;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  HistoryController make({String? id, Duration Function()? elapsed}) =>
      HistoryController(
        accountApi: api,
        accountId: accountId,
        sessionId: id,
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
      historyPage(page: r.url.queryParameters.containsKey('cursor') ? 1 : 0),
    );
    c = make();
  });
  tearDown(() {
    c.dispose();
    api.close();
  });
  test(
    'silent construction, owner GET single flight and reversible pages',
    () async {
      expect(requests, isEmpty);
      final first = c.refresh();
      expect(identical(first, c.refresh()), isTrue);
      await first;
      expect(c.page!.items.first.id, historyId(21));
      await c.next();
      expect(c.pageNumber, 2);
      expect(c.page!.items.first.id, historyId(11));
      await c.previous();
      expect(c.pageNumber, 1);
      expect(requests, hasLength(3));
      expect(
        requests.every(
          (r) => r.method == 'GET' && r.headers['X-Account-ID'] == accountId,
        ),
        isTrue,
      );
    },
  );
  test(
    'page network failure retains current data and position; refresh clears',
    () async {
      await c.refresh();
      handler = (_) async => throw http.ClientException('offline');
      await c.next();
      expect(c.pageNumber, 1);
      expect(c.page, isNotNull);
      expect(c.errorCode, 'network_error');
      final work = c.refresh();
      expect(c.page, isNull);
      await work;
      expect(c.page, isNull);
    },
  );
  for (final code in [401, 404, 409, 200]) {
    test('non-transient $code rejects old page', () async {
      await c.refresh();
      handler = (_) async => response({
        'code': code == 409 ? 'account_changed' : 'practice_not_found',
      }, code);
      await c.next();
      expect(c.page, isNull);
    });
  }
  test(
    'dispose cancels unresolved read and late reply cannot publish',
    () async {
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final work = c.refresh();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      await work;
      pending.complete(response(historyPage()));
      await Future<void>.delayed(Duration.zero);
      expect(c.page, isNull);
    },
  );
  test('identity change clears old data and rejects late page', () async {
    await c.refresh();
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    final work = c.next();
    await Future<void>.delayed(Duration.zero);
    api.expectedAccountId = historyId(99);
    expect(c.page, isNull);
    await work;
    pending.complete(response(historyPage(page: 1)));
    expect(c.errorCode, 'account_changed');
  });
  test('operation elapsed deadline rejects received result', () async {
    c.dispose();
    var elapsed = Duration.zero;
    c = make(elapsed: () => elapsed);
    handler = (_) async {
      elapsed = const Duration(seconds: 8);
      return response(historyPage());
    };
    await c.refresh();
    expect(c.page, isNull);
    expect(c.errorCode, 'history_timeout');
  });
  test('detail reads one summary and no content endpoints', () async {
    c.dispose();
    c = make(id: historyId(1));
    handler = (_) async => response(historyDetail(1, sealed: true));
    await c.refresh();
    expect(c.item!.isSealed, isTrue);
    expect(requests.single.url.path, '/v1/practice-history/${historyId(1)}');
    await c.next();
    expect(requests, hasLength(1));
  });
  test('invalid address makes zero requests', () async {
    c.dispose();
    c = make(id: 'invalid');
    await c.refresh();
    expect(requests, isEmpty);
    expect(c.errorCode, 'invalid_source');
  });
  testWidgets(
    'eight second wall timer ends unresolved read and ignores its late result',
    (t) async {
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      final work = c.refresh();
      await t.pump();
      await t.pump(const Duration(seconds: 8));
      await work;
      expect(c.busy, isFalse);
      expect(c.errorCode, 'history_timeout');
      pending.complete(response(historyPage()));
      await t.pump();
      expect(c.page, isNull);
    },
  );
  test(
    'next page cannot repeat or move above its requested seek boundary',
    () async {
      await c.refresh();
      handler = (_) async => response(historyPage());
      await c.next();
      expect(c.page, isNull);
      expect(c.errorCode, 'invalid_response');
    },
  );
}
