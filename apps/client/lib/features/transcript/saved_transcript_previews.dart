import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'saved_transcript_controller.dart';
import 'saved_transcript_preview_fixtures.dart';
import 'saved_transcript_view.dart';

void savedTranscriptPreviewNoop() {}
Widget _example({
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool empty = false,
  bool error = false,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: SavedTranscriptView(
    state: error ? SavedTranscriptState.failed : SavedTranscriptState.ready,
    page: error ? null : exampleSavedTranscript(empty: empty),
    errorCode: error ? 'network_error' : null,
    hasFocus: !empty && !error,
    onBack: savedTranscriptPreviewNoop,
    onRefresh: savedTranscriptPreviewNoop,
    onPrevious: savedTranscriptPreviewNoop,
    onNext: savedTranscriptPreviewNoop,
    onFocus: savedTranscriptPreviewNoop,
  ),
);

@Preview(
  name: '已保存文字示例 · 浅色定位与多连接',
  group: '已保存文字',
  wrapper: previewWithFonts,
  size: Size(760, 900),
)
Widget savedTranscriptLightPreview() => _example();
@Preview(
  name: '已保存文字示例 · 深色320 · 200%字号',
  group: '已保存文字',
  wrapper: previewWithFonts,
  size: Size(320, 720),
)
Widget savedTranscriptDarkLargePreview() =>
    _example(brightness: Brightness.dark, scale: 2);
@Preview(
  name: '已保存文字示例 · 空记录',
  group: '已保存文字',
  wrapper: previewWithFonts,
  size: Size(375, 760),
)
Widget savedTranscriptEmptyPreview() => _example(empty: true);
@Preview(
  name: '已保存文字示例 · 读取失败',
  group: '已保存文字',
  wrapper: previewWithFonts,
  size: Size(375, 760),
)
Widget savedTranscriptErrorPreview() => _example(error: true);
