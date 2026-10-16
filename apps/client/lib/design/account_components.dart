import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'app_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _BrandPainter(Theme.of(context).colorScheme.primary),
    ),
  );
}

class _BrandPainter extends CustomPainter {
  _BrandPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(41, 14)
        ..cubicTo(18, 2, 3, 19, 13, 36)
        ..lineTo(10, 46)
        ..lineTo(22, 42)
        ..cubicTo(30, 45, 40, 41, 43, 35),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(23, 29)
        ..cubicTo(26, 19, 44, 18, 51, 28)
        ..cubicTo(59, 40, 50, 49, 43, 49)
        ..lineTo(49, 57)
        ..lineTo(36, 51)
        ..cubicTo(29, 50, 24, 45, 24, 40),
      paint,
    );
  }

  @override
  bool shouldRepaint(_BrandPainter oldDelegate) => color != oldDelegate.color;
}

class AccountFrame extends StatelessWidget {
  const AccountFrame({super.key, required this.child, this.wide = false});
  final Widget child;
  final bool wide;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final split =
              !wide &&
              constraints.maxWidth >= 1000 &&
              MediaQuery.textScalerOf(context).scale(16) <= 24;
          final form = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 680 : 440),
            child: child,
          );
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.symmetric(
              horizontal: constraints.maxWidth < 360 ? 16 : 24,
              vertical: 32,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 64).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: split
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1040),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 80),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const BrandMark(size: 96),
                                    const SizedBox(height: 32),
                                    Text(
                                      '让英语\n走进日常对话。',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium
                                          ?.copyWith(
                                            fontSize: 40,
                                            height: 1.35,
                                          ),
                                    ),
                                    const SizedBox(height: 20),
                                    Text(
                                      '从你熟悉的话题开始，\n用自己的节奏，慢慢聊开。',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(child: Align(child: form)),
                          ],
                        ),
                      )
                    : form,
              ),
            ),
          );
        },
      ),
    ),
  );
}

class PageIntro extends StatelessWidget {
  const PageIntro({
    super.key,
    required this.title,
    required this.description,
    this.brand = true,
  });
  final String title;
  final String description;
  final bool brand;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (brand) ...[
        const Row(
          children: [
            BrandMark(size: 36),
            SizedBox(width: 12),
            Flexible(
              child: Text(
                'SimonTalk',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 40),
      ],
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
      ),
      const SizedBox(height: 12),
      Text(
        description,
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 32),
    ],
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  );
}

class StatusMessage extends StatelessWidget {
  const StatusMessage(this.message, {super.key, this.error = true});
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 24),
        decoration: BoxDecoration(
          color: error ? colors.errorContainer : colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: error ? colors.onErrorContainer : colors.onSurface,
          ),
        ),
      ),
    );
  }
}

class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          Text(busy ? '正在处理…' : label),
        ],
      ),
    ),
  );
}

@Preview(name: '品牌与按钮 · 浅色', size: Size(390, 320))
Widget brandPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.light),
  home: const AccountFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(),
        SizedBox(height: 24),
        PrimaryAction(label: '保存设置', onPressed: null),
      ],
    ),
  ),
);

@Preview(name: '品牌与按钮 · 深色', size: Size(390, 320), brightness: Brightness.dark)
Widget darkBrandPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: const AccountFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(),
        SizedBox(height: 24),
        PrimaryAction(label: '保存设置', onPressed: null),
      ],
    ),
  ),
);

@Preview(name: '标题与错误 · 窄屏大字号', size: Size(320, 640))
Widget accessibleStatusPreview() => _statusPreview(Brightness.light);

@Preview(
  name: '标题与错误 · 深色大字号',
  size: Size(320, 640),
  brightness: Brightness.dark,
)
Widget darkAccessibleStatusPreview() => _statusPreview(Brightness.dark);

Widget _statusPreview(Brightness brightness) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
    child: child!,
  ),
  home: const AccountFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(title: '练习偏好', description: '让每次交流更适合你。', brand: false),
        SectionHeading('对话难度'),
        SizedBox(height: 16),
        StatusMessage('暂时无法连接服务，请检查网络后重试。'),
      ],
    ),
  ),
);
