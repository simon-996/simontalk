import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/review/review_page_previews.dart';

void main() {
  for (final entry in {
    'light': reviewLightExamplePreview,
    'dark 200%': reviewDarkLargeTextPreview,
    'blocked': reviewBlockedExamplePreview,
    'empty': reviewEmptyExamplePreview,
    'evaluation': rehearsalEvaluationExamplePreview,
    'independent axes': rehearsalEvaluationChangedPreview,
    'insufficient and not demonstrated': rehearsalEvaluationInsufficientPreview,
    'evaluation dark 320 200%': rehearsalEvaluationDarkLargeTextPreview,
  }.entries) {
    testWidgets('isolated ${entry.key} preview runs with no providers or API', (
      tester,
    ) async {
      await tester.pumpWidget(entry.value());
      expect(find.text('练习复盘'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'evaluation preview refresh is local and clears then restores result',
    (t) async {
      await t.pumpWidget(rehearsalEvaluationExamplePreview());
      expect(find.text('本次重练评价'), findsOneWidget);
      await t.ensureVisible(find.text('刷新复盘状态'));
      await t.tap(find.text('刷新复盘状态'));
      await t.pump();
      expect(find.text('本次重练评价'), findsNothing);
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('本次重练评价'), findsOneWidget);
      await t.ensureVisible(find.text('查看已保存文字'));
      await t.tap(find.text('查看已保存文字'));
      await t.pumpAndSettle();
      expect(find.text('预览示例 · 已保存文字'), findsOneWidget);
      expect(find.text('Yesterday I went to the park.'), findsNWidgets(3));
    },
  );
}
