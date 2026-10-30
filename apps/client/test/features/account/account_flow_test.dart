import 'package:flutter/material.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show CheckedState;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/app.dart';

import 'account_repository_test.dart' as fixtures;

void main() {
  Future<void> launch(
    WidgetTester tester, {
    required MockClient client,
    String? token,
    Size size = const Size(390, 844),
    double scale = 1,
    double keyboardInset = 0,
  }) async {
    tester.platformDispatcher.defaultRouteNameTestValue = '/account';
    addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardInset);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final store = fixtures.MemoryTokenStore()..token = token;
    final repository = AccountRepository(
      ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: store,
        client: client,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountRepositoryProvider.overrideWithValue(repository)],
        child: SimonTalkApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('login validates before contacting the server', (tester) async {
    var requests = 0;
    await launch(
      tester,
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      }),
    );
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(find.text('请输入用户名'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('page titles expose heading semantics', (tester) async {
    await launch(
      tester,
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    expect(
      tester
          .getSemantics(find.text('欢迎回来'))
          .getSemanticsData()
          .flagsCollection
          .isHeader,
      isTrue,
    );
  });

  testWidgets('difficulty exposes a checked mutually exclusive choice', (
    tester,
  ) async {
    await launch(
      tester,
      token: 'valid',
      client: MockClient(
        (request) async => fixtures.jsonResponse(
          request.url.path == '/v1/me'
              ? fixtures.user
              : {...fixtures.preferences, 'difficulty': 'beginner'},
          200,
        ),
      ),
    );
    final flags = tester
        .getSemantics(find.text('轻松起步'))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isChecked, CheckedState.isTrue);
    expect(flags.isInMutuallyExclusiveGroup, isTrue);
  });

  testWidgets('arrow keys change difficulty locally until explicitly saved', (
    tester,
  ) async {
    final patches = <Map<String, dynamic>>[];
    await launch(
      tester,
      token: 'valid',
      client: MockClient((request) async {
        if (request.url.path == '/v1/me') {
          return fixtures.jsonResponse(fixtures.user, 200);
        }
        if (request.method == 'PATCH') {
          final patch = jsonDecode(request.body) as Map<String, dynamic>;
          patches.add(patch);
          return fixtures.jsonResponse({...patch, 'version': 2}, 200);
        }
        return fixtures.jsonResponse({
          ...fixtures.preferences,
          'difficulty': 'beginner',
        }, 200);
      }),
    );
    await tester.ensureVisible(find.text('轻松起步'));
    Focus.of(tester.element(find.text('轻松起步'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('有尚未保存的修改'), findsOneWidget);
    expect(patches, isEmpty);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存设置'));
    await tester.tap(find.widgetWithText(FilledButton, '保存设置'));
    await tester.pumpAndSettle();
    expect(patches.single['difficulty'], 'intermediate');
  });

  testWidgets('login prevents a second submit while waiting', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    await launch(
      tester,
      client: MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    await tester.enterText(find.byType(TextFormField).at(0), 'learner_one');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'a-long-test-password',
    );
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(calls, 1);
    pending.complete(
      fixtures.jsonResponse({'code': 'invalid_credentials'}, 401),
    );
    await tester.pumpAndSettle();
    expect(find.text('用户名或密码不正确，请重试。'), findsOneWidget);
  });

  testWidgets(
    'conflicting preference save reloads the current server version',
    (tester) async {
      var reads = 0;
      await launch(
        tester,
        token: 'valid',
        client: MockClient((request) async {
          if (request.url.path == '/v1/me') {
            return fixtures.jsonResponse(fixtures.user, 200);
          }
          if (request.method == 'PATCH') {
            return fixtures.jsonResponse({'code': 'preferences_conflict'}, 409);
          }
          reads++;
          return fixtures.jsonResponse({
            ...fixtures.preferences,
            'difficulty': reads == 1 ? 'beginner' : 'advanced',
            'version': reads == 1 ? 1 : 2,
          }, 200);
        }),
      );
      await tester.tap(find.text('自然交流'));
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存设置'));
      await tester.tap(find.widgetWithText(FilledButton, '保存设置'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.textContaining('已载入最新设置'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('settings support dark theme and 200% text at 320 width', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await launch(
      tester,
      size: const Size(320, 568),
      scale: 2,
      token: 'valid',
      client: MockClient(
        (request) async => fixtures.jsonResponse(
          request.url.path == '/v1/me'
              ? fixtures.user
              : {...fixtures.preferences, 'difficulty': 'beginner'},
          200,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('退出登录'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('first login requires an explicit difficulty and persists it', (
    tester,
  ) async {
    var saved = false;
    await launch(
      tester,
      token: 'valid',
      client: MockClient((request) async {
        if (request.url.path == '/v1/me') {
          return fixtures.jsonResponse(fixtures.user, 200);
        }
        if (request.method == 'PATCH') {
          saved = true;
          return fixtures.jsonResponse({
            ...fixtures.preferences,
            'difficulty': 'beginner',
            'version': 2,
          }, 200);
        }
        return fixtures.jsonResponse(fixtures.preferences, 200);
      }),
    );
    expect(find.text('找到适合你的节奏'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存并继续'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('轻松起步'));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存并继续'));
    await tester.tap(find.widgetWithText(FilledButton, '保存并继续'));
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(find.text('开始自由聊天'), findsOneWidget);
  });

  testWidgets('offline restore offers retry and does not show login', (
    tester,
  ) async {
    await launch(
      tester,
      token: 'valid',
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    expect(find.text('暂时连接不上'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新连接'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '登录'), findsNothing);
  });

  testWidgets(
    'account change clears the old draft even at the same preference version',
    (tester) async {
      var changed = false;
      var patches = 0;
      await launch(
        tester,
        token: 'valid',
        client: MockClient((request) async {
          if (request.method == 'PATCH') {
            expect(request.headers['X-Account-ID'], 'user-one');
            patches++;
            changed = true;
            return fixtures.jsonResponse({'code': 'account_changed'}, 409);
          }
          if (request.url.path == '/v1/me') {
            return fixtures.jsonResponse(
              changed
                  ? {
                      ...fixtures.user,
                      'id': 'user-two',
                      'username': 'bob',
                      'display_name': 'Bob',
                    }
                  : fixtures.user,
              200,
            );
          }
          return fixtures.jsonResponse({
            ...fixtures.preferences,
            'difficulty': changed ? 'intermediate' : 'beginner',
          }, 200);
        }),
      );
      await tester.tap(find.text('深入表达'));
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存设置'));
      await tester.tap(find.widgetWithText(FilledButton, '保存设置'));
      await tester.pumpAndSettle();
      expect(patches, 1);
      expect(find.text('账号 · bob'), findsOneWidget);
      expect(find.textContaining('浏览器已切换账号'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
            .onPressed,
        isNull,
      );
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(600, 800),
    const Size(1440, 900),
  ]) {
    testWidgets('login remains scrollable at ${size.width} and 200% text', (
      tester,
    ) async {
      await launch(
        tester,
        size: size,
        scale: 2,
        client: MockClient((_) async => http.Response('{}', 500)),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('邀请码注册'));
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in ['join', 'reset']) {
    for (final size in [const Size(320, 568), const Size(844, 390)]) {
      testWidgets(
        '$mode submit remains reachable at $size with 200% text and keyboard',
        (tester) async {
          const inset = 220.0;
          await launch(
            tester,
            size: size,
            scale: 2,
            keyboardInset: inset,
            client: MockClient((_) async => http.Response('{}', 500)),
          );
          final link = find.text(mode == 'join' ? '邀请码注册' : '忘记密码');
          await tester.ensureVisible(link);
          await tester.tap(link);
          await tester.pumpAndSettle();
          final submit = find.widgetWithText(
            FilledButton,
            mode == 'join' ? '创建账号' : '更新密码',
          );
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          await tester.ensureVisible(submit);
          await tester.pumpAndSettle();
          final rect = tester.getRect(submit);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(size.height - inset));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
