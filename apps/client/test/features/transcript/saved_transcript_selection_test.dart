import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_view.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_controller.dart';

import 'transcript_fixtures.dart';

void main() {
  for (final clicks in [1, 2, 3]) {
    testWidgets(
      'saved transcript mouse $clicks clicks keep native selection and copy',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': copied};
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: SavedTranscriptView(
              state: SavedTranscriptState.ready,
              page: page(),
            ),
          ),
        );
        final text = find.text('I enjoy English.');
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
        final point = tester.getTopLeft(text) + const Offset(15, 8);
        for (var i = 0; i < clicks; i++) {
          await tester.tapAt(point, kind: PointerDeviceKind.mouse);
          await tester.pump(const Duration(milliseconds: 70));
        }
        await tester.pumpAndSettle();
        if (clicks == 1) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        }
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(copied, contains('I'));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }
}
