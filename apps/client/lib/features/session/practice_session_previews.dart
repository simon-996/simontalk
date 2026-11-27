import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_completion_models.dart';
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
  bool interruptionNeedsEnd = false,
  String? errorCode,
  bool completionPending = false,
  bool subtitles = true,
  String? openingHint,
  Widget? assistancePanel,
  SessionSpeechPace speechPace = SessionSpeechPace.normal,
  bool showSlowPaceStatus = false,
  VoidCallback? onRequestSlowPace,
  bool showTakeOverAction = false,
  VoidCallback? onTakeOverTurn,
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
    interruptionNeedsEnd: interruptionNeedsEnd,
    errorCode: errorCode,
    turns: openingHint == null ? _turns : const [],
    subtitlesVisible: subtitles,
    chineseOpeningHint: openingHint,
    assistancePanel: assistancePanel,
    speechPace: speechPace,
    showSlowPaceStatus: showSlowPaceStatus,
    onRequestSlowPace: onRequestSlowPace,
    showTakeOverAction: showTakeOverAction,
    onTakeOverTurn: onTakeOverTurn,
    completionPending: completionPending,
    onToggleMute: practiceSessionPreviewNoop,
    onResumePlayback: practiceSessionPreviewNoop,
    onEnd: practiceSessionPreviewNoop,
    onLeave: practiceSessionPreviewNoop,
    onToggleSubtitles: practiceSessionPreviewNoop,
    onToggleChineseHints: practiceSessionPreviewNoop,
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
  name: '通话 · 英文开头 · 窄屏大字',
  group: '通话中',
  size: Size(320, 640),
  wrapper: previewWithFonts,
)
Widget practiceSessionStarterPreview() => _example(
  brightness: Brightness.dark,
  scale: 2,
  subtitles: false,
  assistancePanel: const AssistanceResultPanel(
    heading: '英文开头',
    result: 'One thing I enjoyed this weekend was…',
    onClose: practiceSessionPreviewNoop,
  ),
);

@Preview(
  name: '通话 · 中文开口提示 · 窄屏大字',
  group: '通话中',
  size: Size(320, 640),
  wrapper: previewWithFonts,
)
Widget practiceSessionChineseHintPreview() => _example(
  brightness: Brightness.dark,
  scale: 2,
  openingHint: '分享一个周末安排',
  subtitles: false,
);

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
  speechPace: SessionSpeechPace.slow,
  showSlowPaceStatus: true,
  showTakeOverAction: true,
  onTakeOverTurn: practiceSessionPreviewNoop,
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
  name: '通话 · 麦克风输入中断',
  group: '通话中',
  size: Size(320, 720),
  wrapper: previewWithFonts,
)
Widget practiceSessionDeviceLostPreview() => _example(
  brightness: Brightness.dark,
  scale: 2,
  phase: PracticeMediaPhase.localClosed,
  errorCode: 'device_lost',
);

@Preview(
  name: '通话 · 字幕关闭',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionNoSubtitlesPreview() =>
    _example(subtitles: false, playback: MediaPlayback.playing);

@Preview(
  name: '通话 · 中断待结束 · 深色320 · 200%',
  group: '通话中',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionInterruptedPreview() => _example(
  brightness: Brightness.dark,
  scale: 2,
  playback: MediaPlayback.paused,
  interruptionNeedsEnd: true,
);

@Preview(
  name: '重练通话 · 正在听你说 · 深色320 · 200%',
  group: '通话中',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionRehearsalPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2), disableAnimations: true),
    child: child!,
  ),
  home: PracticeSessionView(
    difficulty: Difficulty.advanced,
    phase: PracticeMediaPhase.active,
    playback: MediaPlayback.idle,
    muted: false,
    rehearsalQuote: 'I enjoy English.',
    rehearsalSuggestion: 'I enjoy learning English.',
    turns: _turns,
    onToggleMute: practiceSessionPreviewNoop,
    onEnd: practiceSessionPreviewNoop,
    onToggleSubtitles: practiceSessionPreviewNoop,
  ),
);

@Preview(
  name: '重练通话 · 已封存可看评价',
  group: '通话中',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget practiceSessionRehearsalSavedPreview() {
  final scope = ConversationScope(
    accountId: '11111111-1111-4111-8111-111111111111',
    sessionId: '99999999-9999-4999-8999-999999999999',
    connectionId: '33333333-3333-4333-8333-333333333333',
    clientInstanceId: '44444444-4444-4444-8444-444444444444',
    epoch: 1,
  );
  final summary = PracticeCompletionSummary.fromJson({
    'source': 'server_recorded',
    'account_id': scope.accountId,
    'session_id': scope.sessionId,
    'origin_connection_id': scope.connectionId,
    'client_instance_id': scope.clientInstanceId,
    'epoch': scope.epoch,
    'end_key': '55555555-5555-4555-8555-555555555555',
    'status': 'sealed',
    'accepted_at': '2026-11-25T00:00:00Z',
    'final_upload_deadline': '2026-11-25T00:00:30Z',
    'sealed_at': '2026-11-25T00:00:02Z',
    'input_revision': 1,
    'input_hash': 'a' * 64,
    'coverage': 'complete',
    'connection_count': 1,
    'gap_codes': <Object>[],
  }, scope: scope);
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: PracticeSessionView(
      difficulty: Difficulty.advanced,
      phase: PracticeMediaPhase.localClosed,
      playback: MediaPlayback.idle,
      muted: false,
      rehearsalQuote: 'I enjoy English.',
      rehearsalSuggestion: 'I enjoy learning English.',
      completion: summary,
      onViewReview: practiceSessionPreviewNoop,
      onViewRecord: practiceSessionPreviewNoop,
      onBackToSourceReview: practiceSessionPreviewNoop,
      onRehearseAgain: practiceSessionPreviewNoop,
      onGoPractice: practiceSessionPreviewNoop,
      onLeave: practiceSessionPreviewNoop,
    ),
  );
}
