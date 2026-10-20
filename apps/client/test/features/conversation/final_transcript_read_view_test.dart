import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/conversation/final_transcript_read_view.dart';

import '../practice/practice_fixtures.dart';
import 'final_transcript_view_fixtures.dart';

Future<void> showTranscript(
  WidgetTester tester,
  FinalTranscriptReadView view, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  ScrollController? outerController,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppTheme(brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        controller: outerController,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(padding: const EdgeInsets.all(16), child: view),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'idle is lazy and exposes a labeled keyboard accessible read action',
    (tester) async {
      var loads = 0;
      await showTranscript(
        tester,
        FinalTranscriptReadView(onLoad: () => loads++),
      );
      expect(loads, 0);
      expect(find.text('已保存文字'), findsOneWidget);
      expect(find.textContaining('来自客户端提交的最终文字'), findsOneWidget);
      expect(find.textContaining('AI 内容为生成文本，不能确认已播放'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(loads, 1);
    },
  );

  testWidgets(
    'AI content is marked unknown and internal identifiers stay hidden',
    (tester) async {
      final history = transcriptViewHistory([
        transcriptViewEvent(1, text: 'I like coffee.'),
        transcriptViewEvent(
          2,
          text: 'What do you enjoy about it?',
          assistant: true,
        ),
      ]);
      await showTranscript(tester, FinalTranscriptReadView(history: history));
      expect(find.text('你'), findsOneWidget);
      expect(find.text('AI 生成内容'), findsOneWidget);
      expect(find.text('播放情况未知'), findsOneWidget);
      expect(find.text('I like coffee.'), findsOneWidget);
      expect(find.text('What do you enjoy about it?'), findsOneWidget);
      expect(find.textContaining(accountId), findsNothing);
      expect(find.textContaining(connectionId), findsNothing);
      expect(find.textContaining('epoch'), findsNothing);
      expect(find.textContaining('sequence'), findsNothing);
      expect(find.text('刷新文字'), findsOneWidget);
      expect(find.text('查看更多文字'), findsNothing);
    },
  );

  testWidgets(
    'latest empty revision stays empty and observed gaps are qualified',
    (tester) async {
      final history = transcriptViewHistory([
        transcriptViewEvent(1, text: 'Old wording must disappear.'),
        transcriptViewEvent(4, turn: 1, revision: 3, text: ''),
        transcriptViewEvent(5, turn: 3, text: 'Another final turn.'),
      ]);
      await showTranscript(tester, FinalTranscriptReadView(history: history));
      expect(find.text('Old wording must disappear.'), findsNothing);
      expect(find.text('此段没有可用文字'), findsOneWidget);
      expect(find.textContaining('存在间隔，无法确认文字完整性'), findsOneWidget);
      expect(find.text('已读取 3 次提交，本次查询共 3 次；当前 2 段文字。'), findsOneWidget);
    },
  );

  testWidgets('empty saved result offers refresh without inventing turns', (
    tester,
  ) async {
    var refreshes = 0;
    await showTranscript(
      tester,
      FinalTranscriptReadView(
        history: transcriptViewHistory([]),
        onRefresh: () => refreshes++,
      ),
    );
    expect(find.text('尚无已保存的最终文字。'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    await tester.tap(find.text('刷新文字'));
    expect(refreshes, 1);
  });

  for (final code in ['account_changed', 'unauthorized']) {
    testWidgets('$code withholds previously read text and further reads', (
      tester,
    ) async {
      await showTranscript(
        tester,
        FinalTranscriptReadView(
          history: transcriptViewHistory([
            transcriptViewEvent(1, text: 'Private earlier account text.'),
          ]),
          errorCode: code,
          onLoad: () => fail('identity failure cannot read'),
          onRefresh: () => fail('identity failure cannot refresh'),
        ),
      );
      expect(find.text('Private earlier account text.'), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.textContaining('重新确认账号'), findsOneWidget);
      expect(find.text(code), findsNothing);
    });
  }

  testWidgets(
    'partial failure keeps current text with explicit retry and refresh',
    (tester) async {
      var loads = 0;
      var refreshes = 0;
      final history = transcriptViewHistory(
        [transcriptViewEvent(1, text: 'Already read.')],
        more: true,
        total: 2,
        last: 2,
        bytes: 14,
      );
      await showTranscript(
        tester,
        FinalTranscriptReadView(
          history: history,
          errorCode: 'invalid_response',
          onLoad: () => loads++,
          onRefresh: () => refreshes++,
        ),
      );
      expect(find.text('Already read.'), findsOneWidget);
      expect(find.text('尚有文字未读取，当前内容可能继续更新。'), findsOneWidget);
      expect(find.textContaining('文字响应异常'), findsOneWidget);
      expect(find.text('invalid_response'), findsNothing);
      await tester.ensureVisible(find.text('重试读取文字'));
      await tester.tap(find.text('重试读取文字'));
      expect(loads, 1);
      await tester.ensureVisible(find.text('刷新文字'));
      await tester.tap(find.text('刷新文字'));
      expect(refreshes, 1);
    },
  );

  testWidgets('busy reading announces status and disables read and refresh', (
    tester,
  ) async {
    await showTranscript(
      tester,
      FinalTranscriptReadView(
        history: transcriptViewHistory(
          [transcriptViewEvent(1)],
          more: true,
          total: 2,
          last: 2,
          bytes: 2,
        ),
        busy: true,
        onLoad: () => fail('busy read'),
        onRefresh: () => fail('busy refresh'),
      ),
    );
    expect(find.text('正在读取文字…'), findsOneWidget);
    final liveStatus = find.ancestor(
      of: find.text('正在读取文字…'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.liveRegion == true,
      ),
    );
    expect(liveStatus, findsWidgets);
    for (final button in tester.widgetList<OutlinedButton>(
      find.byType(OutlinedButton),
    )) {
      expect(button.onPressed, isNull);
    }
  });

  testWidgets(
    'local touch and keyboard scrolling preserve outer page scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final outer = ScrollController();
      addTearDown(outer.dispose);
      final history = transcriptViewHistory([
        for (var i = 1; i <= 32; i++)
          transcriptViewEvent(
            i,
            text: 'Turn $i. ${'A long saved paragraph. ' * 30}',
          ),
      ]);
      await showTranscript(
        tester,
        FinalTranscriptReadView(history: history, onRefresh: () {}),
        outerController: outer,
        scale: 2,
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.primary, isFalse);
      expect(list.controller, isNotNull);
      expect(list.shrinkWrap, isFalse);
      expect(
        tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
        isTrue,
      );
      await tester.ensureVisible(find.byType(ListView));
      final outerOffset = outer.offset;
      await tester.drag(find.byType(ListView), const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(list.controller!.offset, greaterThan(0));
      expect(outer.offset, outerOffset);
      await tester.tap(find.byType(ListView));
      final beforeKey = list.controller!.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(list.controller!.offset, greaterThan(beforeKey));
      await tester.ensureVisible(find.text('已保存文字'));
      final beforeOuterDrag = outer.offset;
      expect(
        outer.position.maxScrollExtent,
        greaterThan(0),
        reason:
            'outer viewport ${outer.position.viewportDimension}; list ${tester.getSize(find.byType(ListView))}',
      );
      await tester.drag(find.text('已保存文字'), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(outer.offset, greaterThan(beforeOuterDrag));
      await tester.ensureVisible(find.text('刷新文字'));
      final refreshFocus = Focus.of(tester.element(find.text('刷新文字')));
      for (var i = 0; i < 8 && !refreshFocus.hasFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(refreshFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 568),
      const Size(844, 390),
      const Size(1024, 768),
    ]) {
      testWidgets('full long text fits $size $brightness at 200 percent', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final longText =
            '${'完整文字 LongEnglishTokenWithoutBreak ' * 120}END-OF-ORIGINAL';
        var refreshes = 0;
        await showTranscript(
          tester,
          FinalTranscriptReadView(
            history: transcriptViewHistory([
              transcriptViewEvent(1, text: longText),
            ]),
            onRefresh: () => refreshes++,
          ),
          brightness: brightness,
          scale: 2,
        );
        expect(tester.takeException(), isNull);
        final original = tester.widget<Text>(find.text(longText));
        expect(original.maxLines, isNull);
        expect(original.overflow, isNot(TextOverflow.ellipsis));
        final list = tester.widget<ListView>(find.byType(ListView));
        await tester.ensureVisible(find.byType(ListView));
        list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text(longText),
            matching: find.byType(RichText),
          ),
        );
        final endBox = paragraph
            .getBoxesForSelection(
              TextSelection(
                baseOffset: longText.length - 15,
                extentOffset: longText.length,
              ),
            )
            .last;
        final endBottom = paragraph
            .localToGlobal(Offset(endBox.left, endBox.bottom))
            .dy;
        final viewport = tester.getRect(find.byType(ListView));
        expect(endBottom, lessThanOrEqualTo(viewport.bottom + 1));
        expect(endBottom, greaterThan(viewport.top));
        await tester.ensureVisible(find.text('刷新文字'));
        final action = find.widgetWithText(OutlinedButton, '刷新文字');
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        await tester.tap(action);
        expect(refreshes, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
