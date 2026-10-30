import 'history_fixtures.dart';
export 'history_fixtures.dart'
    show accountId, practiceId, TestTokenStore, response;

const deletionKey = '44444444-4444-4444-8444-444444444444';
String get scopeVersion => 'a' * 64;
Map<String, dynamic> deletionScope({int children = 2, bool pending = false}) =>
    {
      'schema_version': 'practice_deletion_scope_v1',
      'source': 'server_recorded',
      'account_id': accountId,
      'session_id': practiceId,
      'kind': 'ordinary',
      'record_count': children + 1,
      'rehearsal_count': children,
      'scope_version': scopeVersion,
      'connection_pending': pending,
    };
Map<String, dynamic> deletionReceipt({String key = deletionKey}) => {
  ...deletionScope(),
  'schema_version': 'practice_deletion_receipt_v1',
  'request_key': key,
  'deleted_at': '2026-10-23T12:00:00Z',
}..remove('kind');
