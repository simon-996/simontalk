import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../practice/practice_completion_models.dart';
import 'review_models.dart';
import 'review_page_controller.dart';

/// Pure reading surface. Preview fixtures never enter the connected screen.
class ReviewPageView extends StatelessWidget {
  const ReviewPageView({
    super.key,
    required this.state,
    this.completion,
    this.job,
    this.busy = false,
    this.accountBusy = false,
    this.errorCode,
    this.hasPendingAction = false,
    this.canRequestReview = false,
    this.canRetryGeneration = false,
    this.onRefresh,
    this.onRequestReview,
    this.onRetryGeneration,
    this.onRetryPending,
    this.onConfirmAccount,
    this.onBack,
    this.backLabel = '返回练习偏好',
    this.onReadSavedText,
    this.onLocateItem,
    this.onRehearseItem,
  });
  final ReviewPageState state;
  final PracticeCompletionSummary? completion;
  final ReviewJobSnapshot? job;
  final bool busy,
      accountBusy,
      hasPendingAction,
      canRequestReview,
      canRetryGeneration;
  final String backLabel;
  final String? errorCode;
  final VoidCallback? onReadSavedText;
  final ValueChanged<String>? onLocateItem;
  final ValueChanged<String>? onRehearseItem;
  final VoidCallback? onRefresh,
      onRequestReview,
      onRetryGeneration,
      onRetryPending,
      onConfirmAccount,
      onBack;

