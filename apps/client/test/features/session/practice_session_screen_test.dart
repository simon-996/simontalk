import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/account/account_models.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';
import 'package:simontalk_client/features/session/practice_session_screen.dart';

import '../conversation/conversation_projection_test.dart' as facts;
import '../practice/practice_fixtures.dart';
import '../practice/practice_providers_test.dart' show ScopedAccountController;
import '../realtime/media_fixtures.dart';

AccountState _noSubtitles(String id) => AccountState(
  phase: SessionPhase.signedIn,
  session: AccountSession(
    AccountUser(id: id, username: 'test-only', displayName: 'Test'),
    const AccountPreferences(
      difficulty: Difficulty.beginner,
      speechPace: 'normal',
      subtitleDefault: false,
      chineseHintsEnabled: true,
      version: 1,
    ),
  ),
);

class NoSubtitlesAccountController extends AccountController {
  @override
  AccountState build() => _noSubtitles(accountId);
}

void main() {
  late MediaHarness harness;
  late ProviderContainer container;

  Future<void> open(
    WidgetTester tester, {
    AccountController Function()? account,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    harness = MediaHarness(tester);
    container = ProviderContainer(
      overrides: [
        accountControllerProvider.overrideWith(
          account ?? ScopedAccountController.new,
        ),
        practiceMediaProvider.overrideWith((ref) => harness.controller),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PracticeSessionScreen(),
                  ),
                ),
                child: const Text('打开通话'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开通话'));
    await tester.pumpAndSettle();
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await harness.dispose();
    await tester.pump();
  }

  testWidgets('mounting starts exactly one media attempt', (tester) async {
    await open(tester);
    expect(harness.controller.phase, PracticeMediaPhase.connecting);
    expect(harness.requests, isNotEmpty);
    // A rebuild must not start a second attempt or duplicate the practice.
    await tester.pump();
    expect(harness.signallerCreates, 1);
    expect(find.text('正在连接语音，请稍候…'), findsOneWidget);
    expect(find.text('正在听你说'), findsNothing);
    await close(tester);
  });

  testWidgets('an active call forwards mute and end to the coordinator', (
    tester,
  ) async {
    await open(tester);
    await harness.configured();
    await tester.pump();
    expect(find.text('正在听你说'), findsOneWidget);

    await tester.tap(find.text('静音麦克风'));
    await tester.pump();
    expect(harness.transport.mutes.last, isTrue);
    expect(find.text('麦克风已关闭'), findsOneWidget);
    expect(find.text('打开麦克风'), findsOneWidget);

    await tester.tap(find.text('结束并复盘'));
    await tester.pump();
    expect(harness.controller.phase, PracticeMediaPhase.draining);
    expect(harness.transport.drains, 1);
    expect(find.text('静音麦克风'), findsNothing);
    await close(tester);
  });

  testWidgets(
    'quarantined interruption explains next step and microphone state',
    (tester) async {
      await open(tester);
      await harness.configured();
      harness.protocol!.callbacks.emitConversation(
        facts.ai(finalText: false),
        'channel-0',
      );
      harness.protocol!.callbacks.quarantineUnknownResponse(
        facts.responseId,
        'channel-0',
      );
      await tester.pump();
      expect(find.text('对话已中断，暂时无法继续'), findsOneWidget);
      expect(find.text('说完这句后，请结束并复盘。麦克风仍开启。'), findsOneWidget);
      expect(find.text('已暂停播放'), findsNothing);
      expect(find.text('可以直接开口，也可以自然插话。'), findsNothing);
      expect(find.text('继续播放'), findsNothing);
      await tester.tap(find.text('静音麦克风'));
      await tester.pump();
      expect(find.text('麦克风已关闭，请结束并复盘。'), findsOneWidget);
      final microphone = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '麦克风已关闭'),
      );
      expect(microphone.onPressed, isNull);
      final muteCalls = harness.transport.mutes.length;
      harness.controller.setMuted(false);
      expect(harness.controller.muted, isTrue);
      expect(harness.transport.mutes, hasLength(muteCalls));
      await tester.tap(find.text('结束并复盘'));
      await tester.pump();
      expect(harness.controller.phase, PracticeMediaPhase.draining);
      expect(find.text('对话已中断，暂时无法继续'), findsNothing);
      expect(find.text('正在收尾，等待最后一句识别…'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'subtitles start from the stored preference and toggle in place',
    (tester) async {
      await open(tester, account: NoSubtitlesAccountController.new);
      await harness.configured();
      await tester.pump();
      expect(find.text('字幕：关'), findsOneWidget);
      expect(find.text('字幕已关闭，可随时在右上角打开。'), findsOneWidget);
      await tester.tap(find.text('字幕：关'));
      await tester.pump();
      expect(find.text('字幕：开'), findsOneWidget);
      expect(find.text('字幕已关闭，可随时在右上角打开。'), findsNothing);
      await close(tester);
    },
  );

  testWidgets('a stopped attempt keeps only the real close path', (
    tester,
  ) async {
    await open(tester);
    await harness.configured();
    await tester.pump();
    await tester.tap(find.text('结束并复盘'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(harness.controller.phase, PracticeMediaPhase.localClosed);
    expect(find.text('本次练习已结束'), findsOneWidget);
    expect(find.text('返回练习'), findsOneWidget);
    expect(find.text('静音麦克风'), findsNothing);
    await close(tester);
  });

  testWidgets('an attempt that never connected can be cancelled and closed', (
    tester,
  ) async {
    await open(tester);
    expect(harness.controller.phase, PracticeMediaPhase.connecting);
    expect(find.text('连接确认前不会采集或播放音频。'), findsOneWidget);
    expect(find.text('正在收尾：麦克风与播报已停止，请稍候。'), findsNothing);

    await tester.tap(find.text('取消这次尝试'));
    await tester.pump();
    await tester.pump();
    expect(harness.controller.phase, PracticeMediaPhase.localClosed);
    expect(find.text('打开通话'), findsOneWidget);
    await close(tester);
  });
}
