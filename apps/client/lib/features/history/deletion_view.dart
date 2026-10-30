import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import 'deletion_controller.dart';
import 'deletion_models.dart';

class DeletionView extends StatelessWidget {
  const DeletionView({
    super.key,
    required this.state,
    this.scope,
    this.errorCode,
    this.busy = false,
    this.canReplay = false,
    this.onKeep,
    this.onConfirm,
    this.onLoad,
    this.onCheck,
    this.onReplay,
    this.onConfirmAccount,
  });
  final DeletionState state;
  final DeletionScope? scope;
  final String? errorCode;
  final bool busy, canReplay;
  final VoidCallback? onKeep,
      onConfirm,
      onLoad,
      onCheck,
      onReplay,
      onConfirmAccount;
  @override
  Widget build(BuildContext context) {
    final unknown = state == DeletionState.unconfirmed;
    final identity = state == DeletionState.aborted;
    final current = identity ? null : scope;
    return AccountFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageIntro(
            title: '删除练习记录',
            description: '先核对影响范围。删除后，页面中无法恢复文字和反馈。',
          ),
          OutlinedButton(
            autofocus: true,
            onPressed: busy ? null : onKeep,
            child: Text(unknown ? '返回记录详情' : '保留记录'),
          ),
          const SizedBox(height: 24),
          if (busy || state == DeletionState.idle)
            Semantics(
              liveRegion: true,
              child: Text(switch (state) {
                DeletionState.deleting => '正在删除，请稍候…',
                DeletionState.idle || DeletionState.reading => '正在核对…',
                _ => '正在处理，请稍候…',
              }),
            ),
          if (current != null && state == DeletionState.ready) ...[
            Text(
              current.kind == 'ordinary'
                  ? '将删除这次练习和 ${current.rehearsalCount} 次关联重练，共 ${current.recordCount} 条记录。'
                  : '只删除这一次重练。来源练习和其他重练会保留。',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            const Text('包括这些记录的对话文字、反馈和重练目标；尚未完成的关联重练也在范围内。'),
            const SizedBox(height: 16),
            Text(
              current.connectionPending
                  ? '连接仍待核对。删除内容不会确认远端已结束，也不会恢复已用额度。'
                  : '已消耗的用量不会因删除返还。',
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: busy ? null : onConfirm,
              child: const Text('确认删除'),
            ),
          ],
          if (unknown) ...[
            Text('删除结果尚未确认', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text('请求可能已被受理。先核对本次删除凭据，不会自动重复删除或扩大范围。'),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: busy ? null : onCheck,
              child: const Text('核对删除结果'),
            ),
            if (canReplay) ...[
              const SizedBox(height: 8),
              const Text('暂未找到确认凭据。可以继续核对，或明确重试原来的删除请求。'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: busy ? null : onReplay,
                child: const Text('确认重试原删除'),
              ),
            ],
          ],
          if (state == DeletionState.failed) ...[
            StatusMessage(_message(errorCode), error: true),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: busy ? null : onLoad,
              child: const Text('重新读取删除范围'),
            ),
          ],
          if (identity) ...[
            const StatusMessage('账号需要重新确认，原删除范围已清除。', error: true),
            OutlinedButton(
              onPressed: onConfirmAccount,
              child: const Text('重新确认账号'),
            ),
          ],
        ],
      ),
    );
  }
}

String _message(String? code) => switch (code) {
  'deletion_scope_changed' => '关联记录已变化。请重新读取范围，再决定是否删除。',
  'practice_not_found' => '没有找到这条记录，可能已经被删除。',
  'invalid_source' => '练习地址无效。',
  'csrf_invalid' || 'origin_forbidden' => '安全校验未通过，请重新读取并确认。',
  _ => '暂时无法确认删除范围。请稍后重新读取。',
};
