import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../../design/practice_navigation.dart';
import 'history_controller.dart';
import 'history_models.dart';

String historyTime(DateTime time) {
  final t = time.toLocal();
  String two(int v) => '$v'.padLeft(2, '0');
  return '${t.year}年${t.month}月${t.day}日 ${two(t.hour)}:${two(t.minute)}';
}

class HistoryView extends StatelessWidget {
  const HistoryView({
    super.key,
    required this.state,
    this.page,
    this.item,
    this.detail = false,
    this.busy = false,
    this.pageNumber = 1,
    this.errorCode,
    this.canPrevious = false,
    this.canNext = false,
    this.onRefresh,
    this.onPrevious,
    this.onNext,
    this.onOpen,
    this.onBack,
    this.onText,
    this.onReview,
    this.onSource,
    this.onPractice,
    this.onAccount,
    this.onConfirmAccount,
    this.onDelete,
    this.onTarget,
    this.onRelated,
    this.onSaveStatus,
  });
  final HistoryState state;
  final HistoryPage? page;
  final HistoryItem? item;
  final bool detail, busy, canPrevious, canNext;
  final int pageNumber;
  final String? errorCode;
  final ValueChanged<String>? onOpen;
  final VoidCallback? onRefresh,
      onPrevious,
      onNext,
      onBack,
      onText,
      onReview,
      onSource,
      onPractice,
      onAccount,
      onConfirmAccount,
      onDelete,
      onTarget,
      onRelated,
      onSaveStatus;
  @override
  Widget build(BuildContext context) {
    final identity = {'account_changed', 'unauthorized'}.contains(errorCode);
    final currentPage = identity ? null : page;
    final currentItem = identity ? null : item;
    final theme = Theme.of(context);
    return AccountFrame(
      wide: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (detail) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: onBack,
                child: const Text('返回记录'),
              ),
            ),
            const SizedBox(height: 24),
          ] else ...[
            PracticeNavigation(
              current: 'history',
              onPractice: onPractice,
              onAccount: onAccount,
            ),
            const SizedBox(height: 24),
          ],
          PageIntro(
            title: detail ? '这次练习' : '练习记录',
            description: detail
                ? '回看当时的难度、保存情况与已保存内容。'
                : '每一次练习，都可以回来看看。准备和未完成的记录也会如实保留。',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: busy || identity ? null : onRefresh,
              child: const Text('刷新记录'),
            ),
          ),
          const SizedBox(height: 16),
          if (state == HistoryState.reading || state == HistoryState.idle)
            Semantics(liveRegion: true, child: const Text('正在读取记录…')),
          if (state == HistoryState.failed ||
              state == HistoryState.unavailable ||
              state == HistoryState.aborted) ...[
            StatusMessage(
              _message(errorCode, retained: currentPage != null),
              error: true,
            ),
            if (identity)
              OutlinedButton(
                onPressed: onConfirmAccount,
                child: const Text('重新确认账号'),
              ),
          ],
          if (currentItem != null) ...[
            Text(currentItem.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('原难度：${currentItem.difficultyLabel}'),
            const SizedBox(height: 16),
            SelectableText('登记于 ${historyTime(currentItem.createdAt)}'),
            if (currentItem.endedAt != null)
              SelectableText('结束登记于 ${historyTime(currentItem.endedAt!)}'),
            const SizedBox(height: 16),
            Text(currentItem.statusLabel),
            const SizedBox(height: 8),
            Text(currentItem.saveLabel),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: busy ? null : onSaveStatus,
              child: const Text('查看保存情况'),
            ),
            if (currentItem.connectionPending) ...[
              const SizedBox(height: 8),
              const Text('连接与用量仍待核对。内容保存不代表连接已安全结束。'),
            ],
            if (currentItem.isSealed) ...[
              const SizedBox(height: 24),
              PrimaryAction(label: '查看已保存文字', onPressed: busy ? null : onText),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: busy ? null : onReview,
                child: const Text('查看复盘'),
              ),
            ] else ...[
              const SizedBox(height: 16),
              const Text('暂无封存文字可供回看。'),
            ],
            if (currentItem.sourceSessionId != null) ...[
              const SizedBox(height: 24),
              const Text('这是一条独立的重练记录。'),
              OutlinedButton(
                onPressed: busy ? null : onTarget,
                child: const Text('查看重练目标'),
              ),
              OutlinedButton(
                onPressed: busy ? null : onSource,
                child: const Text('查看来源练习'),
              ),
            ],
            if (currentItem.kind == 'ordinary') ...[
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: busy ? null : onRelated,
                child: const Text('查看关联重练'),
              ),
            ],
          ],
          if (currentItem != null && onDelete != null) ...[
            const SizedBox(height: 32),
            TextButton(
              onPressed: busy ? null : onDelete,
              child: const Text('删除记录'),
            ),
          ],
          if (currentPage != null) ...[
            if (currentPage.items.isEmpty) ...[
              Text(
                pageNumber == 1 ? '还没有练习记录' : '这一页已没有记录',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                pageNumber == 1 ? '开始一次练习后，记录会保存在这里。' : '记录可能已更新。可以返回上一页或刷新。',
              ),
            ],
            for (final record in currentPage.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton(
                  key: ValueKey('history-${record.id}'),
                  onPressed: busy ? null : () => onOpen?.call(record.id),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.all(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(record.title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        '${historyTime(record.createdAt)} · ${record.difficultyLabel}',
                      ),
                      const SizedBox(height: 8),
                      Text('${record.statusLabel} · ${record.saveLabel}'),
                      if (record.connectionPending) const Text('连接与用量待核对'),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text('第 $pageNumber 页', semanticsLabel: '当前第 $pageNumber 页'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: !busy && canPrevious ? onPrevious : null,
                  child: const Text('上一页'),
                ),
                OutlinedButton(
                  onPressed: !busy && canNext ? onNext : null,
                  child: const Text('下一页'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _message(String? code, {required bool retained}) => switch (code) {
  'account_changed' || 'unauthorized' => '登录需要重新确认，旧记录已清除。',
  'invalid_source' => '练习地址无效。',
  'practice_not_found' => '没有找到这次练习，可能已被删除。',
  'history_cursor_invalid' => '分页位置已失效，请刷新记录。',
  'invalid_response' => '记录响应异常，未展示未经核对的内容。请刷新重试。',
  _ => retained ? '这次翻页没有完成，仍显示原页。请明确重试翻页。' : '暂时无法读取记录，请检查网络后刷新重试。',
};
