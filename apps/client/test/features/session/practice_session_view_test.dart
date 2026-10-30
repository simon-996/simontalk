import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/session/practice_session_view.dart';

ConversationTurn turn({
  required ConversationRole role,
  required String text,
  int index = 1,
}) => ConversationTurn(
  turnId: 'turn-$index',
  turnIndex: index,
  role: role,
  revision: 1,
  text: text,
  isFinal: true,
  responseId: role == ConversationRole.assistant ? 'response-$index' : null,
  providerItemId: null,
  playback: const ConversationPlayback.unknown(),
);

void main() {
  Future<void> pump(
    WidgetTester tester,
    PracticeSessionView view, {
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
          child: view,
        ),
      ),
    );
  }

  PracticeSessionView view({
    PracticeMediaPhase phase = PracticeMediaPhase.active,
    MediaPlayback playback = MediaPlayback.idle,
    bool muted = false,
    String? errorCode,
    List<ConversationTurn> turns = const [],
    VoidCallback? onToggleMute,
    VoidCallback? onResumePlayback,
    VoidCallback? onEnd,
    VoidCallback? onLeave,
    VoidCallback? onViewRecord,
    VoidCallback? onRetryCompletion,
    bool completionPending = false,
    String? completionErrorCode,
  }) => PracticeSessionView(
    difficulty: Difficulty.intermediate,
    phase: phase,
    playback: playback,
    muted: muted,
    errorCode: errorCode,
    turns: turns,
    completionPending: completionPending,
    completionErrorCode: completionErrorCode,
    onToggleMute: onToggleMute,
    onResumePlayback: onResumePlayback,
    onEnd: onEnd,
    onLeave: onLeave,
    onViewRecord: onViewRecord,
    onRetryCompletion: onRetryCompletion,
  );

  testWidgets('an active call shows listening only when it is really active', (
    tester,
  ) async {
    await pump(tester, view(phase: PracticeMediaPhase.configuring));
    expect(find.text('正在听你说'), findsNothing);
    expect(find.text('正在确认语音配置，尚未开始收音…'), findsOneWidget);

    await pump(tester, view());
    expect(find.text('正在听你说'), findsOneWidget);
    expect(find.text('本次难度：${Difficulty.intermediate.label}'), findsOneWidget);
  });

  testWidgets('speaking and muted are different states', (tester) async {
    await pump(tester, view(playback: MediaPlayback.playing));
    expect(find.text('正在说'), findsOneWidget);

    await pump(tester, view(muted: true));
    expect(find.text('麦克风已关闭'), findsOneWidget);
    expect(find.text('正在听你说'), findsNothing);
    expect(find.text('打开麦克风'), findsOneWidget);
  });

  testWidgets('blocked playback offers an explicit resume action', (
    tester,
  ) async {
    var resumed = 0;
    await pump(
      tester,
      view(playback: MediaPlayback.blocked, onResumePlayback: () => resumed++),
    );
    expect(find.text('需要点击继续播放'), findsOneWidget);
    await tester.tap(find.text('继续播放'));
    expect(resumed, 1);
  });

  testWidgets('mute and end are explicit actions during an active call', (
    tester,
  ) async {
    var toggles = 0;
    var ends = 0;
    await pump(
      tester,
      view(onToggleMute: () => toggles++, onEnd: () => ends++),
    );
    await tester.tap(find.text('静音麦克风'));
    await tester.tap(find.text('结束并复盘'));
    expect(toggles, 1);
    expect(ends, 1);
  });

  testWidgets('draining keeps the page on screen with media controls off', (
    tester,
  ) async {
    var ends = 0;
    await pump(
      tester,
      view(phase: PracticeMediaPhase.draining, onEnd: () => ends++),
    );
    expect(find.text('正在收尾，等待最后一句识别…'), findsOneWidget);
    expect(find.text('静音麦克风'), findsNothing);
    expect(find.text('结束并复盘'), findsNothing);
    expect(ends, 0);
  });

  testWidgets(
    'a stopped attempt states the real reason and keeps no controls',
    (tester) async {
      await pump(
        tester,
        view(
          phase: PracticeMediaPhase.localClosed,
          errorCode: 'realtime_unavailable',
          onLeave: () {},
        ),
      );
      expect(find.text('本次练习已结束'), findsOneWidget);
      expect(find.text('静音麦克风'), findsNothing);
      expect(find.text('结束并复盘'), findsNothing);
      expect(find.text('已停止收音，等待保存回执'), findsOneWidget);
    },
  );

  testWidgets('a closed call reports saving, not a finished upstream call', (
    tester,
  ) async {
    await pump(tester, view(phase: PracticeMediaPhase.localClosed));
    expect(find.text('本次记录已保存'), findsNothing);
    expect(find.text('已停止收音，等待保存回执'), findsOneWidget);

    await pump(
      tester,
      view(phase: PracticeMediaPhase.localClosed, completionPending: true),
    );
    expect(find.text('正在保存本次记录…'), findsOneWidget);
    expect(find.text('重试保存'), findsOneWidget);
  });

  testWidgets('failed completion exposes retry without duplicating practice', (
    tester,
  ) async {
    var retries = 0;
    await pump(
      tester,
      view(
        phase: PracticeMediaPhase.localClosed,
        completionErrorCode: 'network_error',
        onRetryCompletion: () => retries++,
      ),
    );
    expect(find.text('结束保存暂时失败'), findsOneWidget);
    await tester.tap(find.text('重试保存'));
    expect(retries, 1);
  });

  testWidgets('transcript keeps both speakers in order on a narrow screen', (
    tester,
  ) async {
    await pump(
      tester,
      view(
        turns: [
          turn(
            role: ConversationRole.user,
            text: 'I went to the park.',
            index: 1,
          ),
          turn(
            role: ConversationRole.assistant,
            text: 'Nice, was it busy?',
            index: 2,
          ),
        ],
      ),
      width: 320,
      scale: 1.25,
    );
    expect(find.text('I went to the park.'), findsOneWidget);
    expect(find.text('Nice, was it busy?'), findsOneWidget);
  });

  testWidgets('dark theme keeps the same real labels', (tester) async {
    await pump(tester, view(muted: true), brightness: Brightness.dark);
    expect(find.text('麦克风已关闭'), findsOneWidget);
    expect(find.text('打开麦克风'), findsOneWidget);
  });
}
