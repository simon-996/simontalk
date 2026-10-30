import 'package:simontalk_client/features/transcript/saved_transcript_models.dart';

import '../review/review_fixtures.dart';
export '../review/review_fixtures.dart';

String transcriptTurnId(int ordinal) => ordinal == 1
    ? turnId
    : '88888888-8888-4888-8888-${ordinal.toString().padLeft(12, '0')}';
Map<String, dynamic> turnJson(int ordinal, {String role = 'user'}) => {
  'ordinal': ordinal,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'turn_id': transcriptTurnId(ordinal),
  'turn_index': ordinal,
  'revision': 1,
  'role': role,
  'final_text': 'I enjoy English.',
  'final_source': 'final_transcript',
  'playback_status': role == 'assistant' ? 'unknown' : null,
  'played_text': null,
  'played_revision': null,
};
Map<String, dynamic> focusJson({int ordinal = 1}) => {
  'item_id': itemId,
  'job_id': jobId,
  'result_hash': 'c' * 64,
  'connection_id': connectionId,
  'turn_id': transcriptTurnId(ordinal),
  'revision': 1,
  'exact_quote': 'I enjoy English.',
  'ordinal': ordinal,
};
Map<String, dynamic> pageJson({
  int total = 1,
  int offset = 0,
  bool focus = false,
  int focusOrdinal = 1,
}) => {
  'schema_version': 'saved_transcript_v1',
  'source': 'server_derived',
  'evidence_source': 'client_reported',
  'account_id': accountId,
  'session_id': practiceId,
  'input_revision': 1,
  'practice_input_hash': 'a' * 64,
  'sealed_at': '2026-10-21T08:00:03Z',
  'coverage': 'incomplete',
  'gap_codes': <String>['tail_unconfirmed'],
  'total_turns': total,
  'offset': offset,
  'limit': 16,
  'previous_offset': offset > 0 ? (offset - 16).clamp(0, 8192) : null,
  'next_offset': offset + 16 < total ? offset + 16 : null,
  'focus': focus ? focusJson(ordinal: focusOrdinal) : null,
  'items': [
    for (var n = offset + 1; n <= total && n <= offset + 16; n++) turnJson(n),
  ],
};
SavedTranscriptPage page({
  int total = 1,
  int offset = 0,
  bool focus = false,
  int focusOrdinal = 1,
}) => SavedTranscriptPage.fromJson(
  pageJson(
    total: total,
    offset: offset,
    focus: focus,
    focusOrdinal: focusOrdinal,
  ),
  target: target(),
  offset: offset,
  reviewItemId: focus ? itemId : null,
);
