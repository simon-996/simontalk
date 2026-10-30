import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_controller.dart';

import '../practice/practice_completion_test.dart' show completionSummary;
import '../realtime/api_realtime_signaller_test.dart' show TrackedClient;
import 'transcript_fixtures.dart';

void main() {
  late ApiClient api;
  late SavedTranscriptController c;
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) handler;
  SavedTranscriptController make({
    String? item,
    Duration Function()? elapsed,
    http.Client? client,
    String session = practiceId,
  }) => SavedTranscriptController(
    accountApi: api,
    accountId: accountId,
    sessionId: session,
    reviewItemId: item,
    elapsed: elapsed,
    httpClientFactory: () =>
        client ??
        MockClient((r) {
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
      r.url.path.endsWith('completion')
          ? completionSummary(sealed: true)
          : pageJson(
              total: 23,
              offset: int.parse(r.url.queryParameters['offset'] ?? '0'),
            ),
    );
    c = make();
  });
  tearDown(() {
    c.dispose();
    api.close();
  });
  test('construction is silent; first read needs only owner completion and page; holds one page', () async {
    c.addListener(() {});
    expect(requests, isEmpty);
    await c.refresh();
    expect(requests, hasLength(2));
    expect(
      requests.every(
        (r) => r.method == 'GET' && r.headers['X-Account-ID'] == accountId,
      ),
      isTrue,
    );
    expect(requests.last.url.queryParameters.containsKey('offset'), isFalse);
    expect(c.page!.items, hasLength(16));
    await c.next();
    expect(c.page!.items, hasLength(7));
    expect(c.page!.offset, 16);
    expect(requests, hasLength(3));
    await c.previous();
    expect(c.page!.offset, 0);
  });
  test(
    'initial focus omits offset and paging and return keep item identity',
    () async {
      c.dispose();
      c = make(item: itemId);
      handler = (r) async => response(
        r.url.path.endsWith('completion')
            ? completionSummary(sealed: true)
            : pageJson(
                total: 23,
                offset: int.parse(r.url.queryParameters['offset'] ?? '18'),
                focus: true,
                focusOrdinal: 19,
              ),
      );
      await c.refresh();
      expect(c.page!.offset, 18);
      await c.previous();
      expect(c.page!.offset, 2);
      await c.focus();
      expect(c.page!.offset, 18);
      expect(
        requests
            .where((r) => r.url.path.endsWith('saved-transcript'))
            .every((r) => r.url.queryParameters['review_item_id'] == itemId),
        isTrue,
      );
      expect(requests.last.url.queryParameters.containsKey('offset'), isFalse);
    },
  );
  test('all repeated operations reuse the outer single flight', () async {
    final wait = Completer<http.Response>();
    handler = (_) => wait.future;
    final task = c.refresh();
    expect(c.refresh(), same(task));
    expect(c.next(), same(task));
    expect(c.previous(), same(task));
    await Future<void>.delayed(Duration.zero);
    wait.completeError(http.ClientException('offline'));
    await task;
    expect(requests, hasLength(1));
  });
  test('paging network failure keeps accepted page and original cursor; refresh clears synchronously', () async {
    await c.refresh();
    final first = c.page;
    handler = (_) async => throw http.ClientException('offline');
    await c.next();
    expect(c.page, same(first));
    expect(c.page!.nextOffset, 16);
    expect(c.errorCode, 'network_error');
    handler = (r) async => response(pageJson(total: 23, offset: 16));
    await c.next();
    expect(requests.last.url.queryParameters['offset'], '16');
    expect(c.page!.offset, 16);
    final work = c.refresh();
    expect(c.page, isNull);
    await work;
    expect(c.page, isNull);
  });
  for (final failure in [
    (401, 'unauthorized'),
    (404, 'review_item_not_found'),
    (409, 'saved_transcript_changed'),
    (409, 'saved_transcript_limit_exceeded'),
    (200, 'malformed'),
  ]) {
    test(
      'paging source/identity failure clears previous page: $failure',
      () async {
        await c.refresh();
        handler = (_) async => failure.$1 == 200
            ? response({
                ...pageJson(total: 23, offset: 16),
                'practice_input_hash': 'b' * 64,
              })
            : http.Response('{"code":"${failure.$2}"}', failure.$1);
        await c.next();
        expect(c.page, isNull);
        expect(
          c.errorCode,
          failure.$1 == 200 ? 'invalid_response' : failure.$2,
        );
      },
    );
  }
  for (final change in ['total', 'sealed', 'coverage', 'focus']) {
    test('page immutable anchor rejects $change atomically', () async {
      c.dispose();
      c = make(item: itemId);
      handler = (r) async => response(
        r.url.path.endsWith('completion')
            ? completionSummary(sealed: true)
            : pageJson(total: 23, focus: true),
      );
      await c.refresh();
      expect(c.page, isNotNull);
      handler = (_) async {
        final j = pageJson(
          total: change == 'total' ? 24 : 23,
          offset: 16,
          focus: true,
        );
        if (change == 'sealed') j['sealed_at'] = '2026-10-21T08:00:04Z';
        if (change == 'coverage') {
          j['coverage'] = 'complete';
          j['gap_codes'] = <String>[];
        }
        if (change == 'focus') j['focus']['result_hash'] = 'd' * 64;
        return response(j);
      };
      await c.next();
      expect(c.page, isNull);
      expect(c.errorCode, 'saved_transcript_changed');
    });
  }
  test(
    'initial page metadata must match the confirmed sealed source',
    () async {
      handler = (r) async {
        if (r.url.path.endsWith('completion')) {
          return response(completionSummary(sealed: true));
        }
        final j = pageJson();
        j['sealed_at'] = '2026-10-21T08:00:04Z';
        return response(j);
      };
      await c.refresh();
      expect(c.page, isNull);
      expect(c.errorCode, 'saved_transcript_changed');
    },
  );
  test('invalid source and unsealed never read a page', () async {
    c.dispose();
    c = make(session: 'invalid');
    await c.refresh();
    expect(requests, isEmpty);
    c.dispose();
    c = make();
    handler = (_) async => response(completionSummary());
    await c.refresh();
    expect(requests, hasLength(1));
    expect(c.errorCode, 'completion_not_sealed');
  });
  test('completion and page have one total eight second deadline', () async {
    c.dispose();
    var elapsed = Duration.zero;
    c = make(elapsed: () => elapsed);
    handler = (r) async {
      if (r.url.path.endsWith('completion')) {
        elapsed = const Duration(seconds: 7);
        return response(completionSummary(sealed: true));
      }
      elapsed = const Duration(seconds: 8);
      return response(pageJson());
    };
    await c.refresh();
    expect(c.errorCode, 'transcript_timeout');
    expect(c.page, isNull);
    expect(requests, hasLength(2));
  });
  test('late completion at elapsed deadline starts no page', () async {
    c.dispose();
    var elapsed = Duration.zero;
    c = make(elapsed: () => elapsed);
    handler = (_) async {
      elapsed = const Duration(seconds: 8);
      return response(completionSummary(sealed: true));
    };
    await c.refresh();
    expect(c.errorCode, 'transcript_timeout');
    expect(requests, hasLength(1));
  });
  for (final paging in [false, true]) {
    testWidgets(
      'eight seconds closes operation and ignores late data: paging=$paging',
      (tester) async {
        if (paging) await c.refresh();
        final accepted = c.page;
        c.dispose();
        final wait = Completer<http.Response>();
        final owned = TrackedClient((r) {
          requests.add(r);
          return wait.future;
        });
        c = make(client: owned);
        if (paging) {
          c.dispose();
          var reading = false;
          c = make(
            client: TrackedClient((r) {
              requests.add(r);
              if (!reading) {
                return Future.value(
                  response(
                    r.url.path.endsWith('completion')
                        ? completionSummary(sealed: true)
                        : pageJson(total: 23),
                  ),
                );
              }
              return wait.future;
            }),
          );
          await c.refresh();
          reading = true;
        }
        final work = paging ? c.next() : c.refresh();
        await tester.pump();
        await tester.pump(const Duration(seconds: 8));
        await work;
        expect(c.errorCode, 'transcript_timeout');
        if (paging) {
          expect(c.page!.offset, 0);
        } else {
          expect(c.page, isNull);
          expect(owned.closes, 1);
        }
        final count = requests.length;
        wait.complete(
          response(
            paging
                ? pageJson(total: 23, offset: 16)
                : completionSummary(sealed: true),
          ),
        );
        await tester.pump();
        expect(requests, hasLength(count));
        expect(c.page?.offset, paging ? 0 : null);
        expect(accepted?.offset, paging ? 0 : null);
      },
    );
  }
  for (final switchAccount in [true, false]) {
    test(
      'account getter and dispose cancel pending and never follow up: $switchAccount',
      () async {
        final wait = Completer<http.Response>();
        handler = (_) => wait.future;
        final task = c.refresh();
        await Future<void>.delayed(Duration.zero);
        if (switchAccount) {
          api.expectedAccountId = requestKey;
          expect(c.page, isNull);
        } else {
          c.dispose();
        }
        await task;
        expect(c.page, isNull);
        wait.complete(response(completionSummary(sealed: true)));
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1));
      },
    );
  }
  test('account getter clears accepted page without new HTTP', () async {
    await c.refresh();
    api.expectedAccountId = requestKey;
    expect(c.page, isNull);
    expect(c.errorCode, 'account_changed');
    expect(c.state, SavedTranscriptState.aborted);
    await c.refresh();
    expect(requests, hasLength(2));
  });
}
