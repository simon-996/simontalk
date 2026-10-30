import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../realtime/practice_media_controller.dart';
import 'practice_session_view.dart';

void practiceSessionPreviewNoop() {}

ConversationTurn _turn({
  required ConversationRole role,
  required String text,
  required int index,
}) => ConversationTurn(
  turnId: 'preview-turn-$index',
  turnIndex: index,
  role: role,
  revision: 1,
  text: text,
  isFinal: true,
  responseId: role == ConversationRole.assistant
      ? 'preview-response-$index'
      : null,
  providerItemId: null,
  playback: const ConversationPlayback.unknown(),
);

List<ConversationTurn> get _turns => [
  _turn(
    role: ConversationRole.user,
    text: 'I tried a new noodle place near the office.',
    index: 1,
  ),
  _turn(
    role: ConversationRole.assistant,
    text: 'That sounds fun. What did you order?',
    index: 2,
  ),
];

Widget _example({
  Brightness brightness = Brightness.light,
  double scale = 1,
  PracticeMediaPhase phase = PracticeMediaPhase.active,
  MediaPlayback playback = MediaPlayback.idle,
  bool muted = false,
  String? errorCode,
  bool completionPending = false,
  bool subtitles = true,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: PracticeSessionView(
    difficulty: Difficulty.intermediate,
    phase: phase,
    playback: playback,
    muted: muted,
    errorCode: errorCode,
    turns: _turns,
    subtitlesVisible: subtitles,
    completionPending: completionPending,
    onToggleMute: practiceSessionPreviewNoop,
    onResumePlayback: practiceSessionPreviewNoop,
    onEnd: practiceSessionPreviewNoop,
    onLeave: practiceSessionPreviewNoop,
    onToggleSubtitles: practiceSessionPreviewNoop,
    onViewRecord: practiceSessionPreviewNoop,
  ),
);

@Preview(
  name: '通话 · 正在听你说',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionListeningPreview() => _example();

@Preview(
  name: '通话 · 播报中 · 深色320 · 200%',
  group: '通话中',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionSpeakingPreview() => _example(
  brightness: Brightness.dark,
  scale: 2,
  playback: MediaPlayback.playing,
);

@Preview(
  name: '通话 · 已静音',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionMutedPreview() => _example(muted: true);

@Preview(
  name: '通话 · 已结束待保存',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionSavingPreview() =>
    _example(phase: PracticeMediaPhase.localClosed, completionPending: true);

@Preview(
  name: '通话 · 语音不可用',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionUnavailablePreview() => _example(
  phase: PracticeMediaPhase.localClosed,
  errorCode: 'realtime_unavailable',
);

@Preview(
  name: '通话 · 字幕关闭',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionNoSubtitlesPreview() =>
    _example(subtitles: false, playback: MediaPlayback.playing);
