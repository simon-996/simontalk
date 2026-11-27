import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../account/account_models.dart';
import 'daily_topic.dart';
import 'practice_entry_view.dart';
import 'practice_preparation_controller.dart';
import 'practice_recovery_panel.dart';

void practiceEntryPreviewNoop() {}
void _topicPreviewNoop(DailyTopic topic) {}
Widget _example({
  bool home = true,
  Brightness brightness = Brightness.light,
  double scale = 1,
  PreparationPhase phase = PreparationPhase.idle,
  DailyTopic? topic,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: home
      ? PracticeHomeView(
          difficulty: Difficulty.beginner,
          onStart: practiceEntryPreviewNoop,
          onTopicSelected: _topicPreviewNoop,
          onSettings: practiceEntryPreviewNoop,
          recovery: PracticeRecoveryView(onRefresh: practiceEntryPreviewNoop),
        )
      : PracticePreparationView(
          difficulty: Difficulty.beginner,
          topic: topic,
          phase: phase,
          errorCode: phase == PreparationPhase.blocked
              ? 'realtime_unavailable'
              : null,
          onStart: practiceEntryPreviewNoop,
          onBack: practiceEntryPreviewNoop,
          recovery: const PracticeRecoveryView(),
        ),
);

@Preview(
  name: '首页 · 浅色',
  group: '普通练习入口',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceHomeLightPreview() => _example();
@Preview(
  name: '首页 · 深色320 · 200%',
  group: '普通练习入口',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget practiceHomeDarkPreview() =>
    _example(brightness: Brightness.dark, scale: 2);
@Preview(
  name: '准备 · 未开始',
  group: '普通练习入口',
  size: Size(375, 850),
  wrapper: previewWithFonts,
)
Widget practicePreparationIdlePreview() => _example(home: false);
@Preview(
  name: '话题准备 · 旅行',
  group: '普通练习入口',
  size: Size(375, 700),
  wrapper: previewWithFonts,
)
Widget practiceTopicPreview() =>
    _example(home: false, topic: DailyTopic.travel);
@Preview(
  name: '准备 · 服务未就绪',
  group: '普通练习入口',
  size: Size(375, 700),
  wrapper: previewWithFonts,
)
Widget practicePreparationUnavailablePreview() =>
    _example(home: false, phase: PreparationPhase.blocked);
