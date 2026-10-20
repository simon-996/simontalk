import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';

import 'practice_fixtures.dart';
import 'practice_recovery_controller_test.dart' show ReadClient;

Map<String, dynamic> textEvent(
  int sequence, {
  int? turn,
  int revision = 1,
  String text = 'saved final text.',
}) => {
  'event_id': '77777777-7777-4777-8777-${sequence.toString().padLeft(12, '0')}',
  'sequence': sequence,
  'turn_id':
      '88888888-8888-4888-8888-${(turn ?? sequence).toString().padLeft(12, '0')}',
  'turn_index': turn ?? sequence,
  'role': 'user',
  'revision': revision,
  'text': text,
  'response_id': null,
  'provider_item_id': null,
  'received_at': '2026-10-20T00:00:00Z',
  'delivery_status': null,
};

Map<String, dynamic> textPage(
  List<Map<String, dynamic>> events, {
  int? total,
  int? last,
  bool more = false,
  int after = 0,
  int? bytes,
}) => {
  'source': 'client_reported',
  'account_id': accountId,
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'last_sequence': last ?? (events.isEmpty ? 0 : events.last['sequence']),
  'total_events': total ?? events.length,
  'total_text_bytes':
      bytes ??
      events.fold<int>(
        0,
        (n, e) => n + utf8.encode(e['text'] as String).length,
      ),
  'events': events,
  'next_after_sequence': events.isEmpty ? after : events.last['sequence'],
  'has_more': more,
};

