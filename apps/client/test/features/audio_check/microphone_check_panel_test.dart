import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/audio_check/microphone_check_panel.dart';

import 'microphone_check_controller_test.dart' show TestProbe;

void main() {
  testWidgets('wait can be cancelled and account key change releases capture', (
    tester,
  ) async {
    final probes = <TestProbe>[];
    Widget app(String account) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MicrophoneCheckPanel(
            key: ValueKey(account),
            supported: true,
            createProbe: () {
              final p = TestProbe();
              probes.add(p);
              return p;
            },
          ),
        ),
      ),
    );
    await tester.pumpWidget(app('first'));
    expect(probes, isEmpty);
    await tester.tap(find.text('开始检查'));
    await tester.pump();
    expect(probes, hasLength(1));
    await tester.tap(find.text('取消等待'));
    await tester.pump();
    expect(probes.first.stops, 1);
    await tester.tap(find.text('重新检查'));
    await tester.pump();
    probes.last.permission.complete();
    await tester.pump();
    expect(find.text('停止检查'), findsOneWidget);
    await tester.pumpWidget(app('second'));
    expect(probes.last.stops, 1);
    expect(find.text('开始检查'), findsOneWidget);
    probes.first.permission.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'stop remains reachable at 320 width and 200% text in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final probe = TestProbe();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: MicrophoneCheckPanel(
                    supported: true,
                    createProbe: () => probe,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.ensureVisible(find.text('开始检查'));
        await tester.tap(find.text('开始检查'));
        await tester.pump();
        probe.permission.complete();
        await tester.pump();
        await tester.ensureVisible(find.text('停止检查'));
        await tester.tap(find.text('停止检查'));
        await tester.pump();
        expect(probe.stops, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
