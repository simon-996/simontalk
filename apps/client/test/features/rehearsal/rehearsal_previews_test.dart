import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/rehearsal/rehearsal_previews.dart';

void main() {
  final output = Platform.environment['SIMONTALK_REHEARSAL_RENDER_DIR'];
  setUpAll(() async {
    if (output != null) {
      final bytes = await File('assets/fonts/NotoSansSC.woff2').readAsBytes();
      final loader = FontLoader('RehearsalRenderFont')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  for (final entry in <String, Widget Function()>{
    'light': rehearsalLightPreview,
    'dark-320-200': rehearsalDarkPreview,
    'unknown': rehearsalUnknownPreview,
    'unavailable': rehearsalUnavailablePreview,
    'prepared': rehearsalPreparedPreview,
  }.entries) {
    testWidgets(
      'isolated preview ${entry.key} renders and has usable action bounds',
      (t) async {
        t.view.physicalSize = entry.key.startsWith('dark')
            ? const Size(320, 900)
            : const Size(760, 1050);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        final sample = entry.value() as MaterialApp;
        final rendered = output == null
            ? sample
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: sample.theme!.copyWith(
                  textTheme: sample.theme!.textTheme.apply(
                    fontFamily: 'RehearsalRenderFont',
                  ),
                ),
                builder: sample.builder,
                home: sample.home,
              );
        await t.pumpWidget(RepaintBoundary(key: boundary, child: rendered));
        await t.pumpAndSettle();
        expect(find.text('练这一句'), findsOneWidget);
        expect(t.takeException(), isNull);
        Future<void> capture(String suffix) async {
          if (output == null) return;
          await t.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '$output/rehearsal-render-${entry.key}$suffix.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('');
        final action = find.text(
          entry.key == 'unknown'
              ? '确认上次准备请求'
              : entry.key == 'unavailable'
              ? '重新读取目标'
              : entry.key == 'prepared'
              ? '进入重练通话'
              : '确认并准备',
        );
        await t.ensureVisible(action);
        expect(t.takeException(), isNull);
        final button = find
            .ancestor(
              of: action,
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first;
        expect(t.getSize(button).height, greaterThanOrEqualTo(48));
        if (entry.key.startsWith('dark')) {
          await t.pumpAndSettle();
          await capture('-actions');
        }
      },
    );
  }
}
