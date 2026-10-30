// Explicit isolated examples. Never imported by a connected screen/provider.
import '../review/review_models.dart';
import '../review/review_page_preview_fixtures.dart';
import 'saved_transcript_models.dart';

SavedTranscriptPage exampleSavedTranscript({bool empty = false}) {
  final target = ReviewTarget.fromCompletion(exampleReviewCompletion());
  const c1 = '33333333-3333-4333-8333-333333333333';
  const c2 = '99999999-9999-4999-8999-999999999999';
  const client = '44444444-4444-4444-8444-444444444444';
  const turn = '88888888-8888-4888-8888-888888888888';
  const item = '77777777-7777-4777-8777-777777777777';
  Map<String, dynamic> row(
    int n,
    String role, {
    String? text,
    String? status,
    String? played,
    int? playedRevision,
    int revision = 1,
    String connection = c1,
    int epoch = 1,
  }) => {
    'ordinal': n,
    'connection_id': connection,
    'client_instance_id': client,
    'epoch': epoch,
    'turn_id': n == 1
        ? turn
        : 'aaaaaaaa-aaaa-4aaa-8aaa-${n.toString().padLeft(12, '0')}',
    'turn_index': n,
    'revision': revision,
    'role': role,
    'final_text': text,
    'final_source': text == null ? null : 'final_transcript',
    'playback_status': status,
    'played_text': played,
    'played_revision': playedRevision,
  };
  return SavedTranscriptPage.fromJson(
    {
      'schema_version': 'saved_transcript_v1',
      'source': 'server_derived',
      'evidence_source': 'client_reported',
      'account_id': target.accountId,
      'session_id': target.sessionId,
      'input_revision': 1,
      'practice_input_hash': target.practiceInputHash,
      'sealed_at': '2026-10-21T08:00:03Z',
      'coverage': 'incomplete',
      'gap_codes': ['tail_unconfirmed'],
      'total_turns': empty ? 0 : 5,
      'offset': 0,
      'limit': 16,
      'previous_offset': null,
      'next_offset': null,
      'focus': empty
          ? null
          : {
              'item_id': item,
              'job_id': '66666666-6666-4666-8666-666666666666',
              'result_hash': 'c' * 64,
              'connection_id': c1,
              'turn_id': turn,
              'revision': 1,
              'exact_quote': 'Yesterday I go to the park.',
              'ordinal': 1,
            },
      'items': empty
          ? []
          : [
              row(
                1,
                'user',
                text: 'Yesterday I go to the park. I enjoyed a quiet walk with my friend.',
              ),
              row(
                2,
                'assistant',
                text: 'That sounds like a lovely afternoon. What did you enjoy most?',
                status: 'partial',
                played: 'An older reply',
                playedRevision: 1,
                revision: 2,
              ),
              row(3, 'user', text: '', connection: c2, epoch: 2),
              row(
                4,
                'assistant',
                text: 'What would you like to talk about next?',
                status: 'unknown',
                connection: c2,
                epoch: 2,
              ),
              row(
                5,
                'assistant',
                status: 'revoked',
                revision: 0,
                connection: c2,
                epoch: 2,
              ),
            ],
    },
    target: target,
    reviewItemId: empty ? null : item,
  );
}
