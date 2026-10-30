import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/review/review_models.dart';
import 'package:simontalk_client/features/review/review_page_controller.dart';
import 'package:simontalk_client/features/review/review_page_view.dart';

import 'rehearsal_evaluation_fixtures.dart';
import 'review_fixtures.dart';

void main() {
  testWidgets(
    'evaluation without suggestions shows both axes and saved text only',
    (t) async {
      var reads = 0;
      await t.pumpWidget(
        MaterialApp(
          home: ReviewPageView(
            state: ReviewPageState.ready,
            completion: sealedCompletion(),
            job: ReviewJobSnapshot.fromJson(evaluatedJobJson(), input: input()),
            onReadSavedText: () => reads++,
          ),
        ),
      );
      expect(find.text('本次重练评价'), findsOneWidget);
      expect(find.text('意思表达'), findsOneWidget);
      expect(find.text('目标问题'), findsOneWidget);
      expect(find.text('本次已传达原意'), findsOneWidget);
      expect(find.text('本次已展示目标表达'), findsOneWidget);
      expect(find.text('Yesterday I went to the park.'), findsNWidgets(2));
      expect(find.text('本次精确引文'), findsNWidgets(2));
      expect(find.textContaining('不等于长期掌握'), findsOneWidget);
      expect(find.text('定位到对话'), findsNothing);
      expect(find.text('练这一句'), findsNothing);
      expect(find.text('本次未整理出建议'), findsNothing);
      await t.ensureVisible(find.text('查看已保存文字'));
      await t.tap(find.text('查看已保存文字'));
      expect(reads, 1);
    },
  );

  for (final issue in [
    'still_present',
    'not_demonstrated',
    'insufficient_evidence',
  ]) {
    testWidgets(
      'independent axes explain $issue without inferring improvement',
      (t) async {
        await t.pumpWidget(
          MaterialApp(
            home: ReviewPageView(
              state: ReviewPageState.ready,
              job: ReviewJobSnapshot.fromJson(
                evaluatedJobJson(intent: 'changed', targetIssue: issue),
                input: input(),
              ),
            ),
          ),
        );
        expect(find.text('本次原意有变化'), findsOneWidget);
        expect(
          find.text(switch (issue) {
            'still_present' => '目标问题本次仍在',
            'not_demonstrated' => '本次未展示目标表达',
            _ => '目标问题的证据不足',
          }),
          findsOneWidget,
        );
        expect(find.textContaining('未展示不等于失败，也不能据此判断已掌握'), findsOneWidget);
        if (issue == 'insufficient_evidence') {
          expect(find.text('暂无可用于这一判断的本次引文。'), findsOneWidget);
        }
      },
    );
  }

  testWidgets(
    'old content withdrawal removes evaluation alongside suggestions',
    (t) async {
      final job = ReviewJobSnapshot.fromJson(
        evaluatedJobJson(withSuggestion: true),
        input: input(),
      );
      for (final phase in [
        'ready',
        'reading',
        'busy',
        'error',
        'identity',
        'ready',
      ]) {
        await t.pumpWidget(
          MaterialApp(
            home: ReviewPageView(
              state: phase == 'reading'
                  ? ReviewPageState.readingReview
                  : ReviewPageState.ready,
              job: job,
              busy: phase == 'busy',
              errorCode: phase == 'error'
                  ? 'network_error'
                  : phase == 'identity'
                  ? 'account_changed'
                  : null,
            ),
          ),
        );
        expect(
          find.text('本次重练评价'),
          phase == 'ready' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('I enjoy English.'),
          phase == 'ready' ? findsOneWidget : findsNothing,
        );
      }
    },
  );

  testWidgets('legacy child result never gains an inferred evaluation', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: ReviewPageView(
          state: ReviewPageState.ready,
          job: ReviewJobSnapshot.fromJson(
            jobJson(status: 'succeeded'),
            input: input(),
          ),
        ),
      ),
    );
    expect(find.text('本次重练评价'), findsNothing);
    expect(find.text('本次表达建议'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 568), const Size(844, 390)]) {
      testWidgets(
        'long evaluation selectable without overflow $brightness/$size/200%',
        (t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final raw = evaluatedJobJson();
          raw['result']['rehearsal_evaluation']['intent']['explanation'] =
              '本次仍然讲述昨天去公园的经历。' * 20;
          raw['result']['rehearsal_evaluation']['intent']['evidence'][0]['exact_quote'] =
              'LongQuoteWithoutSpaces' * 40;
          await t.pumpWidget(
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
                  job: ReviewJobSnapshot.fromJson(raw, input: input()),
                ),
              ),
            ),
          );
          expect(find.byType(SelectionArea), findsOneWidget);
          for (final label in ['意思表达', '目标问题', '返回练习偏好']) {
            await t.ensureVisible(find.text(label));
            expect(t.takeException(), isNull);
          }
        },
      );
    }
  }
}
