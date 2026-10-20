import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/final_transcript_read_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

import '../practice/practice_fixtures.dart';
import 'final_transcript_read_fixtures.dart';

FinalTranscriptPage readPage(
  Map<String, dynamic> json, {
  ConversationScope? scope,
  int after = 0,
  int limit = 32,
}) => FinalTranscriptPage.fromJson(
  json,
  scope: scope ?? transcriptScope(),
  afterSequence: after,
  limit: limit,
);

void main() {
  group('event parsing', () {
    test('normalizes IDs, UTC time and preserves empty final text', () {
      final json = transcriptEventJson(
        1,
        text: '',
        role: ConversationRole.assistant,
        providerItemId: '😀' * 256,
      );
      json['event_id'] = 'ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF';
      final event = FinalTranscriptEvent.fromJson(json);
      expect(event.eventId, 'abcdefab-abcd-4abc-8abc-abcdefabcdef');
      expect(event.receivedAt, DateTime.utc(2026, 10, 20, 0, 0, 0, 123, 456));
      expect(event.text, '');
      expect(event.deliveryStatus, DeliveryStatus.unknown);
      expect(event.providerItemId!.runes.length, 256);
      expect(
        FinalTranscriptEvent.fromJson(transcriptEventJson(2)).deliveryStatus,
        isNull,
      );
    });

    final changes = <String, void Function(Map<String, dynamic>)>{
      'event ID': (j) => j['event_id'] = 'private-invalid',
      'turn ID': (j) => j['turn_id'] = null,
      'bool sequence': (j) => j['sequence'] = true,
      'double index': (j) => j['turn_index'] = 1.0,
      'string revision': (j) => j['revision'] = '1',
      'zero revision': (j) => j['revision'] = 0,
      'sequence overflow': (j) => j['sequence'] = 2147483648,
      'role': (j) => j['role'] = 'system',
      'text type': (j) => j['text'] = 42,
      'text NUL': (j) => j['text'] = 'private\u0000text',
      'text invalid Unicode': (j) => j['text'] = '\ud800',
      'text UTF8 bytes': (j) => j['text'] = '你' * 2731,
      'provider empty': (j) => j['provider_item_id'] = '',
      'provider Unicode length': (j) => j['provider_item_id'] = '😀' * 257,
      'provider NUL': (j) => j['provider_item_id'] = '\u0000',
      'provider invalid Unicode': (j) => j['provider_item_id'] = '\udfff',
      'provider type': (j) => j['provider_item_id'] = 4,
      'user response': (j) => j['response_id'] = requestKey,
      'user playback': (j) => j['delivery_status'] = 'unknown',
      'missing delivery status': (j) => j.remove('delivery_status'),
      'missing assistant response': (j) {
        j['role'] = 'assistant';
        j['delivery_status'] = 'unknown';
      },
      'assistant claimed played': (j) {
        j['role'] = 'assistant';
        j['response_id'] = requestKey;
        j['delivery_status'] = 'played';
      },
      'time without zone': (j) => j['received_at'] = '2026-10-20T00:00:00',
      'invalid calendar date': (j) => j['received_at'] = '2026-02-30T00:00:00Z',
      'invalid hour': (j) => j['received_at'] = '2026-10-20T24:00:00Z',
      'invalid minute': (j) => j['received_at'] = '2026-10-20T00:60:00Z',
      'invalid second': (j) => j['received_at'] = '2026-10-20T00:00:60Z',
      'invalid offset': (j) => j['received_at'] = '2026-10-20T00:00:00+24:00',
      'invalid offset minute': (j) =>
          j['received_at'] = '2026-10-20T00:00:00+08:60',
    };
    for (final change in changes.entries) {
      test('rejects ${change.key} without echoing private text', () {
        final json = transcriptEventJson(1, text: 'private-transcript');
        change.value(json);
        expect(
          () => FinalTranscriptEvent.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'safe error',
              isNot(contains('private')),
            ),
          ),
        );
      });
    }
    test('accepts exact UTF8 and positive integer boundaries', () {
      final event = FinalTranscriptEvent.fromJson(
        transcriptEventJson(
          2147483647,
          turnIndex: 2147483647,
          revision: 2147483647,
          text: '😀' * 2048,
        ),
      );
      expect(utf8.encode(event.text).length, 8192);
      expect(event.sequence, 2147483647);
    });
  });

  group('page parsing', () {
    test('keeps a bounded immutable snapshot and a valid past-end cursor', () {
      final page = readPage(transcriptPageJson());
      expect(page.scope.accountId, accountId);
      expect(page.events.map((e) => e.sequence), [1, 3]);
      expect(page.nextAfterSequence, 3);
      expect(() => page.events.clear(), throwsUnsupportedError);
      final past = readPage(
        transcriptPageJson(events: [], total: 2, last: 3, after: 7),
        after: 7,
      );
      expect(past.nextAfterSequence, 7);
      expect(past.hasMore, isFalse);
    });

    final changes = <String, void Function(Map<String, dynamic>)>{
      'source': (j) => j['source'] = 'server_verified',
      'account scope': (j) => j['account_id'] = requestKey,
      'practice scope': (j) => j['session_id'] = requestKey,
      'connection scope': (j) => j['connection_id'] = requestKey,
      'client scope': (j) => j['client_instance_id'] = requestKey,
      'epoch scope': (j) => j['epoch'] = 2,
      'epoch double': (j) => j['epoch'] = 1.0,
      'total limit': (j) => j['total_events'] = 513,
      'last below total': (j) => j['last_sequence'] = 1,
      'last empty contradiction': (j) => j['total_events'] = 0,
      'byte budget': (j) => j['total_text_bytes'] = 1048577,
      'byte per event budget': (j) => j['total_text_bytes'] = 16385,
      'bytes below actual': (j) => j['total_text_bytes'] = 1,
      'byte type': (j) => j['total_text_bytes'] = 1.0,
      'cursor': (j) => j['next_after_sequence'] = 2,
      'more type': (j) => j['has_more'] = 'false',
      'more contradictory': (j) => j['has_more'] = true,
      'duplicate event ID': (j) =>
          j['events'][1]['event_id'] = j['events'][0]['event_id'],
      'sequence order': (j) => j['events'][1]['sequence'] = 1,
      'first page omits known event': (j) => j['total_events'] = 3,
      'empty hides last': (j) => j['events'] = [],
      'invalid event shape': (j) => j['events'] = ['private-transcript'],
    };
    for (final change in changes.entries) {
      test('rejects ${change.key}', () {
        final json = transcriptPageJson();
        change.value(json);
        expect(() => readPage(json), throwsFormatException);
      });
    }
    test('rejects invalid query ranges in direct parser', () {
      for (final after in [-1, 2147483648]) {
        expect(
          () => readPage(transcriptPageJson(), after: after),
          throwsFormatException,
        );
      }
      for (final limit in [0, 33]) {
        expect(
          () => readPage(transcriptPageJson(), limit: limit),
          throwsFormatException,
        );
      }
    });
    test(
      'full first page cannot hide outstanding events behind a last cursor',
      () {
        final events = List.generate(32, (i) => transcriptEventJson(i + 1));
        expect(
          () =>
              readPage(transcriptPageJson(events: events, total: 33, last: 32)),
          throwsFormatException,
        );
        events.last['sequence'] = 40;
        expect(
          () =>
              readPage(transcriptPageJson(events: events, total: 33, last: 40)),
          throwsFormatException,
        );
      },
    );
    test('requires full nonfinal pages and events after request cursor', () {
      expect(
        () => readPage(
          transcriptPageJson(total: 3, last: 5, more: true),
          limit: 3,
        ),
        throwsFormatException,
      );
      expect(
        () => readPage(transcriptPageJson(), after: 1),
        throwsFormatException,
      );
    });
  });

  group('history reconstruction', () {
    test('uses greatest final revision, sorts turn indices and keeps gaps', () {
      final first = transcriptEventJson(
        1,
        turnIndex: 3,
        revision: 2,
        text: 'old',
      );
      final assistant = transcriptEventJson(
        4,
        turnIndex: 1,
        role: ConversationRole.assistant,
        text: 'generated',
      );
      final revised = transcriptEventJson(
        8,
        turnId: first['turn_id'],
        turnIndex: 3,
        revision: 4,
        text: '',
      );
      final initial = FinalTranscriptHistory.empty(transcriptScope());
      final partial = initial.append(
        readPage(
          transcriptPageJson(
            events: [first, assistant],
            total: 3,
            last: 8,
            totalBytes: 12,
            more: true,
          ),
          limit: 2,
        ),
      );
      final all = partial.append(
        readPage(
          transcriptPageJson(
            events: [revised],
            total: 3,
            last: 8,
            totalBytes: 12,
          ),
          after: 4,
        ),
      );
      expect(initial.events, isEmpty);
      expect(partial.events.length, 2);
      expect(partial.hasMore, isTrue);
      expect(all.events.length, 3);
      expect(all.turns.map((e) => e.turnIndex), [1, 3]);
      expect(all.turns.last.text, '');
      expect(all.turns.last.revision, 4);
      expect(all.turns.first.deliveryStatus, DeliveryStatus.unknown);
      expect(all.lastSequence, 8);
      expect(all.nextAfterSequence, 8);
      expect(all.totalTextBytes, 12);
      expect(all.totalEvents, 3);
      expect(all.hasMore, isFalse);
      expect(all.hasSequenceGaps, isTrue);
      expect(all.hasTurnIndexGaps, isTrue);
      expect(all.hasRevisionGaps, isTrue);
      expect(() => all.events.clear(), throwsUnsupportedError);
      expect(() => all.turns.clear(), throwsUnsupportedError);
    });
    test('does not invent gaps in empty or contiguous final facts', () {
      final empty = FinalTranscriptHistory.empty(transcriptScope());
      final history = empty.append(
        readPage(
          transcriptPageJson(
            events: [
              transcriptEventJson(1, text: 'a'),
              transcriptEventJson(2, text: 'b'),
            ],
          ),
        ),
      );
      for (final value in [empty, history]) {
        expect(value.hasSequenceGaps, isFalse);
        expect(value.hasTurnIndexGaps, isFalse);
        expect(value.hasRevisionGaps, isFalse);
      }
    });

    FinalTranscriptHistory partialHistory() =>
        FinalTranscriptHistory.empty(transcriptScope()).append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(1, text: 'a')],
              total: 2,
              last: 2,
              totalBytes: 2,
              more: true,
            ),
            limit: 1,
          ),
        );

    final conflicts = <String, void Function(Map<String, dynamic>)>{
      'event identity repeated': (j) =>
          j['events'][0]['event_id'] = transcriptEventJson(1)['event_id'],
      'turn index reused': (j) => j['events'][0]['turn_index'] = 1,
      'turn index changed': (j) {
        j['events'][0]['turn_id'] = transcriptEventJson(1)['turn_id'];
      },
      'revision reused': (j) {
        j['events'][0]['turn_id'] = transcriptEventJson(1)['turn_id'];
        j['events'][0]['turn_index'] = 1;
      },
      'provider changed': (j) {
        j['events'][0]['turn_id'] = transcriptEventJson(1)['turn_id'];
        j['events'][0]['turn_index'] = 1;
        j['events'][0]['revision'] = 2;
        j['events'][0]['provider_item_id'] = 'other';
      },
      'role changed': (j) {
        j['events'][0]['turn_id'] = transcriptEventJson(1)['turn_id'];
        j['events'][0]['turn_index'] = 1;
        j['events'][0]['revision'] = 2;
        j['events'][0]['role'] = 'assistant';
        j['events'][0]['response_id'] = requestKey;
        j['events'][0]['delivery_status'] = 'unknown';
      },
      'decreased byte watermark': (j) => j['total_text_bytes'] = 1,
      'same count changed bytes': (j) => j['total_text_bytes'] = 3,
      'extra terminal count': (j) {
        j['total_events'] = 3;
        j['last_sequence'] = 3;
        j['events'][0]['sequence'] = 3;
        j['next_after_sequence'] = 3;
      },
      'extra terminal bytes': (j) => j['total_text_bytes'] = 3,
    };
    for (final conflict in conflicts.entries) {
      test('rejects ${conflict.key} atomically across pages', () {
        final previous = partialHistory();
        final json = transcriptPageJson(
          events: [transcriptEventJson(2, text: 'b')],
          total: 2,
          last: 2,
          totalBytes: 2,
        );
        conflict.value(json);
        expect(
          () => previous.append(readPage(json, after: 1)),
          throwsFormatException,
        );
        expect(previous.events.length, 1);
        expect(previous.nextAfterSequence, 1);
        expect(previous.turns.single.text, 'a');
      });
    }
    test('rejects cross-scope page, wrong cursor and late-start history', () {
      final initial = FinalTranscriptHistory.empty(transcriptScope());
      final page = readPage(transcriptPageJson());
      expect(
        () => initial.append(
          readPage(
            transcriptPageJson(events: [], total: 2, last: 3, after: 9),
            after: 9,
          ),
        ),
        throwsFormatException,
      );
      final otherScope = ConversationScope(
        accountId: requestKey,
        sessionId: practiceId,
        connectionId: connectionId,
        clientInstanceId: clientId,
        epoch: 1,
      );
      expect(
        () => FinalTranscriptHistory.empty(otherScope).append(page),
        throwsFormatException,
      );
      expect(() => partialHistory().append(page), throwsFormatException);
    });
    test('rejects decreasing counts and impossible count growth', () {
      final previous = partialHistory();
      expect(
        () => previous.append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(2, text: 'b')],
              total: 1,
              last: 2,
              totalBytes: 2,
            ),
            after: 1,
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => previous.append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(2, text: 'b')],
              total: 3,
              last: 2,
              totalBytes: 3,
            ),
            after: 1,
          ),
        ),
        throwsFormatException,
      );
    });
    test('rejects response remapping without losing accepted AI text', () {
      final first = transcriptEventJson(
        1,
        role: ConversationRole.assistant,
        text: 'a',
      );
      final history = FinalTranscriptHistory.empty(transcriptScope()).append(
        readPage(
          transcriptPageJson(
            events: [first],
            total: 2,
            last: 2,
            totalBytes: 2,
            more: true,
          ),
          limit: 1,
        ),
      );
      final next = transcriptEventJson(
        2,
        turnId: first['turn_id'],
        turnIndex: 1,
        role: ConversationRole.assistant,
        responseId: clientId,
        revision: 2,
        text: 'b',
      );
      expect(
        () => history.append(
          readPage(
            transcriptPageJson(
              events: [next],
              total: 2,
              last: 2,
              totalBytes: 2,
            ),
            after: 1,
          ),
        ),
        throwsFormatException,
      );
      expect(history.turns.single.text, 'a');
    });
    test(
      'accepts appended server snapshots with consistent growing totals',
      () {
        final first = FinalTranscriptHistory.empty(transcriptScope()).append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(1, text: 'a')],
              total: 2,
              last: 3,
              totalBytes: 2,
              more: true,
            ),
            limit: 1,
          ),
        );
        final grown = first.append(
          readPage(
            transcriptPageJson(
              events: [
                transcriptEventJson(3, text: 'b'),
                transcriptEventJson(4, text: 'c'),
              ],
              total: 3,
              last: 4,
              totalBytes: 3,
            ),
            after: 1,
          ),
        );
        expect(grown.events.map((event) => event.sequence), [1, 3, 4]);
        expect(grown.totalEvents, 3);
        expect(grown.hasMore, isFalse);
      },
    );
    test('rejects impossible count growth against a prior large watermark', () {
      final first = FinalTranscriptHistory.empty(transcriptScope()).append(
        readPage(
          transcriptPageJson(
            events: [transcriptEventJson(1, text: 'a')],
            total: 2,
            last: 100,
            totalBytes: 2,
            more: true,
          ),
          limit: 1,
        ),
      );
      expect(
        () => first.append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(100, text: 'b')],
              total: 3,
              last: 100,
              totalBytes: 3,
            ),
            after: 1,
          ),
        ),
        throwsFormatException,
      );
    });
    test('rejects summary bytes which cannot fit remaining unread events', () {
      expect(
        () => FinalTranscriptHistory.empty(transcriptScope()).append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(1, text: '')],
              total: 2,
              last: 2,
              totalBytes: 8193,
              more: true,
            ),
            limit: 1,
          ),
        ),
        throwsFormatException,
      );
    });
    test('accepts server 1MiB history above in-memory projection limit', () {
      var history = FinalTranscriptHistory.empty(transcriptScope());
      final text = 'x' * 8192;
      for (var start = 0; start < 128; start += 32) {
        history = history.append(
          readPage(
            transcriptPageJson(
              events: List.generate(
                32,
                (i) => transcriptEventJson(start + i + 1, text: text),
              ),
              total: 128,
              last: 128,
              after: start,
              totalBytes: 1048576,
              more: start < 96,
            ),
            after: start,
          ),
        );
      }
      expect(history.totalTextBytes, 1048576);
      expect(history.events.length, 128);
    });
    test('accepts 512 revisions but rejects a 257th distinct turn', () {
      var history = FinalTranscriptHistory.empty(transcriptScope());
      for (var start = 0; start < 512; start += 32) {
        history = history.append(
          readPage(
            transcriptPageJson(
              events: List.generate(32, (i) {
                final sequence = start + i + 1;
                final turnIndex = (sequence + 1) ~/ 2;
                return transcriptEventJson(
                  sequence,
                  turnId: transcriptEventJson(turnIndex)['turn_id'],
                  turnIndex: turnIndex,
                  revision: sequence.isOdd ? 1 : 2,
                  text: '',
                );
              }),
              total: 512,
              last: 512,
              after: start,
              totalBytes: 0,
              more: start < 480,
            ),
            after: start,
          ),
        );
      }
      expect(history.events.length, 512);
      expect(history.turns.length, 256);

      var tooMany = FinalTranscriptHistory.empty(transcriptScope());
      for (var start = 0; start < 256; start += 32) {
        tooMany = tooMany.append(
          readPage(
            transcriptPageJson(
              events: List.generate(
                32,
                (i) => transcriptEventJson(start + i + 1, text: ''),
              ),
              total: 257,
              last: 257,
              after: start,
              totalBytes: 0,
              more: true,
            ),
            after: start,
          ),
        );
      }
      expect(
        () => tooMany.append(
          readPage(
            transcriptPageJson(
              events: [transcriptEventJson(257, text: '')],
              total: 257,
              last: 257,
            ),
            after: 256,
          ),
        ),
        throwsFormatException,
      );
      expect(tooMany.turns.length, 256);
    });
  });

  group('repository', () {
    late ApiClient api;
    late PracticeRepository repository;
    late Map<String, dynamic> data;
    var requests = 0;
    final connection = ConnectionReservation.fromJson(connectionJson());
    setUp(() {
      requests = 0;
      data = transcriptPageJson();
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          requests++;
          expect(request.method, 'GET');
          expect(request.headers['X-Account-ID'], accountId);
          expect(request.headers.containsKey('X-CSRF-Token'), isFalse);
          expect(request.body, '');
          expect(
            request.url.path,
            '/v1/practice-sessions/$practiceId/connections/$connectionId/transcripts',
          );
          return response(data);
        }),
      )..expectedAccountId = accountId;
      repository = PracticeRepository(api, accountId: accountId);
    });
    tearDown(() => api.close());
    test(
      'only GETs saved text bound to original account and connection',
      () async {
        final page = await repository.loadFinalTranscripts(connection);
        expect(page.events.length, 2);
        expect(page.scope.accountId, accountId);
        expect(requests, 1);
      },
    );
    test('sends exact paging query', () async {
      api.close();
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((request) async {
          expect(request.url.queryParameters, {
            'after_sequence': '3',
            'limit': '2',
          });
          return response(
            transcriptPageJson(events: [], total: 2, last: 3, after: 3),
          );
        }),
      )..expectedAccountId = accountId;
      repository = PracticeRepository(api, accountId: accountId);
      final page = await repository.loadFinalTranscripts(
        connection,
        afterSequence: 3,
        limit: 2,
      );
      expect(page.nextAfterSequence, 3);
    });
    test('rejects invalid query before HTTP', () async {
      for (final after in [-1, 2147483648]) {
        await expectLater(
          repository.loadFinalTranscripts(connection, afterSequence: after),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
      for (final limit in [0, 33]) {
        await expectLater(
          repository.loadFinalTranscripts(connection, limit: limit),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
      expect(requests, 0);
    });
    test('rejects an invalid account scope before HTTP', () async {
      repository = PracticeRepository(
        api,
        accountId: 'invalid-private-account',
      );
      await expectLater(
        repository.loadFinalTranscripts(connection),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_request'),
        ),
      );
      expect(requests, 0);
    });
    test(
      'rejects foreign account response with safe invalid_response',
      () async {
        data['account_id'] = requestKey;
        data['events'][0]['text'] = 'private-transcript';
        await expectLater(
          repository.loadFinalTranscripts(connection),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', 'invalid_response')
                .having(
                  (e) => e.toString(),
                  'safe',
                  isNot(contains('private-transcript')),
                ),
          ),
        );
      },
    );
    test('stops on account change without issuing HTTP', () async {
      api.expectedAccountId = requestKey;
      await expectLater(
        repository.loadFinalTranscripts(connection),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'account_changed'),
        ),
      );
      expect(requests, 0);
    });
  });
}
