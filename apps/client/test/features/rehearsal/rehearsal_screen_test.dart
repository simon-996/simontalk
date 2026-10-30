import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/app.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_providers.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_view.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_controller.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';

import '../review/review_screen_test.dart' show ReviewAccountController;
import '../practice/practice_providers_test.dart' show signedIn;
import 'rehearsal_fixtures.dart';

void main() {
  final requests = <http.Request>[];
  late ApiClient api;
  late ReviewAccountController account;
  late Future<http.Response> Function(http.Request) handler;
  Future<void> launch(
    WidgetTester t, {
    bool child = false,
    AccountState? initial,
  }) async {
    t.platformDispatcher.defaultRouteNameTestValue = child
        ? '/practice/$childId/rehearsal-target'
        : '/practice/$practiceId/rehearse/$itemId';
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    requests.clear();
    handler = (r) async => response(
      r.url.path.endsWith('/discard-preparation')
          ? childJson(status: 'cancelled')
          : r.method == 'POST'
          ? rehearsalPreparationJson()
          : r.url.path.endsWith('/rehearsal-target')
          ? rehearsalTargetJson()
          : childJson(),
    );
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    account = ReviewAccountController(initial ?? signedIn(accountId));
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          rehearsalHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((r) async {
              requests.add(r);
              return handler(r);
            }),
          ),
        ],
        child: const SimonTalkApp(),
      ),
    );
    await t.pumpAndSettle();
  }

  GoRouter router(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first));
  RehearsalView view(WidgetTester t) => t.widget(find.byType(RehearsalView));
  void makeBusy() => account.change(
    AccountState(
      phase: SessionPhase.signedIn,
      session: account.state.session,
      busy: true,
    ),
  );
  for (final action in ['confirm', 'replay', 'discard']) {
    for (final change in ['busy', 'route']) {
      testWidgets('old rehearsal $action rejects $change before POST', (
        t,
      ) async {
        await launch(t);
        if (action == 'replay') {
          handler = (_) async => response({'code': 'service_unavailable'}, 503);
          view(t).onConfirm!();
          await t.pumpAndSettle();
          expect(view(t).state, RehearsalState.unconfirmed);
        } else if (action == 'discard') {
          view(t).onConfirm!();
          await t.pumpAndSettle();
          expect(view(t).state, RehearsalState.prepared);
        }
        final shown = view(t);
        final callback = action == 'confirm'
            ? shown.onConfirm!
            : action == 'replay'
            ? shown.onReplay!
            : shown.onDiscard!;
        final count = requests.length;
        if (change == 'busy') {
          makeBusy();
        } else {
          router(t).go('/account');
        }
        expect(callback, returnsNormally);
        await t.pump(const Duration(milliseconds: 100));
        expect(requests, hasLength(count));
      });
    }
  }
  for (final action in [
    'refresh',
    'difficulty',
    'history',
    'practice',
    'settings',
  ]) {
    for (final change in ['busy', 'route']) {
      testWidgets('old rehearsal $action rejects $change', (t) async {
        await launch(t);
        if (action == 'history') {
          view(t).onConfirm!();
          await t.pumpAndSettle();
        }
        final scope = ProviderScope.containerOf(
          t.element(find.byType(RehearsalView)),
        );
        final c = scope.read(
          rehearsalProvider((sessionId: practiceId, itemId: itemId)),
        )!;
        final shown = view(t);
        final callback = switch (action) {
          'refresh' => shown.onRefresh!,
          'difficulty' => () => shown.onDifficulty!(Difficulty.advanced),
          'history' => shown.onHistory!,
          'practice' => shown.onPractice!,
          _ => shown.onSettings!,
        };
        final count = requests.length;
        final difficulty = c.difficulty;
        if (change == 'busy') {
          makeBusy();
        } else {
          router(t).go('/account');
        }
        final expectedPath = router(t).routeInformationProvider.value.uri.path;
        final couldPop = router(t).canPop();
        expect(callback, returnsNormally);
        expect(router(t).canPop(), couldPop);
        expect(c.difficulty, difficulty);
        expect(router(t).routeInformationProvider.value.uri.path, expectedPath);
        await t.pump(const Duration(milliseconds: 100));
        expect(requests, hasLength(count));
        expect(router(t).canPop(), couldPop);
        expect(router(t).routeInformationProvider.value.uri.path, expectedPath);
      });
    }
  }
  testWidgets('old rehearsal back rejects account busy before returning', (
    t,
  ) async {
    await launch(t);
    final back = view(t).onBack!;
    makeBusy();
    back();
    expect(
      router(t).routeInformationProvider.value.uri.path,
      '/practice/$practiceId/rehearse/$itemId',
    );
  });
  testWidgets('current rehearsal back remains available during target read', (
    t,
  ) async {
    await launch(t);
    handler = (_) async => response({'code': 'network_unavailable'}, 503);
    view(t).onRefresh!();
    expect(view(t).onBack, isNotNull);
    view(t).onBack!();
    await t.pumpAndSettle();
    expect(
      router(t).routeInformationProvider.value.uri.path,
      '/practice/$practiceId/review',
    );
  });
  testWidgets('old confirmation cannot use newly selected difficulty', (
    t,
  ) async {
    await launch(t);
    final old = view(t).onConfirm!;
    view(t).onDifficulty!(Difficulty.advanced);
    old();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
    expect(view(t).difficulty, Difficulty.advanced);
    view(t).onConfirm!();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
  });
  testWidgets('old confirmation cannot use refreshed target', (t) async {
    await launch(t);
    final old = view(t).onConfirm!;
    handler = (_) async =>
        response({...rehearsalTargetJson(), 'target_hash': 'e' * 64});
    view(t).onRefresh!();
    await t.pumpAndSettle();
    old();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
  for (final change in ['route', 'busy', 'disposed']) {
    testWidgets('old rehearsal reconnect rejects $change', (t) async {
      await launch(
        t,
        initial: const AccountState(phase: SessionPhase.unreachable),
      );
      final callback = t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '重新连接'))
          .onPressed!;
      if (change == 'route') {
        router(t).go('/account');
      } else if (change == 'busy') {
        account.change(
          const AccountState(phase: SessionPhase.unreachable, busy: true),
        );
      } else {
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      }
      expect(callback, returnsNormally);
      expect(account.reconnects, 0);
    });
  }
  testWidgets(
    'account busy preserves target and shows account operation without request spinner',
    (t) async {
      await launch(t);
      makeBusy();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Yes, I enjoy English.'), findsOneWidget);
      expect(find.text('账号操作进行中，请稍候…'), findsOneWidget);
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '返回原复盘'),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认并准备'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'restored account permits exact original pending request replay',
    (t) async {
      await launch(t);
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      view(t).onConfirm!();
      await t.pumpAndSettle();
      final first = requests.last;
      makeBusy();
      await t.pump(const Duration(milliseconds: 100));
      account.change(signedIn(accountId));
      await t.pumpAndSettle();
      handler = (_) async => response(rehearsalPreparationJson());
      view(t).onReplay!();
      await t.pumpAndSettle();
      expect(requests.last.body, first.body);
      expect(
        requests.last.headers['Idempotency-Key'],
        first.headers['Idempotency-Key'],
      );
      expect(view(t).state, RehearsalState.prepared);
    },
  );
  testWidgets(
    'deep link only reads then explicit prepare and discard use independent child',
    (t) async {
      await launch(t);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(find.text('Yes, I enjoy English.'), findsOneWidget);
      await t.ensureVisible(find.text('确认并准备'));
      await t.tap(find.text('确认并准备'));
      await t.pumpAndSettle();
      expect(requests.where((r) => r.method == 'POST'), hasLength(1));
      expect(find.text('已登记重练准备'), findsOneWidget);
      await t.ensureVisible(find.text('放弃本次准备'));
      await t.tap(find.text('放弃本次准备'));
      await t.pumpAndSettle();
      expect(find.text('本次准备已取消'), findsOneWidget);
    },
  );
  testWidgets(
    'stale prepared history button cannot navigate after owner changes before rebuild',
    (t) async {
      await launch(t);
      await t.ensureVisible(find.text('确认并准备'));
      await t.tap(find.text('确认并准备'));
      await t.pumpAndSettle();
      final action = t
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '查看本次记录'))
          .onPressed!;
      api.expectedAccountId = childId;
      expect(action, returnsNormally);
      expect(
        router(t).routeInformationProvider.value.uri.path,
        '/practice/$practiceId/rehearse/$itemId',
      );
    },
  );
  testWidgets(
    'child target direct link is read only and returns to child detail',
    (t) async {
      await launch(t, child: true);
      expect(requests, hasLength(2));
      expect(find.text('确认并准备'), findsNothing);
      expect(find.text('Yes, I enjoy English.'), findsOneWidget);
      await t.ensureVisible(find.text('返回重练详情'));
      await t.tap(find.text('返回重练详情'));
      await t.pumpAndSettle();
      expect(
        router(t).routeInformationProvider.value.uri.path,
        '/history/$childId',
      );
    },
  );
  testWidgets(
    'unreachable account preserves target address then explicit restore reads',
    (t) async {
      await launch(
        t,
        initial: const AccountState(phase: SessionPhase.unreachable),
      );
      expect(requests, isEmpty);
      expect(
        router(t).routeInformationProvider.value.uri.path,
        '/practice/$practiceId/rehearse/$itemId',
      );
      await t.tap(find.text('重新连接'));
      await t.pumpAndSettle();
      expect(requests, hasLength(1));
    },
  );
  testWidgets(
    'unset preference can read but must finish daily settings before creating',
    (t) async {
      final ready = signedIn(accountId);
      final session = ready.session!;
      final prefs = AccountPreferences.fromJson({
        ...session.preferences.toJson(),
        'difficulty': null,
      });
      await launch(
        t,
        initial: AccountState(
          phase: SessionPhase.signedIn,
          session: AccountSession(session.user, prefs),
        ),
      );
      expect(requests, hasLength(1));
      expect(find.text('Yes, I enjoy English.'), findsOneWidget);
      expect(find.text('确认并准备'), findsNothing);
      expect(find.text('本次难度'), findsNothing);
      await t.ensureVisible(find.text('去设置难度'));
      await t.tap(find.text('去设置难度'));
      await t.pumpAndSettle();
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
      expect(router(t).routeInformationProvider.value.uri.path, '/setup');
    },
  );
  for (final size in [const Size(320, 720), const Size(844, 390)]) {
    testWidgets(
      'target reading $size dark 200% supports selection and actions',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: RehearsalView(
                state: RehearsalState.ready,
                target: RehearsalTarget.fromJson(
                  rehearsalTargetJson(),
                  accountId: accountId,
                  sourceSessionId: practiceId,
                  itemId: itemId,
                ),
                difficulty: Difficulty.beginner,
                onConfirm: () {},
                onBack: () {},
                onDifficulty: (_) {},
                onRefresh: () {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.ensureVisible(find.text('确认并准备'));
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'replayed preparation already active elsewhere never claims voice has not started',
    (t) async {
      final p = PracticePreparation.fromJson({
        ...childJson(status: 'active'),
        'connection_epoch': 1,
      });
      await t.pumpWidget(
        MaterialApp(
          home: RehearsalView(state: RehearsalState.prepared, preparation: p),
        ),
      );
      expect(find.textContaining('语音尚未开启'), findsNothing);
      expect(find.textContaining('本次练习状态已变化'), findsWidgets);
    },
  );
  testWidgets(
    'identity failure hides previously supplied target and retry creation',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: RehearsalView(
            state: RehearsalState.aborted,
            errorCode: 'account_changed',
            target: RehearsalTarget.fromJson(
              rehearsalTargetJson(),
              accountId: accountId,
              sourceSessionId: practiceId,
              itemId: itemId,
            ),
            onConfirm: () {},
          ),
        ),
      );
      expect(find.text('Yes, I enjoy English.'), findsNothing);
      expect(find.text('确认并准备'), findsNothing);
    },
  );
}
