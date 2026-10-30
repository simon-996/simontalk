import 'dart:async';

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
import 'package:simontalk_client/features/history/history_providers.dart';
import 'package:simontalk_client/features/history/history_view.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_providers.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_view.dart';

import '../history/history_fixtures.dart';
import '../review/review_screen_test.dart' show ReviewAccountController;
import 'practice_completion_test.dart' show completionSummary;
import 'practice_providers_test.dart' show signedIn;
import 'saved_practice_status_test.dart' show saveStatusDetail;

void main() {
  final requests = <http.Request>[];
  late ApiClient api;
  late ReviewAccountController account;
  late Future<http.Response> Function(http.Request) handler;
  Future<void> launch(
    WidgetTester t, {
    String? path,
    String stage = 'sealed',
    AccountState? initial,
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    requests.clear();
    t.platformDispatcher.defaultRouteNameTestValue =
        path ?? '/practice/$practiceId/save-status';
    t.platformDispatcher.platformBrightnessTestValue = brightness;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    handler = (r) async {
      if (r.url.path.endsWith('/completion')) {
        return stage == 'unregistered'
            ? response({'code': 'completion_not_found'}, 404)
            : response(completionSummary(sealed: stage == 'sealed'));
      }
      if (r.url.path == '/v1/practice-history') return response(historyPage());
      return response(saveStatusDetail(stage: stage));
    };
    Future<http.Response> dispatch(http.Request r) {
      requests.add(r);
      return handler(r);
    }

    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient(dispatch),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    account = ReviewAccountController(initial ?? signedIn(accountId));
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          savedPracticeStatusHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          historyHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
        ],
        child: SimonTalkApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  GoRouter router(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first));
  String path(WidgetTester t) =>
      router(t).routeInformationProvider.value.uri.path;
  Future<void> tap(WidgetTester t, String label) async {
    await t.ensureVisible(find.text(label));
    await t.tap(find.text(label));
    await t.pumpAndSettle();
  }

  testWidgets(
    'saved result reads the URL practice and shows exact gap plus aggregate warning',
    (t) async {
      await launch(t);
      expect(path(t), '/practice/$practiceId/save-status');
      expect(find.text('这次练习的保存情况'), findsOneWidget);
      expect(find.text('已有内容已保存，仍有缺口'), findsOneWidget);
      expect(find.text('部分话语可能未完成识别。'), findsOneWidget);
      expect(find.text('仍有连接与用量待核对。文字保存不会解除连接占用。'), findsOneWidget);
      expect(requests, hasLength(2));
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      await tap(t, '返回练习详情');
      expect(path(t), '/history/$practiceId');
    },
  );

  for (final stage in ['ending', 'unregistered']) {
    testWidgets('$stage has truthful status without saved text claims', (
      t,
    ) async {
      await launch(t, stage: stage);
      expect(
        find.text(stage == 'ending' ? '正在保存本次记录' : '尚未登记结束保存'),
        findsOneWidget,
      );
      expect(find.text('已有内容已保存，仍有缺口'), findsNothing);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    });
  }

  for (final phase in [SessionPhase.restoring, SessionPhase.unreachable]) {
    testWidgets('$phase preserves deep link with zero reads until signed in', (
      t,
    ) async {
      await launch(t, initial: AccountState(phase: phase));
      expect(path(t), '/practice/$practiceId/save-status');
      expect(requests, isEmpty);
      account.change(signedIn(accountId));
      await t.pumpAndSettle();
      expect(find.text('已有内容已保存，仍有缺口'), findsOneWidget);
      expect(requests, hasLength(2));
    });
  }

  testWidgets(
    'difficulty not yet selected still permits saved result reading',
    (t) async {
      final original = signedIn(accountId).session!;
      final session = AccountSession(
        original.user,
        AccountPreferences(
          difficulty: null,
          speechPace: original.preferences.speechPace,
          subtitleDefault: original.preferences.subtitleDefault,
          chineseHintsEnabled: original.preferences.chineseHintsEnabled,
          version: original.preferences.version,
        ),
      );
      await launch(
        t,
        initial: AccountState(phase: SessionPhase.signedIn, session: session),
      );
      expect(path(t), '/practice/$practiceId/save-status');
      expect(requests, hasLength(2));
    },
  );

  testWidgets(
    'refresh failure clears successful status and explicit retry restores',
    (t) async {
      await launch(t);
      final normal = handler;
      handler = (_) async => throw http.ClientException('offline');
      await tap(t, '刷新保存状态');
      expect(find.text('已有内容已保存，仍有缺口'), findsNothing);
      expect(find.text('部分话语可能未完成识别。'), findsNothing);
      expect(find.text('暂时无法读取保存情况，请检查网络后重试。'), findsOneWidget);
      handler = normal;
      await tap(t, '重新读取保存情况');
      expect(find.text('已有内容已保存，仍有缺口'), findsOneWidget);
    },
  );

  testWidgets(
    'history detail opens saved status and back keeps actual destination',
    (t) async {
      await launch(t, path: '/history/$practiceId');
      await tap(t, '查看保存情况');
      expect(path(t), '/practice/$practiceId/save-status');
      expect(find.text('部分话语可能未完成识别。'), findsOneWidget);
      await tap(t, '返回练习详情');
      expect(path(t), '/history/$practiceId');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  for (final change in ['busy', 'route', 'owner']) {
    testWidgets('old saved result refresh rejects $change changes', (t) async {
      await launch(t);
      final old = t
          .widget<SavedPracticeStatusView>(find.byType(SavedPracticeStatusView))
          .onRefresh!;
      final before = requests.length;
      if (change == 'route') {
        router(t).go('/account');
      } else if (change == 'busy') {
        account.change(
          AccountState(
            phase: SessionPhase.signedIn,
            session: account.state.session,
            busy: true,
          ),
        );
      } else {
        account.change(signedIn(historyId(99)));
      }
      old();
      await t.pumpAndSettle();
      expect(requests, hasLength(before));
      if (change == 'route') expect(path(t), '/account');
    });
  }

  testWidgets('account busy blocks refresh without claiming a source read', (
    t,
  ) async {
    await launch(t);
    account.change(
      AccountState(
        phase: SessionPhase.signedIn,
        session: account.state.session,
        busy: true,
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('账号操作进行中，请稍候…'), findsOneWidget);
    expect(find.text('正在核对保存状态…'), findsNothing);
    expect(
      t
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '刷新保存状态'))
          .onPressed,
      isNull,
    );
    expect(requests, hasLength(2));
  });

  for (final change in ['busy', 'route', 'refresh']) {
    testWidgets('old history save-status entry rejects $change', (t) async {
      await launch(t, path: '/history/$practiceId');
      final old = t.widget<HistoryView>(find.byType(HistoryView)).onSaveStatus!;
      if (change == 'route') {
        router(t).go('/account');
      } else if (change == 'busy') {
        account.change(
          AccountState(
            phase: SessionPhase.signedIn,
            session: account.state.session,
            busy: true,
          ),
        );
      } else {
        final container = ProviderScope.containerOf(
          t.element(find.byType(HistoryView)),
        );
        final pending = Completer<http.Response>();
        handler = (_) => pending.future;
        final work = container.read(historyProvider(practiceId))!.refresh();
        old();
        await t.pump();
        expect(path(t), '/history/$practiceId');
        pending.complete(response(saveStatusDetail()));
        await work;
        await t.pumpAndSettle();
        return;
      }
      old();
      await t.pumpAndSettle();
      expect(path(t), change == 'route' ? '/account' : '/history/$practiceId');
      expect(
        requests.where((r) => r.url.path.endsWith('/completion')),
        isEmpty,
      );
    });
  }

  testWidgets('invalid address returns to history without a request', (
    t,
  ) async {
    await launch(t, path: '/practice/not-a-practice/save-status');
    expect(find.text('练习地址无效。'), findsOneWidget);
    await tap(t, '返回练习详情');
    expect(path(t), '/history');
    expect(requests.every((r) => r.url.path == '/v1/practice-history'), isTrue);
  });

  for (final size in [
    const Size(320, 720),
    const Size(375, 812),
    const Size(844, 390),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('save result $size $brightness at 200 percent wraps', (
        t,
      ) async {
        await launch(t, size: size, brightness: brightness, scale: 2);
        expect(
          MediaQuery.textScalerOf(
            t.element(find.byType(SavedPracticeStatusView)),
          ).scale(10),
          20,
        );
        await t.ensureVisible(find.text('刷新保存状态'));
        expect(t.takeException(), isNull);
      });
    }
  }
}
