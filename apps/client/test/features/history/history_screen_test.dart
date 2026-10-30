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
import 'package:simontalk_client/features/history/history_view.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/review/review_providers.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_providers.dart';

import '../practice/practice_providers_test.dart' show signedIn;
import '../review/review_screen_test.dart' show ReviewAccountController;
import '../practice/practice_completion_test.dart' show completionSummary;
import '../transcript/transcript_fixtures.dart' show pageJson;
import 'history_fixtures.dart';

void main() {
  late List<http.Request> requests;
  late ApiClient api;
  late ReviewAccountController account;
  late Future<http.Response> Function(http.Request) handler;
  Future<void> launch(
    WidgetTester t, {
    String path = '/history',
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
    AccountState? state,
    bool rehearsal = false,
  }) async {
    t.platformDispatcher.defaultRouteNameTestValue = path;
    t.platformDispatcher.platformBrightnessTestValue = brightness;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    requests = [];
    handler = (r) async {
      if (r.url.path == '/v1/practice-history') {
        return response(
          historyPage(
            page: r.url.queryParameters.containsKey('cursor') ? 1 : 0,
          ),
        );
      }
      if (r.url.path.startsWith('/v1/practice-history/')) {
        final detail = historyDetail(
          int.parse(r.url.path.split('/').last.split('-').last),
          sealed: true,
        );
        if (rehearsal) {
          (detail['item'] as Map<String, dynamic>)
            ..['kind'] = 'rehearsal'
            ..['source_session_id'] = historyId(1);
        }
        return response(detail);
      }
      if (r.url.path.endsWith('/completion')) {
        return response(completionSummary(sealed: true));
      }
      if (r.url.path.endsWith('/saved-transcript')) return response(pageJson());
      return response({'code': 'review_job_not_found'}, 404);
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
    account = ReviewAccountController(state ?? signedIn(accountId));
    addTearDown(api.close);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          historyHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          recoveryHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          reviewHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          savedTranscriptHttpClientFactoryProvider.overrideWithValue(
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
    if (state?.phase == SessionPhase.restoring) {
      await t.pump();
    } else {
      await t.pumpAndSettle();
    }
  }

  GoRouter router(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first));
  String location(WidgetTester t) =>
      router(t).routeInformationProvider.value.uri.path;
  Future<void> tap(WidgetTester t, String text) async {
    await t.ensureVisible(find.text(text));
    await t.tap(find.text(text));
    await t.pumpAndSettle();
  }

  testWidgets(
    'home record navigation loads only owner history, paging detail return retains page',
    (t) async {
      await launch(t, path: '/practice');
      expect(requests, isEmpty);
      await tap(t, '记录');
      expect(location(t), '/history');
      expect(requests, hasLength(1));
      await tap(t, '下一页');
      expect(find.text('第 2 页'), findsOneWidget);
      final entry = find.byKey(ValueKey('history-${historyId(11)}'));
      await t.ensureVisible(entry);
      final scroll = t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      await t.tap(entry);
      await t.pumpAndSettle();
      expect(location(t), '/history/${historyId(11)}');
      expect(find.text('文字已保存'), findsOneWidget);
      await tap(t, '返回记录');
      expect(find.text('第 2 页'), findsOneWidget);
      expect(
        t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels,
        closeTo(scroll, 1),
      );
      expect(requests, hasLength(3));
    },
  );
  testWidgets(
    'sealed real ID detail opens transcript and returns, then review is read-only',
    (t) async {
      // Existing text fixture is bound to practiceId, independently of history samples.
      await launch(t, path: '/history/$practiceId');
      handler = (r) async {
        if (r.url.path.endsWith('/completion')) {
          return response(completionSummary(sealed: true));
        }
        if (r.url.path.endsWith('/saved-transcript')) {
          return response(pageJson());
        }
        return response({'code': 'review_job_not_found'}, 404);
      };
      await tap(t, '查看已保存文字');
      expect(location(t), '/practice/$practiceId/transcript');
      await tap(t, '返回练习详情');
      expect(location(t), '/history/$practiceId');
      await tap(t, '查看复盘');
      expect(location(t), '/practice/$practiceId/review');
      await tap(t, '返回练习详情');
      expect(location(t), '/history/$practiceId');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );
  testWidgets('unsealed detail has no text or review actions', (t) async {
    await launch(t);
    handler = (_) async => response(historyDetail(21));
    await t.tap(find.byKey(ValueKey('history-${historyId(21)}')));
    await t.pumpAndSettle();
    expect(find.text('查看已保存文字'), findsNothing);
    expect(find.text('查看复盘'), findsNothing);
    expect(find.text('尚未登记文字保存'), findsOneWidget);
  });
  testWidgets(
    'offline history preserves address and resumes after account restore',
    (t) async {
      await launch(t, state: const AccountState(phase: SessionPhase.restoring));
      expect(location(t), '/history');
      expect(requests, isEmpty);
      account.change(const AccountState(phase: SessionPhase.unreachable));
      await t.pumpAndSettle();
      expect(find.text('重新连接'), findsOneWidget);
      expect(location(t), '/history');
      account.change(signedIn(accountId));
      await t.pumpAndSettle();
      expect(requests, hasLength(1));
    },
  );
  testWidgets('invalid detail is visible with zero requests', (t) async {
    await launch(t, path: '/history/invalid');
    expect(requests, isEmpty);
    expect(find.text('练习地址无效。'), findsOneWidget);
  });
  testWidgets('keyboard activates history navigation and paging', (t) async {
    await launch(t, path: '/practice');
    Focus.of(t.element(find.text('记录'))).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(location(t), '/history');
    await t.ensureVisible(find.text('下一页'));
    Focus.of(t.element(find.text('下一页'))).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.text('第 2 页'), findsOneWidget);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
  });
  for (final path in ['/history', '/history/$practiceId']) {
    testWidgets('history reading $path does not require setting difficulty', (
      t,
    ) async {
      final session = signedIn(accountId).session!;
      final raw = session.preferences.toJson()..['difficulty'] = null;
      await launch(
        t,
        path: path,
        state: AccountState(
          phase: SessionPhase.signedIn,
          session: AccountSession(
            session.user,
            AccountPreferences.fromJson(raw),
          ),
        ),
      );
      expect(location(t), path);
      expect(requests.single.method, 'GET');
    });
  }
  testWidgets('account change removes previous list while new read waits', (
    t,
  ) async {
    await launch(t);
    final pending = Completer<http.Response>();
    handler = (_) => pending.future;
    api.expectedAccountId = historyId(99);
    account.change(signedIn(historyId(99)));
    await t.pump();
    expect(find.text('自由聊天'), findsNothing);
    pending.complete(response(historyPage(owner: historyId(99))));
    await t.pumpAndSettle();
  });
  testWidgets(
    'account operation disables visible detail actions until it settles',
    (t) async {
      await launch(t, path: '/history/$practiceId');
      account.change(
        AccountState(
          phase: SessionPhase.signedIn,
          session: signedIn(accountId).session,
          busy: true,
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '查看已保存文字'))
            .onPressed,
        isNull,
      );
      expect(
        t.widget<TextButton>(find.widgetWithText(TextButton, '删除记录')).onPressed,
        isNull,
      );
      expect(find.text('正在读取记录…'), findsNothing);
      account.change(signedIn(accountId));
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '查看已保存文字'))
            .onPressed,
        isNotNull,
      );
      expect(requests, hasLength(1));
    },
  );

  VoidCallback detailAction(HistoryView view, String action) =>
      switch (action) {
        'text' => view.onText!,
        'review' => view.onReview!,
        'source' => view.onSource!,
        'target' => view.onTarget!,
        'delete' => view.onDelete!,
        'related' => view.onRelated!,
        _ => throw ArgumentError(action),
      };
  for (final action in [
    'text',
    'review',
    'source',
    'target',
    'delete',
    'related',
  ]) {
    for (final condition in ['owner changed', 'reading', 'account busy']) {
      testWidgets(
        'old detail $action callback blocks $condition before rebuild',
        (t) async {
          await launch(
            t,
            path: '/history/$practiceId',
            rehearsal: ['source', 'target'].contains(action),
          );
          final callback = detailAction(
            t.widget<HistoryView>(find.byType(HistoryView)),
            action,
          );
          final container = ProviderScope.containerOf(
            t.element(find.byType(HistoryView)),
          );
          Completer<http.Response>? pending;
          Future<void>? read;
          if (condition == 'owner changed') {
            api.expectedAccountId = historyId(99);
          } else if (condition == 'reading') {
            pending = Completer<http.Response>();
            handler = (_) => pending!.future;
            read = container.read(historyProvider(practiceId))!.refresh();
          } else {
            account.change(
              AccountState(
                phase: SessionPhase.signedIn,
                session: signedIn(accountId).session,
                busy: true,
              ),
            );
          }
          callback();
          expect(location(t), '/history/$practiceId');
          if (pending != null) {
            pending.complete(
              response(historyDetail(222222222222, sealed: true)),
            );
            await read;
          }
          await t.pumpAndSettle();
          expect(location(t), '/history/$practiceId');
          expect(
            requests.every(
              (r) =>
                  r.method == 'GET' &&
                  r.url.path == '/v1/practice-history/$practiceId',
            ),
            isTrue,
          );
        },
      );
    }
  }
  for (final action in ['text', 'review']) {
    testWidgets('old $action callback requires currently sealed detail', (
      t,
    ) async {
      await launch(t, path: '/history/$practiceId');
      final callback = detailAction(
        t.widget<HistoryView>(find.byType(HistoryView)),
        action,
      );
      final container = ProviderScope.containerOf(
        t.element(find.byType(HistoryView)),
      );
      handler = (_) async => response(historyDetail(222222222222));
      await container.read(historyProvider(practiceId))!.refresh();
      callback();
      expect(location(t), '/history/$practiceId');
      await t.pumpAndSettle();
      expect(requests, hasLength(2));
    });
  }
  for (final condition in [
    'owner changed',
    'reading',
    'page changed',
    'account busy',
  ]) {
    testWidgets('old row callback blocks $condition', (t) async {
      await launch(t);
      final old = t.widget<HistoryView>(find.byType(HistoryView));
      final container = ProviderScope.containerOf(
        t.element(find.byType(HistoryView)),
      );
      final c = container.read(historyProvider(null))!;
      Completer<http.Response>? pending;
      Future<void>? read;
      if (condition == 'owner changed') {
        api.expectedAccountId = historyId(99);
      } else if (condition == 'reading') {
        pending = Completer<http.Response>();
        handler = (_) => pending!.future;
        read = c.next();
      } else if (condition == 'page changed') {
        await c.next();
      } else {
        account.change(
          AccountState(
            phase: SessionPhase.signedIn,
            session: signedIn(accountId).session,
            busy: true,
          ),
        );
      }
      old.onOpen!(historyId(21));
      expect(location(t), '/history');
      if (pending != null) {
        pending.complete(response(historyPage(page: 1)));
        await read;
      }
      await t.pumpAndSettle();
      expect(
        requests.every(
          (r) => r.method == 'GET' && r.url.path == '/v1/practice-history',
        ),
        isTrue,
      );
    });
  }
  for (final action in ['source', 'target']) {
    testWidgets('current rehearsal $action uses verified current IDs', (
      t,
    ) async {
      await launch(t, path: '/history/$practiceId', rehearsal: true);
      final view = t.widget<HistoryView>(find.byType(HistoryView));
      detailAction(view, action)();
      expect(
        location(t),
        action == 'source'
            ? '/history/${historyId(1)}'
            : '/practice/$practiceId/rehearsal-target',
      );
      await t.pumpAndSettle();
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    });
  }
  for (final size in [
    const Size(320, 720),
    const Size(375, 812),
    const Size(844, 390),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('history $size $brightness at 200% fits and can page', (
        t,
      ) async {
        await launch(t, size: size, brightness: brightness, scale: 2);
        await tap(t, '下一页');
        expect(find.text('第 2 页'), findsOneWidget);
        expect(t.takeException(), isNull);
        await tap(t, '上一页');
        expect(find.text('第 1 页'), findsOneWidget);
      });
    }
  }
}
