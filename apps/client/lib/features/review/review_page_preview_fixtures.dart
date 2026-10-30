// Explicit, isolated examples for widget previews; never a connected data fallback.
import '../conversation/conversation_models.dart';
import '../practice/practice_completion_models.dart';
import 'review_models.dart';

const _account = '11111111-1111-4111-8111-111111111111';
const _session = '22222222-2222-4222-8222-222222222222';
const _connection = '33333333-3333-4333-8333-333333333333';
const _client = '44444444-4444-4444-8444-444444444444';
const _job = '66666666-6666-4666-8666-666666666666';

PracticeCompletionSummary exampleReviewCompletion() =>
    PracticeCompletionSummary.fromJson(
      {
        'source': 'server_recorded',
        'account_id': _account,
        'session_id': _session,
        'origin_connection_id': _connection,
        'client_instance_id': _client,
        'epoch': 1,
        'end_key': '55555555-5555-4555-8555-555555555555',
        'status': 'sealed',
        'accepted_at': '2026-10-21T08:00:00Z',
        'final_upload_deadline': '2026-10-21T08:00:30Z',
        'sealed_at': '2026-10-21T08:00:03Z',
        'input_revision': 1,
        'input_hash': 'a' * 64,
        'coverage': 'incomplete',
        'connection_count': 1,
        'gap_codes': ['tail_unconfirmed'],
      },
      scope: ConversationScope(
        accountId: _account,
        sessionId: _session,
        connectionId: _connection,
        clientInstanceId: _client,
        epoch: 1,
      ),
    );

ReviewJobSnapshot exampleReviewJob({
  String status = 'succeeded',
  String? rehearsalIntentStatus,
  String rehearsalIssueStatus = 'demonstrated',
}) {
  final target = ReviewTarget.fromCompletion(exampleReviewCompletion());
  final empty = status == 'no_evaluable_content';
  final input = ReviewInputBinding.fromJson({
    'source': 'server_derived',
    'evidence_source': 'client_reported',
    'account_id': _account,
    'session_id': _session,
    'input_revision': 1,
    'practice_input_hash': 'a' * 64,
    'policy_version': reviewInputPolicy,
    'review_input_hash': 'b' * 64,
    'created_at': '2026-10-21T08:00:04Z',
    'status': empty ? 'no_evaluable_content' : 'ready',
    'counts': {'eligible': empty ? 0 : 1, 'uncertain': 0, 'excluded': 0},
    'scopes': [
      {
        'account_id': _account,
        'session_id': _session,
        'connection_id': _connection,
        'client_instance_id': _client,
        'epoch': 1,
        'decisions': empty
            ? []
            : [
                {'eligibility': 'eligible'},
              ],
      },
    ],
  }, target: target);
  final examples = [
    [
      'correction',
      'Yesterday I go to the park.',
      'Yesterday I went to the park.',
      '谈论昨天的事情时，使用过去式 went。',
    ],
    [
      'polish',
      'I like English very much.',
      'I really enjoy learning English.',
      '这是一种更自然的表达选择，原句的意思仍然清楚。',
    ],
    [
      'extension',
      'I cook at home.',
      'I usually cook at home because I enjoy trying new recipes.',
      '可以补充频率和原因，让对方更容易继续交流。',
    ],
  ];
  return ReviewJobSnapshot.fromJson({
    'id': _job,
    'account_id': _account,
    'session_id': _session,
    'input_revision': 1,
    'practice_input_hash': 'a' * 64,
    'review_input_hash': 'b' * 64,
    'policy_version': reviewInputPolicy,
    'generation_policy_version': reviewGenerationPolicy,
    'status': status,
    'attempt_count': status == 'blocked' || empty ? 0 : 1,
    'next_attempt_at': null,
    'error_code': status == 'blocked' ? 'capability_unavailable' : null,
    'outcome_unknown': false,
    'created_at': '2026-10-21T08:00:04Z',
    'updated_at': '2026-10-21T08:00:06Z',
    'result': status == 'succeeded' || status == 'no_suggestions'
        ? {
            'schema_version': 'review_result_v1',
            'version': 1,
            'job_id': _job,
            'input_revision': 1,
            'practice_input_hash': 'a' * 64,
            'review_input_hash': 'b' * 64,
            'policy_version': reviewInputPolicy,
            'generation_policy_version': reviewGenerationPolicy,
            'items': status == 'no_suggestions' || rehearsalIntentStatus != null
                ? []
                : [
                    for (var i = 0; i < 3; i++)
                      {
                        'id': '${i + 7}7777777-7777-4777-8777-777777777777',
                        'ordinal': i + 1,
                        'source_connection_id': _connection,
                        'source_turn_id':
                            '88888888-8888-4888-8888-888888888888',
                        'revision': 1,
                        'exact_quote': examples[i][1],
                        'kind': examples[i][0],
                        'basis': 'text_only',
                        'explanation': examples[i][3],
                        'suggestion': examples[i][2],
                      },
                  ],
            if (rehearsalIntentStatus != null)
              'rehearsal_evaluation': {
                'schema_version': 'rehearsal_evaluation_v1',
                'target_hash': 'd' * 64,
                'intent': {
                  'status': rehearsalIntentStatus,
                  'explanation': switch (rehearsalIntentStatus) {
                    'changed' => '原目标是讲述去公园，本次改成了去博物馆。',
                    'insufficient_evidence' => '本次表达没有足够的信息确认是否传达了原意。',
                    _ => '本次仍在讲述昨天去公园的经历，保留了原意。',
                  },
                  'evidence': rehearsalIntentStatus == 'insufficient_evidence'
                      ? []
                      : [
                          _exampleEvaluationEvidence(
                            rehearsalIntentStatus == 'changed'
                                ? 'Yesterday I went to a museum.'
                                : 'Yesterday I went to the park.',
                          ),
                        ],
                },
                'target_issue': {
                  'status': rehearsalIssueStatus,
                  'explanation': switch (rehearsalIssueStatus) {
                    'still_present' => '本次仍用 go 描述昨天的事情。',
                    'not_demonstrated' => '本次只表达了喜欢公园，没有使用目标过去式，暂不能判断目标问题是否改善。',
                    'insufficient_evidence' => '本次已保存文字不足以支持对目标问题作判断。',
                    _ => '本次使用 went 描述过去发生的事情，展示了目标过去式。',
                  },
                  'evidence': rehearsalIssueStatus == 'insufficient_evidence'
                      ? []
                      : [
                          _exampleEvaluationEvidence(
                            switch (rehearsalIssueStatus) {
                              'still_present' => 'Yesterday I go to the park.',
                              'not_demonstrated' => 'I like parks.',
                              _ =>
                                rehearsalIntentStatus == 'changed'
                                    ? 'Yesterday I went to a museum.'
                                    : 'Yesterday I went to the park.',
                            },
                          ),
                        ],
                },
              },
            'result_hash': 'c' * 64,
            'created_at': '2026-10-21T08:00:05Z',
          }
        : null,
  }, input: input);
}

Map<String, dynamic> _exampleEvaluationEvidence(String quote) => {
  'source_connection_id': _connection,
  'source_turn_id': '88888888-8888-4888-8888-888888888888',
  'revision': 1,
  'exact_quote': quote,
};
