import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../account/account_models.dart';
import '../practice/practice_models.dart';
import 'rehearsal_controller.dart';
import 'rehearsal_models.dart';

class RehearsalView extends StatelessWidget {
  const RehearsalView({
    super.key,
    required this.state,
    this.target,
    this.preparation,
    this.difficulty,
    this.errorCode,
    this.readOnly = false,
    this.requiresPreferences = false,
    this.busy = false,
    this.accountBusy = false,
    this.onDifficulty,
    this.onConfirm,
    this.onReplay,
    this.onRefresh,
    this.onEnterSession,
    this.onDiscard,
    this.onBack,
    this.onHistory,
    this.onPractice,
    this.onConfirmAccount,
    this.onSettings,
  });
  final RehearsalState state;
  final RehearsalTarget? target;
  final PracticePreparation? preparation;
  final Difficulty? difficulty;
  final String? errorCode;
  final bool readOnly, busy, accountBusy, requiresPreferences;
  final ValueChanged<Difficulty>? onDifficulty;
  final VoidCallback? onConfirm,
      onReplay,
      onRefresh,
      onEnterSession,
      onDiscard,
      onBack,
      onHistory,
      onPractice,
      onConfirmAccount,
      onSettings;
  @override
  Widget build(BuildContext context) {
    final blocked = busy || accountBusy;
    final identity =
        state == RehearsalState.aborted ||
        {'account_changed', 'unauthorized'}.contains(errorCode);
    final current =
        identity ||
            state == RehearsalState.reading ||
            state == RehearsalState.failed
        ? null
        : target;
    final text = Theme.of(context).textTheme;
    return AccountFrame(
      wide: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PageIntro(
            title: readOnly ? '这次重练的目标' : '练这一句',
            description: readOnly
                ? '回看本次独立重练所确认的来源和目标。'
                : '先确认要练习的内容，再登记一次独立准备。',
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            header: true,
            child: Text(_status, style: text.titleLarge),
          ),
          if (accountBusy) ...[
            const SizedBox(height: 12),
            const StatusMessage('账号操作进行中，请稍候…', error: false),
          ],
          if (busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (errorCode != null) ...[
            const SizedBox(height: 16),
            StatusMessage(_message(errorCode!), error: true),
          ],
          if (current != null) ...[
            const SizedBox(height: 24),
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _section(context, '来源完整原句', current.sourceText),
                  _section(context, '本次关注的片段', current.exactQuote),
                  _section(
                    context,
                    current.kind == 'correction'
                        ? '纠错建议'
                        : current.kind == 'polish'
                        ? '表达更自然'
                        : '拓展表达',
                    current.suggestion,
                  ),
                  _section(context, '为什么这样说', current.explanation),
                  if (current.contextBefore.isNotEmpty) ...[
                    Text('原对话中的前文', style: text.titleMedium),
                    const SizedBox(height: 8),
                    for (final raw in current.contextBefore) ...[
                      Text(
                        raw['role'] == 'user'
                            ? '你'
                            : raw['ledger'] == 'playback'
                            ? 'AI · 已报告播放片段'
                            : 'AI · 原对话文字',
                        style: text.labelLarge,
                      ),
                      Text(raw['text'] as String),
                      const SizedBox(height: 12),
                    ],
                  ],
                  const Text('保留原来的交流意图，可以用自己的正确说法表达。'),
                ],
              ),
            ),
          ],
          if (!identity &&
              !readOnly &&
              !requiresPreferences &&
              state == RehearsalState.ready &&
              current != null) ...[
            const SizedBox(height: 24),
            Text('本次难度', style: text.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final value in Difficulty.values)
                  ChoiceChip(
                    label: Text(value.label),
                    selected: difficulty == value,
                    onSelected: blocked || onDifficulty == null
                        ? null
                        : (_) => onDifficulty!(value),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('只用于这次重练，不更改日常偏好。'),
            const SizedBox(height: 24),
            PrimaryAction(
              label: '确认并准备',
              onPressed: blocked || difficulty == null ? null : onConfirm,
            ),
            const SizedBox(height: 12),
            const Text('这会登记一条独立练习记录。语音尚未开启。'),
          ],
          if (!identity &&
              !readOnly &&
              requiresPreferences &&
              current != null) ...[
            const SizedBox(height: 24),
            const Text('请先设置日常难度，再从原复盘回来确认这次重练。'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: blocked ? null : onSettings,
              child: const Text('去设置难度'),
            ),
          ],
          if (!identity && state == RehearsalState.unconfirmed) ...[
            const SizedBox(height: 24),
            const Text('尚未确认服务器是否已登记。确认原请求不会另建一次准备。'),
            const SizedBox(height: 16),
            PrimaryAction(
              label: '确认上次准备请求',
              onPressed: blocked ? null : onReplay,
            ),
          ],
          if (!identity &&
              preparation != null &&
              [
                RehearsalState.prepared,
                RehearsalState.discarding,
                RehearsalState.cancelled,
              ].contains(state)) ...[
            const SizedBox(height: 24),
            Text(
              '本次难度：${preparation!.configuration.effectiveDifficulty.label}',
            ),
            const SizedBox(height: 8),
            Text(
              state == RehearsalState.cancelled
                  ? '这条取消记录仍可在练习记录中回看。'
                  : preparation!.status == PracticeStatus.created &&
                        preparation!.connectionEpoch == 0
                  ? '语音尚未开启。未结束的准备可在练习页查看和处理。'
                  : '本次练习状态已变化，请查看本次记录或当前练习。',
            ),
            if (!readOnly &&
                state == RehearsalState.prepared &&
                preparation!.status == PracticeStatus.created &&
                preparation!.connectionEpoch == 0 &&
                onEnterSession != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: blocked ? null : onEnterSession,
                child: const Text('进入重练通话'),
              ),
              const SizedBox(height: 8),
              Text('进入后才连接语音并打开麦克风，本次作为独立重练记录保存与计量。', style: text.bodySmall),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton(
                  onPressed: blocked ? null : onHistory,
                  child: const Text('查看本次记录'),
                ),
                if (onDiscard != null)
                  OutlinedButton(
                    onPressed: blocked ? null : onDiscard,
                    child: const Text('放弃本次准备'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (identity)
                OutlinedButton(
                  onPressed: blocked ? null : onConfirmAccount,
                  child: const Text('重新确认账号'),
                )
              else if (!busy &&
                  ![
                    RehearsalState.unconfirmed,
                    RehearsalState.prepared,
                    RehearsalState.cancelled,
                  ].contains(state))
                OutlinedButton(
                  onPressed: blocked ? null : onRefresh,
                  child: const Text('重新读取目标'),
                ),
              OutlinedButton(
                onPressed: accountBusy ? null : onBack,
                child: Text(readOnly ? '返回重练详情' : '返回原复盘'),
              ),
              if (!readOnly)
                TextButton(
                  onPressed: blocked ? null : onPractice,
                  child: const Text('查看当前练习'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String get _status => switch (state) {
    RehearsalState.idle || RehearsalState.reading => '正在核对重练来源…',
    RehearsalState.ready => '本次重练目标',
    RehearsalState.creating => '正在登记重练准备…',
    RehearsalState.unconfirmed => '上次准备结果待确认',
    RehearsalState.prepared =>
      preparation?.status == PracticeStatus.created &&
              preparation?.connectionEpoch == 0
          ? '已登记重练准备'
          : '本次准备状态已变化',
    RehearsalState.discarding => '正在放弃本次准备…',
    RehearsalState.cancelled => '本次准备已取消',
    RehearsalState.failed => '重练目标暂不可用',
    RehearsalState.aborted => '需要重新确认账号',
  };
}

Widget _section(BuildContext context, String title, String body) => Padding(
  padding: const EdgeInsets.only(bottom: 24),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Text(body),
    ],
  ),
);
String _message(String code) => switch (code) {
  'account_changed' || 'unauthorized' => '当前账号需要重新确认，旧目标已撤下。',
  'preferences_required' => '请先在个人设置中选择日常难度，再返回原复盘确认重练。',
  'realtime_unavailable' => '语音服务尚未就绪，本次准备未登记。可以稍后重新读取目标。',
  'rehearsal_source_changed' ||
  'practice_not_found' ||
  'rehearsal_item_not_found' ||
  'rehearsal_not_found' ||
  'review_job_not_found' => '来源已变化、被删除或暂不可用，请返回原记录核对。',
  'practice_in_progress' ||
  'connection_in_progress' => '已有练习或连接尚未安全结束，请先查看当前练习。',
  'rehearsal_timeout' => '这次请求超时。如有待确认准备，请确认原请求。',
  'invalid_source' => '重练地址无效，请返回练习记录。',
  'invalid_response' => '服务响应未通过核对。如有待确认准备，请确认原请求。',
  'idempotency_conflict' => '原请求与当前状态不一致，请返回查看当前练习。',
  _ => '这次操作未完成，请检查网络并明确重试。当前登录仍保留。',
};
