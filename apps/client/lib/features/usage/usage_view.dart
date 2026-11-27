import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../history/history_view.dart' show historyTime;
import 'usage_controller.dart';
import 'usage_models.dart';

class AccountUsageView extends StatelessWidget {
  const AccountUsageView({
    super.key,
    required this.state,
    this.summary,
    this.errorCode,
    this.busy = false,
    this.accountBusy = false,
    this.showAccountStatus = false,
    this.onLoad,
    this.onRefresh,
    this.onConfirmAccount,
  });

  final UsageReadState state;
  final AccountUsageSummary? summary;
  final String? errorCode;
  final bool busy;
  final bool accountBusy;
  final bool showAccountStatus;
  final VoidCallback? onLoad;
  final VoidCallback? onRefresh;
  final VoidCallback? onConfirmAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = busy || accountBusy;
    final current = state == UsageReadState.ready ? summary : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SectionHeading('模型用量'),
        const SizedBox(height: 8),
        Text(
          '仅展示服务端已记录的语音与复盘 Token 统计，不保存或展示被删原话；实际账单与停费以供应商结算为准。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (showAccountStatus && accountBusy) ...[
          const StatusMessage('账号操作进行中，请稍候…', error: false),
          const SizedBox(height: 12),
        ],
        if (state == UsageReadState.idle)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onLoad,
              child: const Text('查看本人用量'),
            ),
          ),
        if (state == UsageReadState.reading)
          Semantics(liveRegion: true, child: const Text('正在读取本人用量…')),
        if (state == UsageReadState.aborted) ...[
          const StatusMessage('登录状态已变化，旧用量记录已清除。', error: true),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onConfirmAccount,
              child: const Text('重新确认账号'),
            ),
          ),
        ],
        if (state == UsageReadState.failed ||
            state == UsageReadState.unavailable) ...[
          StatusMessage(_accountErrorMessage(errorCode), error: true),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onRefresh,
              child: const Text('重试读取用量'),
            ),
          ),
        ],
        if (current != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onRefresh,
              child: const Text('刷新用量'),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText('核对时间：${historyTime(current.checkedAt)}'),
          const SizedBox(height: 4),
          SelectableText(
            current.latestRecordedAt == null
                ? '暂无已记录的模型用量。'
                : '最近入账：${historyTime(current.latestRecordedAt!)}',
          ),
          if (current.connectionPendingCount > 0) ...[
            const SizedBox(height: 12),
            Text(
              '仍有 ${current.connectionPendingCount} 条语音连接终止状态待核对，可能存在尚未入账的上游用量。',
            ),
          ],
          const SizedBox(height: 16),
          _VoiceBucketBlock(title: '普通练习语音', bucket: current.voiceOrdinary),
          const SizedBox(height: 12),
          _VoiceBucketBlock(title: '逐句重练语音', bucket: current.voiceRehearsal),
          const SizedBox(height: 12),
          _ReviewBucketBlock(title: '会后复盘与重练评价', bucket: current.review),
          if (current.assistance case final bucket?
              when bucket.attemptCount > 0) ...[
            const SizedBox(height: 12),
            _ReviewBucketBlock(title: '主动求助', bucket: bucket),
          ],
          if (current.deletedPracticeCount > 0) ...[
            const SizedBox(height: 12),
            Text(
              '已删除练习共 ${current.deletedPracticeCount} 条；脱敏用量继续保留以供核账，不提供原话入口。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ],
    );
  }
}

class PracticeUsageView extends StatelessWidget {
  const PracticeUsageView({
    super.key,
    required this.state,
    this.summary,
    this.errorCode,
    this.busy = false,
    this.accountBusy = false,
    this.onLoad,
    this.onRefresh,
    this.onConfirmAccount,
  });

  final UsageReadState state;
  final PracticeUsageSummary? summary;
  final String? errorCode;
  final bool busy;
  final bool accountBusy;
  final VoidCallback? onLoad;
  final VoidCallback? onRefresh;
  final VoidCallback? onConfirmAccount;

