import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/practice/practice_recovery_panel.dart';
import 'package:simontalk_client/features/practice/preparation_discard_dialog.dart';

import '../review/review_screen_test.dart' show ReviewAccountController;
import 'practice_providers_test.dart' show signedIn;
import 'practice_fixtures.dart';
import 'recovery_fixtures.dart';
import 'practice_completion_test.dart' show completionSummary;
import 'saved_status_recovery_test.dart' show terminationSnapshot;
import 'final_transcript_recovery_test.dart' show textPage, textEvent;

void main() {
  late GoRouter nav;
  late ReviewAccountController account;
  late ProviderContainer container;
  late List<http.Request> requests;
  Future<void> launch(WidgetTester t, {bool cleanable = false}) async {
    final oldUrlOption = GoRouter.optionURLReflectsImperativeAPIs;
    GoRouter.optionURLReflectsImperativeAPIs = true;
    addTearDown(() => GoRouter.optionURLReflectsImperativeAPIs = oldUrlOption);
    requests = [];
    account = ReviewAccountController(signedIn(accountId));
    final api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    nav = GoRouter(
      initialLocation: '/panel',
      routes: [
        GoRoute(
          path: '/panel',
          builder: (_, _) => const Scaffold(
            body: SingleChildScrollView(child: PracticeRecoveryPanel()),
          ),
        ),
        GoRoute(
          path: '/other',
          builder: (_, _) => const Scaffold(body: Text('Other page')),
        ),
        GoRoute(
          path: '/practice/:id/review',
          builder: (_, _) => const Scaffold(body: Text('Review page')),
        ),
      ],
    );
    addTearDown(nav.dispose);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
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
                return response(pageJson());
              }
              if (r.url.path.endsWith('/transcripts')) {
                return response(textPage([textEvent(1)]));
              }
              if (r.method == 'POST') {
                return response(practiceJson(status: 'cancelled', epoch: 0));
              }
              return response({
                'practice': practiceJson(epoch: cleanable ? 0 : 1),
                'connection': cleanable
                    ? null
                    : connectionJson(status: 'unknown', termination: 'unknown'),
              });
            }),
          ),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(Brightness.light),
          routerConfig: nav,
        ),
      ),
    );
    await t.pumpAndSettle();
    container = ProviderScope.containerOf(
      t.element(find.byType(PracticeRecoveryPanel)),
    );
    await container.read(practiceRecoveryProvider)!.refresh();
    await t.pumpAndSettle();
  }

  PracticeRecoveryView view(WidgetTester t) =>
      t.widget(find.byType(PracticeRecoveryView));
  void busy() => account.change(signedIn(accountId, busy: true));
  for (final action in [
    'refresh',
    'observations',
    'text',
    'textRefresh',
    'save',
    'saveRefresh',
    'review',
    'restore',
  ]) {
    for (final change in ['busy', 'go', 'push']) {
      testWidgets('old recovery $action rejects $change', (t) async {
        await launch(t);
        final c = container.read(practiceRecoveryProvider)!;
        if (['review', 'saveRefresh'].contains(action)) {
          await c.loadSaveStatus();
        }
        if (action == 'textRefresh') await c.loadTranscripts();
        await t.pumpAndSettle();
        final shown = view(t);
        final callback = switch (action) {
          'refresh' => shown.onRefresh!,
          'observations' => shown.onLoadObservations!,
          'text' => shown.onLoadTranscripts!,
          'textRefresh' => shown.onRefreshTranscripts!,
          'save' => shown.onLoadSaveStatus!,
          'saveRefresh' => shown.onRefreshSaveStatus!,
          'review' => shown.onOpenReview!,
          _ => shown.onConfirmAccount!,
        };
        final count = requests.length;
        if (change == 'busy') {
          busy();
        } else if (change == 'go') {
          nav.go('/other');
        } else {
          nav.push('/other');
        }
        final expected = nav.routeInformationProvider.value.uri.path;
        expect(callback, returnsNormally);
        await t.pumpAndSettle();
        expect(requests, hasLength(count));
        expect(account.reconnects, 0);
        expect(nav.routeInformationProvider.value.uri.path, expected);
      });
    }
  }
  testWidgets('old source callback cannot read newly refreshed recovery', (
    t,
  ) async {
    await launch(t);
    final old = view(t).onLoadSaveStatus!;
    await container.read(practiceRecoveryProvider)!.refresh();
    await t.pumpAndSettle();
    final count = requests.length;
    old();
    await t.pumpAndSettle();
    expect(requests, hasLength(count));
    view(t).onLoadSaveStatus!();
    await t.pumpAndSettle();
    expect(requests.length, count + 2);
  });
  for (final change in ['busy', 'push']) {
    testWidgets('old recovery discard cannot open dialog after $change', (
      t,
    ) async {
      await launch(t, cleanable: true);
      final old = view(t).onDiscard!;
      if (change == 'busy') {
        busy();
      } else {
        nav.push('/other');
      }
      old();
      await t.pumpAndSettle();
      expect(
        find.byType(PreparationDiscardDialog, skipOffstage: false),
        findsNothing,
      );
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    });
  }
  testWidgets('confirmed discard rechecks account busy after dialog', (
    t,
  ) async {
    await launch(t, cleanable: true);
    view(t).onDiscard!();
    await t.pumpAndSettle();
    busy();
    await t.tap(find.text('确认清理'));
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
  testWidgets('current confirmed discard still sends one explicit cleanup', (
    t,
  ) async {
    await launch(t, cleanable: true);
    view(t).onDiscard!();
    await t.pumpAndSettle();
    await t.tap(find.text('确认清理'));
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    expect(find.text('这项准备已清理。请刷新查看当前状态。'), findsOneWidget);
  });
  for (final label in ['确认清理', '保留准备']) {
    for (final change in ['go', 'push', 'disposed']) {
      testWidgets('old discard dialog $label rejects $change', (t) async {
        await launch(t, cleanable: true);
        view(t).onDiscard!();
        await t.pumpAndSettle();
        final old = t
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed!;
        if (change == 'disposed') {
          await t.pumpWidget(const SizedBox());
          await t.pumpAndSettle();
          expect(old, returnsNormally);
        } else {
          if (change == 'go') {
            nav.go('/other');
          } else {
            nav.push('/other');
          }
          expect(old, returnsNormally);
          await t.pumpAndSettle();
          expect(nav.routeInformationProvider.value.uri.path, '/other');
        }
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
      });
    }
  }
  testWidgets(
    'recovery account operation has independent notice and disables actions',
    (t) async {
      await launch(t, cleanable: true);
      busy();
      await t.pumpAndSettle();
      expect(find.text('账号操作进行中，请稍候…'), findsOneWidget);
      for (final label in ['刷新状态', '清理未开始的准备']) {
        expect(
          t
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, label),
              )
              .onPressed,
          isNull,
        );
      }
    },
  );
}
