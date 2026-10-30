import '../history/history_fixtures.dart';
export '../history/history_fixtures.dart';

const listItemId = '77777777-7777-4777-8777-777777777777';
Map<String, dynamic> relatedRow(int i) => {
  'id': historyId(i),
  'kind': 'rehearsal',
  'source_session_id': practiceId,
  'source_review_item_id': listItemId,
  'status': 'cancelled',
  'created_at': '2026-10-23T01:00:00.123456Z',
  'ended_at': '2026-10-23T01:01:00Z',
};
Map<String, dynamic> relatedPage([int index = 0]) => {
  'schema_version': 'rehearsal_list_v1',
  'source': 'server_recorded',
  'account_id': accountId,
  'source_session_id': practiceId,
  'limit': 10,
  'items': [
    for (
      var i = index == 0
          ? 21
          : index == 1
          ? 11
          : 1;
      i >=
          (index == 0
              ? 12
              : index == 1
              ? 2
              : 1);
      i--
    )
      relatedRow(i),
  ],
  'next_before_id': index == 0
      ? historyId(12)
      : index == 1
      ? historyId(2)
      : null,
};
