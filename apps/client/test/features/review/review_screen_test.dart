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
import 'package:simontalk_client/features/review/review_providers.dart';
import 'package:simontalk_client/features/review/review_page_view.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_providers.dart';
import 'package:simontalk_client/features/review/review_page_controller.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_providers.dart';

import '../rehearsal/rehearsal_fixtures.dart' as rehearsal;

import '../practice/practice_completion_test.dart' show completionSummary;
import '../practice/practice_providers_test.dart' show signedIn;
import 'review_fixtures.dart';
import 'rehearsal_evaluation_fixtures.dart';

class ReviewAccountController extends AccountController {
  ReviewAccountController(this.initial);
  final AccountState initial;
  int reconnects = 0;
  @override
  AccountState build() => initial;
  void change(AccountState next) => state = next;
  @override
  Future<void> restore() async {
    reconnects++;
    state = signedIn(accountId);
  }
}

void main() {
  final requests = <http.Request>[];
  late ApiClient api;
  late ReviewAccountController account;
  late Future<http.Response> Function(http.Request) handler;
  Future<void> launch(
    WidgetTester tester, {
    String? location,
    AccountState? initial,
    bool eligible = false,
    bool missing = false,
    String jobStatus = 'succeeded',
    bool evaluation = false,
    bool evaluationSuggestions = false,
  }) async {
    tester.platformDispatcher.defaultRouteNameTestValue =
        location ?? '/account';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    account = ReviewAccountController(initial ?? signedIn(accountId));
    requests.clear();
    handler = (r) async {
      if (r.headers['X-Account-ID'] != accountId) {
        return http.Response('{"code":"practice_not_found"}', 404);
      }
      if (missing &&
          r.method == 'GET' &&
          r.url.path.endsWith('/review-input')) {
        return response({'code': 'review_input_not_found'}, 404);
      }
      return response(
        r.url.path.endsWith('completion')
            ? completionSummary(sealed: true)
            : r.url.path.endsWith('review-input')
            ? inputJson()
            : evaluation
            ? evaluatedJobJson(withSuggestion: evaluationSuggestions)
            : jobJson(status: jobStatus),
      );
    };
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rehearsalEligibilityProvider.overrideWith(
            (ref, sid) async => eligible,
          ),
          rehearsalHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((r) async {
              requests.add(r);
              return response(rehearsal.rehearsalTargetJson());
            }),
          ),
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          savedTranscriptHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((r) async {
              requests.add(r);
              return response({'code': 'service_unavailable'}, 503);
            }),
          ),
          reviewHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((r) async {
              requests.add(r);
              return handler(r);
            }),
          ),
        ],
        child: const SimonTalkApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  GoRouter router(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(Scaffold).first));
  String path(WidgetTester tester) =>
      router(tester).routeInformationProvider.value.uri.path;

  testWidgets('evaluation reads once and child offers no derived rehearsal', (
    t,
  ) async {
    await launch(
      t,
      location: '/practice/$practiceId/review',
      evaluation: true,
      evaluationSuggestions: true,
    );
    expect(find.text('本次重练评价'), findsOneWidget);
    expect(find.text('I enjoy English.'), findsOneWidget);
    expect(find.text('练这一句'), findsNothing);
    expect(requests, hasLength(3));
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    account.change(signedIn(accountId, busy: true));
    await t.pumpAndSettle();
    expect(find.text('本次重练评价'), findsOneWidget);
    expect(
      t
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '查看已保存文字'),
          )
          .onPressed,
      isNull,
    );
    expect(requests, hasLength(3));
  });

  testWidgets(
    'refresh immediately withdraws evaluation and error keeps it removed',
    (t) async {
      await launch(
        t,
        location: '/practice/$practiceId/review',
        evaluation: true,
      );
      final reply = Completer<http.Response>();
      handler = (_) => reply.future;
      final action = t
          .widget<ReviewPageView>(find.byType(ReviewPageView))
          .onRefresh!;
      action();
      // Refresh starts in the existing controller's microtask, then its
      // notification schedules the frame that withdraws the old content.
      await t.pump();
      await t.pump();
      expect(find.text('本次重练评价'), findsNothing);
      expect(find.text('Yesterday I went to the park.'), findsNothing);
      reply.complete(response({'code': 'service_unavailable'}, 503));
      await t.pumpAndSettle();
      expect(find.text('本次重练评价'), findsNothing);
      expect(find.text('暂时无法读取复盘'), findsOneWidget);
    },
  );

  testWidgets('account switch clears evaluation before B source read fails', (
    t,
  ) async {
    await launch(t, location: '/practice/$practiceId/review', evaluation: true);
    expect(find.text('本次重练评价'), findsOneWidget);
    api.expectedAccountId = requestKey;
    account.change(signedIn(requestKey));
    await t.pumpAndSettle();
    expect(find.text('本次重练评价'), findsNothing);
    expect(find.text('Yesterday I went to the park.'), findsNothing);
    expect(find.text('这份复盘暂不可用'), findsOneWidget);
    expect(requests, hasLength(4));
  });

  for (final action in ['create', 'retry', 'pending']) {
    for (final change in ['busy', 'route']) {
      testWidgets('old review $action rejects $change before submitting', (
        t,
      ) async {
        await launch(
          t,
          location: '/practice/$practiceId/review',
          missing: action != 'retry',
          jobStatus: 'blocked',
        );
        final normal = handler;
        if (action == 'pending') {
          handler = (r) async {
            if (r.method == 'POST') {
              throw http.ClientException('deliberate lost reply');
            }
            return normal(r);
          };
          t
              .widget<ReviewPageView>(find.byType(ReviewPageView))
              .onRequestReview!();
          await t.pumpAndSettle();
          expect(
            t
                .widget<ReviewPageView>(find.byType(ReviewPageView))
                .hasPendingAction,
            isTrue,
          );
          handler = normal;
        }
        final view = t.widget<ReviewPageView>(find.byType(ReviewPageView));
        final old = switch (action) {
          'create' => view.onRequestReview!,
          'retry' => view.onRetryGeneration!,
          _ => view.onRetryPending!,
        };
        final writes = requests.where((r) => r.method == 'POST').length;
        if (change == 'busy') {
          account.change(signedIn(accountId, busy: true));
        } else {
          router(t).go('/account');
        }
        old();
        await t.pumpAndSettle();
        expect(requests.where((r) => r.method == 'POST'), hasLength(writes));
        expect(
          path(t),
          change == 'route' ? '/account' : '/practice/$practiceId/review',
        );
        if (change == 'busy') {
          account.change(signedIn(accountId));
          await t.pumpAndSettle();
          final label = switch (action) {
            'create' => '整理表达建议',
            'retry' => '重试整理',
            _ => '确认上次整理请求',
          };
          await t.ensureVisible(find.text(label));
          await t.tap(find.text(label));
          await t.pumpAndSettle();
          final after = requests.where((r) => r.method == 'POST').toList();
          expect(after.length, greaterThan(writes));
          if (action == 'pending') {
            expect(after[1].url, after[0].url);
            expect(
              after[1].headers['Idempotency-Key'],
              after[0].headers['Idempotency-Key'],
            );
            expect(after[1].body, after[0].body);
          }
        }
      });
    }
  }

  for (final action in ['refresh', 'text', 'locate', 'rehearse']) {
    for (final change in ['busy', 'route']) {
      testWidgets(
        'old review $action rejects $change before reading or navigation',
        (t) async {
          await launch(
            t,
            location: '/practice/$practiceId/review',
            eligible: true,
          );
          final view = t.widget<ReviewPageView>(find.byType(ReviewPageView));
          final old = switch (action) {
            'refresh' => view.onRefresh!,
            'text' => view.onReadSavedText!,
            'locate' => () => view.onLocateItem!(itemId),
            _ => () => view.onRehearseItem!(itemId),
          };
          final count = requests.length;
          if (change == 'busy') {
            account.change(signedIn(accountId, busy: true));
          } else {
            router(t).go('/account');
          }
          old();
          await t.pumpAndSettle();
          expect(
            path(t),
            change == 'route' ? '/account' : '/practice/$practiceId/review',
          );
          expect(requests, hasLength(count));
        },
      );
    }
  }

  testWidgets('old create cannot submit for a newly refreshed sealed input', (
    t,
  ) async {
    await launch(
      t,
      location: '/practice/$practiceId/review',
      missing: true,
      jobStatus: 'blocked',
    );
    final old = t
        .widget<ReviewPageView>(find.byType(ReviewPageView))
        .onRequestReview!;
    final container = ProviderScope.containerOf(
      t.element(find.byType(ReviewPageView)),
    );
    final c = container.read(reviewPageProvider(practiceId))!;
    final normal = handler;
    handler = (r) async {
      if (r.url.path.endsWith('/completion')) {
        return response({
          ...completionSummary(sealed: true),
          'input_hash': 'd' * 64,
        });
      }
      if (r.method == 'POST') {
        return response(
          r.url.path.endsWith('/review-input')
              ? {...inputJson(), 'practice_input_hash': 'd' * 64}
              : {
                  ...jobJson(status: 'blocked'),
                  'practice_input_hash': 'd' * 64,
                },
        );
      }
      return normal(r);
    };
    await c.refresh();
    expect(c.completion!.inputHash, 'd' * 64);
    old();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
    await t.ensureVisible(find.text('整理表达建议'));
    await t.tap(find.text('整理表达建议'));
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'POST'), hasLength(2));
    expect(
      requests.firstWhere((r) => r.method == 'POST').body,
      contains('d' * 64),
    );
  });

  testWidgets(
    'review account busy disables actions and preserves the real result',
    (t) async {
      await launch(t, location: '/practice/$practiceId/review', eligible: true);
      account.change(signedIn(accountId, busy: true));
      await t.pumpAndSettle();
      expect(find.text('账号操作进行中，请稍候…'), findsOneWidget);
      expect(find.text('I enjoy English.'), findsOneWidget);
      expect(find.text('正在处理复盘请求…'), findsNothing);
      expect(find.text('练这一句'), findsOneWidget);
      expect(
        t
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '练这一句'))
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '刷新复盘状态'),
            )
            .onPressed,
        isNull,
      );
      expect(requests, hasLength(3));
    },
  );

  for (final change in ['route', 'restored busy', 'disposed']) {
    testWidgets('old review reconnect rejects $change', (t) async {
      await launch(
        t,
        location: '/practice/$practiceId/review',
        initial: const AccountState(phase: SessionPhase.unreachable),
      );
      final old = t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '重新连接'))
          .onPressed!;
      if (change == 'restored busy') {
        account.change(signedIn(accountId, busy: true));
      } else {
        router(t).go('/account');
        if (change == 'disposed') await t.pumpAndSettle();
      }
      expect(old, returnsNormally);
      await t.pumpAndSettle();
      expect(account.reconnects, 0);
    });
  }

  testWidgets(
    'ordinary rehearsal entry preserves source URL and real back stack',
    (t) async {
      await launch(t, location: '/practice/$practiceId/review', eligible: true);
      await t.ensureVisible(find.text('练这一句'));
      await t.tap(find.text('练这一句'));
      await t.pumpAndSettle();
      expect(path(t), '/practice/$practiceId/rehearse/$itemId');
      expect(find.text('Yes, I enjoy English.'), findsOneWidget);
      expect(requests.last.method, 'GET');
      await t.ensureVisible(find.text('返回原复盘'));
      await t.tap(find.text('返回原复盘'));
      await t.pumpAndSettle();
      expect(path(t), '/practice/$practiceId/review');
      expect(find.text('I enjoy English.'), findsOneWidget);
    },
  );

  testWidgets(
    'direct URL reads once; explicit refresh remains GET and direct return works',
    (tester) async {
      await launch(tester, location: '/practice/$practiceId/review');
      expect(path(tester), '/practice/$practiceId/review');
      expect(find.text('I enjoy English.'), findsOneWidget);
      expect(requests, hasLength(3));
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      await tester.ensureVisible(find.text('刷新复盘状态'));
      await tester.tap(find.text('刷新复盘状态'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(6));
      await tester.ensureVisible(find.text('返回练习偏好'));
      await tester.tap(find.text('返回练习偏好'));
      await tester.pumpAndSettle();
      expect(path(tester), '/account');
    },
  );
  for (final previous in [false, true]) {
    testWidgets(
      'router disposal restores the previous imperative URL option: $previous',
      (tester) async {
        final original = GoRouter.optionURLReflectsImperativeAPIs;
        GoRouter.optionURLReflectsImperativeAPIs = previous;
        addTearDown(() => GoRouter.optionURLReflectsImperativeAPIs = original);
        await launch(tester);
        final navigation = router(tester);
        navigation.push('/practice/$practiceId/review');
        await tester.pumpAndSettle();
        expect(
          navigation.routeInformationParser
              .restoreRouteInformation(
                navigation.routerDelegate.currentConfiguration,
              )!
              .uri
              .path,
          '/practice/$practiceId/review',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(GoRouter.optionURLReflectsImperativeAPIs, previous);
      },
    );
  }
  testWidgets('internal push preserves a real return stack', (tester) async {
    await launch(tester);
    final navigation = router(tester);
    navigation.push('/practice/$practiceId/review');
    await tester.pumpAndSettle();
    expect(navigation.canPop(), isTrue);
    expect(
      navigation.routeInformationParser
          .restoreRouteInformation(
            navigation.routerDelegate.currentConfiguration,
          )!
          .uri
          .path,
      '/practice/$practiceId/review',
    );
    expect(requests, hasLength(3));
    await tester.ensureVisible(find.text('返回练习偏好'));
    await tester.tap(find.text('返回练习偏好'));
    await tester.pumpAndSettle();
    expect(path(tester), '/account');
    expect(navigation.canPop(), isFalse);
    expect(
      navigation.routeInformationParser
          .restoreRouteInformation(
            navigation.routerDelegate.currentConfiguration,
          )!
          .uri
          .path,
      '/account',
    );
  });
  testWidgets(
    'pushed review keeps its URL and source while the account reconnects',
    (tester) async {
      await launch(tester);
      final navigation = router(tester);
      navigation.push('/practice/$practiceId/review');
      await tester.pumpAndSettle();
      expect(requests, hasLength(3));
      account.change(const AccountState());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        navigation.routeInformationParser
            .restoreRouteInformation(
              navigation.routerDelegate.currentConfiguration,
            )!
            .uri
            .path,
        '/practice/$practiceId/review',
      );
      expect(find.text('正在恢复你的账号'), findsOneWidget);
      expect(requests, hasLength(3));
      account.change(const AccountState(phase: SessionPhase.unreachable));
      await tester.pumpAndSettle();
      expect(path(tester), '/practice/$practiceId/review');
      expect(find.text('重新连接'), findsOneWidget);
      account.change(signedIn(accountId));
      await tester.pumpAndSettle();
      expect(path(tester), '/practice/$practiceId/review');
      expect(requests, hasLength(6));
    },
  );
  for (final phase in [
    SessionPhase.restoring,
    SessionPhase.unreachable,
    SessionPhase.signedOut,
  ]) {
    testWidgets(
      'browser forward restores incoming review history during $phase',
      (tester) async {
        await launch(tester);
        final navigation = router(tester);
        navigation.push('/practice/$practiceId/review');
        await tester.pumpAndSettle();
        final saved = navigation.routeInformationParser.restoreRouteInformation(
          navigation.routerDelegate.currentConfiguration,
        )!;
        navigation.pop();
        await tester.pumpAndSettle();
        expect(path(tester), '/account');
        account.change(AccountState(phase: phase));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await navigation.routeInformationProvider.didPushRouteInformation(
          saved,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          navigation.routeInformationParser
              .restoreRouteInformation(
                navigation.routerDelegate.currentConfiguration,
              )!
              .uri
              .path,
          phase == SessionPhase.signedOut
              ? '/login'
              : '/practice/$practiceId/review',
        );
        expect(find.text('I enjoy English.'), findsNothing);
        expect(requests, hasLength(3));
        if (phase == SessionPhase.restoring) {
          expect(find.text('正在恢复你的账号'), findsOneWidget);
        }
        if (phase == SessionPhase.unreachable) {
          expect(find.text('重新连接'), findsOneWidget);
        }
      },
    );
  }
  for (final hasDifficulty in [true, false]) {
    testWidgets(
      'pushed review restores as B regardless of preference completion: $hasDifficulty',
      (tester) async {
        await launch(tester);
        final navigation = router(tester);
        navigation.push('/practice/$practiceId/review');
        await tester.pumpAndSettle();
        expect(find.text('I enjoy English.'), findsOneWidget);
        account.change(const AccountState());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('I enjoy English.'), findsNothing);
        expect(requests, hasLength(3));
        final b = signedIn(requestKey).session!;
        api.expectedAccountId = requestKey;
        account.change(
          AccountState(
            phase: SessionPhase.signedIn,
            session: AccountSession(
              b.user,
              AccountPreferences(
                difficulty: hasDifficulty ? Difficulty.beginner : null,
                speechPace: 'normal',
                subtitleDefault: true,
                chineseHintsEnabled: true,
                version: 1,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          navigation.routeInformationParser
              .restoreRouteInformation(
                navigation.routerDelegate.currentConfiguration,
              )!
              .uri
              .path,
          '/practice/$practiceId/review',
        );
        expect(find.text('I enjoy English.'), findsNothing);
        expect(find.text('这份复盘暂不可用'), findsOneWidget);
        expect(requests, hasLength(4));
        expect(requests.last.method, 'GET');
        expect(requests.last.url.path.endsWith('/completion'), isTrue);
        expect(requests.last.headers['X-Account-ID'], requestKey);
        navigation.go('/account');
        await tester.pumpAndSettle();
        expect(path(tester), hasDifficulty ? '/account' : '/setup');
        account.change(const AccountState(phase: SessionPhase.signedOut));
        await tester.pumpAndSettle();
        expect(path(tester), '/login');
      },
    );
  }
  testWidgets(
    'returning from a pushed review while offline follows account routing',
    (tester) async {
      await launch(tester);
      final navigation = router(tester);
      navigation.push('/practice/$practiceId/review');
      await tester.pumpAndSettle();
      account.change(const AccountState(phase: SessionPhase.unreachable));
      await tester.pumpAndSettle();
      expect(find.text('重新连接'), findsOneWidget);
      expect(navigation.canPop(), isTrue);
      await tester.tap(find.text('返回练习偏好'));
      await tester.pumpAndSettle();
      expect(
        navigation.routeInformationParser
            .restoreRouteInformation(
              navigation.routerDelegate.currentConfiguration,
            )!
            .uri
            .path,
        '/account',
      );
      expect(find.text('暂时连接不上'), findsOneWidget);
      expect(requests, hasLength(3));
    },
  );
  testWidgets(
    'legal deep link survives account restore and offline; data waits for reconnect',
    (tester) async {
      await launch(
        tester,
        location: '/practice/$practiceId/review',
        initial: const AccountState(),
      );
      expect(path(tester), '/practice/$practiceId/review');
      expect(requests, isEmpty);
      expect(find.text('正在恢复你的账号'), findsOneWidget);
      account.change(const AccountState(phase: SessionPhase.unreachable));
      await tester.pumpAndSettle();
      expect(path(tester), '/practice/$practiceId/review');
      expect(requests, isEmpty);
      await tester.tap(find.text('重新连接'));
      await tester.pumpAndSettle();
      expect(account.reconnects, 1);
      expect(requests, hasLength(3));
    },
  );
  testWidgets('invalid source is clear and sends zero review HTTP', (
    tester,
  ) async {
    await launch(tester, location: '/practice/not-a-uuid/review');
    expect(requests, isEmpty);
    expect(find.textContaining('练习地址无效'), findsOneWidget);
    expect(find.text('整理表达建议'), findsNothing);
  });
  testWidgets('account switch removes A data and rechecks same URL as B', (
    tester,
  ) async {
    await launch(tester, location: '/practice/$practiceId/review');
    expect(find.text('I enjoy English.'), findsOneWidget);
    api.expectedAccountId = requestKey;
    account.change(signedIn(requestKey));
    await tester.pumpAndSettle();
    expect(path(tester), '/practice/$practiceId/review');
    expect(find.text('I enjoy English.'), findsNothing);
    expect(requests.last.headers['X-Account-ID'], requestKey);
    expect(find.text('这份复盘暂不可用'), findsOneWidget);
    account.change(const AccountState(phase: SessionPhase.signedOut));
    await tester.pumpAndSettle();
    expect(path(tester), '/login');
  });
  test('page provider is silent, invalid URL is absent and accounts rebuild/dispose', () async {
    account = ReviewAccountController(signedIn(accountId));
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
        accountControllerProvider.overrideWith(() => account),
        reviewHttpClientFactoryProvider.overrideWithValue(
          () => MockClient((_) async {
            requests++;
            return response({});
          }),
        ),
      ],
    );
    final subscription = container.listen(
      reviewPageProvider(practiceId),
      (_, _) {},
    );
    final initial = container.read(reviewPageProvider(practiceId))!;
    expect(requests, 0);
    expect(container.read(reviewPageProvider('wrong')), isNull);
    account.change(signedIn(accountId, busy: true));
    await container.pump();
    expect(container.read(reviewPageProvider(practiceId)), same(initial));
    api.expectedAccountId = requestKey;
    account.change(signedIn(requestKey));
    await container.pump();
    expect(
      container.read(reviewPageProvider(practiceId)),
      isNot(same(initial)),
    );
    expect(initial.state, ReviewPageState.aborted);
    subscription.close();
    container.dispose();
    api.close();
  });
}
