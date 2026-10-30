import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../history/history_models.dart';
import 'practice_completion_models.dart';
import 'practice_save_status_view.dart';
import 'saved_practice_status_controller.dart';

class SavedPracticeStatusView extends StatelessWidget {
  const SavedPracticeStatusView({
    super.key,
    required this.state,
    this.item,
    this.completion,
    this.errorCode,
    this.busy = false,
    this.accountBusy = false,
    this.onRefresh,
    this.onBack,
    this.onConfirmAccount,
  });
  final SavedPracticeStatusState state;
  final HistoryItem? item;
  final PracticeCompletionSummary? completion;
  final String? errorCode;
  final bool busy, accountBusy;
  final VoidCallback? onRefresh, onBack, onConfirmAccount;
  @override
  Widget build(BuildContext context) {
    final ready = state == SavedPracticeStatusState.ready;
    final blocked = busy || accountBusy;
    final identity = state == SavedPracticeStatusState.aborted;
    final failed = {
      SavedPracticeStatusState.failed,
      SavedPracticeStatusState.unavailable,
    }.contains(state);
    return AccountFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: onBack,
              child: const Text('返回练习详情'),
            ),
          ),
          const SizedBox(height: 24),
          const PageIntro(
            title: '这次练习的保存情况',
            description: '查看服务器已收到的记录和保存缺口。刷新只核对现有状态。',
          ),
          if (identity) ...[
            const StatusMessage('账号需要重新确认，旧保存状态已清除。', error: true),
            OutlinedButton(
              onPressed: blocked ? null : onConfirmAccount,
              child: const Text('重新确认账号'),
            ),
          ] else if (failed) ...[
            StatusMessage(_message(errorCode), error: true),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: blocked ? null : onRefresh,
              child: const Text('重新读取保存情况'),
            ),
          ] else ...[
            if (accountBusy) ...[
              const StatusMessage('账号操作进行中，请稍候…', error: false),
              const SizedBox(height: 16),
            ],
            if (ready && item != null) ...[
              Text(item!.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('原难度：${item!.difficultyLabel}'),
              const SizedBox(height: 16),
              Text(item!.statusLabel),
              const SizedBox(height: 24),
            ],
            PracticeSaveStatusView(
              loaded: ready,
              busy: busy || !ready,
              completion: ready ? completion : null,
              onLoad: blocked ? null : onRefresh,
              onRefresh: blocked ? null : onRefresh,
            ),
            if (ready) ...[
              const SizedBox(height: 24),
              Text('连接与用量', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                item?.connectionPending == true
                    ? '仍有连接与用量待核对。文字保存不会解除连接占用。'
                    : '记录中暂无待核对连接。实际用量仍需另行核对。',
              ),
            ],
          ],
        ],
      ),
    );
  }
}

String _message(String? code) => switch (code) {
  'invalid_source' => '练习地址无效。',
  'practice_not_found' => '没有找到这次练习，可能已被删除。',
  'save_status_changed' => '保存状态在读取期间发生变化，请重新读取。',
  'invalid_response' => '保存状态响应异常，未展示未经核对的结果。',
  _ => '暂时无法读取保存情况，请检查网络后重试。',
};
