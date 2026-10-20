import 'dart:convert';

import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/final_transcript_read_models.dart';

import '../practice/practice_fixtures.dart';

ConversationScope transcriptViewScope() => ConversationScope(
  accountId: accountId,
  sessionId: practiceId,
  connectionId: connectionId,
  clientInstanceId: clientId,
  epoch: 1,
);

Map<String, dynamic> transcriptViewEvent(
  int sequence, {
  int? turn,
  int revision = 1,
  String text = 'x',
  bool assistant = false,
}) => {
  'event_id': '77777777-7777-4777-8777-${sequence.toString().padLeft(12, '0')}',
  'sequence': sequence,
  'turn_id':
      '88888888-8888-4888-8888-${(turn ?? sequence).toString().padLeft(12, '0')}',
  'turn_index': turn ?? sequence,
  'role': assistant ? 'assistant' : 'user',
  'revision': revision,
  'text': text,
  'response_id': assistant ? requestKey : null,
  'provider_item_id': null,
  'received_at': '2026-10-20T00:00:00Z',
  'delivery_status': assistant ? 'unknown' : null,
};

Map<String, dynamic> transcriptViewPage(
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
        (sum, event) => sum + utf8.encode(event['text'] as String).length,
      ),
  'events': events,
  'next_after_sequence': events.isEmpty ? after : events.last['sequence'],
  'has_more': more,
};

FinalTranscriptHistory transcriptViewHistory(
  List<Map<String, dynamic>> events, {
  bool more = false,
  int? total,
  int? last,
  int? bytes,
}) {
  final scope = transcriptViewScope();
  return FinalTranscriptHistory.empty(scope).append(
    FinalTranscriptPage.fromJson(
      transcriptViewPage(
        events,
        more: more,
        total: total,
        last: last,
        bytes: bytes,
      ),
      scope: scope,
      afterSequence: 0,
      limit: more ? events.length : 32,
    ),
  );
}