void main() {
  late ApiClient source;
  late PracticeRecoveryController controller;
  late List<ReadClient> clients;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  var elapsed = Duration.zero;

  setUp(() {
    clients = [];
    requests = [];
    elapsed = Duration.zero;
    handler = (_) async => response({
      'practice': practiceJson(status: 'interrupted', epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    source = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    controller = PracticeRecoveryController(
      api: source,
      accountId: accountId,
      elapsed: () => elapsed,
      httpClientFactory: () {
        final client = ReadClient((r) async {
          requests.add(r);
          return handler(r);
        });
        clients.add(client);
        return client;
      },
    );
  });

  tearDown(() {
    controller.dispose();
    source.close();
  });

  Future<void> loaded() async {
    await controller.refresh();
    handler = (_) async => response(textPage([textEvent(1)]));
    await controller.loadTranscripts();
    expect(controller.transcripts!.turns.single.text, 'saved final text.');
  }

  test('constructor and absent connection cannot read final text', () async {
    expect(controller.transcripts, isNull);
    await controller.loadTranscripts();
    expect(requests, isEmpty);
    handler = (_) async => response({'practice': null, 'connection': null});
    await controller.refresh();
    await controller.loadTranscripts();
    expect(requests, hasLength(1));
    expect(controller.transcripts, isNull);
  });

  test('explicit read only GETs original account and keeps unknown lifecycle', () async {
    await loaded();
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    final r = requests.last;
    expect(
      r.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/transcripts',
    );
    expect(r.url.queryParameters, {'after_sequence': '0', 'limit': '32'});
    expect(r.headers['X-Account-ID'], accountId);
    expect(controller.recovery!.connection!.safelyEnded, isFalse);
    expect(clients.every((c) => c.closed), isTrue);
    expect(controller.transcripts!.hasMore, isFalse);
    await controller.loadTranscripts();
    expect(requests, hasLength(2));
    expect(
      () => controller.transcripts!.events.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'page retry preserves original cursor and rebuilds later empty revision',
    () async {
      await controller.refresh();
      handler = (_) async => response(
        textPage(
          [for (var i = 1; i <= 32; i++) textEvent(i)],
          total: 33,
          last: 35,
          more: true,
          bytes: 544,
        ),
      );
      await controller.loadTranscripts();
      final original = controller.transcripts;
      expect(original!.events, hasLength(32));
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      await controller.loadTranscripts();
      expect(controller.transcriptErrorCode, 'service_unavailable');
      expect(controller.transcripts, same(original));
      handler = (_) async => response(
        textPage(
          [textEvent(35, turn: 1, revision: 2, text: '')],
          total: 33,
          last: 35,
          bytes: 544,
        ),
      );
      await controller.loadTranscripts();
      expect(requests[2].url.queryParameters['after_sequence'], '32');
      expect(requests[3].url.queryParameters['after_sequence'], '32');
      final now = controller.transcripts!;
      expect(now.events, hasLength(33));
      expect(now.turns, hasLength(32));
      expect(now.turns.first.revision, 2);
      expect(now.turns.first.text, '');
      expect(now.hasSequenceGaps, isTrue);
      expect(now.hasMore, isFalse);
      expect(controller.transcriptErrorCode, isNull);
      expect(original.turns.first.text, 'saved final text.');
    },
  );

  test(
    'bad later page preserves the entire accepted snapshot atomically',
    () async {
      await controller.refresh();
      handler = (_) async => response(
        textPage(
          [for (var i = 1; i <= 32; i++) textEvent(i)],
          total: 34,
          last: 34,
          more: true,
          bytes: 578,
        ),
      );
      await controller.loadTranscripts();
      final original = controller.transcripts;
      final bad = textEvent(
        34,
        turn: 1,
      ); // same turn revision was already accepted
      handler = (_) async =>
          response(textPage([textEvent(33), bad], total: 34, bytes: 578));
      await controller.loadTranscripts();
      expect(controller.transcriptErrorCode, 'invalid_response');
      expect(controller.transcripts, same(original));
      expect(controller.transcripts!.turns, hasLength(32));
    },
  );

  test(
    'refresh text clears prior text before request and starts at zero',
    () async {
      await loaded();
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final pending = controller.loadTranscripts(refresh: true);
      expect(controller.transcripts, isNull);
      expect(controller.loadingTranscripts, isTrue);
      waiting.complete(response({'code': 'service_unavailable'}, 503));
      await pending;
      expect(requests.last.url.queryParameters['after_sequence'], '0');
      expect(controller.transcripts, isNull);
      expect(controller.recovery, isNotNull);
      expect(controller.transcriptErrorCode, 'service_unavailable');
    },
  );

  test('global refresh clears text and never reads it automatically', () async {
    await loaded();
    handler = (_) async => response({'practice': null, 'connection': null});
    await controller.refresh();
    expect(requests, hasLength(3));
    expect(controller.transcripts, isNull);
    expect(controller.transcriptErrorCode, isNull);
  });

  test(
    'read errors keep login and accepted text, 401 clears all old content',
    () async {
      await loaded();
      handler = (_) async =>
          throw http.ClientException('private response body');
      await controller.loadTranscripts(refresh: true);
      expect(controller.transcriptErrorCode, 'network_error');
      expect(source.hasCurrentAccount(accountId), isTrue);
      handler = (_) async => response(textPage([textEvent(1)]));
      await controller.loadTranscripts();
      handler = (_) async => response({'code': 'unauthorized'}, 401);
      await controller.loadTranscripts(refresh: true);
      expect(controller.errorCode, 'unauthorized');
      expect(controller.recovery, isNull);
      expect(controller.transcripts, isNull);
    },
  );

  for (final code in ['practice_not_found', 'connection_not_found']) {
    test(
      'deleted $code clears original scope without automatic refresh',
      () async {
        await loaded();
        handler = (_) async => response({'code': code}, 404);
        await controller.loadTranscripts(refresh: true);
        expect(controller.recovery, isNull);
        expect(controller.transcripts, isNull);
        expect(controller.errorCode, code);
        expect(requests, hasLength(3));
      },
    );
  }

  test(
    'raw account change synchronously clears getter text and cancels late page',
    () async {
      await loaded();
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final pending = controller.loadTranscripts(refresh: true);
      await Future<void>.delayed(Duration.zero);
      source.expectedAccountId = requestKey;
      expect(controller.transcripts, isNull);
      expect(controller.recovery, isNull);
      expect(controller.errorCode, 'account_changed');
      await pending;
      waiting.complete(
        response(textPage([textEvent(1, text: 'late private text')])),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.transcripts, isNull);
      expect(clients.last.closed, isTrue);
      await controller.loadTranscripts();
      expect(requests, hasLength(3));
    },
  );

  test('account change clears an already visible idle text snapshot', () async {
    await loaded();
    source.expectedAccountId = requestKey;
    expect(controller.transcripts, isNull);
    source.expectedAccountId = accountId;
    expect(controller.transcripts, isNull);
  });

  test(
    'operations share one in-flight read and never silently queue actions',
    () async {
      await controller.refresh();
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final first = controller.loadTranscripts();
      expect(controller.loadTranscripts(), same(first));
      expect(controller.refresh(), same(first));
      expect(controller.loadObservations(), same(first));
      waiting.complete(response(textPage([textEvent(1)])));
      await first;
      expect(requests, hasLength(2));
      expect(controller.loadingTranscripts, isFalse);
      expect(controller.busy, isFalse);
    },
  );

  test('elapsed deadline rejects a late successful text response and retains login', () async {
    await controller.refresh();
    final waiting = Completer<http.Response>();
    handler = (_) => waiting.future;
    final pending = controller.loadTranscripts();
    await Future<void>.delayed(Duration.zero);
    elapsed = const Duration(seconds: 8);
    waiting.complete(response(textPage([textEvent(1)])));
    await pending;
    expect(controller.transcripts, isNull);
    expect(controller.transcriptErrorCode, 'network_error');
    expect(source.hasCurrentAccount(accountId), isTrue);
  });

  testWidgets(
    'text-specific stalled request ends at eight seconds and rejects late data',
    (tester) async {
      await controller.refresh();
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final pending = controller.loadTranscripts();
      await tester.pump();
      expect(controller.loadingTranscripts, isTrue);
      await tester.pump(const Duration(seconds: 8));
      await pending;
      expect(controller.transcriptErrorCode, 'network_error');
      expect(controller.busy, isFalse);
      expect(controller.loadingTranscripts, isFalse);
      expect(clients.last.closed, isTrue);
      waiting.complete(response(textPage([textEvent(1, text: 'late text')])));
      await tester.pump();
      expect(controller.transcripts, isNull);
    },
  );

  for (final status in [200, 409, 503]) {
    test(
      'explicit cleanup result $status clears all previously read text',
      () async {
        handler = (_) async => response({
          'practice': practiceJson(status: 'connecting', epoch: 1),
          'connection': connectionJson(),
        });
        await controller.refresh();
        final original = controller.recovery!.practice!;
        expect(controller.recovery!.canDiscardPreparation, isTrue);
        handler = (_) async => response(textPage([textEvent(1)]));
        await controller.loadTranscripts();
        expect(controller.transcripts, isNotNull);
        handler = (r) async {
          if (r.url.path.endsWith('/csrf')) {
            return response({'csrf_token': 'scope-csrf'});
          }
          return status == 200
              ? response(practiceJson(status: 'cancelled', epoch: 1))
              : response({
                  'code': status == 409
                      ? 'preparation_not_discardable'
                      : 'service_unavailable',
                }, status);
        };
        await controller.discardPreparation(original);
        expect(controller.transcripts, isNull);
        expect(controller.recovery, isNull);
        expect(
          controller.cleanupStatus,
          status == 200
              ? PreparationCleanupStatus.succeeded
              : status == 409
              ? PreparationCleanupStatus.refused
              : PreparationCleanupStatus.unconfirmed,
        );
      },
    );
  }

  test('dispose settles blocked read and never publishes late text', () async {
    await controller.refresh();
    final waiting = Completer<http.Response>();
    handler = (_) => waiting.future;
    final pending = controller.loadTranscripts();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    await pending;
    expect(controller.transcripts, isNull);
    expect(clients.last.closed, isTrue);
    expect(source.hasCurrentAccount(accountId), isTrue);
    waiting.complete(response(textPage([textEvent(1, text: 'late text')])));
    await Future<void>.delayed(Duration.zero);
    expect(controller.transcripts, isNull);
  });
}
