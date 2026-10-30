import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'review_page_controller.dart';
import 'review_page_preview_fixtures.dart';
import 'review_page_view.dart';

void reviewPreviewNoop() {}

Widget _example({
  Brightness brightness = Brightness.light,
  double scale = 1,
  String status = 'succeeded',
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: ReviewPageView(
    state: ReviewPageState.ready,
    completion: exampleReviewCompletion(),
    job: exampleReviewJob(status: status),
    canRetryGeneration: status == 'blocked',
    onBack: reviewPreviewNoop,
    onRefresh: reviewPreviewNoop,
    onReadSavedText: reviewPreviewNoop,
    onLocateItem: (_) => reviewPreviewNoop(),
    onRetryGeneration: reviewPreviewNoop,
  ),
);

@Preview(
  name: '复盘示例 · 浅色三项',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(760, 900),
)
Widget reviewLightExamplePreview() => _example();

@Preview(
  name: '复盘示例 · 深色320 · 200%字号',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(320, 720),
)
Widget reviewDarkLargeTextPreview() =>
    _example(brightness: Brightness.dark, scale: 2);

@Preview(
  name: '复盘示例 · 整理能力未就绪',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(375, 760),
)
Widget reviewBlockedExamplePreview() => _example(status: 'blocked');

@Preview(
  name: '复盘示例 · 有效空建议',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(375, 760),
)
Widget reviewEmptyExamplePreview() => _example(status: 'no_suggestions');

@Preview(
  name: '重练评价示例 · 原意与目标均展示',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(760, 900),
)
Widget rehearsalEvaluationExamplePreview() => const _EvaluationExample();

@Preview(
  name: '重练评价示例 · 原意变化且目标展示',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(375, 760),
)
Widget rehearsalEvaluationChangedPreview() =>
    const _EvaluationExample(intent: 'changed');

@Preview(
  name: '重练评价示例 · 原意证据不足且目标未展示',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(375, 760),
)
Widget rehearsalEvaluationInsufficientPreview() => const _EvaluationExample(
  intent: 'insufficient_evidence',
  issue: 'not_demonstrated',
);

@Preview(
  name: '重练评价示例 · 深色320 · 200%字号',
  group: '复盘阅读页',
  wrapper: previewWithFonts,
  size: Size(320, 720),
)
Widget rehearsalEvaluationDarkLargeTextPreview() =>
    const _EvaluationExample(brightness: Brightness.dark, scale: 2);

/// All interaction stays inside this isolated fixture. No providers or API.
class _EvaluationExample extends StatefulWidget {
  const _EvaluationExample({
    this.intent = 'conveyed',
    this.issue = 'demonstrated',
    this.brightness = Brightness.light,
    this.scale = 1,
  });
  final String intent, issue;
  final Brightness brightness;
  final double scale;

  @override
  State<_EvaluationExample> createState() => _EvaluationExampleState();
}

class _EvaluationExampleState extends State<_EvaluationExample> {
  bool _reading = false;

  Future<void> _refresh() async {
    setState(() => _reading = true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => _reading = false);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildAppTheme(widget.brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(widget.scale),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: Builder(
      builder: (context) => ReviewPageView(
        state: _reading ? ReviewPageState.readingReview : ReviewPageState.ready,
        completion: exampleReviewCompletion(),
        job: exampleReviewJob(
          rehearsalIntentStatus: widget.intent,
          rehearsalIssueStatus: widget.issue,
        ),
        busy: _reading,
        onRefresh: _refresh,
        onReadSavedText: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('预览示例 · 已保存文字'),
            content: SingleChildScrollView(
              child: SelectableText(switch (widget.issue) {
                'not_demonstrated' => 'I like parks.',
                'still_present' => 'Yesterday I go to the park.',
                _ =>
                  widget.intent == 'changed'
                      ? 'Yesterday I went to a museum.'
                      : 'Yesterday I went to the park.',
              }),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回示例'),
              ),
            ],
          ),
        ),
        onBack: () => ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这是独立重练评价预览，无账号或网络请求。'))),
      ),
    ),
  );
}
