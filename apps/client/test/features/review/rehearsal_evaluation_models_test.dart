import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/review/review_models.dart';

import 'rehearsal_evaluation_fixtures.dart';
import 'review_fixtures.dart';

ReviewJobSnapshot parse(Map<String, dynamic> json) =>
    ReviewJobSnapshot.fromJson(json, input: input());

void main() {
  test('evaluation alone is succeeded; legacy results remain readable', () {
    final job = parse(evaluatedJobJson());
    expect(job.status, ReviewJobStatus.succeeded);
    expect(job.result!.items, isEmpty);
    final evaluation = job.result!.rehearsalEvaluation!;
    expect(evaluation.targetHash, 'd' * 64);
    expect(evaluation.intent.status.name, 'conveyed');
    expect(evaluation.targetIssue.status.name, 'demonstrated');
    expect(
      evaluation.intent.evidence.single.exactQuote,
      'Yesterday I went to the park.',
    );
    for (final status in ['succeeded', 'no_suggestions']) {
      final result = parse(jobJson(status: status)).result!;
      expect(result.rehearsalEvaluation, isNull);
    }
    expect(
      parse(evaluatedJobJson(withSuggestion: true)).result!.items,
      hasLength(1),
    );
  });

  for (final intent in ['conveyed', 'changed', 'insufficient_evidence']) {
    for (final issue in [
      'demonstrated',
      'still_present',
      'not_demonstrated',
      'insufficient_evidence',
    ]) {
      test('independent axes accept $intent / $issue', () {
        expect(
          parse(evaluatedJobJson(intent: intent, targetIssue: issue)).status,
          ReviewJobStatus.succeeded,
        );
      });
    }
  }

  test('job status agrees with optional evaluation and suggestions', () {
    expect(
      () => parse({...evaluatedJobJson(), 'status': 'no_suggestions'}),
      throwsFormatException,
    );
    expect(
      () => parse(
        jobJson(status: 'succeeded')..['result'] = resultJson(empty: true),
      ),
      throwsFormatException,
    );
    expect(
      () => parse({
        ...evaluatedJobJson(withSuggestion: true),
        'status': 'no_suggestions',
      }),
      throwsFormatException,
    );
  });

  test('evaluation rejects unknown or explicit null root extensions', () {
    for (final invalid in <dynamic>[
      null,
      [],
      'evaluation',
      {},
      {...evaluationJson(), 'extra': true},
      {...evaluationJson(), 'schema_version': 'rehearsal_evaluation_v2'},
      {...evaluationJson(), 'target_hash': 'D' * 64},
      {...evaluationJson(), 'target_hash': 'd' * 63},
      {...evaluationJson(), 'target_hash': '${'d' * 64}\n'},
      {...evaluationJson()}..remove('intent'),
      {...evaluationJson(), 'intent': null},
      {...evaluationJson(), 'target_issue': null},
    ]) {
      final raw = evaluatedJobJson();
      raw['result']['rehearsal_evaluation'] = invalid;
      expect(() => parse(raw), throwsFormatException, reason: '$invalid');
    }
  });

  test('every required nested field is mandatory and rows must be objects', () {
    for (final key in [
      'schema_version',
      'target_hash',
      'intent',
      'target_issue',
    ]) {
      final raw = evaluatedJobJson();
      (raw['result']['rehearsal_evaluation'] as Map).remove(key);
      expect(() => parse(raw), throwsFormatException, reason: key);
    }
    for (final axis in ['intent', 'target_issue']) {
      for (final key in ['status', 'explanation', 'evidence']) {
        final raw = evaluatedJobJson();
        (raw['result']['rehearsal_evaluation'][axis] as Map).remove(key);
        expect(() => parse(raw), throwsFormatException, reason: '$axis.$key');
      }
      for (final row in <dynamic>[null, 'quote', [], true]) {
        final raw = evaluatedJobJson();
        raw['result']['rehearsal_evaluation'][axis]['evidence'] = [row];
        expect(() => parse(raw), throwsFormatException);
      }
    }
    for (final key in [
      'source_connection_id',
      'source_turn_id',
      'revision',
      'exact_quote',
    ]) {
      final raw = evaluatedJobJson();
      (raw['result']['rehearsal_evaluation']['intent']['evidence'][0] as Map)
          .remove(key);
      expect(() => parse(raw), throwsFormatException, reason: key);
    }
  });

  for (final axis in ['intent', 'target_issue']) {
    test('$axis strictly validates shape enums text and evidence count', () {
      for (final change in <Map<String, dynamic>>[
        {'status': 'success'},
        {'status': null},
        {'status': true},
        {'status': axis == 'intent' ? 'demonstrated' : 'conveyed'},
        {'extra': true},
        {'explanation': null},
        {'explanation': ''},
        {'explanation': ' \t\n'},
        {'explanation': '\u0085\u00A0\u2003\u2028\u3000'},
        {'explanation': '🙂' * 4097},
        {'explanation': '\u0000'},
        {'explanation': '\uD800'},
        {'explanation': 'a\uD800b'},
        {'evidence': null},
        {'evidence': []},
        {'evidence': {}},
        {'evidence': List.generate(4, (_) => evaluationEvidenceJson())},
      ]) {
        final raw = evaluatedJobJson();
        final evaluation = raw['result']['rehearsal_evaluation'];
        evaluation[axis] = {...evaluation[axis], ...change};
        expect(
          () => parse(raw),
          throwsFormatException,
          reason: '$axis ${change.keys.join()}',
        );
      }
      final raw = evaluatedJobJson(
        intent: 'insufficient_evidence',
        targetIssue: 'insufficient_evidence',
      );
      raw['result']['rehearsal_evaluation'][axis]['explanation'] = '🙂' * 4096;
      expect(parse(raw).result, isNotNull);
      raw['result']['rehearsal_evaluation'][axis]['evidence'] = List.generate(
        3,
        (_) => evaluationEvidenceJson(),
      );
      expect(parse(raw).result, isNotNull);
    });
  }

  test(
    'evidence strictly validates exact fields UUID revision and Unicode',
    () {
      for (final change in <Map<String, dynamic>>[
        {'source_connection_id': 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'},
        {'source_turn_id': 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'},
        {'source_connection_id': 'bad'},
        {'source_turn_id': null},
        {'source_turn_id': '$turnId\n'},
        {'revision': true},
        {'revision': 1.0},
        {'revision': 0},
        {'revision': 2147483648},
        {'exact_quote': null},
        {'exact_quote': ''},
        {'exact_quote': '\t\n'},
        {'exact_quote': '\u0085\u00A0\u2003\u2028\u3000'},
        {'exact_quote': '🙂' * 8193},
        {'exact_quote': '\u0000'},
        {'exact_quote': '\uDC00'},
        {'exact_quote': 'a\uD800b'},
        {'extra': true},
      ]) {
        final raw = evaluatedJobJson();
        raw['result']['rehearsal_evaluation']['intent']['evidence'] = [
          {...evaluationEvidenceJson(), ...change},
        ];
        expect(
          () => parse(raw),
          throwsFormatException,
          reason: change.keys.join(),
        );
      }
      final raw = evaluatedJobJson();
      raw['result']['rehearsal_evaluation']['intent']['evidence'][0]
        ..['exact_quote'] = '🙂' * 8192
        ..['revision'] = 2147483647;
      expect(parse(raw).result, isNotNull);
    },
  );

  test('evaluation makes a deep immutable copy without claiming source lookup', () {
    final raw = evaluatedJobJson();
    // Only the service holds the transcript and checks its substring binding.
    raw['result']['rehearsal_evaluation']['intent']['evidence'][0]['exact_quote'] =
        'A server-validated quote not available in this client input summary.';
    final evaluation = parse(raw).result!.rehearsalEvaluation!;
    raw['result']['rehearsal_evaluation']['intent']['evidence'].clear();
    expect(evaluation.intent.evidence, hasLength(1));
    expect(() => evaluation.intent.evidence.clear(), throwsUnsupportedError);
    expect(
      () => evaluation.targetIssue.evidence.clear(),
      throwsUnsupportedError,
    );
  });
}
