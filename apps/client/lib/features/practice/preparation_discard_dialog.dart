import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';

class PreparationDiscardDialog extends StatelessWidget {
  const PreparationDiscardDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('清理这项准备？'),
    content: const Text(
      '仅在所有连接均未开始远端媒体时取消这项准备，也会取消当前账号在其他页面的同一准备。\n\n'
      '历史记录会保留。如果连接已开始或状态发生变化，服务端会拒绝清理。',
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context, false),
        child: const Text('保留准备'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('确认清理'),
      ),
    ],
  );
}

@Preview(
  name: '准备清理 · 确认 · 浅色',
  size: Size(390, 700),
  wrapper: previewWithFonts,
)
Widget preparationDiscardLightPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.light),
  home: const Scaffold(body: Center(child: PreparationDiscardDialog())),
);

@Preview(
  name: '准备清理 · 确认 · 深色大字号',
  size: Size(320, 880),
  wrapper: previewWithFonts,
)
Widget preparationDiscardDarkPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: const MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(2)),
    child: Scaffold(body: Center(child: PreparationDiscardDialog())),
  ),
);
