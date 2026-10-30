import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/review/review_models.dart';

import 'review_fixtures.dart';

void main() {
  test(
    'ending cannot authorize review and sealed targets have value equality',
    () {
      expect(
        () => ReviewTarget.fromCompletion(sealedCompletion(sealed: false)),
        throwsFormatException,
      );
      expect(target(), target());
      expect(target().hashCode, target().hashCode);
      expect(target().accountId, accountId);
    },
  );
  test('input summary validates binding counts scopes and budget', () {
    expect(input().eligibleCount, 1);
    expect(input(empty: true).status, ReviewInputStatus.noEvaluableContent);
    for (final change in <Map<String, dynamic>>[
      {'source': 'client'},
      {'evidence_source': 'server_verified'},
      {'account_id': requestKey},
      {'session_id': requestKey},
      {'input_revision': true},
      {'practice_input_hash': 'd' * 64},
      {'review_input_hash': 'A' * 64},
      {'policy_version': 'future'},
      {'created_at': '2026-02-30T00:00:00Z'},
      {'status': 'unknown'},
      {'status': 'no_evaluable_content'},
      {
        'counts': {'eligible': 2, 'uncertain': 0, 'excluded': 0},
      },
      {'scopes': List.filled(33, inputJson()['scopes'][0])},
      {'extra': true},
      {
        'scopes': [
          {
            'decisions': List.filled(8193, {'eligibility': 'eligible'}),
          },
        ],
      },
    ]) {
      expect(
        () => ReviewInputBinding.fromJson({
          ...inputJson(),
          ...change,
        }, target: target()),
        throwsFormatException,
        reason: change.keys.join(),
      );
    }
    final oversized = inputJson();
    oversized['scopes'][0]['decisions'][0]['text'] = '中' * 180000;
    expect(utf8.encode(jsonEncode(oversized)).length, greaterThan(512 * 1024));
    expect(
      () => ReviewInputBinding.fromJson(oversized, target: target()),
      throwsFormatException,
    );
  });
  test('all nine job states and valid results are immutable', () {
    for (final status in [
      'queued',
      'running',
      'retry_wait',
      'blocked',
      'succeeded',
      'no_suggestions',
      'no_evaluable_content',
      'failed',
      'invalidated',
    ]) {
      final job = ReviewJobSnapshot.fromJson(
        jobJson(status: status),
        input: input(empty: status == 'no_evaluable_content'),
      );
      expect(
        job.status.name,
        status.replaceAllMapped(RegExp('_([a-z])'), (m) => m[1]!.toUpperCase()),
      );
    }
    final job = ReviewJobSnapshot.fromJson(
      jobJson(status: 'succeeded'),
      input: input(),
    );
    expect(job.result!.items.single.exactQuote, 'I enjoy English.');
    expect(() => job.result!.items.clear(), throwsUnsupportedError);
  });
  test('job rejects identity type date count and state contradictions', () {
    for (final change in <Map<String, dynamic>>[
      {'id': 'bad'},
      {'account_id': requestKey},
      {'session_id': requestKey},
      {'input_revision': true},
      {'practice_input_hash': 'd' * 64},
      {'review_input_hash': 'd' * 64},
      {'policy_version': 'future'},
      {'generation_policy_version': 'future'},
      {'status': 'complete'},
      {'attempt_count': true},
      {'attempt_count': 4},
      {'outcome_unknown': 0},
      {'created_at': '2026-02-30T08:00:00Z'},
      {'updated_at': '2026-10-20T00:00:00Z'},
      {'next_attempt_at': 'bad'},
      {'next_attempt_at': '2026-10-21T08:00:07Z'},
      {'result': resultJson()},
      {'error_code': true},
      {'extra': true},
    ]) {
      expect(
        () => ReviewJobSnapshot.fromJson({
          ...jobJson(),
          ...change,
        }, input: input()),
        throwsFormatException,
        reason: change.keys.join(),
      );
    }
    for (final change in <Map<String, dynamic>>[
      {'result': null},
      {'result': resultJson(empty: true)},
      {'attempt_count': 0},
      {'outcome_unknown': true},
    ]) {
      expect(
        () => ReviewJobSnapshot.fromJson({
          ...jobJson(status: 'succeeded'),
          ...change,
        }, input: input()),
        throwsFormatException,
      );
    }
    expect(
      () => ReviewJobSnapshot.fromJson(
        jobJson(status: 'no_evaluable_content', attempts: 1),
        input: input(empty: true),
      ),
      throwsFormatException,
    );
  });
  test(
    'results reject schema binding item identity enums and character limits',
    () {
      void rejects(Map<String, dynamic> result) => expect(
        () => ReviewJobSnapshot.fromJson({
          ...jobJson(status: 'succeeded'),
          'result': result,
        }, input: input()),
        throwsFormatException,
      );
      for (final change in <Map<String, dynamic>>[
        {'schema_version': 'future'},
        {'version': true},
        {'version': 2},
        {'job_id': requestKey},
        {'input_revision': 2},
        {'review_input_hash': 'd' * 64},
        {'generation_policy_version': 'future'},
        {'result_hash': 'A' * 64},
        {'created_at': 'yesterday'},
        {'items': List.filled(4, itemJson())},
        {
          'items': [
            itemJson(),
            {...itemJson(), 'ordinal': 2},
          ],
        },
        {'extra': true},
      ]) {
        rejects({...resultJson(), ...change});
      }
      for (final change in <Map<String, dynamic>>[
        {'id': 'bad'},
        {'ordinal': 0},
        {'ordinal': true},
        {'source_connection_id': 'bad'},
        {'source_turn_id': 'bad'},
        {'revision': true},
        {'revision': 0},
        {'kind': 'pronunciation'},
        {'basis': 'audio'},
        {'exact_quote': ' '},
        {'exact_quote': '🙂' * 8193},
        {'explanation': 'x' * 4097},
        {'suggestion': 'x' * 8193},
        {'explanation': ''},
        {'suggestion': '\t'},
        {'extra': true},
      ]) {
        rejects({
          ...resultJson(),
          'items': [
            {...itemJson(), ...change},
          ],
        });
      }
      final unicode = {
        ...resultJson(),
        'items': [
          {...itemJson(), 'exact_quote': '🙂' * 8192},
        ],
      };
      expect(
        ReviewJobSnapshot.fromJson({
          ...jobJson(status: 'succeeded'),
          'result': unicode,
        }, input: input()).result!.items.single.exactQuote.runes.length,
        8192,
      );
    },
  );
}
