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
import 'package:simontalk_client/features/history/history_providers.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_providers.dart';
import 'package:simontalk_client/features/usage/usage_previews.dart';
import 'package:simontalk_client/features/usage/usage_providers.dart';

import '../history/history_fixtures.dart';
import '../practice/practice_completion_test.dart' show completionSummary;
import '../practice/practice_providers_test.dart' show signedIn;
import '../practice/saved_practice_status_test.dart' show saveStatusDetail;
import '../review/review_screen_test.dart' show ReviewAccountController;
import 'usage_models_and_controller_test.dart'
    show accountUsagePayload, practiceUsagePayload;

void main() {
  testWidgets(
    'preferences screen keeps usage silent until clicked and guards stale actions',
    (tester) async {
      final requests = <http.Request>[];
      tester.platformDispatcher.defaultRouteNameTestValue = '/account';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<http.Response> dispatch(http.Request r) async {
        requests.add(r);
        if (r.url.path == '/v1/usage') return response(accountUsagePayload());
        return response({});
      }

      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient(dispatch),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final account = ReviewAccountController(signedIn(accountId));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
            accountControllerProvider.overrideWith(() => account),
            usageHttpClientFactoryProvider.overrideWithValue(
              () => MockClient(dispatch),
            ),
          ],
          child: const SimonTalkApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(requests, isEmpty);
      expect(find.text('模型用量'), findsOneWidget);
      expect(find.text('查看本人用量'), findsOneWidget);

      final loadButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '查看本人用量'),
      );
      account.change(
        AccountState(
          phase: SessionPhase.signedIn,
          session: signedIn(accountId).session,
          busy: true,
        ),
      );
      await tester.pump();
      // Stale callback captured before account became busy must not fire HTTP.
      loadButton.onPressed?.call();
      await tester.pump();
      expect(requests, isEmpty);

      account.change(signedIn(accountId));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看本人用量'));
      await tester.tap(find.text('查看本人用量'));
      await tester.pumpAndSettle();

      expect(requests.map((r) => r.url.path), ['/v1/usage']);
      expect(find.textContaining('已知输入 770 Token'), findsOneWidget);
      expect(find.textContaining('已知输入 310 Token'), findsOneWidget);
      expect(find.textContaining('已知输入 645 Token'), findsOneWidget);
      expect(find.text('已删除练习共 2 条；脱敏用量继续保留以供核账，不提供原话入口。'), findsOneWidget);

      final refreshButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '刷新用量'),
      );
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/practice');
      await tester.pumpAndSettle();
      refreshButton.onPressed?.call();
      await tester.pump();
      expect(requests, hasLength(1));
    },
  );

  testWidgets(
    'saved practice status screen keeps initial 2 GETs and loads practice usage on demand',
    (tester) async {
      final requests = <http.Request>[];
      tester.platformDispatcher.defaultRouteNameTestValue =
          '/practice/$practiceId/save-status';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      tester.view.physicalSize = const Size(320, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<http.Response> dispatch(http.Request r) async {
        requests.add(r);
        if (r.url.path.endsWith('/completion')) {
          return response(completionSummary(sealed: true));
        }
        if (r.url.path == '/v1/usage/practices/$practiceId') {
          return response(practiceUsagePayload());
        }
        return response(saveStatusDetail());
      }

      final api = ApiClient(
        baseUrl: Uri.parse('http://localhost'),
        isWeb: false,
        tokenStore: TestTokenStore(),
        client: MockClient(dispatch),
      )..expectedAccountId = accountId;
      addTearDown(api.close);
      final account = ReviewAccountController(signedIn(accountId));

      await tester.pumpWidget(
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
            usageHttpClientFactoryProvider.overrideWithValue(
              () => MockClient(dispatch),
            ),
          ],
          child: SimonTalkApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(requests, hasLength(2));
      expect(find.text('查看本次用量'), findsOneWidget);

      await tester.ensureVisible(find.text('查看本次用量'));
      await tester.tap(find.text('查看本次用量'));
      await tester.pumpAndSettle();

      expect(requests, hasLength(3));
      expect(requests.last.url.path, '/v1/usage/practices/$practiceId');
      expect(find.text('本次语音回复'), findsOneWidget);
      expect(find.text('本次复盘整理'), findsOneWidget);
      expect(find.textContaining('已知输入 770 Token'), findsOneWidget);
      expect(find.textContaining('已知输入 645 Token'), findsOneWidget);
    },
  );

  for (final (name, builder, size) in [
    ('full', accountUsageFullPreview, const Size(760, 980)),
    ('dark320', accountUsageDarkCompactPreview, const Size(320, 1280)),
    ('empty', accountUsageEmptyPreview, const Size(390, 760)),
    ('practice', practiceUsageReadyPreview, const Size(390, 760)),
  ]) {
    testWidgets('usage preview $name renders without overflow', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(builder());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
