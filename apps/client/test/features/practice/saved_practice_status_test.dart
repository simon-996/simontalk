import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_controller.dart';

import '../history/history_fixtures.dart';
import 'practice_completion_test.dart' show completionSummary;

Map<String, dynamic> saveStatusDetail({String stage = 'sealed'}) => {
  ...historyDetail(222222222222, sealed: stage == 'sealed'),
  'item': {
    ...historyItem(222222222222, sealed: stage == 'sealed'),
    'completion_status': stage,
    'coverage': stage == 'sealed'
        ? 'incomplete'
        : stage == 'ending'
        ? 'pending'
        : null,
    'connection_pending': true,
  },
};

void main() {
  late ApiClient api;
  late SavedPracticeStatusController c;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  SavedPracticeStatusController make({Duration Function()? elapsed}) =>
      SavedPracticeStatusController(
        accountApi: api,
        accountId: accountId,
        sessionId: practiceId,
        elapsed: elapsed,
        httpClientFactory: () => MockClient((r) {
          requests.add(r);
          return handler(r);
        }),
      );
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  setUp(() {
    requests.clear();
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (r) async => response(
      r.url.path.endsWith('/completion')
          ? completionSummary(sealed: true)
          : saveStatusDetail(),
    );
    c = make();
  });
  tearDown(() {
    c.dispose();
    api.close();
  });

  test(
    'construction is silent; two owner GETs publish one complete snapshot',
    () async {
      expect(requests, isEmpty);
      expect(c.state, SavedPracticeStatusState.idle);
      final task = c.refresh();
      expect(identical(task, c.refresh()), isTrue);
      await task;
      expect(c.state, SavedPracticeStatusState.ready);
      expect(c.item!.connectionPending, isTrue);
      expect(c.completion!.gapCodes, ['tail_unconfirmed']);
      expect(requests.map((r) => r.url.path), [
        '/v1/practice-history/$practiceId',
        '/v1/practice-sessions/$practiceId/completion',
      ]);
      expect(
        requests.every(
          (r) => r.method == 'GET' && r.headers['X-Account-ID'] == accountId,
        ),
        isTrue,
      );
    },
  );

  test(
    'unregistered requires an explicit missing completion after owned detail',
    () async {
      handler = (r) async => r.url.path.endsWith('/completion')
          ? response({'code': 'completion_not_found'}, 404)
          : response(saveStatusDetail(stage: 'unregistered'));
      await c.refresh();
      expect(c.state, SavedPracticeStatusState.ready);
      expect(c.item!.completionStatus, 'unregistered');
      expect(c.completion, isNull);
      expect(c.errorCode, isNull);
      expect(requests, hasLength(2));
    },
  );

  for (final stage in ['ending', 'sealed']) {
    test('$stage is displayed only after both GETs agree', () async {
      handler = (r) async => response(
        r.url.path.endsWith('/completion')
            ? completionSummary(sealed: stage == 'sealed')
            : saveStatusDetail(stage: stage),
      );
      await c.refresh();
      expect(c.state, SavedPracticeStatusState.ready);
      expect(c.item!.completionStatus, stage);
      expect(c.completion!.status.name, stage);
      expect(requests, hasLength(2));
      await tick();
      expect(requests, hasLength(2));
    });
  }

  test('complete coverage retains its exact empty gaps', () async {
    handler = (r) async {
      if (r.url.path.endsWith('/completion')) {
        return response({
          ...completionSummary(sealed: true),
          'coverage': 'complete',
          'gap_codes': [],
        });
      }
      final detail = saveStatusDetail();
      (detail['item'] as Map<String, dynamic>)['coverage'] = 'complete';
      return response(detail);
    };
    await c.refresh();
    expect(c.state, SavedPracticeStatusState.ready);
    expect(c.completion!.coverage.name, 'complete');
    expect(c.completion!.gapCodes, isEmpty);
  });

  for (final change in ['stage', 'coverage', 'missing']) {
    test('inconsistent $change never publishes a mixed snapshot', () async {
      handler = (r) async {
        if (r.url.path.endsWith('/completion')) {
          return change == 'missing'
              ? response({'code': 'completion_not_found'}, 404)
              : response(completionSummary(sealed: true));
        }
        final detail = saveStatusDetail(
          stage: change == 'stage' ? 'ending' : 'sealed',
        );
        if (change == 'coverage') {
          (detail['item'] as Map<String, dynamic>)['coverage'] = 'complete';
        }
        return response(detail);
      };
      await c.refresh();
      expect(c.state, SavedPracticeStatusState.failed);
      expect(c.errorCode, 'save_status_changed');
      expect(c.item, isNull);
      expect(c.completion, isNull);
    });
  }

  for (final endpoint in ['detail', 'completion']) {
    for (final change in ['owner', 'target', 'format']) {
      test('$endpoint rejects wrong $change without publishing', () async {
        handler = (r) async {
          final detail = !r.url.path.endsWith('/completion');
          final json = detail
              ? saveStatusDetail()
              : completionSummary(sealed: true);
          if ((detail ? 'detail' : 'completion') == endpoint) {
            if (change == 'owner') json['account_id'] = historyId(99);
            if (change == 'target') {
              if (detail) {
                (json['item'] as Map<String, dynamic>)['id'] = historyId(99);
              } else {
                json['session_id'] = historyId(99);
              }
            }
            if (change == 'format') json.clear();
          }
          return response(json);
        };
        await c.refresh();
        expect(c.state, SavedPracticeStatusState.failed);
        expect(c.errorCode, 'invalid_response');
        expect(c.item, isNull);
        expect(c.completion, isNull);
        if (endpoint == 'detail') expect(requests, hasLength(1));
      });
    }
  }

  test(
    'refresh clears prior success immediately and network failure retains none',
    () async {
      await c.refresh();
      handler = (_) async => throw http.ClientException('offline');
      final task = c.refresh();
      expect(c.item, isNull);
      expect(c.completion, isNull);
      await task;
      expect(c.state, SavedPracticeStatusState.failed);
      expect(c.errorCode, 'network_error');
      expect(c.item, isNull);
    },
  );

  for (final status in [401, 404, 409]) {
    test('$status source loss clears accepted state', () async {
      await c.refresh();
      handler = (_) async => response({
        'code': status == 409 ? 'account_changed' : 'practice_not_found',
      }, status);
      await c.refresh();
      expect(c.item, isNull);
      expect(c.completion, isNull);
      expect(
        c.state,
        status == 404
            ? SavedPracticeStatusState.unavailable
            : SavedPracticeStatusState.aborted,
      );
    });
  }

  for (final endpoint in ['detail', 'completion']) {
    test(
      'dispose cancels pending $endpoint and ignores late success',
      () async {
        final pending = Completer<http.Response>();
        handler = (r) async =>
            (r.url.path.endsWith('/completion') ? 'completion' : 'detail') ==
                endpoint
            ? pending.future
            : response(saveStatusDetail());
        final task = c.refresh();
        await tick();
        c.dispose();
        await task;
        pending.complete(
          response(
            endpoint == 'detail'
                ? saveStatusDetail()
                : completionSummary(sealed: true),
          ),
        );
        await tick();
        expect(c.item, isNull);
        expect(c.completion, isNull);
        expect(requests, hasLength(endpoint == 'detail' ? 1 : 2));
      },
    );
  }

  test('identity change between GETs stops the second request', () async {
    handler = (_) async {
      api.expectedAccountId = historyId(99);
      return response(saveStatusDetail());
    };
    await c.refresh();
    expect(c.state, SavedPracticeStatusState.aborted);
    expect(c.item, isNull);
    expect(requests, hasLength(1));
  });

  test('identity loss clears successful values through getters', () async {
    await c.refresh();
    api.expectedAccountId = historyId(99);
    expect(c.item, isNull);
    expect(c.completion, isNull);
    expect(c.state, SavedPracticeStatusState.aborted);
    expect(c.errorCode, 'account_changed');
  });

  for (final endpoint in ['detail', 'completion']) {
    test(
      'eight second elapsed boundary after $endpoint prevents publication',
      () async {
        c.dispose();
        var elapsed = Duration.zero;
        c = make(elapsed: () => elapsed);
        handler = (r) async {
          final detail = !r.url.path.endsWith('/completion');
          if ((detail ? 'detail' : 'completion') == endpoint) {
            elapsed = const Duration(seconds: 8);
          }
          return response(
            detail ? saveStatusDetail() : completionSummary(sealed: true),
          );
        };
        await c.refresh();
        expect(c.state, SavedPracticeStatusState.failed);
        expect(c.errorCode, 'save_status_timeout');
        expect(c.item, isNull);
        expect(requests, hasLength(endpoint == 'detail' ? 1 : 2));
      },
    );
  }

  testWidgets('pending completion shares the original eight second timer', (
    t,
  ) async {
    final pending = Completer<http.Response>();
    handler = (r) async => r.url.path.endsWith('/completion')
        ? pending.future
        : response(saveStatusDetail());
    final task = c.refresh();
    await t.pump();
    await t.pump(const Duration(seconds: 8));
    await task;
    expect(c.errorCode, 'save_status_timeout');
    pending.complete(response(completionSummary(sealed: true)));
    await t.pump();
    expect(c.completion, isNull);
  });
}
