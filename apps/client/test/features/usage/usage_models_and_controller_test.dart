import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/usage/usage_controller.dart';
import 'package:simontalk_client/features/usage/usage_models.dart';

import '../history/history_fixtures.dart';

Map<String, dynamic> voiceBucketJson({
  int count = 0,
  bool includeDeleted = true,
  int deleted = 0,
  int incomplete = 0,
  int detailIncomplete = 0,
  int input = 0,
  int output = 0,
  int inText = 0,
  int inAudio = 0,
  int outText = 0,
  int outAudio = 0,
}) => {
  'response_count': count,
  if (includeDeleted) 'deleted_response_count': deleted,
  'incomplete_count': incomplete,
  'detail_incomplete_count': detailIncomplete,
  'known_input_tokens': input,
  'known_output_tokens': output,
  'known_input_text_tokens': inText,
  'known_input_audio_tokens': inAudio,
  'known_output_text_tokens': outText,
  'known_output_audio_tokens': outAudio,
};

Map<String, dynamic> accountUsagePayload({bool empty = false}) => {
  'schema_version': 'account_usage_v1',
  'source': 'server_recorded',
  'account_id': accountId,
  'checked_at': '2026-11-25T06:00:00Z',
  'latest_recorded_at': empty ? null : '2026-11-25T05:55:00Z',
  'connection_pending_count': empty ? 0 : 1,
  'deleted_practice_count': empty ? 0 : 2,
  'voice_ordinary': empty
      ? voiceBucketJson()
      : voiceBucketJson(
          count: 2,
          deleted: 1,
          incomplete: 1,
          detailIncomplete: 1,
          input: 770,
          output: 29,
          inText: 728,
          inAudio: 42,
          outText: 7,
          outAudio: 22,
        ),
  'voice_rehearsal': empty
      ? voiceBucketJson()
      : voiceBucketJson(
          count: 1,
          deleted: 1,
          input: 310,
          output: 18,
          inText: 290,
          inAudio: 20,
          outText: 5,
          outAudio: 13,
        ),
  'review': {
    'attempt_count': empty ? 0 : 2,
    'deleted_attempt_count': empty ? 0 : 1,
    'incomplete_count': empty ? 0 : 1,
    'known_input_tokens': empty ? 0 : 645,
    'known_output_tokens': empty ? 0 : 5,
  },
};

Map<String, dynamic> practiceUsagePayload() => {
  'schema_version': 'practice_usage_v1',
  'source': 'server_recorded',
  'account_id': accountId,
  'session_id': practiceId,
  'kind': 'ordinary',
  'checked_at': '2026-11-25T06:00:00Z',
  'latest_recorded_at': '2026-11-25T05:55:00Z',
  'connection_count': 1,
  'connection_pending': true,
  'voice': voiceBucketJson(
    count: 1,
    includeDeleted: false,
    input: 770,
    output: 29,
    inText: 728,
    inAudio: 42,
    outText: 7,
    outAudio: 22,
  ),
  'review': {
    'attempt_count': 1,
    'incomplete_count': 0,
    'known_input_tokens': 645,
    'known_output_tokens': 5,
  },
};

