import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:simontalk_client/features/rehearsal/rehearsal_list_providers.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_list_view.dart';

import '../practice/practice_providers_test.dart' show signedIn;
import '../review/review_screen_test.dart' show ReviewAccountController;
import 'rehearsal_list_fixtures.dart';

void main() {
  final requests = <http.Request>[];
  late ApiClient api;
  late ReviewAccountController account;
  late Future<http.Response> Function(http.Request) handler;
  Future<void> launch(
    WidgetTester t, {
    String? path,
    AccountState? initial,
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    requests.clear();
    t.platformDispatcher.defaultRouteNameTestValue =
        path ?? '/history/$practiceId/rehearsals';
    t.platformDispatcher.platformBrightnessTestValue = brightness;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    handler = (r) async {
      if (r.url.path.endsWith('/rehearsals')) {
        final before = r.url.queryParameters['before_id'];
        return response(
          relatedPage(
            before == historyId(12)
                ? 1
                : before == historyId(2)
                ? 2
                : 0,
          ),
        );
      }
      final id = r.url.path.split('/').last;
      final child = id != practiceId;
      return response({
        'schema_version': 'practice_history_detail_v1',
        'source': 'server_recorded',
        'account_id': accountId,
        'item': {
          ...historyItem(1),
          'id': id,
          'kind': child ? 'rehearsal' : 'ordinary',
          'source_session_id': child ? practiceId : null,
        },
      });
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
          historyHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          rehearsalListHttpClientFactoryProvider.overrideWithValue(
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
  RehearsalListView view(WidgetTester t) =>
      t.widget(find.byType(RehearsalListView));
  for (final action in ['refresh', 'previous', 'next', 'open', 'back']) {
    for (final change in ['busy', 'go', 'push']) {
      testWidgets('old related $action rejects $change', (t) async {
        await launch(t);
        if (action == 'previous') {
          view(t).onNext!();
          await t.pumpAndSettle();
        }
        final shown = view(t);
        final callback = switch (action) {
          'refresh' => shown.onRefresh!,
          'previous' => shown.onPrevious!,
          'next' => shown.onNext!,
          'open' => () => shown.onOpen!(shown.page!.items.first.id),
          _ => shown.onBack!,
        };
        final count = requests.length;
        if (change == 'busy') {
          account.change(
            AccountState(
              phase: SessionPhase.signedIn,
              session: account.state.session,
              busy: true,
            ),
          );
        } else if (change == 'go') {
          router(t).go('/account');
        } else {
          router(t).push('/account');
        }
        final expected = router(t).routeInformationProvider.value.uri.path;
        expect(callback, returnsNormally);
        await t.pump(const Duration(milliseconds: 100));
        expect(requests, hasLength(count));
        expect(router(t).routeInformationProvider.value.uri.path, expected);
      });
    }
  }
  testWidgets('old related next cannot page from subsequently displayed page', (
    t,
  ) async {
    await launch(t);
    final next = view(t).onNext!;
    next();
    await t.pumpAndSettle();
    expect(view(t).pageNumber, 2);
    final count = requests.length;
    next();
    await t.pumpAndSettle();
    expect(requests, hasLength(count));
    expect(view(t).pageNumber, 2);
    view(t).onNext!();
    await t.pumpAndSettle();
    expect(view(t).pageNumber, 3);
  });
  testWidgets('old related row cannot open same ID from a refreshed page', (
    t,
  ) async {
    await launch(t);
    final original = view(t);
    original.onRefresh!();
    await t.pumpAndSettle();
    original.onOpen!(original.page!.items.first.id);
    await t.pumpAndSettle();
    expect(
      router(t).routeInformationProvider.value.uri.path,
      '/history/$practiceId/rehearsals',
    );
  });
  for (final change in ['busy', 'go', 'disposed']) {
    testWidgets('old related reconnect rejects $change', (t) async {
      await launch(
        t,
        initial: const AccountState(phase: SessionPhase.unreachable),
      );
      final callback = t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '重新连接'))
          .onPressed!;
      if (change == 'busy') {
        account.change(
          const AccountState(phase: SessionPhase.unreachable, busy: true),
        );
      } else if (change == 'go') {
        router(t).go('/account');
      } else {
        await t.pumpWidget(const SizedBox());
        await t.pumpAndSettle();
      }
      expect(callback, returnsNormally);
      expect(account.reconnects, 0);
    });
  }
  testWidgets('account busy retains related rows without pretending to read', (
    t,
  ) async {
    await launch(t);
    final originalPage = view(t).page;
    account.change(
      AccountState(
        phase: SessionPhase.signedIn,
        session: account.state.session,
        busy: true,
      ),
    );
    await t.pumpAndSettle();
    expect(view(t).page, same(originalPage));
    expect(find.text('账号操作进行中，请稍候…'), findsOneWidget);
    expect(find.text('正在读取关联重练…'), findsNothing);
    for (final label in ['刷新关联重练', '下一页', '返回来源练习']) {
      expect(
        t
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
            .onPressed,
        isNull,
      );
    }
  });
  testWidgets(
    'covered related read completion cannot steal focus from another route',
    (t) async {
      await launch(t);
      final done = Completer<http.Response>();
      handler = (_) => done.future;
      view(t).onNext!();
      await t.pump();
      router(t).push('/account');
      await t.pumpAndSettle();
      done.complete(response(relatedPage(1)));
      await t.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('关联重练当前页'));
      expect(router(t).routeInformationProvider.value.uri.path, '/account');
    },
  );
  testWidgets('ordinary detail offers related list but child does not', (
    t,
  ) async {
    await launch(t, path: '/history/$practiceId');
    await t.ensureVisible(find.text('查看关联重练'));
    await t.tap(find.text('查看关联重练'));
    await t.pumpAndSettle();
    expect(
      router(t).routeInformationProvider.value.uri.path,
      '/history/$practiceId/rehearsals',
    );
    expect(find.text('关联重练'), findsOneWidget);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    await t.ensureVisible(find.byKey(ValueKey('related-${historyId(21)}')));
    await t.tap(find.byKey(ValueKey('related-${historyId(21)}')));
    await t.pumpAndSettle();
    expect(find.text('查看关联重练'), findsNothing);
    expect(find.text('查看重练目标'), findsOneWidget);
  });
  testWidgets(
    'next page restores visible result focus; returning child preserves page and no extra read',
    (t) async {
      await launch(t);
      expect(requests, hasLength(1));
      await t.ensureVisible(find.text('下一页'));
      await t.tap(find.text('下一页'));
      await t.pumpAndSettle();
      expect(find.text('第 2 页 · 本页 10 条'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, '关联重练当前页');
      final item = find.byKey(ValueKey('related-${historyId(11)}'));
      await t.ensureVisible(item);
      await t.tap(item);
      await t.pumpAndSettle();
      final before = requests.length;
      await t.ensureVisible(find.text('返回记录'));
      await t.tap(find.text('返回记录'));
      await t.pumpAndSettle();
      expect(find.text('第 2 页 · 本页 10 条'), findsOneWidget);
      expect(requests, hasLength(before));
    },
  );
  testWidgets('empty and failed page can be retried without any writes', (
    t,
  ) async {
    await launch(t);
    handler = (_) async => throw http.ClientException('offline');
    await t.ensureVisible(find.text('下一页'));
    await t.tap(find.text('下一页'));
    await t.pumpAndSettle();
    expect(find.text('第 1 页 · 本页 10 条'), findsOneWidget);
    expect(find.byKey(ValueKey('related-${historyId(21)}')), findsOneWidget);
    handler = (_) async => response({
      ...relatedPage(),
      'items': <dynamic>[],
      'next_before_id': null,
    });
    await t.ensureVisible(find.text('刷新关联重练'));
    await t.tap(find.text('刷新关联重练'));
    await t.pumpAndSettle();
    expect(find.text('还没有关联重练'), findsOneWidget);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
  });
  testWidgets('cursor failure removes old rows and directs refresh', (t) async {
    await launch(t);
    handler = (_) async =>
        response({'code': 'rehearsal_cursor_not_found'}, 404);
    await t.ensureVisible(find.text('下一页'));
    await t.tap(find.text('下一页'));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('related-${historyId(21)}')), findsNothing);
    expect(find.textContaining('分页位置已变化'), findsOneWidget);
  });
  testWidgets(
    'unreachable account preserves deep link and reads after explicit restore',
    (t) async {
      await launch(
        t,
        initial: const AccountState(phase: SessionPhase.unreachable),
      );
      expect(requests, isEmpty);
      expect(
        router(t).routeInformationProvider.value.uri.path,
        '/history/$practiceId/rehearsals',
      );
      await t.tap(find.text('重新连接'));
      await t.pumpAndSettle();
      expect(requests, hasLength(1));
    },
  );
  testWidgets('unset difficulty can directly read related history', (t) async {
    final s = signedIn(accountId).session!;
    await launch(
      t,
      initial: AccountState(
        phase: SessionPhase.signedIn,
        session: AccountSession(
          s.user,
          AccountPreferences.fromJson({
            ...s.preferences.toJson(),
            'difficulty': null,
          }),
        ),
      ),
    );
    expect(find.text('关联重练'), findsOneWidget);
    expect(requests, hasLength(1));
  });
  testWidgets(
    'old row callback cannot navigate after account changes before rebuild',
    (t) async {
      await launch(t);
      final button = t.widget<OutlinedButton>(
        find.byKey(ValueKey('related-${historyId(21)}')),
      );
      api.expectedAccountId = practiceId;
      expect(button.onPressed!, returnsNormally);
      expect(
        router(t).routeInformationProvider.value.uri.path,
        '/history/$practiceId/rehearsals',
      );
    },
  );
  testWidgets('invalid parent link is unavailable without requests', (t) async {
    await launch(t, path: '/history/bad/rehearsals');
    expect(requests, isEmpty);
    expect(find.textContaining('地址无效'), findsOneWidget);
  });
  for (final size in [const Size(320, 720), const Size(844, 390)]) {
    testWidgets(
      'related page $size dark 200% wraps, scrolls and keyboard can move focus',
      (t) async {
        await launch(t, size: size, scale: 2, brightness: Brightness.dark);
        expect(t.takeException(), isNull);
        await t.ensureVisible(find.text('下一页'));
        await t.tap(find.text('下一页'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(FocusManager.instance.primaryFocus?.debugLabel, '关联重练当前页');
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot('关联重练当前页'),
        );
      },
    );
  }
}
