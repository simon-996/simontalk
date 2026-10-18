import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/practice/practice_recovery_controller.dart';
import 'package:simontalk_client/features/practice/practice_recovery_panel.dart';
import 'package:simontalk_client/features/practice/preparation_discard_dialog.dart';

import 'practice_fixtures.dart';
import 'practice_providers_test.dart' show ScopedAccountController;
import 'preparation_discard_test.dart' show candidateJson;

void main() {
  testWidgets(
    'cancel sends no mutation, confirm discards once and does not invent empty current',
    (tester) async {
      final requests = <http.Request>[];
      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: true,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(ScopedAccountController.new),
            recoveryHttpClientFactoryProvider.overrideWithValue(
              () => MockClient((r) async {
                requests.add(r);
                if (r.url.path.endsWith('/csrf')) {
                  return response({'csrf_token': 'test'});
                }
                return response(
                  r.url.path.endsWith('/discard-preparation')
                      ? practiceJson(status: 'cancelled', epoch: 1)
                      : candidateJson(),
                );
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
      await tester.tap(find.text('查看未结束练习'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('清理未开始的准备'));
      await tester.tap(find.text('清理未开始的准备'));
      await tester.pumpAndSettle();
      expect(find.byType(PreparationDiscardDialog), findsOneWidget);
      await tester.tap(find.text('保留准备'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      await tester.tap(find.text('清理未开始的准备'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(
        requests.where((r) => r.url.path.endsWith('/discard-preparation')),
        hasLength(1),
      );
      expect(requests, hasLength(3));
      expect(find.text('这项准备已清理。请刷新查看当前状态。'), findsOneWidget);
      expect(find.text('没有未结束的练习'), findsNothing);
      expect(find.text('清理未开始的准备'), findsNothing);
      expect(find.text('刷新状态'), findsOneWidget);
    },
  );

  testWidgets('unknown and confirmed media are never cleanup candidates', (
    tester,
  ) async {
    final recovery = PracticeRecovery.fromJson({
      'practice': practiceJson(epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PracticeRecoveryView(recovery: recovery, onDiscard: () {}),
          ),
        ),
      ),
    );
    expect(find.text('清理未开始的准备'), findsNothing);
    expect(find.text('远端是否结束尚未确认'), findsOneWidget);
  });

  for (final status in [
    PreparationCleanupStatus.unconfirmed,
    PreparationCleanupStatus.refused,
  ]) {
    testWidgets('$status only offers refresh instead of repeating cleanup', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PracticeRecoveryView(cleanupStatus: status)),
        ),
      );
      expect(find.text('刷新状态'), findsOneWidget);
      expect(find.text('清理未开始的准备'), findsNothing);
      expect(find.text('没有未结束的练习'), findsNothing);
      expect(
        find.textContaining(
          status == PreparationCleanupStatus.unconfirmed
              ? '清理结果尚未确认'
              : '暂不能安全清理',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets(
    'working cleanup uses action status rather than reading or success',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PracticeRecoveryView(
              busy: true,
              cleanupStatus: PreparationCleanupStatus.working,
            ),
          ),
        ),
      );
      expect(find.text('正在清理准备…'), findsOneWidget);
      expect(find.text('正在读取状态…'), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
    },
  );

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(844, 390)]) {
      testWidgets('dialog remains operable at $size $brightness and 200%', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        bool? confirmed;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => const PreparationDiscardDialog(),
                  ),
                  child: const Text('打开确认'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开确认'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('确认清理'));
        expect(
          tester.getSize(find.widgetWithText(TextButton, '确认清理')).height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.text('确认清理'));
        await tester.pumpAndSettle();
        expect(confirmed, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
