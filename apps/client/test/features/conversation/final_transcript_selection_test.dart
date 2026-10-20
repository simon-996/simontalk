import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/final_transcript_read_view.dart';

import 'final_transcript_read_view_test.dart' show showTranscript;
import 'final_transcript_view_fixtures.dart';

void main() {
  for (final clicks in [1, 2, 3]) {
    testWidgets('mouse $clicks clicks keeps the selection focus and can copy', (
      tester,
    ) async {
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
      const word = 'copiableword';
      await showTranscript(
        tester,
        FinalTranscriptReadView(
          history: transcriptViewHistory([transcriptViewEvent(1, text: word)]),
        ),
      );
      final point = tester.getTopLeft(find.text(word)) + const Offset(12, 8);
      for (var i = 0; i < clicks; i++) {
        await tester.tapAt(point, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 70));
      }
      await tester.pumpAndSettle();
      if (clicks == 1) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(copied, contains(word));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
}
