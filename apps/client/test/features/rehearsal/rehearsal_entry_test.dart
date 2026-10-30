import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/history/history_controller.dart';
import 'package:simontalk_client/features/history/history_models.dart';
import 'package:simontalk_client/features/history/history_view.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_providers.dart';

import '../history/history_fixtures.dart' show historyItem;
import '../review/review_screen_test.dart' show ReviewAccountController;
import '../practice/practice_providers_test.dart' show signedIn;
import 'rehearsal_fixtures.dart';

void main() {
  for (final kind in ['ordinary', 'rehearsal', 'unexpected']) {
    test('eligibility requires a current ordinary source: $kind', () async {
      var calls = 0;
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(
            () => ReviewAccountController(signedIn(accountId)),
          ),
          rehearsalHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((r) async {
              calls++;
              expect(r.method, 'GET');
              expect(r.headers['X-Account-ID'], accountId);
              return response({
                ...practiceJson(),
                'kind': kind,
                'source_session_id': kind == 'ordinary' ? null : childId,
                'source_review_item_id': kind == 'ordinary' ? null : itemId,
              });
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(api.close);
      expect(
        await container.read(rehearsalEligibilityProvider(practiceId).future),
        kind == 'ordinary',
      );
      expect(calls, 1);
    });
  }
  testWidgets('independent child detail links to its fixed target only', (
    t,
  ) async {
    var opened = false;
    final item = HistoryItem.fromJson({
      ...historyItem(1),
      'kind': 'rehearsal',
      'source_session_id': practiceId,
    });
    await t.pumpWidget(
      MaterialApp(
        home: HistoryView(
          state: HistoryState.ready,
          item: item,
          detail: true,
          onTarget: () => opened = true,
        ),
      ),
    );
    await t.ensureVisible(find.text('查看重练目标'));
    await t.tap(find.text('查看重练目标'));
    expect(opened, isTrue);
  });
}
