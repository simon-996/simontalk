import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/account_components.dart';
import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'conversation_models.dart';
import 'final_transcript_read_models.dart';

class FinalTranscriptReadView extends StatelessWidget {
  const FinalTranscriptReadView({
    super.key,
    this.history,
    this.busy = false,
    this.errorCode,
    this.onLoad,
    this.onRefresh,
  });

  final FinalTranscriptHistory? history;
  final bool busy;
  final String? errorCode;
  final VoidCallback? onLoad;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final identityError =
        errorCode == 'account_changed' || errorCode == 'unauthorized';
    final saved = identityError ? null : history;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading('已保存文字'),
        const SizedBox(height: 8),
        Text(
          '来自客户端提交的最终文字，可能有遗漏。AI 内容为生成文本，不能确认已播放。',
          style: textTheme.bodySmall,
        ),
        if (saved != null) ...[
          const SizedBox(height: 16),
          Text(
            '已读取 ${saved.events.length} 次提交，本次查询共 ${saved.totalEvents} 次；当前 ${saved.turns.length} 段文字。',
            style: textTheme.bodySmall,
          ),
          if (saved.hasMore) ...[
            const SizedBox(height: 8),
            const Text('尚有文字未读取，当前内容可能继续更新。'),
          ],
          if (saved.hasSequenceGaps ||
              saved.hasTurnIndexGaps ||
              saved.hasRevisionGaps) ...[
            const SizedBox(height: 8),
            const Text('记录中存在间隔，无法确认文字完整性；这不代表一定有文字丢失。'),
          ],
          const SizedBox(height: 16),
          if (saved.turns.isEmpty)
            const Text('尚无已保存的最终文字。')
          else
            _TranscriptReadingArea(history: saved),
        ],
        if (errorCode != null) ...[
          const SizedBox(height: 16),
          StatusMessage(_textErrorMessage(errorCode!)),
        ],
        if (busy && !identityError) ...[
          const SizedBox(height: 12),
          Semantics(liveRegion: true, child: const Text('正在读取文字…')),
        ],
        if (!identityError) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (saved == null || saved.hasMore)
                OutlinedButton(
                  onPressed: busy ? null : onLoad,
                  child: Text(
                    errorCode != null
                        ? '重试读取文字'
                        : saved == null
                        ? '查看已保存文字'
                        : '查看更多文字',
                  ),
                ),
              if (saved != null)
                OutlinedButton(
                  onPressed: busy ? null : onRefresh,
                  child: const Text('刷新文字'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TranscriptReadingArea extends StatefulWidget {
  const _TranscriptReadingArea({required this.history});
  final FinalTranscriptHistory history;

  @override
  State<_TranscriptReadingArea> createState() => _TranscriptReadingAreaState();
}

class _TranscriptReadingAreaState extends State<_TranscriptReadingArea> {
  final _scrollController = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'Saved transcript reading area');
  bool _showFocus = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Object? _scroll(ScrollIntent intent) {
    if (!_scrollController.hasClients) return null;
    final position = _scrollController.position;
    final distance = intent.type == ScrollIncrementType.page
        ? position.viewportDimension * 0.8
        : 48.0;
    final direction = intent.direction == AxisDirection.up ? -1 : 1;
    _scrollController.jumpTo(
      (position.pixels + distance * direction).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = (MediaQuery.sizeOf(context).height * 0.55).clamp(
      200.0,
      420.0,
    );
    return Semantics(
      label: '已保存文字阅读区',
      hint: '可滚动阅读和选择文字，聚焦后可用方向键或翻页键滚动。',
      child: FocusableActionDetector(
        focusNode: _focusNode,
        onShowFocusHighlight: (show) => setState(() => _showFocus = show),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowUp): ScrollIntent(
            direction: AxisDirection.up,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): ScrollIntent(
            direction: AxisDirection.down,
          ),
          SingleActivator(LogicalKeyboardKey.pageUp): ScrollIntent(
            direction: AxisDirection.up,
            type: ScrollIncrementType.page,
          ),
          SingleActivator(LogicalKeyboardKey.pageDown): ScrollIntent(
            direction: AxisDirection.down,
            type: ScrollIncrementType.page,
          ),
        },
        actions: {
          ScrollIntent: CallbackAction<ScrollIntent>(onInvoke: _scroll),
        },
        child: Listener(
          onPointerDown: (_) {
            if (!_focusNode.hasFocus) _focusNode.requestFocus();
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _showFocus ? colors.primary : colors.outline,
                width: 2,
              ),
            ),
            child: SizedBox(
              height: height,
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SelectionArea(
                  child: ListView.builder(
                    controller: _scrollController,
                    primary: false,
                    padding: const EdgeInsets.fromLTRB(16, 16, 24, 16),
                    itemCount: widget.history.turns.length,
                    itemBuilder: (context, index) {
                      final turn = widget.history.turns[index];
                      final assistant = turn.role == ConversationRole.assistant;
                      return Padding(
                        padding: EdgeInsets.only(top: index == 0 ? 0 : 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              assistant ? 'AI 生成内容' : '你',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            if (assistant) ...[
                              const SizedBox(height: 4),
                              Text(
                                '播放情况未知',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            const SizedBox(height: 8),
                            if (turn.text.isEmpty)
                              const Text('此段没有可用文字')
                            else
                              Text(turn.text),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _textErrorMessage(String code) => switch (code) {
  'account_changed' => '当前账号已变化，请重新确认账号后查看。',
  'unauthorized' => '登录已失效，请重新确认账号。',
  'invalid_response' => '已保存文字响应异常，请重试读取文字。',
  _ => '暂时无法读取文字，请检查网络后重试。',
};

// These samples are only used by the isolated previewer, never by account state.
FinalTranscriptHistory _previewHistory({bool empty = false}) {
  final scope = ConversationScope(
    accountId: '11111111-1111-4111-8111-111111111111',
    sessionId: '22222222-2222-4222-8222-222222222222',
    connectionId: '33333333-3333-4333-8333-333333333333',
    clientInstanceId: '44444444-4444-4444-8444-444444444444',
    epoch: 1,
  );
  final events = <Map<String, dynamic>>[
    if (!empty)
      {
        'event_id': '55555555-5555-4555-8555-555555555555',
        'sequence': 1,
        'turn_id': '66666666-6666-4666-8666-666666666666',
        'turn_index': 1,
        'role': 'user',
        'revision': 1,
        'text': 'I enjoy walking after work.',
        'response_id': null,
        'provider_item_id': null,
        'received_at': '2026-10-20T00:00:00Z',
        'delivery_status': null,
      },
    if (!empty)
      {
        'event_id': '77777777-7777-4777-8777-777777777777',
        'sequence': 2,
        'turn_id': '88888888-8888-4888-8888-888888888888',
        'turn_index': 2,
        'role': 'assistant',
        'revision': 1,
        'text': 'What do you like about those walks?',
        'response_id': '99999999-9999-4999-8999-999999999999',
        'provider_item_id': null,
        'received_at': '2026-10-20T00:00:01Z',
        'delivery_status': 'unknown',
      },
  ];
  return FinalTranscriptHistory.empty(scope).append(
    FinalTranscriptPage.fromJson(
      {
        'source': 'client_reported',
        'account_id': scope.accountId,
        'session_id': scope.sessionId,
        'connection_id': scope.connectionId,
        'client_instance_id': scope.clientInstanceId,
        'epoch': scope.epoch,
        'last_sequence': events.length,
        'total_events': events.length,
        'total_text_bytes': events.fold<int>(
          0,
          (sum, event) => sum + (event['text'] as String).length,
        ),
        'events': events,
        'next_after_sequence': events.length,
        'has_more': false,
      },
      scope: scope,
      afterSequence: 0,
      limit: 32,
    ),
  );
}

Widget _transcriptPreview(Brightness brightness, {bool empty = false}) =>
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: FinalTranscriptReadView(
            history: _previewHistory(empty: empty),
            onRefresh: () {},
          ),
        ),
      ),
    );

@Preview(name: '保存文字 · 浅色', size: Size(390, 760), wrapper: previewWithFonts)
Widget finalTranscriptLightPreview() => _transcriptPreview(Brightness.light);

@Preview(
  name: '保存文字 · 深色',
  size: Size(390, 760),
  brightness: Brightness.dark,
  wrapper: previewWithFonts,
)
Widget finalTranscriptDarkPreview() => _transcriptPreview(Brightness.dark);

@Preview(name: '保存文字 · 空态', size: Size(320, 620), wrapper: previewWithFonts)
Widget finalTranscriptEmptyPreview() =>
    _transcriptPreview(Brightness.light, empty: true);