void main() {
  test('strict models accept valid payloads and reject tampered shapes', () {
    final accountSummary = AccountUsageSummary.fromJson(
      accountUsagePayload(),
      accountId: accountId,
    );
    expect(accountSummary.hasAnyRecords, isTrue);
    expect(accountSummary.voiceOrdinary.knownInputTokens, 770);
    expect(accountSummary.voiceOrdinary.deletedResponseCount, 1);

    final emptySummary = AccountUsageSummary.fromJson(
      accountUsagePayload(empty: true),
      accountId: accountId,
    );
    expect(emptySummary.hasAnyRecords, isFalse);
    expect(emptySummary.latestRecordedAt, isNull);

    // Partial total missing while sub-details exist is permitted when incomplete > 0.
    final partialMissingTotal = AccountUsageSummary.fromJson({
      ...accountUsagePayload(),
      'voice_ordinary': voiceBucketJson(
        count: 1,
        deleted: 0,
        incomplete: 1,
        detailIncomplete: 0,
        input: 0,
        output: 10,
        inText: 8,
        inAudio: 2,
        outText: 5,
        outAudio: 5,
      ),
    }, accountId: accountId);
    expect(partialMissingTotal.voiceOrdinary.knownInputTextTokens, 8);

    for (final invalid in <Map<String, dynamic>>[
      {...accountUsagePayload(), 'extra': 1},
      {...accountUsagePayload(), 'schema_version': 'other'},
      {...accountUsagePayload(), 'source': 'client_reported'},
      {
        ...accountUsagePayload(),
        'account_id': '99999999-9999-4999-8999-999999999999',
      },
      {...accountUsagePayload(), 'checked_at': '2026-11-25 06:00:00'},
      {...accountUsagePayload(), 'latest_recorded_at': null},
      {
        ...accountUsagePayload(empty: true),
        'latest_recorded_at': '2026-11-25T06:00:00Z',
      },
      {...accountUsagePayload(), 'deleted_practice_count': 0},
      {
        ...accountUsagePayload(),
        'voice_ordinary': voiceBucketJson(
          count: 1,
          incomplete: 0,
          input: 10,
          output: 10,
          inText: 8,
          inAudio: 5,
        ),
      },
    ]) {
      expect(
        () => AccountUsageSummary.fromJson(invalid, accountId: accountId),
        throwsFormatException,
      );
    }

    final practiceSummary = PracticeUsageSummary.fromJson(
      practiceUsagePayload(),
      accountId: accountId,
      sessionId: practiceId,
    );
    expect(practiceSummary.voice.knownOutputTokens, 29);
    expect(practiceSummary.review.knownInputTokens, 645);

    for (final invalid in <Map<String, dynamic>>[
      {...practiceUsagePayload(), 'extra': true},
      {
        ...practiceUsagePayload(),
        'session_id': '99999999-9999-4999-8999-999999999999',
      },
      {...practiceUsagePayload(), 'connection_count': 0},
      {...practiceUsagePayload(), 'kind': 'unknown'},
    ]) {
      expect(
        () => PracticeUsageSummary.fromJson(
          invalid,
          accountId: accountId,
          sessionId: practiceId,
        ),
        throwsFormatException,
      );
    }
  });

  test('controllers stay silent until refresh, deduplicate, time out and abort on identity loss', () async {
    final requests = <http.Request>[];
    late Future<http.Response> Function(http.Request) handler;
    var now = Duration.zero;
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    addTearDown(api.close);

    handler = (_) async => response(accountUsagePayload());
    final controller = AccountUsageController(
      accountApi: api,
      accountId: accountId,
      elapsed: () => now,
      httpClientFactory: () => MockClient((r) {
        requests.add(r);
        return handler(r);
      }),
    );
    addTearDown(controller.dispose);

    expect(requests, isEmpty);
    expect(controller.state, UsageReadState.idle);

    final first = controller.refresh();
    expect(identical(first, controller.refresh()), isTrue);
    await first;
    expect(controller.state, UsageReadState.ready);
    expect(controller.summary!.voiceOrdinary.knownInputTokens, 770);
    expect(requests.single.url.path, '/v1/usage');
    expect(requests.single.headers['X-Account-ID'], accountId);

    // Network/timeout failure clears old summary rather than retaining stale counts.
    handler = (_) async {
      now += const Duration(seconds: 9);
      return response(accountUsagePayload());
    };
    await controller.refresh();
    expect(controller.state, UsageReadState.failed);
    expect(controller.errorCode, 'usage_timeout');
    expect(controller.summary, isNull);

    // Practice 404 maps to unavailable; 401 aborts permanently.
    final practiceController = PracticeUsageController(
      accountApi: api,
      accountId: accountId,
      sessionId: practiceId,
      httpClientFactory: () => MockClient((r) {
        requests.add(r);
        return handler(r);
      }),
    );
    addTearDown(practiceController.dispose);

    handler = (_) async => response({'code': 'practice_not_found'}, 404);
    await practiceController.refresh();
    expect(practiceController.state, UsageReadState.unavailable);
    expect(practiceController.errorCode, 'practice_not_found');

    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    final inFlight = practiceController.refresh();
    api.expectedAccountId = '99999999-9999-4999-8999-999999999999';
    expect(practiceController.state, UsageReadState.aborted);
    pending.complete(response(practiceUsagePayload()));
    await inFlight;
    expect(practiceController.summary, isNull);
  });
}
