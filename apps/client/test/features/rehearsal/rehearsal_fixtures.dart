import '../review/review_fixtures.dart';
export '../review/review_fixtures.dart';

const childId = '99999999-9999-4999-8999-999999999999';
Map<String, dynamic> rehearsalTargetJson() => {
  'schema_version': 'rehearsal_target_v1',
  'source': 'server_derived',
  'evidence_source': 'client_reported',
  'account_id': accountId,
  'source_session_id': practiceId,
  'source_kind': 'ordinary',
  'item_id': itemId,
  'job_id': jobId,
  'result_hash': 'c' * 64,
  'input_revision': 1,
  'practice_input_hash': 'a' * 64,
  'review_input_hash': 'b' * 64,
  'policy_version': 'review_input_v1',
  'generation_policy_version': 'review_generation_v1',
  'source_connection_id': connectionId,
  'source_client_instance_id': clientId,
  'source_epoch': 1,
  'source_turn_id': turnId,
  'revision': 1,
  'source_text': 'Yes, I enjoy English.',
  'exact_quote': 'I enjoy English.',
  'kind': 'polish',
  'basis': 'text_only',
  'explanation': '说出具体喜欢的活动。',
  'suggestion': 'I enjoy learning English.',
  'situation_mode': 'source_original',
  'context_before': <Map<String, dynamic>>[],
  'target_hash': 'd' * 64,
};
Map<String, dynamic> childJson({String status = 'created'}) => {
  ...practiceJson(status: status),
  'id': childId,
  'kind': 'rehearsal',
  'source_session_id': practiceId,
  'source_review_item_id': itemId,
};
Map<String, dynamic> rehearsalPreparationJson() => {
  'schema_version': 'rehearsal_preparation_v1',
  'source': 'server_recorded',
  'account_id': accountId,
  'practice': childJson(),
  'target': rehearsalTargetJson(),
};
