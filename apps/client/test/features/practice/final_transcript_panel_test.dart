import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/practice/practice_recovery_panel.dart';

import '../conversation/final_transcript_view_fixtures.dart';
import 'practice_fixtures.dart';
import 'practice_providers_test.dart' show ScopedAccountController;

void main() {
  late ApiClient api;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;

  setUp(() {
    requests = [];
    api = ApiClient(
      baseUrl: Uri.parse('http://localhost'),
      isWeb: true,
      tokenStore: TestTokenStore(),
      client: MockClient((_) async => response({})),
    )..expectedAccountId = accountId;
    handler = (_) async => response({
      'practice': practiceJson(status: 'interrupted', epoch: 1),
      'connection': connectionJson(status: 'unknown', termination: 'unknown'),
    });
  });

  tearDown(() => api.close());

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
        accountControllerProvider.overrideWith(ScopedAccountController.new),
        recoveryHttpClientFactoryProvider.overrideWithValue(
          () => MockClient((request) async {
            requests.add(request);
            return handler(request);
          }),
        ),
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: PracticeRecoveryPanel()),
        ),
      ),
    ),
  );

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('actual panel lazily GETs final text for the original connection', (
    tester,
  ) async {
    await show(tester);
    expect(requests, isEmpty);
    expect(find.text('查看已保存文字'), findsNothing);
    await tap(tester, '查看未结束练习');
    expect(requests, hasLength(1));
    expect(find.text('查看已保存文字'), findsOneWidget);
    handler = (_) async => response(
      transcriptViewPage([
        transcriptViewEvent(1, text: 'Saved on this account.'),
      ]),
    );
    await tap(tester, '查看已保存文字');
    expect(find.text('Saved on this account.'), findsOneWidget);
    expect(find.text('远端是否结束尚未确认'), findsOneWidget);
    expect(find.text('刷新文字'), findsOneWidget);
    expect(requests, hasLength(2));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(
      requests.last.url.path,
      '/v1/practice-sessions/$practiceId/connections/$connectionId/transcripts',
    );
    expect(requests.last.headers['X-Account-ID'], accountId);
    expect(find.textContaining(connectionId), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'page failure retains text and explicitly retries the same cursor',
    (tester) async {
      await show(tester);
      await tap(tester, '查看未结束练习');
      final events = [for (var i = 1; i <= 32; i++) transcriptViewEvent(i)];
      handler = (_) async => response(
        transcriptViewPage(events, total: 33, last: 33, more: true, bytes: 33),
      );
      await tap(tester, '查看已保存文字');
      expect(find.text('尚有文字未读取，当前内容可能继续更新。'), findsOneWidget);
      handler = (_) async => response({'code': 'service_unavailable'}, 503);
      await tap(tester, '查看更多文字');
      expect(find.text('x'), findsWidgets);
      expect(find.text('重试读取文字'), findsOneWidget);
      handler = (_) async => response(
        transcriptViewPage([transcriptViewEvent(33)], total: 33, bytes: 33),
      );
      await tap(tester, '重试读取文字');
      expect(requests[2].url.queryParameters['after_sequence'], '32');
      expect(requests[3].url.queryParameters['after_sequence'], '32');
      expect(find.text('查看更多文字'), findsNothing);
      expect(find.text('已读取 33 次提交，本次查询共 33 次；当前 33 段文字。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'text loading alone has a specific status and disables all actions',
    (tester) async {
      await show(tester);
      await tap(tester, '查看未结束练习');
      final pending = Completer<http.Response>();
      handler = (_) => pending.future;
      await tester.ensureVisible(find.text('查看已保存文字'));
      await tester.tap(find.text('查看已保存文字'));
      await tester.pump();
      expect(find.text('正在读取文字…'), findsOneWidget);
      expect(find.text('正在读取连接记录…'), findsNothing);
      for (final button in tester.widgetList<OutlinedButton>(
        find.byType(OutlinedButton),
      )) {
        expect(button.onPressed, isNull);
      }
      pending.complete(response(transcriptViewPage([])));
      await tester.pumpAndSettle();
      expect(find.text('尚无已保存的最终文字。'), findsOneWidget);
    },
  );

  for (final code in ['practice_not_found', 'connection_not_found']) {
    testWidgets('deleted $code displays a stable readable message', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PracticeRecoveryView(errorCode: code, onRefresh: () {}),
          ),
        ),
      );
      expect(find.text('这条记录已不可用，请刷新查看当前状态。'), findsOneWidget);
      expect(find.text(code), findsNothing);
      expect(find.text('刷新状态'), findsOneWidget);
    });
  }
}
