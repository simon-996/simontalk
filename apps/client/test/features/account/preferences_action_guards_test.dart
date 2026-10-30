import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/app.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/account/account_models.dart';

import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show signedIn;

class EditableAccount extends AccountController {
  EditableAccount(this.initial);
  final AccountState initial;
  @override
  AccountState build() => initial;
  void change(AccountState next) => state = next;
  AccountState get current => state;
}

void main() {
  late ApiClient api;
  late EditableAccount account;
  late AccountRepository repository;
  late List<http.Request> requests;
  Future<http.Response> Function(http.Request)? handler;
  Future<void> launch(
    WidgetTester t, {
    AccountState? initial,
    String location = '/account',
  }) async {
    t.platformDispatcher.defaultRouteNameTestValue = location;
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    t.view.physicalSize = const Size(1000, 1800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    requests = [];
    handler = null;
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: false,
      tokenStore: TestTokenStore(),
      client: MockClient((r) async {
        requests.add(r);
        if (handler != null) return handler!(r);
        if (r.method == 'PATCH') {
          return response({...jsonDecode(r.body), 'version': 2});
        }
        return response({});
      }),
    )..expectedAccountId = accountId;
    addTearDown(api.close);
    account = EditableAccount(initial ?? signedIn(accountId));
    repository = AccountRepository(api);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWith((_) => repository),
          accountControllerProvider.overrideWith(() => account),
        ],
        child: const SimonTalkApp(),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String text) async {
    await t.ensureVisible(find.text(text));
    await t.tap(find.text(text));
    await t.pumpAndSettle();
  }

  testWidgets('old settings save cannot PATCH the newly switched account', (
    t,
  ) async {
    await launch(t);
    await tap(t, '自然交流');
    final oldSave = t
        .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
        .onPressed!;
    api.expectedAccountId = requestKey;
    account.change(signedIn(requestKey));
    oldSave();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    expect(account.current.session!.user.id, requestKey);
    expect(account.current.session!.preferences.difficulty!.name, 'beginner');
  });

  testWidgets(
    'old logout confirmation cannot revoke the newly switched account',
    (t) async {
      await launch(t);
      await tap(t, '退出登录');
      api.expectedAccountId = requestKey;
      account.change(signedIn(requestKey));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('退出登录'),
        ),
      );
      await t.pumpAndSettle();
      expect(requests.where((r) => r.url.path == '/v1/auth/logout'), isEmpty);
      expect(account.current.session!.user.id, requestKey);
    },
  );

  GoRouter router(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first));
  String path(WidgetTester t) =>
      router(t).routeInformationProvider.value.uri.path;
  RadioGroup<Difficulty> group(WidgetTester t) =>
      t.widget(find.byWidgetPredicate((w) => w is RadioGroup<Difficulty>));
  VoidCallback button(WidgetTester t, String label) =>
      t.widget<TextButton>(find.widgetWithText(TextButton, label)).onPressed!;
  VoidCallback callback(WidgetTester t, String action) => switch (action) {
    'save' =>
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
          .onPressed!,
    'back' => button(t, '返回练习'),
    'logout' => button(t, '退出登录'),
    'discard' => button(t, '放弃修改'),
    'difficulty' => () => group(t).onChanged(Difficulty.advanced),
    _ => () {},
  };
  void change(String kind, WidgetTester t) {
    switch (kind) {
      case 'owner':
        api.expectedAccountId = requestKey;
        account.change(signedIn(requestKey));
      case 'api':
        api.expectedAccountId = requestKey;
      case 'busy':
        account.change(signedIn(accountId, busy: true));
      case 'repository':
        repository = AccountRepository(api);
        ProviderScope.containerOf(t.element(find.byType(Scaffold).first))
            .invalidate(accountRepositoryProvider);
      case 'preferences':
        final prefs = account.current.session!.preferences;
        account.change(
          AccountState(
            phase: SessionPhase.signedIn,
            session: AccountSession(
              account.current.session!.user,
              AccountPreferences(
                difficulty: prefs.difficulty,
                speechPace: prefs.speechPace,
                subtitleDefault: prefs.subtitleDefault,
                chineseHintsEnabled: prefs.chineseHintsEnabled,
                version: prefs.version + 1,
              ),
            ),
          ),
        );
      case 'go':
        router(t).go('/practice');
      case 'push':
        router(t).push('/practice');
    }
  }

  for (final action in [
    'save',
    'back',
    'logout',
    'discard',
    'pace',
    'subtitle',
    'hints',
    'difficulty',
  ]) {
    for (final kind in [
      'owner',
      'api',
      'busy',
      'preferences',
      'repository',
      'go',
      'push',
    ]) {
      testWidgets('old settings $action rejects $kind change before rebuild', (
        t,
      ) async {
        await launch(t);
        await tap(t, '自然交流');
        final switches = t
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .toList();
        final VoidCallback old = switch (action) {
          'pace' => () => switches[0].onChanged!(true),
          'subtitle' => () => switches[1].onChanged!(false),
          'hints' => () => switches[2].onChanged!(false),
          'difficulty' => (() {
            final shown = group(t);
            return () => shown.onChanged(Difficulty.advanced);
          })(),
          _ => callback(t, action),
        };
        change(kind, t);
        final expectedPath = path(t);
        old();
        if (kind == 'busy') {
          await t.pump(const Duration(milliseconds: 400));
        } else {
          await t.pumpAndSettle();
        }
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
        expect(path(t), expectedPath);
        expect(find.byType(AlertDialog), findsNothing);
        if (kind == 'go' || kind == 'push') return;
        final selected = group(t).groupValue;
        expect(
          selected,
          kind == 'owner' || kind == 'preferences'
              ? Difficulty.beginner
              : Difficulty.intermediate,
        );
        final current = t
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .toList();
        expect(current[0].value, isFalse);
        expect(current[1].value, isTrue);
        expect(current[2].value, isTrue);
      });
    }
  }

  for (final dialog in ['logout', 'back']) {
    for (final kind in [
      'owner',
      'api',
      'busy',
      'preferences',
      'repository',
      'go',
      'push',
    ]) {
      testWidgets('$dialog confirmation rejects $kind after opening', (
        t,
      ) async {
        await launch(t);
        await tap(t, '自然交流');
        await tap(t, dialog == 'logout' ? '退出登录' : '返回练习');
        final shown = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(
            TextButton,
            dialog == 'logout' ? '退出登录' : '放弃并返回',
          ),
        );
        final confirm = t.widget<TextButton>(shown).onPressed!;
        change(kind, t);
        final expectedPath = path(t);
        confirm();
        if (kind == 'busy') {
          await t.pump(const Duration(milliseconds: 400));
        } else {
          await t.pumpAndSettle();
        }
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
        expect(path(t), expectedPath);
      });
    }
  }

  for (final action in [
    'save',
    'back',
    'logout',
    'discard',
    'difficulty',
    'pace',
    'subtitle',
    'hints',
  ]) {
    testWidgets(
      'old $action does not consume or overwrite a newer local draft',
      (t) async {
        await launch(t);
        await tap(t, '自然交流');
        final shown = group(t);
        final switches = t
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .toList();
        final VoidCallback old = switch (action) {
          'difficulty' => () => shown.onChanged(Difficulty.beginner),
          'pace' => () => switches[0].onChanged!(true),
          'subtitle' => () => switches[1].onChanged!(false),
          'hints' => () => switches[2].onChanged!(false),
          _ => callback(t, action),
        };
        shown.onChanged(Difficulty.advanced);
        old();
        await t.pumpAndSettle();
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
        expect(path(t), '/account');
        expect(group(t).groupValue, Difficulty.advanced);
        expect(find.byType(AlertDialog), findsNothing);
        final current = t
            .widgetList<SwitchListTile>(find.byType(SwitchListTile))
            .toList();
        expect(current[0].value, isFalse);
        expect(current[1].value, isTrue);
        expect(current[2].value, isTrue);
      },
    );
  }

  testWidgets(
    'current save sends exactly the displayed draft and confirms success',
    (t) async {
      await launch(t);
      await tap(t, '自然交流');
      await tap(t, '保存设置');
      final sent = requests.singleWhere((r) => r.method == 'PATCH');
      expect(sent.headers['X-Account-ID'], accountId);
      expect(jsonDecode(sent.body)['difficulty'], 'intermediate');
      expect(account.current.session!.preferences.version, 2);
      expect(find.text('练习偏好已保存。'), findsOneWidget);
      expect(find.text('有尚未保存的修改'), findsNothing);
    },
  );

  testWidgets(
    'onboarding saves normally and proceeds through the existing router',
    (t) async {
      final original = signedIn(accountId).session!;
      await launch(
        t,
        location: '/setup',
        initial: AccountState(
          phase: SessionPhase.signedIn,
          session: AccountSession(
            original.user,
            const AccountPreferences(
              difficulty: null,
              speechPace: 'normal',
              subtitleDefault: true,
              chineseHintsEnabled: true,
              version: 1,
            ),
          ),
        ),
      );
      await tap(t, '自然交流');
      await tap(t, '保存并继续');
      expect(requests.where((r) => r.method == 'PATCH'), hasLength(1));
      expect(path(t), '/practice');
      expect(find.text('练习偏好已保存。'), findsNothing);
    },
  );

  testWidgets('current logout requires confirmation and sends one revocation', (
    t,
  ) async {
    await launch(t);
    await tap(t, '退出登录');
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
    await t.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('退出登录'),
      ),
    );
    await t.pumpAndSettle();
    expect(
      requests.where((r) => r.url.path == '/v1/auth/logout'),
      hasLength(1),
    );
    expect(account.current.phase, SessionPhase.signedOut);
    expect(path(t), '/login');
  });

  for (final dialog in ['logout', 'back']) {
    testWidgets(
      'current $dialog can be cancelled without changing draft or identity',
      (t) async {
        await launch(t);
        await tap(t, '自然交流');
        await tap(t, dialog == 'logout' ? '退出登录' : '返回练习');
        await t.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(dialog == 'logout' ? '继续使用' : '继续编辑'),
          ),
        );
        await t.pumpAndSettle();
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
        expect(path(t), '/account');
        expect(group(t).groupValue, Difficulty.intermediate);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  testWidgets(
    'current dirty back confirms and returns, local discard does not write',
    (t) async {
      await launch(t);
      await tap(t, '自然交流');
      await tap(t, '放弃修改');
      expect(group(t).groupValue, Difficulty.beginner);
      await tap(t, '自然交流');
      await tap(t, '返回练习');
      await t.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('放弃并返回'),
        ),
      );
      await t.pumpAndSettle();
      expect(path(t), '/practice');
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
    },
  );

  for (final navigation in ['go', 'push']) {
    testWidgets(
      'late successful save does not show a message on $navigation destination',
      (t) async {
        await launch(t);
        final pending = Completer<http.Response>();
        handler = (r) =>
            r.method == 'PATCH' ? pending.future : Future.value(response({}));
        await tap(t, '自然交流');
        callback(t, 'save')();
        await t.pump();
        expect(account.current.busy, isTrue);
        final sent = requests.singleWhere((r) => r.method == 'PATCH');
        change(navigation, t);
        await t.pumpAndSettle();
        pending.complete(response({...jsonDecode(sent.body), 'version': 2}));
        await t.pumpAndSettle();
        expect(path(t), '/practice');
        expect(find.text('练习偏好已保存。'), findsNothing);
      },
    );
  }

  testWidgets('old dialog cancel and confirm cannot pop a newer modal', (
    t,
  ) async {
    await launch(t);
    await tap(t, '退出登录');
    final oldDialog = find.byType(AlertDialog);
    final cancel = t
        .widget<TextButton>(
          find.descendant(
            of: oldDialog,
            matching: find.widgetWithText(TextButton, '继续使用'),
          ),
        )
        .onPressed!;
    final confirm = t
        .widget<TextButton>(
          find.descendant(
            of: oldDialog,
            matching: find.widgetWithText(TextButton, '退出登录'),
          ),
        )
        .onPressed!;
    final context = t.element(find.byType(Scaffold).first);
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('另一项确认')),
      ),
    );
    await t.pumpAndSettle();
    cancel();
    confirm();
    await t.pumpAndSettle();
    expect(find.text('另一项确认'), findsOneWidget);
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
    expect(path(t), '/account');
  });
}
