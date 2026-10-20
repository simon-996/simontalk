import 'dart:convert';

import 'package:simontalk_client/features/conversation/conversation_models.dart';

import '../practice/practice_fixtures.dart';

ConversationScope transcriptScope() => ConversationScope(
  accountId: accountId,
  sessionId: practiceId,
  connectionId: connectionId,
  clientInstanceId: clientId,
  epoch: 1,
);

Map<String, dynamic> transcriptEventJson(
  int sequence, {
  String? turnId,
  int? turnIndex,
  int revision = 1,
  String text = 'Saved final text.',
  ConversationRole role = ConversationRole.user,
  String? responseId,
  String? providerItemId,
}) => {
  'event_id': '60000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}',
  'sequence': sequence,
  'turn_id':
      turnId ??
      '70000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}',
  'turn_index': turnIndex ?? sequence,
  'role': role.name,
  'revision': revision,
  'text': text,
  'response_id': role == ConversationRole.assistant
      ? responseId ?? requestKey
      : responseId,
  'provider_item_id': providerItemId,
  'received_at': '2026-10-20T08:00:00.123456+08:00',
  'delivery_status': role == ConversationRole.assistant ? 'unknown' : null,
};

Map<String, dynamic> transcriptPageJson({
  List<Map<String, dynamic>>? events,
  int? total,
  int? last,
  int after = 0,
  bool more = false,
  int? totalBytes,
}) {
  final entries = events ?? [transcriptEventJson(1), transcriptEventJson(3)];
  return {
    'source': 'client_reported',
    'account_id': accountId,
    'session_id': practiceId,
    'connection_id': connectionId,
    'client_instance_id': clientId,
    'epoch': 1,
    'events': entries,
    'last_sequence': last ?? (entries.isEmpty ? 0 : entries.last['sequence']),
    'total_events': total ?? entries.length,
    'total_text_bytes':
        totalBytes ??
        entries.fold<int>(
          0,
          (sum, event) => sum + utf8.encode(event['text'] as String).length,
        ),
    'next_after_sequence': entries.isEmpty ? after : entries.last['sequence'],
    'has_more': more,
  };
}
