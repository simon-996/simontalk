import 'dart:async';
import 'dart:convert';

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
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/practice/practice_entry_provider.dart';
import 'package:simontalk_client/features/practice/practice_entry_view.dart';

import 'practice_fixtures.dart';
import 'practice_providers_test.dart' show signedIn;
import '../review/review_screen_test.dart' show ReviewAccountController;

void main() {
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  late ReviewAccountController account;
  late ApiClient api;
  Future<void> launch(
    WidgetTester t, {
    String location = '/',
    Size size = const Size(390, 844),
    double scale = 1,
    Brightness brightness = Brightness.light,
    AccountState? state,
  }) async {
    t.platformDispatcher.defaultRouteNameTestValue = location;
    t.platformDispatcher.platformBrightnessTestValue = brightness;
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    requests = [];
    handler = (r) async => r.method == 'GET'
        ? response({'practice': null, 'connection': null})
        : response({'code': 'realtime_unavailable'}, 503);
    Future<http.Response> dispatch(http.Request r) async {
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
          recoveryHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
        ],
        child: SimonTalkApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
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
  String path(WidgetTester t) =>
      router(t).routeInformationProvider.value.uri.path;
  Future<void> tap(WidgetTester t, String label) async {
    await t.ensureVisible(find.text(label));
    await t.tap(find.text(label));
    await t.pumpAndSettle();
  }

  PracticeHomeView home(WidgetTester t) =>
      t.widget(find.byType(PracticeHomeView));
  PracticePreparationView prepared(WidgetTester t) =>
      t.widget(find.byType(PracticePreparationView));
  for (final action in ['start', 'settings', 'history']) {
    for (final change in ['go', 'push', 'busy']) {
      if (action == 'start' && change == 'busy') continue;
      testWidgets('old home $action rejects $change navigation', (t) async {
        await launch(t);
        final shown = home(t);
        final callback = switch (action) {
          'start' => shown.onStart!,
          'settings' => shown.onSettings!,
          _ => shown.onHistory!,
        };
        if (change == 'busy') {
          account.change(signedIn(accountId, busy: true));
        } else if (change == 'go') {
          router(t).go('/account');
        } else {
          router(t).push('/account');
        }
        final expected = path(t);
        expect(callback, returnsNormally);
        expect(path(t), expected);
        await t.pump(const Duration(milliseconds: 100));
        expect(path(t), expected);
        if (change == 'go') expect(router(t).canPop(), isFalse);
        if (change == 'push') {
          expect(
            router(t).routerDelegate.currentConfiguration.matches,
            hasLength(2),
          );
        }
      });
    }
  }
  for (final action in ['start', 'retry', 'back']) {
    for (final change in ['go', 'push']) {
      testWidgets('old preparation $action rejects $change route', (t) async {
        await launch(t, location: '/practice/prepare');
        if (action == 'retry') {
          handler = (r) async {
            if (r.method == 'GET') {
              return response({'practice': null, 'connection': null});
            }
            throw http.ClientException('lost');
          };
          await tap(t, '开始准备');
        }
        final scope = ProviderScope.containerOf(
          t.element(find.byType(PracticePreparationView)),
        );
        final entry = scope.read(practiceEntryProvider)!;
        final shown = prepared(t);
        final callback = action == 'start'
            ? shown.onStart!
            : action == 'retry'
            ? shown.onRetry!
            : shown.onBack!;
        final writes = requests.where((r) => r.method == 'POST').length;
        if (change == 'go') {
          router(t).go('/account');
        } else {
          router(t).push('/account');
        }
        final expected = path(t);
        expect(callback, returnsNormally);
        expect(entry.busy, isFalse);
        expect(path(t), expected);
        await t.pumpAndSettle();
        expect(requests.where((r) => r.method == 'POST'), hasLength(writes));
        expect(path(t), expected);
      });
    }
  }
  for (final change in ['busy', 'push']) {
    testWidgets('old cancel cannot release current preparation after $change', (
      t,
    ) async {
      await launch(t, location: '/practice/prepare');
      var instance = clientId;
      handler = (r) async {
        if (r.method == 'GET') {
          return response({'practice': null, 'connection': null});
        }
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          return response(connectionJson(instance: instance), 201);
        }
        if (r.url.path.contains('/connections/')) {
          return response(connectionJson(instance: instance, status: 'closed'));
        }
        return response(
          practiceJson(
            status: r.url.path.endsWith('/cancel-preparation')
                ? 'cancelled'
                : 'created',
          ),
          201,
        );
      };
      await tap(t, '开始准备');
      final callback = prepared(t).onCancel!;
      final writes = requests.where((r) => r.method == 'POST').length;
      if (change == 'busy') {
        account.change(signedIn(accountId, busy: true));
      } else {
        router(t).push('/account');
      }
      callback();
      await t.pump(const Duration(milliseconds: 100));
      expect(requests.where((r) => r.method == 'POST'), hasLength(writes));
    });
  }
  testWidgets('old preparation back cannot leave during account operation', (
    t,
  ) async {
    await launch(t, location: '/practice/prepare');
    final callback = prepared(t).onBack!;
    account.change(signedIn(accountId, busy: true));
    callback();
    expect(path(t), '/practice/prepare');
  });
  for (final action in ['settings', 'history']) {
    testWidgets('disposed home $action callback is inert', (t) async {
      await launch(t);
      final callback = action == 'settings'
          ? home(t).onSettings!
          : home(t).onHistory!;
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      expect(callback, returnsNormally);
    });
  }
  testWidgets(
    'account busy on preparation has account notice without pretending to prepare',
    (t) async {
      await launch(t, location: '/practice/prepare');
      account.change(signedIn(accountId, busy: true));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('账号操作进行中，请稍候…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        t
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '返回练习'))
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始准备'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'signed in lands on inert home with personal difficulty and no placeholder navigation',
    (t) async {
      await launch(t);
      expect(path(t), '/practice');
      expect(find.text('开始自由聊天'), findsOneWidget);
      expect(find.textContaining('当前难度：轻松起步'), findsOneWidget);
      expect(find.text('记录'), findsOneWidget);
      expect(requests, isEmpty);
      expect(
        t
            .getSemantics(find.text('今天，聊点日常。'))
            .getSemanticsData()
            .flagsCollection
            .isHeader,
        isTrue,
      );
    },
  );
  testWidgets(
    'prepare direct URL is inert; start reads current then displays real unavailable',
    (t) async {
      await launch(t, location: '/practice/prepare');
      expect(path(t), '/practice/prepare');
      expect(requests, isEmpty);
      await tap(t, '开始准备');
      expect(requests.map((r) => r.method), ['GET', 'POST']);
      expect(find.text('实时语音尚未就绪，暂时无法开始练习。'), findsOneWidget);
      expect(find.text('正在听你说'), findsNothing);
      expect(find.text('开始准备'), findsNothing);
      await tap(t, '返回练习');
      expect(path(t), '/practice');
    },
  );
  testWidgets(
    'home opens preparation, browser pop returns home without creating',
    (t) async {
      await launch(t);
      await tap(t, '开始自由聊天');
      expect(path(t), '/practice/prepare');
      router(t).pop();
      await t.pumpAndSettle();
      expect(path(t), '/practice');
      expect(requests, isEmpty);
    },
  );
  testWidgets(
    'topic selection is a read-free preparation before explicit start',
    (t) async {
      await launch(t);
      await tap(t, '周末计划');
      expect(path(t), '/practice/prepare');
      expect(find.text('周末计划'), findsOneWidget);
      expect(find.text('分享一个周末安排'), findsOneWidget);
      expect(find.text('开始语音练习'), findsOneWidget);
      expect(requests, isEmpty);
      await tap(t, '返回练习');
      expect(path(t), '/practice');
      expect(requests, isEmpty);
    },
  );
  testWidgets('topic checks an unresolved call before launching media', (
    t,
  ) async {
    await launch(t, location: '/practice/prepare?topic=travel');
    handler = (_) async => response({
      'practice': practiceJson(epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
    await tap(t, '开始语音练习');
    expect(path(t), '/practice/prepare');
    expect(find.text('远端是否结束尚未确认'), findsOneWidget);
    expect(requests.map((r) => r.method), ['GET']);
  });
  testWidgets(
    'unknown existing practice disables start and refresh remains read only',
    (t) async {
      await launch(t, location: '/practice/prepare');
      handler = (_) async => response({
        'practice': practiceJson(epoch: 1),
        'connection': connectionJson(status: 'unknown', termination: 'unknown'),
      });
      await tap(t, '开始准备');
      expect(find.text('远端是否结束尚未确认'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始准备'))
            .onPressed,
        isNull,
      );
      await tap(t, '刷新状态');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );
  testWidgets(
    'failed preflight does not write and refresh alone cannot start',
    (t) async {
      await launch(t, location: '/practice/prepare');
      handler = (_) async => throw http.ClientException('offline');
      await tap(t, '开始准备');
      expect(requests.length, 1);
      handler = (_) async => response({'practice': null, 'connection': null});
      await tap(t, '刷新状态');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始准备'))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'leaving during preflight prevents late preparation and duplicate taps',
    (t) async {
      await launch(t, location: '/practice/prepare');
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      await t.tap(find.text('开始准备'));
      await t.pump();
      expect(requests.length, 1);
      await tap(t, '返回练习');
      pending.complete(response({'practice': null, 'connection': null}));
      await t.pumpAndSettle();
      expect(path(t), '/practice');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );
  testWidgets(
    'browser pop invalidates preflight before the exit animation finishes',
    (t) async {
      await launch(t);
      await tap(t, '开始自由聊天');
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      await t.tap(find.text('开始准备'));
      await t.pump();
      router(t).pop();
      await t.pump();
      pending.complete(response({'practice': null, 'connection': null}));
      await t.pump();
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      await t.pumpAndSettle();
    },
  );

  testWidgets(
    'isolated successful preparation stays silent and cancels its own registration',
    (t) async {
      await launch(t, location: '/practice/prepare');
      var instance = clientId;
      handler = (r) async {
        if (r.url.path.endsWith('/current')) {
          return response({'practice': null, 'connection': null});
        }
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          return response(connectionJson(instance: instance), 201);
        }
        if (r.url.path.contains('/connections/')) {
          return response(connectionJson(instance: instance, status: 'closed'));
        }
        return response(
          practiceJson(
            status: r.url.path.endsWith('/cancel-preparation')
                ? 'cancelled'
                : 'created',
          ),
          201,
        );
      };
      await tap(t, '开始准备');
      expect(find.text('准备已登记，尚未启动语音。你可以取消准备或返回练习。'), findsOneWidget);
      expect(find.text('正在听你说'), findsNothing);
      expect(requests.length, 3);
      await tap(t, '取消准备');
      expect(find.text('这次准备已停止，未启动语音。'), findsOneWidget);
      expect(requests.last.url.path, endsWith('/cancel-preparation'));
    },
  );

  testWidgets(
    'account switch during preflight removes the old action and does not write',
    (t) async {
      await launch(t, location: '/practice/prepare');
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      await t.tap(find.text('开始准备'));
      await t.pump();
      api.expectedAccountId = requestKey;
      account.change(signedIn(requestKey));
      await t.pump();
      pending.complete(response({'practice': null, 'connection': null}));
      await t.pumpAndSettle();
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      expect(find.text('开始准备'), findsOneWidget);
    },
  );

  testWidgets(
    'settings remain reachable and explicit return confirms a dirty draft',
    (t) async {
      await launch(t);
      await tap(t, '我的');
      expect(path(t), '/account');
      await tap(t, '自然交流');
      await tap(t, '返回练习');
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tap(t, '继续编辑');
      expect(path(t), '/account');
      await tap(t, '返回练习');
      await tap(t, '放弃并返回');
      expect(path(t), '/practice');
      expect(requests, isEmpty);
    },
  );
  testWidgets(
    'direct preparation survives restoring and unreachable account states',
    (t) async {
      await launch(
        t,
        location: '/practice/prepare',
        state: const AccountState(),
      );
      expect(path(t), '/practice/prepare');
      account.change(const AccountState(phase: SessionPhase.unreachable));
      await t.pumpAndSettle();
      expect(path(t), '/practice/prepare');
      expect(find.text('暂时连接不上'), findsOneWidget);
      account.change(signedIn(accountId));
      await t.pumpAndSettle();
      expect(find.text('开始准备'), findsOneWidget);
      expect(requests, isEmpty);
    },
  );
  void changeDifficulty(Difficulty value) {
    final session = signedIn(accountId).session!;
    account.change(
      AccountState(
        phase: SessionPhase.signedIn,
        session: AccountSession(
          session.user,
          AccountPreferences.fromJson({
            ...session.preferences.toJson(),
            'difficulty': value.name,
            'version': 2,
          }),
        ),
      ),
    );
  }

  testWidgets(
    'uncertain preparation displays and confirms its original difficulty after preferences change',
    (t) async {
      await launch(t, location: '/practice/prepare');
      final normal = handler;
      var lost = true;
      handler = (r) {
        if (r.method == 'POST' && lost) {
          lost = false;
          throw http.ClientException('lost preparation reply');
        }
        return normal(r);
      };
      await tap(t, '开始准备');
      expect(find.text('准备结果尚未确认。请确认原准备结果，不会自动重新创建。'), findsOneWidget);
      final original = requests.last;
      changeDifficulty(Difficulty.advanced);
      await t.pumpAndSettle();
      expect(find.textContaining('难度：轻松起步'), findsOneWidget);
      expect(find.textContaining('难度：深入表达'), findsNothing);
      await tap(t, '确认原准备结果');
      final creates = requests.where((r) => r.method == 'POST').toList();
      expect(creates, hasLength(2));
      expect(
        creates.last.headers['Idempotency-Key'],
        original.headers['Idempotency-Key'],
      );
      expect(creates.last.body, original.body);
      expect(jsonDecode(creates.last.body)['difficulty_override'], 'beginner');
    },
  );
  testWidgets(
    'known preparation displays its recorded difficulty after preferences change',
    (t) async {
      await launch(t, location: '/practice/prepare');
      var instance = clientId;
      handler = (r) async {
        if (r.method == 'GET') {
          return response({'practice': null, 'connection': null});
        }
        if (r.url.path.endsWith('/connections')) {
          instance = jsonDecode(r.body)['client_instance_id'] as String;
          return response(connectionJson(instance: instance), 201);
        }
        if (r.url.path.contains('/connections/')) {
          return response(connectionJson(instance: instance, status: 'closed'));
        }
        return response(
          practiceJson(
            status: r.url.path.endsWith('/cancel-preparation')
                ? 'cancelled'
                : 'created',
          ),
          201,
        );
      };
      await tap(t, '开始准备');
      changeDifficulty(Difficulty.advanced);
      await t.pumpAndSettle();
      try {
        expect(find.textContaining('难度：轻松起步'), findsOneWidget);
        expect(find.textContaining('难度：深入表达'), findsNothing);
      } finally {
        await tap(t, '取消准备');
      }
    },
  );
  testWidgets(
    'preflight freezes clicked difficulty before it sends the original preparation',
    (t) async {
      await launch(t, location: '/practice/prepare');
      final pending = Completer<http.Response>();
      handler = (r) => r.method == 'GET'
          ? pending.future
          : Future.value(response({'code': 'realtime_unavailable'}, 503));
      await t.tap(find.text('开始准备'));
      await t.pump();
      changeDifficulty(Difficulty.advanced);
      await t.pump();
      try {
        expect(find.textContaining('难度：轻松起步'), findsOneWidget);
      } finally {
        pending.complete(response({'practice': null, 'connection': null}));
        await t.pumpAndSettle();
      }
      expect(jsonDecode(requests.last.body)['difficulty_override'], 'beginner');
      expect(find.textContaining('难度：轻松起步'), findsOneWidget);
    },
  );
  testWidgets(
    'failed preflight releases its snapshot so a later start uses new preferences',
    (t) async {
      await launch(t, location: '/practice/prepare');
      handler = (_) async => throw http.ClientException('offline');
      await tap(t, '开始准备');
      changeDifficulty(Difficulty.advanced);
      await t.pumpAndSettle();
      expect(find.textContaining('难度：深入表达'), findsOneWidget);
      handler = (r) async => r.method == 'GET'
          ? response({'practice': null, 'connection': null})
          : response({'code': 'realtime_unavailable'}, 503);
      await tap(t, '刷新状态');
      await tap(t, '开始准备');
      expect(jsonDecode(requests.last.body)['difficulty_override'], 'advanced');
      expect(find.textContaining('难度：深入表达'), findsOneWidget);
    },
  );
  for (final condition in [
    'account busy',
    'preferences changed',
    'new occupancy',
  ]) {
    testWidgets('old home start blocks $condition before rebuild', (t) async {
      await launch(t);
      final callback = t
          .widget<PracticeHomeView>(find.byType(PracticeHomeView))
          .onStart!;
      if (condition == 'account busy') {
        account.change(signedIn(accountId, busy: true));
      } else if (condition == 'preferences changed') {
        changeDifficulty(Difficulty.advanced);
      } else {
        handler = (_) async => response({
          'practice': practiceJson(epoch: 1),
          'connection': connectionJson(
            status: 'unknown',
            termination: 'unknown',
          ),
        });
        final container = ProviderScope.containerOf(
          t.element(find.byType(PracticeHomeView)),
        );
        await container.read(practiceRecoveryProvider)!.refresh();
      }
      callback();
      expect(path(t), '/practice');
      await t.pumpAndSettle();
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    });
  }
  for (final condition in [
    'account busy',
    'preferences changed',
    'owner changed',
  ]) {
    testWidgets('old preparation start blocks $condition before rebuild', (
      t,
    ) async {
      await launch(t, location: '/practice/prepare');
      final callback = t
          .widget<PracticePreparationView>(find.byType(PracticePreparationView))
          .onStart!;
      if (condition == 'account busy') {
        account.change(signedIn(accountId, busy: true));
      } else if (condition == 'preferences changed') {
        changeDifficulty(Difficulty.advanced);
      } else {
        api.expectedAccountId = requestKey;
      }
      callback();
      await t.pump();
      expect(requests, isEmpty);
      if (condition == 'account busy') account.change(signedIn(accountId));
      await t.pumpAndSettle();
    });
  }
  testWidgets('old retry cannot replay while an account operation is busy', (
    t,
  ) async {
    await launch(t, location: '/practice/prepare');
    handler = (r) async {
      if (r.method == 'GET') {
        return response({'practice': null, 'connection': null});
      }
      throw http.ClientException('lost');
    };
    await tap(t, '开始准备');
    final callback = t
        .widget<PracticePreparationView>(find.byType(PracticePreparationView))
        .onRetry!;
    final count = requests.length;
    account.change(signedIn(accountId, busy: true));
    callback();
    await t.pumpAndSettle();
    expect(requests, hasLength(count));
  });

  testWidgets('keyboard activates preparation without starting media', (
    t,
  ) async {
    await launch(t);
    Focus.of(t.element(find.text('开始自由聊天'))).requestFocus();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(path(t), '/practice/prepare');
    expect(requests, isEmpty);
  });
  for (final location in ['/practice', '/practice/prepare']) {
    for (final size in [
      const Size(320, 568),
      const Size(375, 667),
      const Size(844, 390),
      const Size(1440, 900),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets('$location fits $size $brightness at 200%', (t) async {
          await launch(
            t,
            location: location,
            size: size,
            scale: 2,
            brightness: brightness,
          );
          expect(t.takeException(), isNull);
          await t.ensureVisible(
            find.text(location == '/practice' ? '查看未结束练习' : '返回练习'),
          );
          expect(t.takeException(), isNull);
          expect(requests, isEmpty);
        });
      }
    }
  }
  testWidgets('a direct visit to the live page never opens the microphone', (
    t,
  ) async {
    await launch(t, location: '/practice/session');
    expect(path(t), '/practice');
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
    expect(find.text('正在连接语音，请稍候…'), findsNothing);
  });

  testWidgets('the call is entered only after the pre-flight is cancelled', (
    t,
  ) async {
    await launch(t, location: '/practice/prepare');
    var instance = clientId;
    handler = (r) async {
      if (r.url.path.endsWith('/current')) {
        return response({'practice': null, 'connection': null});
      }
      if (r.url.path.endsWith('/connections')) {
        instance = jsonDecode(r.body)['client_instance_id'] as String;
        return response(connectionJson(instance: instance), 201);
      }
      if (r.url.path.contains('/connections/')) {
        return response(connectionJson(instance: instance, status: 'closed'));
      }
      return response(
        practiceJson(
          status: r.url.path.endsWith('/cancel-preparation')
              ? 'cancelled'
              : 'created',
        ),
        201,
      );
    };
    await tap(t, '开始准备');
    expect(find.text('进入通话'), findsOneWidget);
    await t.ensureVisible(find.text('进入通话'));
    await t.tap(find.text('进入通话'));
    await t.pump();
    await t.pump();
    await t.pump();
    expect(path(t), '/practice/session');
    expect(requests.last.url.path, endsWith('/cancel-preparation'));
  });
}