  @override
  Widget build(BuildContext context) {
    final identity = {'account_changed', 'unauthorized'}.contains(errorCode);
    final blocked = busy || accountBusy;
    final reading =
        state == ReviewPageState.readingSource ||
        state == ReviewPageState.readingReview;
    final visibleJob = identity || reading || busy || errorCode != null
        ? null
        : job;
    final visibleCompletion = identity || state == ReviewPageState.readingSource
        ? null
        : completion;
    final readySource =
        visibleCompletion?.status == PracticeCompletionStatus.sealed;
    final unavailable =
        state == ReviewPageState.unavailable ||
        state == ReviewPageState.aborted;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final gutter = constraints.maxWidth < 360
                ? 16.0
                : constraints.maxWidth < 840
                ? 24.0
                : 32.0;
            return SingleChildScrollView(
              key: const PageStorageKey('review-reading-scroll'),
              padding: EdgeInsets.all(gutter),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const PageIntro(
                        title: '练习复盘',
                        description: '回看本次表达，带走少量有依据的建议。',
                      ),
                      const SizedBox(height: 24),
                      if (accountBusy) ...[
                        const StatusMessage('账号操作进行中，请稍候…', error: false),
                        const SizedBox(height: 16),
                      ],
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          if (identity)
                            OutlinedButton(
                              onPressed: blocked ? null : onConfirmAccount,
                              child: const Text('重新确认账号'),
                            )
                          else if (!unavailable)
                            OutlinedButton(
                              onPressed: blocked || reading ? null : onRefresh,
                              child: Text(readySource ? '刷新复盘状态' : '刷新练习状态'),
                            ),
                          if (!identity && readySource)
                            OutlinedButton(
                              onPressed: blocked || reading
                                  ? null
                                  : onReadSavedText,
                              child: const Text('查看已保存文字'),
                            ),
                          if (!identity && readySource && hasPendingAction)
                            FilledButton(
                              onPressed: blocked || reading
                                  ? null
                                  : onRetryPending,
                              child: const Text('确认上次整理请求'),
                            )
                          else if (!identity &&
                              readySource &&
                              canRequestReview &&
                              errorCode == null)
                            FilledButton(
                              onPressed: blocked || reading
                                  ? null
                                  : onRequestReview,
                              child: const Text('整理表达建议'),
                            )
                          else if (!identity &&
                              readySource &&
                              canRetryGeneration &&
                              errorCode == null)
                            FilledButton(
                              onPressed: blocked || reading
                                  ? null
                                  : onRetryGeneration,
                              child: const Text('重试整理'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (visibleCompletion != null) ...[
                        Text(
                          '保存登记于 ${_date(visibleCompletion.acceptedAt)}',
                          style: textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          visibleCompletion.coverage ==
                                  PracticeCompletionCoverage.incomplete
                              ? '本次保存仍有缺口，建议仅基于已保存部分。'
                              : visibleCompletion.status ==
                                    PracticeCompletionStatus.sealed
                              ? '本次文字已保存。'
                              : '文字仍在保存。',
                        ),
                        const SizedBox(height: 16),
                      ],
                      Semantics(
                        liveRegion: true,
                        header: true,
                        child: Text(
                          _status(visibleJob),
                          style: textTheme.titleLarge,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _description(visibleJob),
                        style: textTheme.bodyMedium,
                      ),
                      if (errorCode != null) ...[
                        const SizedBox(height: 16),
                        StatusMessage(_error(errorCode!)),
                      ],
                      if (visibleJob?.status == ReviewJobStatus.succeeded) ...[
                        const SizedBox(height: 24),
                        SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (visibleJob!.result!.rehearsalEvaluation
                                  case final evaluation?) ...[
                                _RehearsalEvaluationView(
                                  evaluation: evaluation,
                                ),
                                if (visibleJob.result!.items.isNotEmpty) ...[
                                  Text('本次表达建议', style: textTheme.titleLarge),
                                  const SizedBox(height: 16),
                                ],
                              ],
                              for (final item in visibleJob.result!.items)
                                _ReviewItemCard(
                                  item: item,
                                  showRehearse: onRehearseItem != null,
                                  onRehearse: blocked || onRehearseItem == null
                                      ? null
                                      : () => onRehearseItem!(item.id),
                                  onLocate: blocked
                                      ? null
                                      : onLocateItem == null
                                      ? null
                                      : () => onLocateItem!(item.id),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 32),
                      const Text('建议基于本次识别文字，识别可能有遗漏。'),
                      const SizedBox(height: 8),
                      Text(
                        '复盘状态不能确认远端连接或费用已结束，可返回原练习状态查看记录。',
                        style: textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          onPressed: onBack,
                          child: Text(backLabel),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _status(ReviewJobSnapshot? current) {
    if (state == ReviewPageState.readingSource ||
        state == ReviewPageState.idle) {
      return '正在核对练习来源…';
    }
    if (state == ReviewPageState.readingReview || busy) return '正在处理复盘请求…';
    if (state == ReviewPageState.notSaved) return '尚未登记保存';
    if (state == ReviewPageState.saving) return '文字仍在保存';
    if (state == ReviewPageState.unavailable ||
        state == ReviewPageState.aborted) {
      return '这份复盘暂不可用';
    }
    if (hasPendingAction) return '上次整理请求尚未确认';
    if (errorCode != null) return '暂时无法读取复盘';
    return switch (current?.status) {
      ReviewJobStatus.queued => '建议已排队',
      ReviewJobStatus.running => '正在整理表达建议',
      ReviewJobStatus.retryWait => '建议整理稍后继续',
      ReviewJobStatus.blocked => '表达建议暂不可用',
      ReviewJobStatus.failed => '建议暂未生成',
      ReviewJobStatus.noEvaluableContent => '没有可评价的用户表达',
      ReviewJobStatus.noSuggestions => '本次未整理出建议',
      ReviewJobStatus.succeeded =>
        current!.result!.rehearsalEvaluation == null ? '本次表达建议' : '本次重练评价',
      ReviewJobStatus.invalidated => '这份复盘已失效',
      null => '尚未整理建议',
    };
  }

  String _description(ReviewJobSnapshot? current) {
    if (state == ReviewPageState.readingSource ||
        state == ReviewPageState.idle) {
      return '先核对当前账号与本次保存记录。';
    }
    if (state == ReviewPageState.readingReview || busy) {
      return '正在处理本次操作，请稍候。页面不会自动重复整理。';
    }
    if (state == ReviewPageState.notSaved || state == ReviewPageState.saving) {
      return '保存就绪后才能整理建议。可以稍后刷新练习状态。';
    }
    if (state == ReviewPageState.unavailable ||
        state == ReviewPageState.aborted) {
      return '请确认当前账号，或返回查看原练习状态。';
    }
    if (hasPendingAction) return '可以确认原请求的处理结果；不会另建一次生成尝试。';
    if (errorCode != null) return '旧建议已撤下。请按下方提示重新读取当前状态。';
    if (current?.outcomeUnknown == true) return '上次生成结果未知，已暂停重复生成。可刷新状态或联系维护者。';
    if ((current?.status == ReviewJobStatus.blocked ||
            current?.status == ReviewJobStatus.failed) &&
        current!.attemptCount >= 3) {
      return '已达到本次整理的尝试上限。可刷新状态或联系维护者。';
    }
    return switch (current?.status) {
      ReviewJobStatus.queued ||
      ReviewJobStatus.running ||
      ReviewJobStatus.retryWait => '可以稍后刷新查看最新状态，页面不会自动轮询或重复请求生成。',
      ReviewJobStatus.blocked => '当前整理能力尚未就绪。可以刷新状态，或在允许时明确重试整理。',
      ReviewJobStatus.failed => '对话文字已保存，建议暂未生成。可以刷新状态，或在允许时明确重试整理。',
      ReviewJobStatus.noEvaluableContent => '本次已保存文字中没有可用于评价的用户表达。',
      ReviewJobStatus.noSuggestions => '这是本次整理的有效空结果，不代表证明表达没有语言问题。',
      ReviewJobStatus.succeeded =>
        current!.result!.rehearsalEvaluation == null
            ? '原话、建议和解释逐项对应，可选择复制文字。'
            : '分别查看本次的意思表达和目标问题，两项判断均附有解释。可选择复制文字。',
      ReviewJobStatus.invalidated => '来源已失效，请返回查看原练习状态。',
      null => '你可以选择整理表达建议。刷新状态只会读取已有记录。',
    };
  }
}

class _RehearsalEvaluationView extends StatelessWidget {
  const _RehearsalEvaluationView({required this.evaluation});
  final RehearsalEvaluation evaluation;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _EvaluationAxisCard(
        title: '意思表达',
        status: switch (evaluation.intent.status) {
          RehearsalIntentStatus.conveyed => '本次已传达原意',
          RehearsalIntentStatus.changed => '本次原意有变化',
          RehearsalIntentStatus.insufficientEvidence => '意思表达的证据不足',
        },
        explanation: evaluation.intent.explanation,
        evidence: evaluation.intent.evidence,
      ),
      _EvaluationAxisCard(
        title: '目标问题',
        status: switch (evaluation.targetIssue.status) {
          RehearsalTargetIssueStatus.demonstrated => '本次已展示目标表达',
          RehearsalTargetIssueStatus.stillPresent => '目标问题本次仍在',
          RehearsalTargetIssueStatus.notDemonstrated => '本次未展示目标表达',
          RehearsalTargetIssueStatus.insufficientEvidence => '目标问题的证据不足',
        },
        explanation: evaluation.targetIssue.explanation,
        evidence: evaluation.targetIssue.evidence,
      ),
      const Text('评价只针对本次已保存表达，本次达到目标不等于长期掌握。未展示不等于失败，也不能据此判断已掌握；证据不足时暂不下结论。'),
      const SizedBox(height: 24),
    ],
  );
}

class _EvaluationAxisCard extends StatelessWidget {
  const _EvaluationAxisCard({
    required this.title,
    required this.status,
    required this.explanation,
    required this.evidence,
  });
  final String title, status, explanation;
  final List<RehearsalEvaluationEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 8),
              Text(status, style: theme.textTheme.titleSmall),
              const SizedBox(height: 16),
              Text(explanation),
              const SizedBox(height: 16),
              Text('本次精确引文', style: theme.textTheme.labelLarge),
              if (evidence.isEmpty) ...[
                const SizedBox(height: 8),
                const Text('暂无可用于这一判断的本次引文。'),
              ] else
                for (final quote in evidence) ...[
                  const SizedBox(height: 8),
                  Text(quote.exactQuote),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewItemCard extends StatelessWidget {
  const _ReviewItemCard({
    required this.item,
    this.onLocate,
    this.onRehearse,
    this.showRehearse = false,
  });
  final VoidCallback? onLocate, onRehearse;
  final bool showRehearse;
  final ReviewItem item;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = switch (item.kind) {
      ReviewItemKind.correction => '纠错建议',
      ReviewItemKind.polish => '表达更自然',
      ReviewItemKind.extension => '拓展表达',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(kind, style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 16),
              Text('你的原话', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(item.exactQuote),
              const SizedBox(height: 16),
              Text('表达建议', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(item.suggestion),
              const SizedBox(height: 16),
              Text('为什么这样说', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(item.explanation),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: onLocate,
                    child: const Text('定位到对话'),
                  ),
                  if (showRehearse)
                    OutlinedButton(
                      onPressed: onRehearse,
                      child: const Text('练这一句'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _date(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String _error(String code) => switch (code) {
  'account_changed' => '当前账号已变化，请重新确认账号后查看。',
  'unauthorized' => '登录已失效，请重新确认账号。',
  'invalid_source' => '练习地址无效，请返回练习偏好。',
  'practice_not_found' ||
  'source_invalidated' ||
  'review_input_invalid' ||
  'review_input_changed' => '这条练习来源已不可用，请返回查看原练习状态。',
  'idempotency_conflict' ||
  'review_retry_changed' => '请求状态已变化，请先刷新当前状态，再按允许的操作继续。',
  'invalid_response' => '服务响应异常，请刷新重试；仍有问题时请联系维护者。',
  'source_timeout' => '练习来源读取超时，请刷新重试。',
  'review_timeout' => '复盘请求超时，请刷新状态；如有待确认请求，可确认原请求。',
  _ => '暂时无法读取记录，请检查网络后重试。当前登录仍保留。',
};
