import 'dart:convert';

export '../practice/practice_fixtures.dart'
    show accountId, practiceId, TestTokenStore, response;
import '../practice/practice_fixtures.dart' show accountId;

String historyId(int i) =>
    '22222222-2222-4222-8222-${i.toString().padLeft(12, '0')}';
Map<String, dynamic> historyItem(
  int i, {
  String status = 'cancelled',
  bool sealed = false,
}) => {
  'id': historyId(i),
  'kind': 'ordinary',
  'source_session_id': null,
  'status': status,
  'created_at': '2026-10-20T12:00:00.123456Z',
  'ended_at': '2026-10-20T12:01:00Z',
  'difficulty': 'beginner',
  'completion_status': sealed ? 'sealed' : 'unregistered',
  'coverage': sealed ? 'complete' : null,
  'connection_pending': false,
};
String historyCursor(int i, {String owner = accountId}) => base64Url
    .encode(
      utf8.encode(
        jsonEncode([owner, '2026-10-20T12:00:00.123456+00:00', historyId(i)]),
      ),
    )
    .replaceAll('=', '');
Map<String, dynamic> historyPage({int page = 0, String owner = accountId}) => {
  'schema_version': 'practice_history_v1',
  'source': 'server_recorded',
  'account_id': owner,
  'limit': 10,
  'items': [
    for (var i = page == 0 ? 21 : 11; i > (page == 0 ? 11 : 8); i--)
      historyItem(i),
  ],
  'next_cursor': page == 0 ? historyCursor(12, owner: owner) : null,
};
Map<String, dynamic> historyDetail(int i, {bool sealed = false}) => {
  'schema_version': 'practice_history_detail_v1',
  'source': 'server_recorded',
  'account_id': accountId,
  'item': historyItem(i, sealed: sealed),
};