  @override
  Widget build(BuildContext context) {
    final blocked = busy || accountBusy;
    final current = state == UsageReadState.ready ? summary : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state == UsageReadState.idle)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onLoad,
              child: const Text('查看本次用量'),
            ),
          ),
        if (state == UsageReadState.reading)
          Semantics(liveRegion: true, child: const Text('正在读取本次用量…')),
        if (state == UsageReadState.aborted) ...[
          const StatusMessage('登录状态已变化，旧用量记录已清除。', error: true),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onConfirmAccount,
              child: const Text('重新确认账号'),
            ),
          ),
        ],
        if (state == UsageReadState.failed ||
            state == UsageReadState.unavailable) ...[
          StatusMessage(_practiceErrorMessage(errorCode), error: true),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onRefresh,
              child: const Text('重试读取本次用量'),
            ),
          ),
        ],
        if (current != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: blocked ? null : onRefresh,
              child: const Text('刷新本次用量'),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            current.latestRecordedAt == null
                ? '本次练习暂无已入账的模型用量记录。'
                : '最近入账：${historyTime(current.latestRecordedAt!)}',
          ),
          const SizedBox(height: 12),
          _VoiceBucketBlock(title: '本次语音回复', bucket: current.voice),
          const SizedBox(height: 12),
          _ReviewBucketBlock(title: '本次复盘整理', bucket: current.review),
          if (current.assistance case final bucket?
              when bucket.attemptCount > 0) ...[
            const SizedBox(height: 12),
            _ReviewBucketBlock(title: '本次主动求助', bucket: bucket),
          ],
        ],
      ],
    );
  }
}

class _VoiceBucketBlock extends StatelessWidget {
  const _VoiceBucketBlock({required this.title, required this.bucket});

  final String title;
  final VoiceUsageBucket bucket;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final deleted = bucket.deletedResponseCount ?? 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
              bucket.responseCount == 0
                  ? '暂无已记录的语音回复。'
                  : '已记录 ${bucket.responseCount} 次回复 · 已知输入 ${bucket.knownInputTokens} Token（文本 ${bucket.knownInputTextTokens} / 音频 ${bucket.knownInputAudioTokens}） · 已知输出 ${bucket.knownOutputTokens} Token（文本 ${bucket.knownOutputTextTokens} / 音频 ${bucket.knownOutputAudioTokens}）',
            ),
            if (deleted > 0) ...[
              const SizedBox(height: 4),
              Text('含已删除练习 $deleted 次回复（原话已清除）。'),
            ],
            if (bucket.incompleteCount > 0) ...[
              const SizedBox(height: 4),
              Text('另有 ${bucket.incompleteCount} 次回复缺少总用量（不计作零）。'),
            ] else if (bucket.detailIncompleteCount > 0) ...[
              const SizedBox(height: 4),
              Text('其中 ${bucket.detailIncompleteCount} 次回复缺少文本或音频分项。'),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReviewBucketBlock extends StatelessWidget {
  const _ReviewBucketBlock({required this.title, required this.bucket});

  final String title;
  final ReviewUsageBucket bucket;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final deleted = bucket.deletedAttemptCount ?? 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
              bucket.attemptCount == 0
                  ? '暂无已记录的复盘模型尝试。'
                  : '已记录 ${bucket.attemptCount} 次尝试 · 已知输入 ${bucket.knownInputTokens} Token · 已知输出 ${bucket.knownOutputTokens} Token',
            ),
            if (deleted > 0) ...[
              const SizedBox(height: 4),
              Text('含已删除练习 $deleted 次尝试（原话已清除）。'),
            ],
            if (bucket.incompleteCount > 0) ...[
              const SizedBox(height: 4),
              Text('另有 ${bucket.incompleteCount} 次尝试结果或用量未知（不计作零）。'),
            ],
          ],
        ),
      ),
    );
  }
}

String _accountErrorMessage(String? code) => switch (code) {
  'invalid_source' => '账号地址无效，无法读取用量。',
  'invalid_response' => '用量响应异常，未展示未经核对的数据。',
  _ => '暂时无法读取本人用量，请检查网络后重试。',
};

String _practiceErrorMessage(String? code) => switch (code) {
  'invalid_source' => '练习地址无效，无法读取本次用量。',
  'practice_not_found' => '没有找到这次练习，可能已被删除。',
  'invalid_response' => '本次用量响应异常，未展示未经核对的数据。',
  _ => '暂时无法读取本次用量，请检查网络后重试。',
};
