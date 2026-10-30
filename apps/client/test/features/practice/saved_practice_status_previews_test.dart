import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/practice/saved_practice_status_previews.dart';

void main() {
  final output = Platform.environment['SIMONTALK_SAVE_STATUS_RENDER_DIR'];
  setUpAll(() async {
    if (output != null) {
      final bytes = await File('assets/fonts/NotoSansSC.woff2').readAsBytes();
      final loader = FontLoader('SaveResultRenderFont')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  for (final sample in <String, Widget Function()>{
    'complete': savedPracticeCompletePreview,
    'gap-dark320-200': savedPracticeGapPreview,
    'saving': savedPracticeSavingPreview,
    'failed': savedPracticeFailedPreview,
  }.entries) {
    testWidgets('saved practice preview ${sample.key} renders independently', (
      t,
    ) async {
      t.view.physicalSize = sample.key.startsWith('gap')
          ? const Size(320, 1100)
          : const Size(760, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final original = sample.value() as MaterialApp;
      final boundary = GlobalKey();
      final app = output == null
          ? original
          : MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: original.theme!.copyWith(
                textTheme: original.theme!.textTheme.apply(
                  fontFamily: 'SaveResultRenderFont',
                ),
              ),
              builder: original.builder,
              home: original.home,
            );
      await t.pumpWidget(RepaintBoundary(key: boundary, child: app));
      await t.pumpAndSettle();
      expect(find.text('这次练习的保存情况'), findsOneWidget);
      expect(t.takeException(), isNull);
      Future<void> capture(String suffix) async {
        if (output == null) return;
        await t.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final pixels = await render.toImage(pixelRatio: 1);
          final data = await pixels.toByteData(format: ui.ImageByteFormat.png);
          pixels.dispose();
          await Directory(output).create(recursive: true);
          await File('$output/saved-practice-${sample.key}$suffix.png')
              .writeAsBytes(data!.buffer.asUint8List());
        });
      }

      await capture('');
      await t.ensureVisible(find.byType(OutlinedButton).last);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (sample.key.startsWith('gap')) await capture('-bottom');
    });
  }
}
