import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_controller.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_models.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_view.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_preview_fixtures.dart';

import 'transcript_fixtures.dart';

void main() {
  testWidgets(
    'role text is selectable; old reported prefix is distinct from generated suffix',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: SavedTranscriptView(
            state: SavedTranscriptState.ready,
            page: exampleSavedTranscript(),
            hasFocus: true,
            onBack: () {},
            onRefresh: () {},
            onFocus: () {},
          ),
        ),
      );
      expect(find.text('建议对应原话'), findsOneWidget);
      expect(find.text('An older reply'), findsOneWidget);
      expect(find.textContaining('此前版本'), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(
        find.text(
          'That sounds like a lovely afternoon. What did you enjoy most?',
        ),
        findsNothing,
      );
      await tester.ensureVisible(find.text('查看已保存生成文字（不代表已播放）').first);
      await tester.tap(find.text('查看已保存生成文字（不代表已播放）').first);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That sounds like a lovely afternoon. What did you enjoy most?',
        ),
        findsOneWidget,
      );
      final liveRegion = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.liveRegion == true,
      );
      for (final body in [
        find.text(
          'Yesterday I go to the park. I enjoyed a quiet walk with my friend.',
        ),
        find.text(
          'That sounds like a lovely afternoon. What did you enjoy most?',
        ),
      ]) {
        expect(find.ancestor(of: body, matching: liveRegion), findsNothing);
      }
      expect(find.text('这段没有可用文字'), findsOneWidget);
      expect(find.textContaining('这段没有有效播放证据'), findsOneWidget);
      expect(find.textContaining('这段播放证据已撤销'), findsOneWidget);
    },
  );
  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 568),
      const Size(375, 667),
      const Size(844, 390),
      const Size(1200, 800),
    ]) {
      testWidgets(
        'responsive reading $brightness $size at 200% reduced motion',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: SavedTranscriptView(
                  state: SavedTranscriptState.ready,
                  page: exampleSavedTranscript(),
                  hasFocus: true,
                  onBack: () {},
                  onRefresh: () {},
                  onFocus: () {},
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          final semantics = tester.ensureSemantics();

          expect(
            tester
                .getSemantics(find.text('已保存文字'))
                .getSemanticsData()
                .flagsCollection
                .isHeader,
            isTrue,
          );
          for (final label in ['返回复盘', '刷新已保存文字', '上一页', '下一页', '回到原话']) {
            await tester.ensureVisible(
              find.widgetWithText(OutlinedButton, label),
            );
            expect(
              tester.getSize(find.widgetWithText(OutlinedButton, label)).height,
              greaterThanOrEqualTo(48),
            );
          }
          await tester.ensureVisible(find.text('连接段 2'));
          expect(tester.takeException(), isNull);
          final live = find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.liveRegion == true &&
                w.properties.header == true,
          );
          expect(live, findsOneWidget);
          semantics.dispose();
        },
      );
    }
  }
  testWidgets(
    'paging failure retains prior range and all cursor actions; empty and identity clear',
    (tester) async {
      var next = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: SavedTranscriptView(
            state: SavedTranscriptState.failed,
            page: page(total: 23),
            errorCode: 'network_error',
            onNext: () => next++,
          ),
        ),
      );
      expect(find.textContaining('仍显示上一已读取页'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      expect(next, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: SavedTranscriptView(
            state: SavedTranscriptState.aborted,
            page: page(),
            errorCode: 'account_changed',
          ),
        ),
      );
      expect(find.text('I enjoy English.'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: SavedTranscriptView(
            state: SavedTranscriptState.ready,
            page: page(total: 0),
          ),
        ),
      );
      expect(find.text('本次没有已保存文字'), findsOneWidget);
    },
  );
  testWidgets('not played state has explicit text and no playback controls', (
    tester,
  ) async {
    final j = pageJson();
    j['items'][0] = turnJson(1, role: 'assistant')
      ..['playback_status'] = 'not_played';
    final p = SavedTranscriptPage.fromJson(j, target: target());
    await tester.pumpWidget(
      MaterialApp(
        home: SavedTranscriptView(state: SavedTranscriptState.ready, page: p),
      ),
    );
    expect(find.text('客户端报告这段没有播放。'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'focused refresh remains visible while dynamic page is withdrawn and replaced $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var reading = false;
        late StateSetter change;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: StatefulBuilder(
              builder: (context, set) {
                change = set;
                return MediaQuery(
                  data: MediaQueryData(
                    size: const Size(320, 568),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: SavedTranscriptView(
                    state: reading
                        ? SavedTranscriptState.reading
                        : SavedTranscriptState.ready,
                    page: reading ? null : page(total: 23),
                    busy: reading,
                    hasFocus: true,
                    onBack: () {},
                    onRefresh: () {},
                    onFocus: () {},
                  ),
                );
              },
            ),
          ),
        );
        final refresh = find.widgetWithText(OutlinedButton, '刷新已保存文字');
        await tester.ensureVisible(refresh);
        await tester.tap(refresh);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        change(() => reading = true);
        await tester.pump();
        change(() => reading = false);
        await tester.pump();
        expect(
          tester.getRect(refresh).overlaps(Offset.zero & const Size(320, 568)),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
