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
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_repository.dart';
import 'package:simontalk_client/features/history/deletion_controller.dart';
import 'package:simontalk_client/features/history/deletion_models.dart';
import 'package:simontalk_client/features/history/deletion_view.dart';
import 'package:simontalk_client/features/history/history_providers.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_providers.dart';
import 'package:simontalk_client/features/practice/practice_providers.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_providers.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_list_providers.dart';
import 'package:simontalk_client/features/practice/practice_recovery_panel.dart';

import '../practice/practice_fixtures.dart' show practiceJson, connectionJson;
import '../practice/practice_completion_test.dart' show completionSummary;
import '../practice/practice_providers_test.dart' show signedIn;
import '../review/review_screen_test.dart' show ReviewAccountController;
import 'deletion_fixtures.dart';
import 'history_fixtures.dart' show historyDetail, historyPage;
import '../rehearsal/rehearsal_fixtures.dart' show itemId, rehearsalTargetJson;
import '../rehearsal/rehearsal_list_fixtures.dart' show relatedPage, relatedRow;

void main() {
  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) handler;
  late ApiClient api;
  late ReviewAccountController account;
  Future<void> launch(
    WidgetTester t, {
    String path = '/history/$practiceId',
    bool restoring = false,
    bool connectionPending = false,
  }) async {
    requests.clear();
    t.platformDispatcher.defaultRouteNameTestValue = path;
    addTearDown(t.platformDispatcher.clearDefaultRouteNameTestValue);
    var removed = false;
    handler = (r) async {
      if (r.method == 'DELETE') {
        removed = true;
        return response({
          ...deletionReceipt(key: r.headers['Idempotency-Key']!),
          'connection_pending': connectionPending,
        });
      }
      if (r.url.path.endsWith('/deletion-scope')) {
        return response(deletionScope(pending: connectionPending));
      }
      if (r.url.path.endsWith('/completion')) {
        return response({
          ...completionSummary(sealed: true),
          'coverage': 'complete',
          'gap_codes': [],
        });
      }
      if (r.url.path.endsWith('/current')) {
        return response({
          'practice': {
            ...practiceJson(
              status: removed ? 'completed' : 'created',
              epoch: 1,
            ),
            if (removed) 'state_reason': 'content_deleted',
            if (removed) 'ended_at': '2026-10-23T12:00:00Z',
          },
          'connection': connectionJson(
            status: 'unknown',
            termination: 'unknown',
          ),
        });
      }
      if (r.url.path.endsWith('/rehearsal-target')) {
        return removed
            ? response({'code': 'practice_not_found'}, 404)
            : response(rehearsalTargetJson());
      }
      if (r.url.path.endsWith('/rehearsals')) {
        return removed
            ? response({'code': 'practice_not_found'}, 404)
            : response({
                ...relatedPage(),
                'items': [relatedRow(21), relatedRow(20)],
                'next_before_id': null,
              });
      }
      if (r.url.path == '/v1/practice-sessions/$practiceId') {
        return removed
            ? response({'code': 'practice_not_found'}, 404)
            : response({
                ...practiceJson(),
                'kind': 'ordinary',
                'source_session_id': null,
                'source_review_item_id': null,
              });
      }
      if (r.url.path == '/v1/practice-history') {
        return response({
          ...historyPage(),
          'items': removed ? [] : historyPage()['items'],
          'next_cursor': null,
        });
      }
      return response(historyDetail(222222222222, sealed: true));
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
    account = ReviewAccountController(signedIn(accountId));
    addTearDown(api.close);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider.overrideWithValue(AccountRepository(api)),
          accountControllerProvider.overrideWith(() => account),
          historyHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          savedPracticeStatusHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          recoveryHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          rehearsalHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
          rehearsalListHttpClientFactoryProvider.overrideWithValue(
            () => MockClient(dispatch),
          ),
        ],
        child: const SimonTalkApp(),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String label) async {
    await t.ensureVisible(find.text(label));
    await t.tap(find.text(label));
    await t.pumpAndSettle();
  }

  String location(WidgetTester t) =>
      GoRouter.of(t.element(find.byType(Scaffold).first))
          .routeInformationProvider
          .value
          .uri
          .path;

  testWidgets(
    'details scope shows all counts; keeping record makes zero writes',
    (t) async {
      await launch(t);
      await tap(t, '删除记录');
      expect(location(t), '/history/$practiceId/delete');
      expect(find.text('将删除这次练习和 2 次关联重练，共 3 条记录。'), findsOneWidget);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      await tap(t, '保留记录');
      expect(location(t), '/history/$practiceId');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );
  testWidgets(
    'confirmed receipt clears prior providers and returns fresh list',
    (t) async {
      await launch(t);
      await tap(t, '删除记录');
      await tap(t, '确认删除');
      expect(location(t), '/history');
      expect(find.text('还没有练习记录'), findsOneWidget);
      expect(find.text('已删除 3 条练习记录。'), findsOneWidget);
      expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
      expect(requests.last.url.path, '/v1/practice-history');
    },
  );
  testWidgets(
    'confirmed deletion clears retained recovery, target, list and eligibility scopes',
    (t) async {
      await launch(
        t,
        path: '/history/$practiceId/delete',
        connectionPending: true,
      );
      final container = ProviderScope.containerOf(
        t.element(find.byType(DeletionView)),
      );
      final target = container.listen(
        rehearsalProvider((sessionId: practiceId, itemId: itemId)),
        (_, _) {},
      );
      final list = container.listen(
        rehearsalListProvider(practiceId),
        (_, _) {},
      );
      final recovery = container.listen(practiceRecoveryProvider, (_, _) {});
      final eligible = container.listen(
        rehearsalEligibilityProvider(practiceId),
        (_, _) {},
      );
      addTearDown(target.close);
      addTearDown(list.close);
      addTearDown(recovery.close);
      addTearDown(eligible.close);
      final savedStatus = container.listen(
        savedPracticeStatusProvider(practiceId),
        (_, _) {},
      );
      addTearDown(savedStatus.close);
      final oldStatus = savedStatus.read()!;
      await oldStatus.refresh();
      expect(oldStatus.completion, isNotNull);
      final oldTarget = target.read()!,
          oldList = list.read()!,
          oldRecovery = recovery.read()!;
      await oldTarget.load();
      await oldList.refresh();
      await oldRecovery.refresh();
      expect(
        await container.read(rehearsalEligibilityProvider(practiceId).future),
        isTrue,
      );
      expect(oldTarget.target!.sourceText, 'Yes, I enjoy English.');
      expect(oldList.page!.items, hasLength(2));
      expect(
        oldRecovery.recovery!.connection!.terminationStatus,
        TerminationStatus.unknown,
      );
      await tap(t, '确认删除');
      expect(location(t), '/history');
      expect(oldStatus.item, isNull);
      expect(oldStatus.completion, isNull);
      expect(identical(savedStatus.read(), oldStatus), isFalse);
      expect(oldTarget.target, isNull);
      expect(oldList.page, isNull);
      expect(oldRecovery.recovery, isNull);
      expect(identical(target.read(), oldTarget), isFalse);
      expect(identical(list.read(), oldList), isFalse);
      expect(identical(recovery.read(), oldRecovery), isFalse);
      expect(
        await container.read(rehearsalEligibilityProvider(practiceId).future),
        isFalse,
      );
      expect(find.text('内容已删除，连接与用量仍待核对。'), findsOneWidget);
      await recovery.read()!.refresh();
      expect(
        recovery.read()!.recovery!.practice!.stateReason,
        'content_deleted',
      );
      expect(
        recovery.read()!.recovery!.practice!.status,
        PracticeStatus.completed,
      );
      expect(
        recovery.read()!.recovery!.connection!.terminationStatus,
        TerminationStatus.unknown,
      );
      expect(requests.where((r) => r.method != 'GET').map((r) => r.method), [
        'DELETE',
      ]);
    },
  );

  for (final kind in ['target', 'list', 'recovery']) {
    testWidgets('late $kind read cannot republish after confirmed deletion', (
      t,
    ) async {
      await launch(t, path: '/history/$practiceId/delete');
      final container = ProviderScope.containerOf(
        t.element(find.byType(DeletionView)),
      );
      final target = container.listen(
        rehearsalProvider((sessionId: practiceId, itemId: itemId)),
        (_, _) {},
      );
      final list = container.listen(
        rehearsalListProvider(practiceId),
        (_, _) {},
      );
      final recovery = container.listen(practiceRecoveryProvider, (_, _) {});
      addTearDown(target.close);
      addTearDown(list.close);
      addTearDown(recovery.close);
      final oldTarget = target.read()!,
          oldList = list.read()!,
          oldRecovery = recovery.read()!;
      final pending = Completer<http.Response>();
      final normal = handler;
      final path = switch (kind) {
        'target' =>
          '/v1/practice-sessions/$practiceId/review-items/$itemId/rehearsal-target',
        'list' => '/v1/practice-sessions/$practiceId/rehearsals',
        _ => '/v1/practice-sessions/current',
      };
      handler = (r) => r.url.path == path ? pending.future : normal(r);
      final task = switch (kind) {
        'target' => oldTarget.load(),
        'list' => oldList.refresh(),
        _ => oldRecovery.refresh(),
      };
      await t.pump();
      await tap(t, '确认删除');
      pending.complete(
        response(switch (kind) {
          'target' => rehearsalTargetJson(),
          'list' => {
            ...relatedPage(),
            'items': [relatedRow(21), relatedRow(20)],
            'next_before_id': null,
          },
          _ => {
            'practice': practiceJson(epoch: 1),
            'connection': connectionJson(
              status: 'unknown',
              termination: 'unknown',
            ),
          },
        }),
      );
      await task;
      await t.pumpAndSettle();
      expect(oldTarget.target, isNull);
      expect(oldList.page, isNull);
      expect(oldRecovery.recovery, isNull);
      expect(target.read()!.target, isNull);
      expect(list.read()!.page, isNull);
      expect(recovery.read()!.recovery, isNull);
      expect(requests.where((r) => r.method != 'GET').map((r) => r.method), [
        'DELETE',
      ]);
    });
  }
  for (final outcome in ['keep', 'conflict', 'lost then checked']) {
    testWidgets(
      '$outcome does not clear retained reads before a verified receipt',
      (t) async {
        await launch(t, path: '/history/$practiceId/delete');
        final container = ProviderScope.containerOf(
          t.element(find.byType(DeletionView)),
        );
        final target = container.listen(
          rehearsalProvider((sessionId: practiceId, itemId: itemId)),
          (_, _) {},
        );
        final list = container.listen(
          rehearsalListProvider(practiceId),
          (_, _) {},
        );
        final recovery = container.listen(practiceRecoveryProvider, (_, _) {});
        addTearDown(target.close);
        addTearDown(list.close);
        addTearDown(recovery.close);
        final oldTarget = target.read()!,
            oldList = list.read()!,
            oldRecovery = recovery.read()!;
        await oldTarget.load();
        await oldList.refresh();
        await oldRecovery.refresh();
        final normal = handler;
        handler = (r) async {
          if (r.method == 'DELETE') {
            if (outcome == 'conflict') {
              return response({'code': 'deletion_scope_changed'}, 409);
            }
            await normal(r);
            throw http.ClientException('deliberately lost accepted reply');
          }
          if (r.url.path.endsWith('/deletion')) {
            return response(
              deletionReceipt(key: r.url.queryParameters['key']!),
            );
          }
          return normal(r);
        };
        await tap(t, outcome == 'keep' ? '保留记录' : '确认删除');
        expect(identical(target.read(), oldTarget), isTrue);
        expect(identical(list.read(), oldList), isTrue);
        expect(identical(recovery.read(), oldRecovery), isTrue);
        expect(oldTarget.target, isNotNull);
        expect(oldList.page, isNotNull);
        expect(oldRecovery.recovery, isNotNull);
        if (outcome == 'lost then checked') {
          expect(find.text('删除结果尚未确认'), findsOneWidget);
          await tap(t, '核对删除结果');
          expect(oldTarget.target, isNull);
          expect(oldList.page, isNull);
          expect(oldRecovery.recovery, isNull);
          expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
          expect(location(t), '/history');
        } else if (outcome == 'keep') {
          expect(requests.every((r) => r.method == 'GET'), isTrue);
        } else {
          expect(find.text('重新读取删除范围'), findsOneWidget);
        }
      },
    );
  }

  testWidgets(
    'lost response requires explicit receipt check and never invents success',
    (t) async {
      await launch(t, path: '/history/$practiceId/delete');
      handler = (r) async => throw http.ClientException('lost');
      await tap(t, '确认删除');
      expect(find.text('删除结果尚未确认'), findsOneWidget);
      expect(location(t), '/history/$practiceId/delete');
      handler = (r) async =>
          response({'code': 'deletion_receipt_not_found'}, 404);
      await tap(t, '核对删除结果');
      expect(find.text('确认重试原删除'), findsOneWidget);
      expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
      expect(find.text('确认删除'), findsNothing);
    },
  );
  testWidgets('scope conflict removes confirmation until reread', (t) async {
    await launch(t, path: '/history/$practiceId/delete');
    handler = (r) async => response({'code': 'deletion_scope_changed'}, 409);
    await tap(t, '确认删除');
    expect(find.text('确认删除'), findsNothing);
    expect(find.text('重新读取删除范围'), findsOneWidget);
  });
  for (final change in ['busy', 'restoring', 'unreachable', 'other account']) {
    testWidgets('old deletion confirmation rejects account $change', (t) async {
      await launch(t, path: '/history/$practiceId/delete');
      final old = t.widget<DeletionView>(find.byType(DeletionView)).onConfirm!;
      final session = account.state.session;
      account.change(switch (change) {
        'busy' => AccountState(
          phase: SessionPhase.signedIn,
          session: session,
          busy: true,
        ),
        'restoring' => const AccountState(),
        'unreachable' => const AccountState(phase: SessionPhase.unreachable),
        _ => signedIn('99999999-9999-4999-8999-999999999999'),
      });
      old();
      await t.pumpAndSettle();
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    });
  }

  for (final routing in ['go', 'push']) {
    for (final action in ['confirm', 'keep']) {
      testWidgets('old $action is inert after route leaves by $routing', (
        t,
      ) async {
        await launch(t, path: '/history/$practiceId/delete');
        final view = t.widget<DeletionView>(find.byType(DeletionView));
        final old = action == 'confirm' ? view.onConfirm! : view.onKeep!;
        final router = GoRouter.of(t.element(find.byType(DeletionView)));
        final destination = routing == 'go' ? '/history' : '/account';
        if (routing == 'go') {
          router.go(destination);
        } else {
          router.push(destination);
        }
        // Route changes precede the next frame and disposal of the old page.
        old();
        await t.pumpAndSettle();
        expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
        expect(location(t), destination);
      });
    }
  }

  testWidgets('old confirmation cannot approve a newly read scope', (t) async {
    await launch(t, path: '/history/$practiceId/delete');
    final old = t.widget<DeletionView>(find.byType(DeletionView)).onConfirm!;
    final container = ProviderScope.containerOf(
      t.element(find.byType(DeletionView)),
    );
    final controller = container.read(deletionProvider(practiceId))!;
    final normal = handler;
    final changed = {...deletionScope(children: 5), 'scope_version': 'b' * 64};
    handler = (r) async {
      if (r.url.path.endsWith('/deletion-scope')) return response(changed);
      if (r.method == 'DELETE') {
        return response({
          ...deletionReceipt(key: r.headers['Idempotency-Key']!),
          'scope_version': changed['scope_version'],
          'record_count': 6,
          'rehearsal_count': 5,
        });
      }
      return normal(r);
    };
    // Finish HTTP without a frame: the old rendered confirmation is still present.
    await controller.load();
    expect(controller.scope!.recordCount, 6);
    expect(find.text('将删除这次练习和 2 次关联重练，共 3 条记录。'), findsOneWidget);
    old();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    expect(find.text('将删除这次练习和 5 次关联重练，共 6 条记录。'), findsOneWidget);
    await tap(t, '确认删除');
    expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(location(t), '/history');
  });

  testWidgets('old confirmation cannot use an invalidated provider', (t) async {
    await launch(t, path: '/history/$practiceId/delete');
    final old = t.widget<DeletionView>(find.byType(DeletionView)).onConfirm!;
    final container = ProviderScope.containerOf(
      t.element(find.byType(DeletionView)),
    );
    container.invalidate(deletionProvider(practiceId));
    old();
    await t.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    expect(find.text('确认删除'), findsOneWidget);
  });

  testWidgets('old keep cannot leave while a deletion is in flight', (t) async {
    await launch(t, path: '/history/$practiceId/delete');
    final view = t.widget<DeletionView>(find.byType(DeletionView));
    final pending = Completer<http.Response>();
    final normal = handler;
    handler = (r) => r.method == 'DELETE' ? pending.future : normal(r);
    view.onConfirm!();
    await t.pump();
    final request = requests.singleWhere((r) => r.method == 'DELETE');
    view.onKeep!();
    await t.pump();
    final afterKeep = location(t);
    pending.complete(
      response(deletionReceipt(key: request.headers['Idempotency-Key']!)),
    );
    await t.pumpAndSettle();
    expect(afterKeep, '/history/$practiceId/delete');
    expect(location(t), '/history');
  });

  testWidgets(
    'account busy disables keeping and confirmation including old callbacks',
    (t) async {
      await launch(t, path: '/history/$practiceId/delete');
      final oldKeep = t.widget<DeletionView>(find.byType(DeletionView)).onKeep!;
      account.change(
        AccountState(
          phase: SessionPhase.signedIn,
          session: account.state.session,
          busy: true,
        ),
      );
      oldKeep();
      await t.pumpAndSettle();
      expect(location(t), '/history/$practiceId/delete');
      expect(
        t
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '保留记录'))
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认删除'))
            .onPressed,
        isNull,
      );
      expect(find.text('正在处理，请稍候…'), findsOneWidget);
      account.change(signedIn(accountId));
      await t.pumpAndSettle();
      await tap(t, '保留记录');
      expect(location(t), '/history/$practiceId');
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  for (final action in ['load', 'check', 'replay']) {
    testWidgets('old deletion $action waits while account is busy', (t) async {
      await launch(t, path: '/history/$practiceId/delete');
      final normal = handler;
      if (action == 'load') {
        final container = ProviderScope.containerOf(
          t.element(find.byType(DeletionView)),
        );
        handler = (r) async => response({'code': 'service_unavailable'}, 503);
        await container.read(deletionProvider(practiceId))!.load();
        await t.pumpAndSettle();
      } else {
        handler = (r) async {
          if (r.method == 'DELETE') await normal(r);
          throw http.ClientException('lost');
        };
        await tap(t, '确认删除');
        if (action == 'replay') {
          handler = (r) async =>
              response({'code': 'deletion_receipt_not_found'}, 404);
          await tap(t, '核对删除结果');
        }
      }
      final view = t.widget<DeletionView>(find.byType(DeletionView));
      final callback = switch (action) {
        'load' => view.onLoad!,
        'check' => view.onCheck!,
        _ => view.onReplay!,
      };
      final count = requests.length;
      account.change(
        AccountState(
          phase: SessionPhase.signedIn,
          session: account.state.session,
          busy: true,
        ),
      );
      callback();
      await t.pumpAndSettle();
      expect(requests, hasLength(count));
      expect(location(t), '/history/$practiceId/delete');
      account.change(signedIn(accountId));
      handler = (r) async => r.url.path.endsWith('/deletion')
          ? response(deletionReceipt(key: r.url.queryParameters['key']!))
          : normal(r);
      await t.pumpAndSettle();
      await tap(t, switch (action) {
        'load' => '重新读取删除范围',
        'check' => '核对删除结果',
        _ => '确认重试原删除',
      });
      if (action == 'load') {
        expect(find.text('确认删除'), findsOneWidget);
        expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
      } else {
        expect(location(t), '/history');
        final deletes = requests.where((r) => r.method == 'DELETE').toList();
        expect(deletes, hasLength(action == 'check' ? 1 : 2));
        if (action == 'replay') {
          expect(
            deletes.last.headers['Idempotency-Key'],
            deletes.first.headers['Idempotency-Key'],
          );
          expect(deletes.last.body, deletes.first.body);
        }
      }
    });
  }

  testWidgets('invalid deletion address can keep and leave without requests', (
    t,
  ) async {
    await launch(t, path: '/history/not-a-practice/delete');
    expect(find.text('练习地址无效。'), findsOneWidget);
    await tap(t, '保留记录');
    expect(location(t), '/history/not-a-practice');
    expect(requests, isEmpty);
  });

  testWidgets('initial keyboard focus preserves record', (t) async {
    await launch(t, path: '/history/$practiceId/delete');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(location(t), '/history/$practiceId');
    expect(requests.every((r) => r.method == 'GET'), isTrue);
  });
  for (final size in [const Size(320, 720), const Size(844, 390)]) {
    for (final brightness in Brightness.values) {
      testWidgets('deletion scope $size $brightness 200% wraps', (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: DeletionView(
              state: DeletionState.ready,
              scope: DeletionScope.fromJson(
                deletionScope(pending: true),
                accountId: accountId,
                sessionId: practiceId,
              ),
              onKeep: () {},
              onConfirm: () {},
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('确认删除'));
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('deleted recovery retains warning and hides all body actions', (
    t,
  ) async {
    final practice = practiceJson(status: 'completed', epoch: 1)
      ..['state_reason'] = 'content_deleted';
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PracticeRecoveryView(
              recovery: PracticeRecovery.fromJson({
                'practice': practice,
                'connection': connectionJson(
                  status: 'unknown',
                  termination: 'unknown',
                ),
              }),
            ),
          ),
        ),
      ),
    );
    expect(find.text('内容已删除，原连接与用量仍待核对。'), findsOneWidget);
    expect(find.text('查看已保存文字'), findsNothing);
    expect(find.text('查看保存状态'), findsNothing);
  });
}
