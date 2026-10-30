import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/review/review_models.dart';

import '../practice/practice_completion_test.dart' show completionSummary;
import '../practice/practice_fixtures.dart';
export '../practice/practice_fixtures.dart';

const jobId = '66666666-6666-4666-8666-666666666666';
const itemId = '77777777-7777-4777-8777-777777777777';
const turnId = '88888888-8888-4888-8888-888888888888';
ConversationScope reviewScope() => ConversationScope(
  accountId: accountId,
  sessionId: practiceId,
  connectionId: connectionId,
  clientInstanceId: clientId,
  epoch: 1,
);
PracticeCompletionSummary sealedCompletion({bool sealed = true}) =>
    PracticeCompletionSummary.fromJson(
      completionSummary(sealed: sealed),
      scope: reviewScope(),
      endKey: requestKey,
    );
ReviewTarget target() => ReviewTarget.fromCompletion(sealedCompletion());
Map<String, dynamic> inputJson({bool empty = false}) => {
  'source': 'server_derived',
  'evidence_source': 'client_reported',
  'account_id': accountId,
  'session_id': practiceId,
  'input_revision': 1,
  'practice_input_hash': 'a' * 64,
  'policy_version': 'review_input_v1',
  'review_input_hash': 'b' * 64,
  'created_at': '2026-10-21T08:00:04Z',
  'status': empty ? 'no_evaluable_content' : 'ready',
  'counts': {'eligible': empty ? 0 : 1, 'uncertain': 0, 'excluded': 0},
  'scopes': [
    {
      'account_id': accountId,
      'session_id': practiceId,
      'connection_id': connectionId,
      'client_instance_id': clientId,
      'epoch': 1,
      'decisions': empty
          ? []
          : [
              {'eligibility': 'eligible', 'text': 'I enjoy English.'},
            ],
    },
  ],
};
ReviewInputBinding input({bool empty = false}) =>
    ReviewInputBinding.fromJson(inputJson(empty: empty), target: target());
Map<String, dynamic> itemJson() => {
  'id': itemId,
  'ordinal': 1,
  'source_connection_id': connectionId,
  'source_turn_id': turnId,
  'revision': 1,
  'exact_quote': 'I enjoy English.',
  'kind': 'polish',
  'basis': 'text_only',
  'explanation': 'More specific.',
  'suggestion': 'I enjoy learning English.',
};
Map<String, dynamic> resultJson({bool empty = false}) => {
  'schema_version': 'review_result_v1',
  'version': 1,
  'job_id': jobId,
  'input_revision': 1,
  'practice_input_hash': 'a' * 64,
  'review_input_hash': 'b' * 64,
  'policy_version': 'review_input_v1',
  'generation_policy_version': 'review_generation_v1',
  'items': empty ? [] : [itemJson()],
  'result_hash': 'c' * 64,
  'created_at': '2026-10-21T08:00:05Z',
};
Map<String, dynamic> jobJson({
  String status = 'blocked',
  int? attempts,
  bool unknown = false,
}) => {
  'id': jobId,
  'account_id': accountId,
  'session_id': practiceId,
  'input_revision': 1,
  'practice_input_hash': 'a' * 64,
  'review_input_hash': 'b' * 64,
  'policy_version': 'review_input_v1',
  'generation_policy_version': 'review_generation_v1',
  'status': status,
  'attempt_count':
      attempts ??
      ([
            'succeeded',
            'no_suggestions',
            'failed',
            'running',
            'retry_wait',
          ].contains(status)
          ? 1
          : 0),
  'next_attempt_at': status == 'retry_wait' ? '2026-10-21T08:00:07Z' : null,
  'error_code':
      ['blocked', 'failed', 'retry_wait', 'invalidated'].contains(status)
      ? 'capability_unavailable'
      : null,
  'outcome_unknown': unknown,
  'created_at': '2026-10-21T08:00:04Z',
  'updated_at': '2026-10-21T08:00:06Z',
  'result': status == 'succeeded'
      ? resultJson()
      : status == 'no_suggestions'
      ? resultJson(empty: true)
      : null,
};
