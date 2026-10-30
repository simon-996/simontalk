import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/account/account_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_controller.dart';
import 'package:simontalk_client/features/realtime/practice_media_providers.dart';
import 'package:simontalk_client/features/session/practice_session_screen.dart';

import '../practice/practice_providers_test.dart' show ScopedAccountController;
import '../realtime/media_fixtures.dart';

void main() {
  late MediaHarness harness;
  late ProviderContainer container;

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    harness = MediaHarness(tester);
    container = ProviderContainer(
      overrides: [
        accountControllerProvider.overrideWith(ScopedAccountController.new),
        practiceMediaProvider.overrideWith((ref) => harness.controller),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const PracticeSessionScreen(),
        ),
      ),
    );
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
}
