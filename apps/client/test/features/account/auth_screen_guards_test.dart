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
import 'package:simontalk_client/features/account/account_repository.dart';

import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show signedIn;
import 'account_repository_test.dart' show MemoryTokenStore;
import 'preferences_action_guards_test.dart' show EditableAccount;

void main() {
  late EditableAccount account;
  late ApiClient api;
  late List<http.Request> requests;
  Future<http.Response> Function(http.Request)? handler;
  Future<void> launch(WidgetTester t, String location) async {
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
      tokenStore: MemoryTokenStore(),
      client: MockClient((r) async {
        requests.add(r);
        return handler != null
            ? handler!(r)
            : response({'code': 'service_unavailable'}, 500);
      }),
    );
    addTearDown(api.close);
    account = EditableAccount(
      const AccountState(phase: SessionPhase.signedOut),
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
        ],
        child: const SimonTalkApp(),
      ),
    );
    await t.pumpAndSettle();
    for (final field in find.byType(TextFormField).evaluate().toList()) {
      await t.enterText(find.byWidget(field.widget), 'testuser1234567');
    }
  }

  GoRouter router(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first));
  for (final source in ['/login', '/join', '/reset']) {
    for (final action in ['submit', 'navigate']) {
      for (final change in ['go', 'push', 'busy', 'owner']) {
        testWidgets('$source old $action rejects $change', (t) async {
          await launch(t, source);
          final VoidCallback old = action == 'submit'
              ? t.widget<FilledButton>(find.byType(FilledButton)).onPressed!
              : t.widget<TextButton>(find.byType(TextButton).first).onPressed!;
          final target = source == '/reset' ? '/login' : '/reset';
          if (change == 'go') router(t).go(target);
          if (change == 'push') router(t).push(target);
          if (change == 'busy') {
            account.change(
              const AccountState(phase: SessionPhase.signedOut, busy: true),
            );
          }
          if (change == 'owner') {
            api.expectedAccountId = requestKey;
            account.change(signedIn(requestKey));
          }
          final path = router(t).routeInformationProvider.value.uri.path;
          old();
          await t.pump(const Duration(milliseconds: 400));
          expect(requests, isEmpty);
          if (change != 'owner') {
            expect(router(t).routeInformationProvider.value.uri.path, path);
          }
        });
      }
    }
  }
  for (final change in ['go', 'push']) {
    testWidgets(
      'late reset success does not navigate or show toast after $change',
      (t) async {
        await launch(t, '/reset');
        final pending = Completer<http.Response>();
        handler = (_) => pending.future;
        t.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
        await t.pump();
        if (change == 'go') router(t).go('/join');
        if (change == 'push') router(t).push('/join');
        await t.pump(const Duration(milliseconds: 400));
        pending.complete(response({}));
        await t.pumpAndSettle();
        expect(router(t).routeInformationProvider.value.uri.path, '/join');
        expect(find.text('密码已更新，请使用新密码登录。'), findsNothing);
      },
    );
  }

  for (final source in ['/login', '/join', '/reset']) {
    testWidgets('$source current valid form completes the normal flow', (
      t,
    ) async {
      await launch(t, source);
      handler = (r) async => r.method == 'POST'
          ? response({
              'user': {
                'id': accountId,
                'username': 'test-user',
                'display_name': 'Test',
              },
              'access_token': 'test-only',
            })
          : response(signedIn(accountId).session!.preferences.toJson());
      t.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
      await t.pumpAndSettle();
      expect(requests.where((r) => r.method == 'POST'), hasLength(1));
      expect(
        router(t).routeInformationProvider.value.uri.path,
        source == '/reset' ? '/login' : '/practice',
      );
      if (source == '/reset') {
        expect(find.text('密码已更新，请使用新密码登录。'), findsOneWidget);
      }
    });
  }
}
