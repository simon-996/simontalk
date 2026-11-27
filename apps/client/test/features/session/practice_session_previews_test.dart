import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/session/practice_session_previews.dart';

void main() {
  for (final (preview, label) in [
    (practiceSessionListeningPreview, '正在听你说'),
    (practiceSessionStarterPreview, '英文开头'),
    (practiceSessionChineseHintPreview, '分享一个周末安排'),
    (practiceSessionSpeakingPreview, '正在说'),
    (practiceSessionMutedPreview, '麦克风已关闭'),
    (practiceSessionSavingPreview, '正在保存本次记录…'),
    (practiceSessionUnavailablePreview, '本次练习已结束'),
    (practiceSessionDeviceLostPreview, '麦克风输入已中断，本次练习已停止。'),
    (practiceSessionNoSubtitlesPreview, '字幕已关闭，可随时在右上角打开。'),
    (practiceSessionInterruptedPreview, '对话已中断，暂时无法继续'),
    (practiceSessionRehearsalPreview, '重练：这一句表达'),
    (practiceSessionRehearsalSavedPreview, '查看重练评价'),
  ]) {
    testWidgets('isolated call preview $preview renders without services', (
      t,
    ) async {
      await t.pumpWidget(preview());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text(label), findsOneWidget);
    });
  }
}
