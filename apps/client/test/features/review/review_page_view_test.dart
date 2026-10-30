import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/review/review_models.dart';
import 'package:simontalk_client/features/review/review_page_controller.dart';
import 'package:simontalk_client/features/review/review_page_view.dart';

import 'review_fixtures.dart';

ReviewJobSnapshot snapshot(
  String status, {
  int? attempts,
  bool unknown = false,
}) => ReviewJobSnapshot.fromJson(
  jobJson(status: status, attempts: attempts, unknown: unknown),
  input: input(empty: status == 'no_evaluable_content'),
);

void main() {
  testWidgets(
    'verified ordinary source exposes rehearsal action for its exact item',
    (t) async {
      String? selected;
      await t.pumpWidget(
        MaterialApp(
          home: ReviewPageView(
            state: ReviewPageState.ready,
            completion: sealedCompletion(),
            job: snapshot('succeeded'),
            onRehearseItem: (id) => selected = id,
          ),
        ),
      );
      await t.ensureVisible(find.text('练这一句'));
      await t.tap(find.text('练这一句'));
      expect(selected, itemId);
    },
  );
  testWidgets(
    'without ordinary source eligibility no rehearsal action is offered',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: ReviewPageView(
            state: ReviewPageState.ready,
            completion: sealedCompletion(),
            job: snapshot('succeeded'),
          ),
        ),
      );
      expect(find.text('练这一句'), findsNothing);
    },
  );

  testWidgets('sealed review exposes saved text with blocked model', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ReviewPageView(
          state: ReviewPageState.ready,
          completion: sealedCompletion(),
          job: snapshot('blocked'),
        ),
      ),
    );
    expect(find.text('查看已保存文字'), findsOneWidget);
  });
  testWidgets('each successful suggestion exposes exact location', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ReviewPageView(
          state: ReviewPageState.ready,
          completion: sealedCompletion(),
          job: snapshot('succeeded'),
        ),
      ),
    );
    expect(find.text('定位到对话'), findsOneWidget);
  });
  testWidgets('business states expose only their allowed explicit action', (
    tester,
  ) async {
    var request = 0, retry = 0, refresh = 0, pending = 0;
    Future<void> show({
      ReviewJobSnapshot? job,
      bool canRequest = false,
      bool canRetry = false,
      bool hasPending = false,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ReviewPageView(
          state: ReviewPageState.ready,
          completion: sealedCompletion(),
          job: job,
          canRequestReview: canRequest,
          canRetryGeneration: canRetry,
          hasPendingAction: hasPending,
          onRequestReview: () => request++,
          onRetryGeneration: () => retry++,
          onRefresh: () => refresh++,
          onRetryPending: () => pending++,
          onBack: () {},
        ),
      ),
    );
    await show(canRequest: true);
    await tester.tap(find.text('整理表达建议'));
    expect(request, 1);
    for (final state in ['queued', 'running', 'retry_wait']) {
      await show(job: snapshot(state));
      expect(find.text('整理表达建议'), findsNothing);
      expect(find.text('重试整理'), findsNothing);
      await tester.ensureVisible(find.text('刷新复盘状态'));
      await tester.tap(find.text('刷新复盘状态'));
    }
    expect(refresh, 3);
    for (final state in ['blocked', 'failed']) {
      await show(job: snapshot(state), canRetry: true);
      await tester.ensureVisible(find.text('重试整理'));
      await tester.tap(find.text('重试整理'));
      await show(job: snapshot(state, attempts: 3));
      expect(find.text('重试整理'), findsNothing);
      expect(find.textContaining('联系维护者'), findsOneWidget);
    }
    expect(retry, 2);
    await show(job: snapshot('failed', unknown: true));
    expect(find.text('重试整理'), findsNothing);
    expect(find.textContaining('暂停重复生成'), findsOneWidget);
    await show(hasPending: true);
    expect(find.text('整理表达建议'), findsNothing);
    expect(find.text('重试整理'), findsNothing);
    await tester.ensureVisible(find.text('确认上次整理请求'));
    await tester.tap(find.text('确认上次整理请求'));
    expect(pending, 1);
  });

  testWidgets(
    'valid empty outcomes differ from technical failure and data errors hide old text',
    (tester) async {
      Future<void> show({
        String? status,
        String? error,
        ReviewPageState state = ReviewPageState.ready,
      }) => tester.pumpWidget(
        MaterialApp(
          home: ReviewPageView(
            state: state,
            job: status == null ? null : snapshot(status),
            errorCode: error,
            onBack: () {},
            onRefresh: () {},
          ),
        ),
      );
      await show(status: 'no_evaluable_content');
      expect(find.text('没有可评价的用户表达'), findsOneWidget);
      await show(status: 'no_suggestions');
      expect(find.text('本次未整理出建议'), findsOneWidget);
      expect(find.textContaining('不代表'), findsOneWidget);
      await show(
        status: 'succeeded',
        error: 'network_error',
        state: ReviewPageState.failed,
      );
      expect(find.text('I enjoy English.'), findsNothing);
      expect(find.text('暂时无法读取复盘'), findsOneWidget);
      await show(error: 'idempotency_conflict', state: ReviewPageState.failed);
      expect(find.textContaining('请先刷新'), findsOneWidget);
    },
  );

  testWidgets('explicit write busy state does not claim it is only reading', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReviewPageView(
          state: ReviewPageState.readingReview,
          busy: true,
          completion: sealedCompletion(),
          canRequestReview: true,
          onRequestReview: () {},
        ),
      ),
    );
    expect(find.textContaining('正在处理本次操作'), findsOneWidget);
    expect(find.textContaining('只读取现有状态'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '整理表达建议'))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'source and identity states have explicit refresh or confirmation',
    (tester) async {
      for (final state in [
        ReviewPageState.notSaved,
        ReviewPageState.saving,
        ReviewPageState.readingSource,
        ReviewPageState.unavailable,
        ReviewPageState.aborted,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: ReviewPageView(
              state: state,
              errorCode: state == ReviewPageState.aborted
                  ? 'account_changed'
                  : null,
              onConfirmAccount: () {},
              onRefresh: () {},
              onBack: () {},
            ),
          ),
        );
        expect(find.text('整理表达建议'), findsNothing);
        expect(find.text('重试整理'), findsNothing);
        expect(find.text('返回练习偏好'), findsOneWidget);
        if (state == ReviewPageState.aborted) {
          expect(find.text('重新确认账号'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  for (final width in [320.0, 375.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'focused refresh stays visible after source shrink and three results return: $width/$scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final phase = ValueNotifier(false);
          addTearDown(phase.dispose);
          final json = jobJson(status: 'succeeded');
          json['result']['items'] = [
            for (var i = 0; i < 3; i++)
              {
                ...itemJson(),
                'id': '${i + 7}7777777-7777-4777-8777-777777777777',
                'ordinal': i + 1,
              },
          ];
          final three = ReviewJobSnapshot.fromJson(json, input: input());
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(Brightness.light),
              home: MediaQuery(
                // Directional navigation retains the actual focused disabled control
                // while its asynchronous source is loading.
                data: MediaQueryData(
                  size: Size(width, 568),
                  textScaler: TextScaler.linear(scale),
                  navigationMode: NavigationMode.directional,
                  disableAnimations: true,
                ),
                child: ValueListenableBuilder(
                  valueListenable: phase,
                  builder: (context, reading, _) => ReviewPageView(
                    state: reading
                        ? ReviewPageState.readingSource
                        : ReviewPageState.ready,
                    completion: reading ? null : sealedCompletion(),
                    job: reading ? null : three,
                    busy: reading,
                    onRefresh: () => phase.value = true,
                    onBack: () {},
                  ),
                ),
              ),
            ),
          );
          final button = find.widgetWithText(OutlinedButton, '刷新复盘状态');
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          Focus.of(tester.element(find.text('刷新复盘状态'))).requestFocus();
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus!;
          expect(focused.hasFocus, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(phase.value, isTrue);
          expect(focused.hasFocus, isTrue);
          phase.value = false;
          await tester.pumpAndSettle();
          expect(focused.hasFocus, isTrue);
          final rect = tester.getRect(button);
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(568));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 568),
      const Size(375, 667),
      const Size(844, 390),
      const Size(1200, 800),
    ]) {
      testWidgets(
        'three long selectable items fit $brightness $size at 200% reduced motion',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final json = jobJson(status: 'succeeded');
          json['result']['items'] = [
            for (var i = 0; i < 3; i++)
              {
                ...itemJson(),
                'id': '${i + 7}7777777-7777-4777-8777-777777777777',
                'ordinal': i + 1,
                'kind': ['correction', 'polish', 'extension'][i],
                'exact_quote': 'OriginalSentenceWithoutSpaces' * 10,
                'explanation': '保留原意，解释这项表达建议。' * 12,
              },
          ];
          final job = ReviewJobSnapshot.fromJson(json, input: input());
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: ReviewPageView(
                  state: ReviewPageState.ready,
                  completion: sealedCompletion(),
                  job: job,
                  onBack: () {},
                  onRefresh: () {},
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(SelectionArea), findsOneWidget);
          final resultSemantics = tester
              .getSemantics(find.text('本次表达建议'))
              .getSemanticsData()
              .flagsCollection;
          expect(resultSemantics.isHeader, isTrue);
          expect(resultSemantics.isLiveRegion, isTrue);
          expect(
            tester
                .getSemantics(find.text('练习复盘'))
                .getSemanticsData()
                .flagsCollection
                .isHeader,
            isTrue,
          );
          for (final kind in ['纠错建议', '表达更自然', '拓展表达']) {
            await tester.ensureVisible(find.text(kind));
            expect(tester.takeException(), isNull);
          }
          await tester.ensureVisible(find.text('返回练习偏好'));
          expect(
            tester
                .getSize(find.widgetWithText(OutlinedButton, '返回练习偏好'))
                .height,
            greaterThanOrEqualTo(48),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
