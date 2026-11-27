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
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: Size(width, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: view,
          ),
        ),
      ),
    );
  }

  PracticeSessionView view({
    PracticeMediaPhase phase = PracticeMediaPhase.active,
    MediaPlayback playback = MediaPlayback.idle,
    bool muted = false,
    bool interruptionNeedsEnd = false,
    String? errorCode,
    List<ConversationTurn> turns = const [],
    VoidCallback? onToggleMute,
    VoidCallback? onResumePlayback,
    VoidCallback? onEnd,
    VoidCallback? onLeave,
    VoidCallback? onViewRecord,
    VoidCallback? onRetryCompletion,
    VoidCallback? onCancelAttempt,
    VoidCallback? onToggleSubtitles,
    bool subtitlesVisible = true,
    bool completionPending = false,
    String? completionErrorCode,
  }) => PracticeSessionView(
    difficulty: Difficulty.intermediate,
    phase: phase,
    playback: playback,
    muted: muted,
    interruptionNeedsEnd: interruptionNeedsEnd,
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
    onCancelAttempt: onCancelAttempt,
    onToggleSubtitles: onToggleSubtitles,
    subtitlesVisible: subtitlesVisible,
  );

  testWidgets('an active call shows listening only when it is really active', (
    tester,
  ) async {
    await pump(
      tester,
      view(phase: PracticeMediaPhase.configuring, onCancelAttempt: () {}),
    );
    expect(find.text('正在听你说'), findsNothing);
    expect(find.text('正在确认语音配置，尚未开始收音…'), findsOneWidget);
    expect(find.text('连接确认前不会采集或播放音频。'), findsOneWidget);
    expect(find.text('取消这次尝试'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('正在收尾：麦克风与播报已停止，请稍候。'), findsNothing);

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

  testWidgets(
    'interrupted narrow view explains microphone and suppresses resume',
    (tester) async {
      await pump(
        tester,
        view(
          interruptionNeedsEnd: true,
          playback: MediaPlayback.blocked,
          onResumePlayback: () {},
          onToggleMute: () {},
          onEnd: () {},
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('对话已中断，暂时无法继续'), findsOneWidget);
      expect(find.text('说完这句后，请结束并复盘。麦克风仍开启。'), findsOneWidget);
      expect(find.text('继续播放'), findsNothing);
      expect(find.text('结束并复盘'), findsOneWidget);
      expect(find.text('可以直接开口，也可以自然插话。'), findsNothing);
      expect(
        tester.getTopLeft(find.text('结束并复盘')).dy,
        greaterThan(tester.getBottomLeft(find.text('静音麦克风')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'interrupted state disappears after draining and ordinary pause remains distinct',
    (tester) async {
      await pump(tester, view(playback: MediaPlayback.paused));
      expect(find.text('已暂停播放'), findsOneWidget);
      expect(find.text('对话已中断，暂时无法继续'), findsNothing);
      await pump(
        tester,
        view(phase: PracticeMediaPhase.draining, interruptionNeedsEnd: true),
      );
      expect(find.text('正在收尾，等待最后一句识别…'), findsOneWidget);
      expect(find.text('对话已中断，暂时无法继续'), findsNothing);
    },
  );

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
      expect(find.text('实时语音尚未就绪，本次无法开始交流。'), findsOneWidget);
      expect(find.text('已停止收音，等待保存回执'), findsNothing);
    },
  );

  testWidgets(
    'a device interruption gives the reason and keeps record access',
    (tester) async {
      var views = 0;
      await pump(
        tester,
        view(
          phase: PracticeMediaPhase.localClosed,
          errorCode: 'device_lost',
          onViewRecord: () => views++,
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('麦克风输入已中断，本次练习已停止。'), findsOneWidget);
      expect(find.text('已停止收音，等待保存回执'), findsNothing);
      await tester.tap(find.text('查看本次记录'));
      expect(views, 1);
    },
  );

  testWidgets('a closed call reports saving, not a finished upstream call', (
    tester,
  ) async {
    await pump(tester, view(phase: PracticeMediaPhase.localClosed));
    expect(find.text('本次记录已保存'), findsNothing);
    expect(find.text('本机语音已停止'), findsOneWidget);

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

  testWidgets(
    'subtitles follow the preference and toggle without page reload',
    (tester) async {
      var toggles = 0;
      await pump(
        tester,
        view(
          turns: [
            turn(
              role: ConversationRole.assistant,
              text: 'Nice, was it busy?',
              index: 2,
            ),
          ],
          onToggleSubtitles: () => toggles++,
        ),
      );
      expect(find.text('Nice, was it busy?'), findsOneWidget);
      expect(find.text('字幕：开'), findsOneWidget);
      expect(find.text('字幕已关闭，可随时在右上角打开。'), findsNothing);
      await tester.tap(find.text('字幕：开'));
      expect(toggles, 1);

      await pump(
        tester,
        view(
          turns: [
            turn(
              role: ConversationRole.assistant,
              text: 'Nice, was it busy?',
              index: 2,
            ),
          ],
          subtitlesVisible: false,
          onToggleSubtitles: () {},
        ),
      );
      expect(find.text('Nice, was it busy?'), findsNothing);
      expect(find.text('字幕已关闭，可随时在右上角打开。'), findsOneWidget);
      expect(find.text('字幕：关'), findsOneWidget);
      // Hiding text never hides the call controls.
      expect(find.text('结束并复盘'), findsOneWidget);
      expect(find.text('静音麦克风'), findsOneWidget);
    },
  );

  testWidgets('dark theme keeps the same real labels', (tester) async {
    await pump(tester, view(muted: true), brightness: Brightness.dark);
    expect(find.text('麦克风已关闭'), findsOneWidget);
    expect(find.text('打开麦克风'), findsOneWidget);
  });

  testWidgets('topic call shows both controls at 320px and 200%', (
    tester,
  ) async {
    await pump(
      tester,
      PracticeSessionView(
        difficulty: Difficulty.beginner,
        phase: PracticeMediaPhase.active,
        playback: MediaPlayback.idle,
        muted: false,
        topicTitle: '周末计划',
        chineseOpeningHint: '分享一个周末安排',
        subtitlesVisible: false,
        onToggleMute: () {},
        onEnd: () {},
        onToggleSubtitles: () {},
        onToggleChineseHints: () {},
      ),
      width: 320,
      scale: 2,
      brightness: Brightness.dark,
    );
    expect(find.text('周末计划'), findsOneWidget);
    expect(find.text('分享一个周末安排'), findsOneWidget);
    expect(find.byTooltip('关闭中文提示').hitTestable(), findsOneWidget);
    expect(find.byTooltip('开启英文字幕').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rehearsal call renders target banner on 320px dark 200% and post-call actions',
    (tester) async {
      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.advanced,
          phase: PracticeMediaPhase.active,
          playback: MediaPlayback.idle,
          muted: false,
          rehearsalQuote: 'I enjoy English.',
          rehearsalSuggestion: 'I enjoy learning English.',
          onToggleMute: () {},
          onEnd: () {},
          onToggleSubtitles: () {},
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('重练：这一句表达'), findsOneWidget);
      expect(find.text('重练片段：I enjoy English.'), findsOneWidget);
      expect(find.text('参考说法：I enjoy learning English.'), findsOneWidget);
      expect(find.text('本次难度：${Difficulty.advanced.label}'), findsOneWidget);
      expect(tester.takeException(), isNull);

      var reviews = 0, records = 0, sourceReviews = 0, again = 0, home = 0;
      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.advanced,
          phase: PracticeMediaPhase.localClosed,
          playback: MediaPlayback.idle,
          muted: false,
          rehearsalQuote: 'I enjoy English.',
          rehearsalSuggestion: 'I enjoy learning English.',
          onViewReview: () => reviews++,
          onViewRecord: () => records++,
          onBackToSourceReview: () => sourceReviews++,
          onRehearseAgain: () => again++,
          onGoPractice: () => home++,
        ),
      );
      expect(find.text('重练片段：I enjoy English.'), findsNothing);
      await tester.tap(find.text('查看重练评价'));
      await tester.tap(find.text('查看本次记录'));
      await tester.tap(find.text('回原复盘'));
      await tester.tap(find.text('再练一次'));
      await tester.tap(find.text('回到练习'));
      expect([reviews, records, sourceReviews, again, home], [1, 1, 1, 1, 1]);
    },
  );

  testWidgets(
    'in-call slow pace renders button, pending, and confirmed states without overflow at 320px 200%',
    (tester) async {
      var slowRequests = 0;
      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.intermediate,
          phase: PracticeMediaPhase.active,
          playback: MediaPlayback.playing,
          muted: false,
          showSlowPaceStatus: true,
          onRequestSlowPace: () => slowRequests++,
          onAskForStarter: () {},
          onChooseTranslation: () {},
          onToggleMute: () {},
          onEnd: () {},
          onToggleSubtitles: () {},
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('说慢一点'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('说慢一点'));
      expect(slowRequests, 1);

      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.intermediate,
          phase: PracticeMediaPhase.active,
          playback: MediaPlayback.playing,
          muted: false,
          speechPace: SessionSpeechPace.slowing,
          showSlowPaceStatus: true,
          onAskForStarter: () {},
          onChooseTranslation: () {},
          onToggleMute: () {},
          onEnd: () {},
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('正在放慢语速…'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.intermediate,
          phase: PracticeMediaPhase.active,
          playback: MediaPlayback.idle,
          muted: false,
          speechPace: SessionSpeechPace.slow,
          showSlowPaceStatus: true,
          onAskForStarter: () {},
          onChooseTranslation: () {},
          onToggleMute: () {},
          onEnd: () {},
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('本场已放慢语速'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'turn phases render listening-in-progress, thinking, and explicit takeover with mute guard',
    (tester) async {
      await pump(
        tester,
        view(
          turns: [
            ConversationTurn(
              turnId: 'turn-1',
              turnIndex: 1,
              role: ConversationRole.user,
              revision: 1,
              text: 'I am thinking...',
              isFinal: false,
              responseId: null,
              providerItemId: null,
              playback: const ConversationPlayback.unknown(),
            ),
          ],
        ),
      );
      expect(find.text('在听，请继续'), findsOneWidget);

      await pump(tester, view(playback: MediaPlayback.waiting));
      expect(find.text('正在想怎么回应'), findsOneWidget);

      var takeovers = 0;
      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.intermediate,
          phase: PracticeMediaPhase.active,
          playback: MediaPlayback.playing,
          muted: true,
          showTakeOverAction: true,
          onTakeOverTurn: () => takeovers++,
          onToggleMute: () {},
          onEnd: () {},
        ),
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(find.text('正在说'), findsOneWidget);
      expect(find.text('我来说（先开启麦克风）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我来说（先开启麦克风）'));
      expect(takeovers, 0);

      await pump(
        tester,
        PracticeSessionView(
          difficulty: Difficulty.intermediate,
          phase: PracticeMediaPhase.active,
          playback: MediaPlayback.playing,
          muted: false,
          showTakeOverAction: true,
          onTakeOverTurn: () => takeovers++,
          onToggleMute: () {},
          onEnd: () {},
        ),
      );
      await tester.tap(find.text('我来说'));
      expect(takeovers, 1);
    },
  );
}
