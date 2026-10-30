import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/termination_check_models.dart';
import 'package:simontalk_client/features/practice/practice_save_status_view.dart';
import 'package:simontalk_client/features/practice/practice_recovery_panel.dart';

import 'practice_fixtures.dart';
import 'practice_completion_test.dart' show completionSummary;
import 'saved_status_recovery_test.dart' show terminationSnapshot;

ConversationScope savedScope() => ConversationScope(
  accountId: accountId,
  sessionId: practiceId,
  connectionId: connectionId,
  clientInstanceId: clientId,
  epoch: 1,
);
PracticeCompletionSummary savedSummary({
  bool sealed = true,
  bool complete = false,
  List<String>? gaps,
}) => PracticeCompletionSummary.fromJson({
  ...completionSummary(sealed: sealed),
  if (complete) 'coverage': 'complete',
  if (complete) 'gap_codes': <String>[],
  'gap_codes': ?gaps,
}, scope: savedScope());
TerminationCheckSnapshot savedCheck({bool blocked = true}) =>
    TerminationCheckSnapshot.fromJson(
      terminationSnapshot(blocked: blocked),
      scope: savedScope(),
    );
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double width = 375,
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('view is lazy and load is an explicit action', (tester) async {
    var calls = 0;
    await pump(tester, PracticeSaveStatusView(onLoad: () => calls++));
    expect(calls, 0);
    expect(find.text('保存状态'), findsOneWidget);
    await tester.tap(find.text('查看保存状态'));
    expect(calls, 1);
    expect(find.text('记录已保存'), findsNothing);
  });
  testWidgets(
    'a registered end hides obsolete preparation cleanup even after read failure',
    (tester) async {
      await pump(
        tester,
        PracticeRecoveryView(
          recovery: PracticeRecovery.fromJson({
            'practice': practiceJson(status: 'connecting', epoch: 1),
            'connection': connectionJson(),
          }),
          endRegistered: true,
          saveStatusErrorCode: 'network_error',
        ),
      );
      expect(find.text('清理未开始的准备'), findsNothing);
      expect(find.text('服务器记录：已登记结束'), findsOneWidget);
    },
  );
  testWidgets('loading announces a read and disables controls', (tester) async {
    var calls = 0;
    await pump(
      tester,
      PracticeSaveStatusView(
        busy: true,
        onLoad: () => calls++,
        onRefresh: () => calls++,
      ),
    );
    expect(find.text('正在核对保存状态…'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.byType(OutlinedButton).first,
    );
    expect(button.onPressed, isNull);
    expect(calls, 0);
  });
  testWidgets('missing completion means unregistered rather than saved', (
    tester,
  ) async {
    await pump(
      tester,
      PracticeSaveStatusView(
        loaded: true,
        terminationCheck: savedCheck(blocked: false),
        terminationStatus: TerminationStatus.unknown,
      ),
    );
    expect(find.text('尚未登记结束保存'), findsOneWidget);
    expect(find.text('记录已保存'), findsNothing);
    expect(find.textContaining('自动核验暂不可用'), findsNothing);
  });
  testWidgets('ending displays collection without claiming a complete save', (
    tester,
  ) async {
    await pump(
      tester,
      PracticeSaveStatusView(
        loaded: true,
        completion: savedSummary(sealed: false),
        terminationCheck: savedCheck(),
        terminationStatus: TerminationStatus.unknown,
      ),
    );
    expect(find.text('正在保存本次记录'), findsOneWidget);
    expect(find.text('记录已保存'), findsNothing);
    expect(find.textContaining('维护者协助确认'), findsOneWidget);
    expect(find.textContaining('2026-10-21'), findsOneWidget);
    expect(find.textContaining('服务器仍在等待收尾内容'), findsNothing);
  });
  testWidgets('refresh can be reached and activated from the keyboard', (
    tester,
  ) async {
    var reads = 0;
    await pump(
      tester,
      PracticeSaveStatusView(
        loaded: true,
        completion: savedSummary(),
        terminationCheck: savedCheck(),
        onRefresh: () => reads++,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(reads, 1);
    expect(
      tester.getSize(find.byType(OutlinedButton)).height,
      greaterThanOrEqualTo(48),
    );
  });
  for (final preview in [
    savedStatusLightPreview,
    savedStatusDarkLargePreview,
    savedStatusCompletePreview,
  ]) {
    testWidgets('preview fixture ${preview.toString()} renders', (
      tester,
    ) async {
      await tester.pumpWidget(preview());
      expect(tester.takeException(), isNull);
      expect(find.text('保存状态'), findsOneWidget);
    });
  }
  testWidgets('complete save remains independent from unknown termination', (
    tester,
  ) async {
    await pump(
      tester,
      PracticeSaveStatusView(
        loaded: true,
        completion: savedSummary(complete: true),
        terminationCheck: savedCheck(),
        terminationStatus: TerminationStatus.unknown,
      ),
    );
    expect(find.text('记录已保存'), findsOneWidget);
    expect(find.textContaining('维护者协助确认'), findsOneWidget);
    expect(find.textContaining('费用已停止'), findsNothing);
  });
  testWidgets(
    'missing evidence has bounded understandable reasons and no impossible save retry',
    (tester) async {
      final gaps = practiceCompletionGapCodes.toList()..sort();
      await pump(
        tester,
        PracticeSaveStatusView(
          loaded: true,
          completion: savedSummary(gaps: gaps),
          terminationCheck: savedCheck(),
          terminationStatus: TerminationStatus.unknown,
        ),
      );
      expect(find.text('已有内容已保存，仍有缺口'), findsOneWidget);
      expect(find.text('部分文字未保存。'), findsOneWidget);
      expect(find.text('部分话语可能未完成识别。'), findsOneWidget);
      expect(find.textContaining('刷新不能补回'), findsOneWidget);
      expect(find.text('重试保存'), findsNothing);
      expect(find.textContaining('transcript_missing'), findsNothing);
    },
  );
  testWidgets('read failure hides any stale successful result', (tester) async {
    await pump(
      tester,
      PracticeSaveStatusView(
        errorCode: 'network_error',
        loaded: true,
        completion: savedSummary(complete: true),
        terminationCheck: savedCheck(),
      ),
    );
    expect(find.text('记录已保存'), findsNothing);
    expect(find.textContaining('维护者协助确认'), findsNothing);
    expect(find.text('重试读取保存状态'), findsOneWidget);
  });
  for (final brightness in Brightness.values) {
    for (final width in [320.0, 375.0, 900.0]) {
      testWidgets(
        'status wraps at $width in $brightness and 200 percent text',
        (tester) async {
          await pump(
            tester,
            PracticeSaveStatusView(
              loaded: true,
              completion: savedSummary(),
              terminationCheck: savedCheck(),
              terminationStatus: TerminationStatus.unknown,
            ),
            width: width,
            brightness: brightness,
            scale: 2,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
