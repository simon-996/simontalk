import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/connection_observation_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/practice/practice_recovery_panel.dart';

import 'practice_fixtures.dart';
import 'practice_providers_test.dart' show ScopedAccountController;
import 'recovery_fixtures.dart';
import 'practice_completion_test.dart' show completionSummary;
import 'saved_status_recovery_test.dart' show terminationSnapshot;
import 'practice_save_status_view_test.dart' show savedSummary, savedCheck;

PracticeRecovery unknownRecovery() => PracticeRecovery.fromJson({
  'practice': practiceJson(status: 'interrupted', epoch: 1),
  'connection': connectionJson(status: 'unknown', termination: 'unknown'),
});

void main() {
  testWidgets('sealed saved source exposes a review entry only while usable', (
    tester,
  ) async {
    var opened = 0;
    Future<void> show({
      bool busy = false,
      bool loaded = true,
      bool accountReady = true,
      bool ending = false,
      bool missing = false,
      String? error,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PracticeRecoveryView(
              recovery: unknownRecovery(),
              savedCompletion: missing
                  ? null
                  : ending
                  ? PracticeCompletionSummary.fromJson(
                      completionSummary(),
                      scope: savedSummary().scope,
                    )
                  : savedSummary(),
              reviewEntryAvailable: accountReady,
              onOpenReview: () => opened++,
              saveStatusLoaded: loaded,
              saveStatusErrorCode: error,
              busy: busy,
            ),
          ),
        ),
      ),
    );
    await show();
    expect(find.text('查看复盘'), findsOneWidget);
    await tester.ensureVisible(find.text('查看复盘'));
    await tester.tap(find.text('查看复盘'));
    expect(opened, 1);
    await show(ending: true);
    expect(find.text('查看复盘'), findsNothing);
    await show(missing: true);
    expect(find.text('查看复盘'), findsNothing);
    await show(accountReady: false);
    expect(find.text('查看复盘'), findsNothing);
    await show(busy: true);
    expect(find.text('查看复盘'), findsNothing);
    await show(loaded: false);
    expect(find.text('查看复盘'), findsNothing);
    await show(error: 'account_changed');
    expect(find.text('查看复盘'), findsNothing);
  });

  testWidgets(
    'actual panel only reads on explicit actions, preserves unknown alongside local close',
    (tester) async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final closed = pageJson(sequences: [1]);
      closed['events'] = [observationJson(1, code: 'local_closed')];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(ScopedAccountController.new),
            recoveryHttpClientFactoryProvider.overrideWithValue(
              () => MockClient((r) async {
                requests.add(r);
                if (r.url.path.endsWith('/completion')) {
                  return response(completionSummary(sealed: true));
                }
                if (r.url.path.endsWith('/termination-check')) {
                  return response(terminationSnapshot());
                }
                if (r.url.path.endsWith('/observations')) {
                  return response(closed);
                }
                return response({
                  'practice': practiceJson(epoch: 1),
                  'connection': connectionJson(
                    status: 'unknown',
                    termination: 'unknown',
                  ),
                });
              }),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const Scaffold(
              body: SingleChildScrollView(child: PracticeRecoveryPanel()),
            ),
          ),
        ),
      );
      expect(requests, isEmpty);
      await tester.tap(find.text('查看未结束练习'));
      await tester.pumpAndSettle();
      expect(find.text('远端是否结束尚未确认'), findsOneWidget);
      expect(find.text('已有内容已保存，仍有缺口'), findsNothing);
      expect(requests, hasLength(1));
      await tester.ensureVisible(find.text('查看连接记录'));
      await tester.tap(find.text('查看连接记录'));
      await tester.pumpAndSettle();
      expect(find.text('客户端报告本地已关闭'), findsOneWidget);
      expect(find.text('远端是否结束尚未确认'), findsOneWidget);
      await tester.ensureVisible(find.text('查看保存状态'));
      await tester.tap(find.text('查看保存状态'));
      await tester.pumpAndSettle();
      expect(find.text('已有内容已保存，仍有缺口'), findsOneWidget);
      expect(find.textContaining('维护者协助确认'), findsOneWidget);
      expect(find.text('上次练习状态'), findsOneWidget);
      expect(find.text('服务器记录：练习已结束'), findsOneWidget);
      expect(requests, hasLength(4));
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(
        requests.every((r) => r.headers['X-Account-ID'] == accountId),
        isTrue,
      );
      expect(find.textContaining(connectionId), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty and read failure have explicit refresh without invented records',
    (tester) async {
      var refreshes = 0;
      Future<void> show(PracticeRecovery? recovery, String? error) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: PracticeRecoveryView(
                    recovery: recovery,
                    errorCode: error,
                    onRefresh: () => refreshes++,
                  ),
                ),
              ),
            ),
          );
      await show(
        PracticeRecovery.fromJson({'practice': null, 'connection': null}),
        null,
      );
      expect(find.text('没有未结束的练习'), findsOneWidget);
      expect(find.text('查看连接记录'), findsNothing);
      await tester.tap(find.text('刷新状态'));
      expect(refreshes, 1);
      await show(null, 'network_error');
      expect(find.textContaining('暂时无法读取'), findsOneWidget);
      expect(find.text('没有未结束的练习'), findsNothing);
    },
  );

  testWidgets(
    'identity errors offer account confirmation and disable stale reads',
    (tester) async {
      var confirmations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PracticeRecoveryView(
              errorCode: 'account_changed',
              onConfirmAccount: () => confirmations++,
            ),
          ),
        ),
      );
      expect(find.text('刷新状态'), findsNothing);
      await tester.tap(find.text('重新确认账号'));
      expect(confirmations, 1);
    },
  );

  testWidgets('busy view cannot request another read', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PracticeRecoveryView(busy: true))),
    );
    expect(find.text('正在读取状态…'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
  });

  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 568),
      const Size(375, 667),
      const Size(844, 390),
      const Size(1024, 768),
    ]) {
      testWidgets('unknown, closure and paging fit $brightness $size at 200%', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final recovery = unknownRecovery();
        final json = pageJson(
          sequences: List.generate(32, (i) => i + 1),
          total: 33,
          last: 40,
          more: true,
        );
        json['events'][0] = observationJson(1, code: 'local_closed');
        final page = ConnectionObservationPage.fromJson(
          json,
          connection: recovery.connection!,
          afterSequence: 0,
          limit: 32,
        );
        var more = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            home: MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: PracticeRecoveryView(
                        recovery: recovery,
                        saveStatusLoaded: true,
                        savedCompletion: savedSummary(),
                        terminationCheck: savedCheck(),
                        page: page,
                        events: page.events,
                        onLoadObservations: () => more++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('查看更多记录'));
        final button = find.widgetWithText(OutlinedButton, '查看更多记录');
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        await tester.tap(button);
        expect(more, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
