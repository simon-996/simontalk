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
import 'package:simontalk_client/features/review/review_providers.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_providers.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_controller.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_view.dart';

import '../practice/practice_completion_test.dart' show completionSummary;
import '../practice/practice_providers_test.dart' show signedIn;
import '../review/review_screen_test.dart' show ReviewAccountController;
import 'transcript_fixtures.dart';

void main() {
  final requests = <http.Request>[];
  late ApiClient api;
  late ReviewAccountController account;
  Future<void> launch(
    WidgetTester tester, {
    String? location,
    AccountState? initial,
    bool noJob = false,
  }) async {
    tester.platformDispatcher.defaultRouteNameTestValue =
        location ?? '/account';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    requests.clear();
    account = ReviewAccountController(initial ?? signedIn(accountId));
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    http.Client client() => MockClient((r) async {
      requests.add(r);
      if (r.headers['X-Account-ID'] != accountId) {
        return http.Response('{"code":"practice_not_found"}', 404);
      }
      if (r.url.path.endsWith('completion')) {
        return response(completionSummary(sealed: true));
      }
      if (r.url.path.endsWith('saved-transcript')) {
        final focus = r.url.queryParameters.containsKey('review_item_id');
        return response(
          pageJson(
            total: 23,
            offset: int.parse(
              r.url.queryParameters['offset'] ?? (focus ? '18' : '0'),
            ),
            focus: focus,
            focusOrdinal: 19,
          ),
        );
      }
      if (noJob) return http.Response('{"code":"review_input_not_found"}', 404);
      if (r.url.path.endsWith('review-input')) return response(inputJson());
      final j = jobJson(status: 'succeeded');
      j['result']['items'][0]['explanation'] = 'More specific. ' * 100;
      return response(j);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          reviewHttpClientFactoryProvider.overrideWithValue(client),
          savedTranscriptHttpClientFactoryProvider.overrideWithValue(client),
        ],
        child: const SimonTalkApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  GoRouter router(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first));
  String url(WidgetTester t) => router(t).routeInformationParser
      .restoreRouteInformation(router(t).routerDelegate.currentConfiguration)!
      .uri
      .path;
  SavedTranscriptView view(WidgetTester t) =>
      t.widget(find.byType(SavedTranscriptView));
  for (final action in ['refresh', 'previous', 'next', 'focus', 'back']) {
    for (final change in ['busy', 'go', 'push']) {
      testWidgets('old transcript $action rejects $change', (t) async {
        await launch(
          t,
          location:
              '/practice/$practiceId/transcript${['previous', 'focus'].contains(action) ? '/$itemId' : ''}',
        );
        final shown = view(t);
        final callback = switch (action) {
          'refresh' => shown.onRefresh!,
          'previous' => shown.onPrevious!,
          'next' => shown.onNext!,
          'focus' => shown.onFocus!,
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
  testWidgets(
    'old previous callback cannot page from subsequently displayed transcript page',
    (t) async {
      await launch(t, location: '/practice/$practiceId/transcript/$itemId');
      final previous = view(t).onPrevious!;
      previous();
      await t.pumpAndSettle();
      expect(view(t).page!.offset, 2);
      final count = requests.length;
      previous();
      await t.pumpAndSettle();
      expect(requests, hasLength(count));
      expect(view(t).page!.offset, 2);
      view(t).onPrevious!();
      await t.pumpAndSettle();
      expect(view(t).page!.offset, 0);
    },
  );
  for (final change in ['busy', 'go', 'disposed']) {
    testWidgets('old transcript reconnect rejects $change', (t) async {
      await launch(
        t,
        location: '/practice/$practiceId/transcript',
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
  testWidgets(
    'account busy retains transcript and disables reading actions with truthful status',
    (t) async {
      await launch(t, location: '/practice/$practiceId/transcript');
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
      expect(find.text('正在读取已保存文字…'), findsNothing);
      for (final label in ['刷新已保存文字', '下一页', '返回复盘']) {
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
  testWidgets(
    'direct ordinary address works without review job; only two GETs and direct return review',
    (t) async {
      await launch(
        t,
        location: '/practice/$practiceId/transcript',
        noJob: true,
      );
      expect(url(t), '/practice/$practiceId/transcript');
      expect(requests, hasLength(2));
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(find.text('第 1–16 段，共 23 段'), findsOneWidget);
      await t.tap(find.text('返回复盘'));
      await t.pumpAndSettle();
      expect(url(t), '/practice/$practiceId/review');
      expect(find.text('查看已保存文字'), findsOneWidget);
    },
  );
  testWidgets(
    'real sealed no-job review button pushes saved text and returns',
    (t) async {
      await launch(t, location: '/practice/$practiceId/review', noJob: true);
      expect(find.text('查看已保存文字'), findsOneWidget);
      await t.tap(find.text('查看已保存文字'));
      await t.pumpAndSettle();
      expect(url(t), '/practice/$practiceId/transcript');
      expect(requests, hasLength(4));
      await t.tap(find.text('返回复盘'));
      await t.pumpAndSettle();
      expect(url(t), '/practice/$practiceId/review');
      expect(requests, hasLength(4));
    },
  );
  testWidgets(
    'real suggestion push locates first exact target, pages and returns preserving review scroll',
    (t) async {
      await launch(t, location: '/practice/$practiceId/review');
      await t.ensureVisible(find.text('定位到对话'));
      final reviewScroll = t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels;
      expect(reviewScroll, greaterThan(0));
      await t.tap(find.text('定位到对话'));
      await t.pumpAndSettle();
      expect(url(t), '/practice/$practiceId/transcript/$itemId');
      expect(find.text('第 19–23 段，共 23 段'), findsOneWidget);
      expect(find.text('建议对应原话'), findsOneWidget);
      expect(requests.last.url.queryParameters.containsKey('offset'), isFalse);
      await t.tap(find.text('上一页'));
      await t.pumpAndSettle();
      expect(find.text('第 3–18 段，共 23 段'), findsOneWidget);
      expect(requests.last.url.queryParameters['review_item_id'], itemId);
      await t.tap(find.text('回到原话'));
      await t.pumpAndSettle();
      expect(find.text('第 19–23 段，共 23 段'), findsOneWidget);
      await t.tap(find.text('返回复盘'));
      await t.pumpAndSettle();
      expect(url(t), '/practice/$practiceId/review');
      expect(
        t.state<ScrollableState>(find.byType(Scrollable).first).position.pixels,
        reviewScroll,
      );
      expect(
        requests.where((r) => r.url.path.endsWith('/review')),
        hasLength(1),
      );
    },
  );
  for (final suffix in ['transcript', 'transcript/$itemId']) {
    testWidgets('direct $suffix waits for restore and offline then reads', (
      t,
    ) async {
      final location = '/practice/$practiceId/$suffix';
      await launch(t, location: location, initial: const AccountState());
      expect(url(t), location);
      expect(requests, isEmpty);
      account.change(const AccountState(phase: SessionPhase.unreachable));
      await t.pumpAndSettle();
      expect(url(t), location);
      expect(requests, isEmpty);
      await t.tap(find.text('重新连接'));
      await t.pumpAndSettle();
      expect(url(t), location);
      expect(requests, hasLength(2));
    });
  }
  for (final phase in [
    SessionPhase.restoring,
    SessionPhase.unreachable,
    SessionPhase.signedOut,
  ]) {
    testWidgets('incoming encoded transcript forward history survives $phase', (
      t,
    ) async {
      await launch(t);
      final nav = router(t);
      nav.push('/practice/$practiceId/transcript/$itemId');
      await t.pumpAndSettle();
      final history = nav.routeInformationParser.restoreRouteInformation(
        nav.routerDelegate.currentConfiguration,
      )!;
      nav.pop();
      await t.pumpAndSettle();
      account.change(AccountState(phase: phase));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await nav.routeInformationProvider.didPushRouteInformation(history);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(
        url(t),
        phase == SessionPhase.signedOut
            ? '/login'
            : '/practice/$practiceId/transcript/$itemId',
      );
      expect(requests, hasLength(2));
      expect(find.text('建议对应原话'), findsNothing);
    });
  }
  for (final difficulty in [true, false]) {
    testWidgets(
      'pushed reader account B rechecks URL regardless of difficulty $difficulty',
      (t) async {
        await launch(t);
        final nav = router(t);
        nav.push('/practice/$practiceId/transcript');
        await t.pumpAndSettle();
        account.change(const AccountState());
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        api.expectedAccountId = requestKey;
        final b = signedIn(requestKey).session!;
        account.change(
          AccountState(
            phase: SessionPhase.signedIn,
            session: AccountSession(
              b.user,
              AccountPreferences(
                difficulty: difficulty ? Difficulty.beginner : null,
                speechPace: 'normal',
                subtitleDefault: true,
                chineseHintsEnabled: true,
                version: 1,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(url(t), '/practice/$practiceId/transcript');
        expect(find.text('I enjoy English.'), findsNothing);
        expect(requests, hasLength(3));
        expect(requests.last.headers['X-Account-ID'], requestKey);
        nav.go('/account');
        await t.pumpAndSettle();
        expect(url(t), difficulty ? '/account' : '/setup');
      },
    );
  }
  for (final location in [
    '/practice/not-a-uuid/transcript',
    '/practice/$practiceId/transcript/not-a-uuid',
  ]) {
    testWidgets('invalid reading ID is visible and zero HTTP $location', (
      t,
    ) async {
      await launch(t, location: location);
      expect(requests, isEmpty);
      expect(find.textContaining('练习地址无效'), findsOneWidget);
    });
  }
  test(
    'provider listening is silent and account switch disposes held page',
    () async {
      account = ReviewAccountController(signedIn(accountId));
      api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient((_) async => response({})),
      )..expectedAccountId = accountId;
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          savedTranscriptHttpClientFactoryProvider.overrideWithValue(
            () => throw StateError('no HTTP'),
          ),
        ],
      );
      final key = (sessionId: practiceId, reviewItemId: itemId);
      final sub = container.listen(savedTranscriptProvider(key), (_, _) {});
      final first = container.read(savedTranscriptProvider(key));
      expect(first, isNotNull);
      expect(
        container.read(
          savedTranscriptProvider((sessionId: practiceId, reviewItemId: 'bad')),
        ),
        isNull,
      );
      api.expectedAccountId = requestKey;
      account.change(signedIn(requestKey));
      await container.pump();
      expect(first!.state, SavedTranscriptState.aborted);
      expect(container.read(savedTranscriptProvider(key)), isNot(same(first)));
      sub.close();
      container.dispose();
      api.close();
    },
  );
}
