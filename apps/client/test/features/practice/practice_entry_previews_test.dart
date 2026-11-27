import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/practice/practice_entry_previews.dart';

void main() {
  for (final (preview, label) in [
    (practiceHomeLightPreview, '当前难度：轻松起步'),
    (practiceHomeDarkPreview, '当前难度：轻松起步'),
    (practicePreparationIdlePreview, '本次难度：轻松起步'),
    (practicePreparationUnavailablePreview, '本次难度：轻松起步'),
    (practiceTopicPreview, '描述一个想去的地方'),
  ]) {
    testWidgets('isolated entry preview $preview renders without services', (
      t,
    ) async {
      await t.pumpWidget(preview());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.textContaining(label), findsOneWidget);
    });
  }
}
