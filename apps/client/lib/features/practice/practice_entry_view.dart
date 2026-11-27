import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../../design/practice_navigation.dart';
import '../account/account_models.dart';
import 'daily_topic.dart';
import 'practice_preparation_controller.dart';

class PracticeHomeView extends StatelessWidget {
  const PracticeHomeView({
    super.key,
    required this.difficulty,
    this.onStart,
    this.onTopicSelected,
    this.onSettings,
    this.onHistory,
    this.recovery = const SizedBox.shrink(),
  });
  final Difficulty difficulty;
  final VoidCallback? onStart;
  final ValueChanged<DailyTopic>? onTopicSelected;
  final VoidCallback? onSettings;
  final VoidCallback? onHistory;
  final Widget recovery;
  @override
  Widget build(BuildContext context) => AccountFrame(
    wide: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageIntro(title: '今天，聊点日常。', description: '从熟悉的小事开始，用自己的节奏说英语。'),
        Text(
          '当前难度：${difficulty.label}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          difficulty.description,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        PrimaryAction(label: '开始自由聊天', onPressed: onStart),
        const SizedBox(height: 12),
        Text('开始前会检查已有练习与服务状态。', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        Semantics(
          header: true,
          child: Text('日常话题', style: Theme.of(context).textTheme.titleMedium),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final width = constraints.maxWidth >= 520
                ? (constraints.maxWidth - spacing) / 2
                : constraints.maxWidth;
            final select = onTopicSelected;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final topic in DailyTopic.values)
                  SizedBox(
                    width: width,
                    child: OutlinedButton(
                      onPressed: select == null ? null : () => select(topic),
                      style: OutlinedButton.styleFrom(
                        alignment: AlignmentDirectional.centerStart,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          16,
                          12,
                          16,
                          12,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(topic.title),
                          const SizedBox(height: 4),
                          Text(topic.goal),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        PracticeNavigation(
          current: 'practice',
          onHistory: onHistory,
          onAccount: onSettings,
        ),
        const SizedBox(height: 32),
        recovery,
      ],
    ),
  );
}

class PracticePreparationView extends StatelessWidget {
  const PracticePreparationView({
    super.key,
    required this.difficulty,
    this.topic,
    this.phase = PreparationPhase.idle,
    this.busy = false,
    this.accountBusy = false,
    this.errorCode,
    this.onStart,
    this.onRetry,
    this.onCancel,
    this.onBack,
    this.onConfirmAccount,
    this.onEnterSession,
    this.recovery = const SizedBox.shrink(),
  });
  final Difficulty difficulty;
  final DailyTopic? topic;
  final PreparationPhase phase;
  final bool busy, accountBusy;
  final String? errorCode;
  final VoidCallback? onStart, onRetry, onCancel, onBack, onConfirmAccount;
  final VoidCallback? onEnterSession;
  final Widget recovery;
  @override
  Widget build(BuildContext context) => AccountFrame(
    wide: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: topic?.title ?? '准备一次自由聊天',
          description: topic?.goal ?? '先确认练习状态。进入这里不会打开麦克风。',
        ),
        Text(
          '本次难度：${difficulty.label}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        if (accountBusy) ...[
          const StatusMessage('账号操作进行中，请稍候…', error: false),
          const SizedBox(height: 12),
        ],
        if (phase == PreparationPhase.idle) ...[
          Text(
            topic == null
                ? '准备登记不代表已经连接 AI。只有语音服务就绪后，才能开始交流。'
                : '开始后会检查语音服务和麦克风。连接就绪时，你可以先说一句。',
          ),
          const SizedBox(height: 24),
          PrimaryAction(
            label: topic == null ? '开始准备' : '开始语音练习',
            busy: busy,
            onPressed: accountBusy ? null : onStart,
          ),
          const SizedBox(height: 24),
          recovery,
        ] else ...[
          StatusMessage(
            _message(phase, errorCode),
            error:
                phase == PreparationPhase.blocked ||
                phase == PreparationPhase.uncertain,
          ),
          if (phase == PreparationPhase.uncertain)
            OutlinedButton(
              onPressed: busy || accountBusy ? null : onRetry,
              child: const Text('确认原准备结果'),
            ),
          if (phase == PreparationPhase.reserved) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: accountBusy ? null : onEnterSession,
              child: const Text('进入通话'),
            ),
            const SizedBox(height: 8),
            Text(
              '进入后会先结束这次准备，再打开麦克风开始练习。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (phase == PreparationPhase.preparing ||
              phase == PreparationPhase.reserved ||
              phase == PreparationPhase.uncertain) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: accountBusy ? null : onCancel,
              child: const Text('取消准备'),
            ),
          ],
          if (errorCode == 'account_changed' || errorCode == 'unauthorized')
            OutlinedButton(
              onPressed: accountBusy ? null : onConfirmAccount,
              child: const Text('重新确认账号'),
            ),
        ],
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: accountBusy ? null : onBack,
          child: const Text('返回练习'),
        ),
      ],
    ),
  );
}

String _message(PreparationPhase phase, String? error) => switch (phase) {
  PreparationPhase.idle => '',
  PreparationPhase.preparing => '正在登记准备，尚未打开麦克风。',
  PreparationPhase.reserved => '准备已登记，尚未启动语音。你可以取消准备或返回练习。',
  PreparationPhase.releasing => '正在取消未开始的准备…',
  PreparationPhase.stopped => '这次准备已停止，未启动语音。',
  PreparationPhase.uncertain => '准备结果尚未确认。请确认原准备结果，不会自动重新创建。',
  PreparationPhase.blocked => switch (error) {
    'realtime_unavailable' => '实时语音尚未就绪，暂时无法开始练习。',
    'account_changed' || 'unauthorized' => '当前登录需要重新确认。确认后请重新查看练习状态。',
    'practice_in_progress' => '已有练习占用，请返回练习查看当前状态。',
    _ => '准备暂时无法继续，请返回练习查看当前状态。',
  },
};
