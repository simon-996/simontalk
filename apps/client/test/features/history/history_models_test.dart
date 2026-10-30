import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/history/history_models.dart';

import 'history_fixtures.dart';

void main() {
  test(
    'owner-bound ordered immutable summary page with microsecond cursor',
    () {
      final p = HistoryPage.fromJson(historyPage(), accountId: accountId);
      expect(p.items, hasLength(10));
      expect(p.items.first.id, historyId(21));
      expect(p.items.first.createdAt.microsecond, 456);
      expect(() => p.items.clear(), throwsUnsupportedError);
    },
  );
  for (final change in [
    'owner',
    'source',
    'schema',
    'duplicate',
    'order',
    'limit',
    'cursor',
    'coverage',
    'parent',
    'difficulty',
    'time',
    'pending',
  ]) {
    test('rejects malformed $change atomically', () {
      final j = historyPage();
      final items = j['items'] as List;
      switch (change) {
        case 'owner':
          j['account_id'] = historyId(1);
        case 'source':
          j['source'] = 'fixture';
        case 'schema':
          j['schema_version'] = 'other';
        case 'duplicate':
          items[1] = items[0];
        case 'order':
          final x = items[0];
          items[0] = items[1];
          items[1] = x;
        case 'limit':
          j['limit'] = 11;
        case 'cursor':
          j['next_cursor'] = historyCursor(11);
        case 'coverage':
          items[0]['coverage'] = 'complete';
        case 'parent':
          items[0]['source_session_id'] = historyId(3);
        case 'difficulty':
          items[0]['difficulty'] = 'invented';
        case 'time':
          items[0]['created_at'] = '2026-10-20';
        case 'pending':
          items[0]['connection_pending'] = 1;
      }
      expect(
        () => HistoryPage.fromJson(j, accountId: accountId),
        throwsFormatException,
      );
    });
  }
  test('detail binds requested ID, accepts real rehearsal and independent pending seal', () {
    final j = historyDetail(1, sealed: true);
    final item = j['item'] as Map<String, dynamic>;
    item['kind'] = 'rehearsal';
    item['source_session_id'] = historyId(2);
    item['connection_pending'] = true;
    final parsed = HistoryItem.fromDetail(
      j,
      accountId: accountId,
      sessionId: historyId(1),
    );
    expect(parsed.isSealed, isTrue);
    expect(parsed.connectionPending, isTrue);
    expect(
      () => HistoryItem.fromDetail(
        j,
        accountId: accountId,
        sessionId: historyId(3),
      ),
      throwsFormatException,
    );
  });
}
