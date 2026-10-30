import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../history/history_view.dart' show historyTime;
import 'rehearsal_list_controller.dart';
import 'rehearsal_list_models.dart';

class RehearsalListView extends StatelessWidget {
  const RehearsalListView({
    super.key,
    required this.state,
    this.page,
    this.pageNumber = 1,
    this.errorCode,
    this.busy = false,
    this.accountBusy = false,
    this.canPrevious = false,
    this.canNext = false,
    this.onRefresh,
    this.onPrevious,
    this.onNext,
    this.onBack,
    this.onOpen,
    this.onConfirmAccount,
    this.pageFocus,
  });
  final RehearsalListState state;
  final RehearsalListPage? page;
  final String? errorCode;
  final int pageNumber;
  final bool busy, accountBusy, canPrevious, canNext;
  final FocusNode? pageFocus;
  final VoidCallback? onRefresh, onPrevious, onNext, onBack, onConfirmAccount;
  final ValueChanged<String>? onOpen;
  @override
  Widget build(BuildContext context) {
    final blocked = busy || accountBusy;
    final identity =
        state == RehearsalListState.aborted ||
        {'unauthorized', 'account_changed'}.contains(errorCode);
    final current = identity || state == RehearsalListState.unavailable
        ? null
        : page;
    final theme = Theme.of(context);
    final heading = Semantics(
      liveRegion: true,
      header: true,
      child: Text(
        '第 $pageNumber 页 · 本页 ${current?.items.length ?? 0} 条',
        key: const ValueKey('related-page-heading'),
        style: theme.textTheme.titleMedium,
      ),
    );
    return AccountFrame(
      wide: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageIntro(title: '关联重练', description: '回看同一来源练习下，每一次独立重练的记录。'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton(
                onPressed: blocked || identity ? null : onRefresh,
                child: const Text('刷新关联重练'),
              ),
              OutlinedButton(
                onPressed: accountBusy ? null : onBack,
                child: const Text('返回来源练习'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (accountBusy) ...[
            const StatusMessage('账号操作进行中，请稍候…', error: false),
            const SizedBox(height: 12),
          ],
          if (busy || state == RehearsalListState.idle)
            Semantics(liveRegion: true, child: const Text('正在读取关联重练…')),
          if (errorCode != null) ...[
            StatusMessage(
              _message(errorCode!, retained: current != null),
              error: true,
            ),
            if (identity)
              OutlinedButton(
                onPressed: blocked ? null : onConfirmAccount,
                child: const Text('重新确认账号'),
              ),
            const SizedBox(height: 16),
          ],
          if (current != null) ...[
            if (pageFocus == null)
              heading
            else
              Focus(
                focusNode: pageFocus,
                child: ListenableBuilder(
                  listenable: pageFocus!,
                  builder: (context, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: pageFocus!.hasFocus
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: heading,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (current.items.isEmpty) ...[
              Text(
                pageNumber == 1 ? '还没有关联重练' : '这一页已没有重练',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                pageNumber == 1
                    ? '从来源练习的复盘中选择“练这一句”后，独立记录会显示在这里。'
                    : '记录可能已更新。可以返回上一页，或刷新列表。',
              ),
            ],
            for (final item in current.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton(
                  key: ValueKey('related-${item.id}'),
                  onPressed: blocked || onOpen == null
                      ? null
                      : () => onOpen!(item.id),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.all(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('逐句重练', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('登记于 ${historyTime(item.createdAt)}'),
                      if (item.endedAt != null)
                        Text('结束登记于 ${historyTime(item.endedAt!)}'),
                      const SizedBox(height: 8),
                      Text(item.statusLabel),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton(
                  onPressed: !blocked && canPrevious ? onPrevious : null,
                  child: const Text('上一页'),
                ),
                OutlinedButton(
                  onPressed: !blocked && canNext ? onNext : null,
                  child: const Text('下一页'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('这是重练记录列表。保存内容与目标可在各条记录的详情中查看。'),
          ],
        ],
      ),
    );
  }
}

String _message(String code, {required bool retained}) => switch (code) {
  'unauthorized' || 'account_changed' => '当前账号需要重新确认，旧记录已撤下。',
  'invalid_source' => '关联重练地址无效。',
  'practice_not_found' => '没有找到来源练习，可能已被删除。',
  'rehearsal_cursor_not_found' => '分页位置已变化，请刷新关联重练后继续。',
  'rehearsal_source_changed' => '这条来源不支持关联重练，请返回原记录查看。',
  'invalid_response' => '记录响应未通过核对，请刷新重试。',
  _ => retained ? '这次翻页没有完成，仍显示原页。请检查网络后明确重试。' : '暂时无法读取关联重练，请检查网络后刷新。',
};
