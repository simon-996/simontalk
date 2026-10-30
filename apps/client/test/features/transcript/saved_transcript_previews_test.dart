import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_previews.dart';

void main() {
  for (final preview in [
    savedTranscriptLightPreview,
    savedTranscriptDarkLargePreview,
    savedTranscriptEmptyPreview,
    savedTranscriptErrorPreview,
  ]) {
    testWidgets(
      'isolated saved transcript preview $preview has no account or API',
      (tester) async {
        await tester.pumpWidget(preview());
        await tester.pumpAndSettle();
        expect(find.text('已保存文字'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
