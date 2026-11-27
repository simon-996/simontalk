import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import '../account/account_models.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_completion_models.dart';
import '../realtime/practice_media_controller.dart';

/// A live practice is a full page: no bottom navigation can pull the user away
/// from an active microphone without an explicit end or leave.
///
/// Every label here derives from [PracticeMediaPhase], [MediaPlayback] and the
/// controller's error code. Nothing may render "listening" before the media and
/// protocol actually report active, and a local close is never described as an
/// upstream termination.
class PracticeSessionView extends StatelessWidget {
  const PracticeSessionView({
    super.key,
    required this.difficulty,
    required this.phase,
    required this.playback,
    required this.muted,
    this.rehearsalQuote,
    this.rehearsalSuggestion,
    this.topicTitle,
    this.chineseOpeningHint,
    this.chineseHintsVisible = true,
    this.interruptionNeedsEnd = false,
    this.errorCode,
    this.turns = const [],
    this.subtitlesVisible = true,
    this.completion,
    this.completionPending = false,
    this.completionErrorCode,
    this.onToggleMute,
    this.onResumePlayback,
    this.onEnd,
    this.onRetryCompletion,
    this.onViewReview,
    this.onViewRecord,
    this.onBackToSourceReview,
    this.onRehearseAgain,
    this.onGoPractice,
    this.onLeave,
    this.onCancelAttempt,
    this.onToggleSubtitles,
    this.onToggleChineseHints,
    this.speechPace = SessionSpeechPace.normal,
    this.showSlowPaceStatus = false,
    this.onRequestSlowPace,
    this.showTakeOverAction = false,
    this.onTakeOverTurn,
    this.onAskForStarter,
    this.onChooseTranslation,
    this.assistancePanel,
  });

  final Difficulty difficulty;
  final PracticeMediaPhase phase;
  final MediaPlayback playback;
  final bool muted;
  final String? rehearsalQuote;
  final String? rehearsalSuggestion;
  final String? topicTitle;
  final String? chineseOpeningHint;
  final bool chineseHintsVisible;
  final bool interruptionNeedsEnd;
  final String? errorCode;
  final List<ConversationTurn> turns;
  final bool subtitlesVisible;
  final PracticeCompletionSummary? completion;
  final bool completionPending;
  final String? completionErrorCode;
  final VoidCallback? onToggleMute;
  final VoidCallback? onResumePlayback;
  final VoidCallback? onEnd;
  final VoidCallback? onRetryCompletion;
  final VoidCallback? onViewReview;
  final VoidCallback? onViewRecord;
  final VoidCallback? onBackToSourceReview;
  final VoidCallback? onRehearseAgain;
  final VoidCallback? onGoPractice;
  final VoidCallback? onLeave;
  final VoidCallback? onCancelAttempt;
  final VoidCallback? onToggleSubtitles;
  final VoidCallback? onToggleChineseHints;
  final SessionSpeechPace speechPace;
  final bool showSlowPaceStatus;
  final VoidCallback? onRequestSlowPace;
  final bool showTakeOverAction;
  final VoidCallback? onTakeOverTurn;
  final VoidCallback? onAskForStarter;
  final VoidCallback? onChooseTranslation;
  final Widget? assistancePanel;

  bool get _isRehearsal => rehearsalQuote != null;
  bool get _closed => phase == PracticeMediaPhase.localClosed;
  bool get _live => phase == PracticeMediaPhase.active;
  bool get _draining => phase == PracticeMediaPhase.draining;
  bool get _interrupted => _live && interruptionNeedsEnd;

  /// Phases before the first confirmed media: there is no call to end, only an
  /// attempt to cancel, and the media coordinator still owns the release.
  bool get _starting =>
      phase == PracticeMediaPhase.idle ||
      phase == PracticeMediaPhase.preparing ||
      phase == PracticeMediaPhase.connecting ||
      phase == PracticeMediaPhase.configuring;

  @override
  Widget build(BuildContext context) {
    final compactActions =
        MediaQuery.sizeOf(context).width /
            MediaQuery.textScalerOf(context).scale(1) <
        250;
    final showOpeningHint =
        _live &&
        !_interrupted &&
        !muted &&
        errorCode == null &&
        playback == MediaPlayback.idle &&
        chineseHintsVisible &&
        chineseOpeningHint != null &&
        turns.every((turn) => turn.text.trim().isEmpty);
    final captions = showOpeningHint
        ? _ChineseOpeningHint(
            message: chineseOpeningHint!,
            subtitlesVisible: subtitlesVisible,
          )
        : subtitlesVisible
        ? _TranscriptList(
            turns: turns,
            phase: phase,
            interruptionNeedsEnd: _interrupted,
          )
        : const _SubtitlesHidden();
    final panel = assistancePanel;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isRehearsal ? '重练：这一句表达' : topicTitle ?? '自由聊天'),
        centerTitle: false,
        automaticallyImplyLeading: false,
        actions: [
          if (_closed && onLeave != null)
            TextButton(onPressed: onLeave, child: const Text('返回练习')),
          if (_starting && onCancelAttempt != null)
            TextButton(onPressed: onCancelAttempt, child: const Text('关闭')),
          if (_live &&
              !_interrupted &&
              chineseOpeningHint != null &&
              onToggleChineseHints != null)
            IconButton(
              tooltip: chineseHintsVisible ? '关闭中文提示' : '开启中文提示',
              isSelected: chineseHintsVisible,
              icon: const Icon(Icons.lightbulb_outline),
              selectedIcon: const Icon(Icons.lightbulb),
              onPressed: onToggleChineseHints,
            ),
          if (!_closed && !_starting && onToggleSubtitles != null)
            if (compactActions)
              IconButton(
                onPressed: onToggleSubtitles,
                tooltip: subtitlesVisible ? '关闭英文字幕' : '开启英文字幕',
                icon: Icon(
                  subtitlesVisible
                      ? Icons.closed_caption_outlined
                      : Icons.closed_caption_disabled_outlined,
                ),
              )
            else
              TextButton(
                onPressed: onToggleSubtitles,
                child: Text(subtitlesVisible ? '字幕：开' : '字幕：关'),
              ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusHeader(
                    difficulty: difficulty,
                    phase: phase,
                    playback: playback,
                    muted: muted,
                    interruptionNeedsEnd: _interrupted,
                    errorCode: errorCode,
                    turns: turns,
                  ),
                  if (_isRehearsal && !_closed) ...[
                    const SizedBox(height: 12),
                    _RehearsalBanner(
                      quote: rehearsalQuote!,
                      suggestion: rehearsalSuggestion,
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_interrupted) ...[
                    StatusMessage(
                      muted ? '麦克风已关闭，请结束并复盘。' : '说完这句后，请结束并复盘。麦克风仍开启。',
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (errorCode != null && !_closed) ...[
                    StatusMessage(_errorMessage(errorCode!), error: true),
                    const SizedBox(height: 12),
                  ],
                  Expanded(
                    child: _closed
                        ? _SavedSection(
                            isRehearsal: _isRehearsal,
                            completion: completion,
                            pending: completionPending,
                            errorCode: completionErrorCode,
                            stopReason: errorCode,
                            onRetry: onRetryCompletion,
                            onViewReview: onViewReview,
                            onViewRecord: onViewRecord,
                            onBackToSourceReview: onBackToSourceReview,
                            onRehearseAgain: onRehearseAgain,
                            onGoPractice: onGoPractice,
                          )
                        : panel == null
                        ? captions
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: panel),
                              const Divider(height: 16),
                              Expanded(child: captions),
                            ],
                          ),
                  ),
                  if (playback == MediaPlayback.blocked &&
                      _live &&
                      !_interrupted) ...[
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: onResumePlayback,
                      child: const Text('继续播放'),
                    ),
                  ],
                  if (showTakeOverAction && _live && !_interrupted) ...[
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: muted ? null : onTakeOverTurn,
                      child: Text(muted ? '我来说（先开启麦克风）' : '我来说'),
                    ),
                  ],
                  if (_live &&
                      !_interrupted &&
                      (onRequestSlowPace != null ||
                          (showSlowPaceStatus &&
                              speechPace != SessionSpeechPace.normal) ||
                          onAskForStarter != null ||
                          onChooseTranslation != null))
                    Wrap(
                      spacing: 8,
                      children: [
                        if (showSlowPaceStatus &&
                            speechPace == SessionSpeechPace.slowing)
                          const TextButton(
                            onPressed: null,
                            child: Text('正在放慢语速…'),
                          )
                        else if (showSlowPaceStatus &&
                            speechPace == SessionSpeechPace.slow)
                          const TextButton(
                            onPressed: null,
                            child: Text('本场已放慢语速'),
                          )
                        else if (onRequestSlowPace != null)
                          TextButton(
                            onPressed: onRequestSlowPace,
                            child: const Text('说慢一点'),
                          ),
                        if (onAskForStarter != null)
                          TextButton(
                            onPressed: onAskForStarter,
                            child: const Text('给我一个英文开头'),
                          ),
                        if (onChooseTranslation != null)
                          TextButton(
                            onPressed: onChooseTranslation,
                            child: const Text('逐句翻译'),
                          ),
                      ],
                    ),
                  if (!_closed) ...[
                    const SizedBox(height: 16),
                    if (_live)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final muteButton = OutlinedButton(
                            onPressed: _interrupted && muted
                                ? null
                                : onToggleMute,
                            child: Text(
                              muted
                                  ? (_interrupted ? '麦克风已关闭' : '打开麦克风')
                                  : '静音麦克风',
                            ),
                          );
                          final endButton = FilledButton(
                            onPressed: onEnd,
                            child: const Text('结束并复盘'),
                          );
                          final scaledWidth =
                              constraints.maxWidth /
                              MediaQuery.textScalerOf(context).scale(1);
                          if (_interrupted && scaledWidth < 200) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                muteButton,
                                const SizedBox(height: 8),
                                endButton,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: muteButton),
                              const SizedBox(width: 12),
                              Expanded(child: endButton),
                            ],
                          );
                        },
                      )
                    else if (_draining)
                      Text(
                        '正在收尾：麦克风与播报已停止，请稍候。',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    else if (_starting) ...[
                      Text(
                        '连接确认前不会采集或播放音频。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: onCancelAttempt,
                        child: const Text('取消这次尝试'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.difficulty,
    required this.phase,
    required this.playback,
    required this.muted,
    required this.interruptionNeedsEnd,
    required this.errorCode,
    required this.turns,
  });
  final Difficulty difficulty;
  final PracticeMediaPhase phase;
  final MediaPlayback playback;
  final bool muted;
  final bool interruptionNeedsEnd;
  final String? errorCode;
  final List<ConversationTurn> turns;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = interruptionNeedsEnd
        ? '对话已中断，暂时无法继续'
        : _statusText(phase, playback, muted, errorCode, turns);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '本次难度：${difficulty.label}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(status, style: theme.textTheme.titleMedium),
            ],
          ),
        ),
        if (!interruptionNeedsEnd)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: const BorderRadius.all(Radius.circular(999)),
            ),
            child: Text(
              _phaseChip(phase),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _TranscriptList extends StatelessWidget {
  const _TranscriptList({
    required this.turns,
    required this.phase,
    required this.interruptionNeedsEnd,
  });
  final List<ConversationTurn> turns;
  final PracticeMediaPhase phase;
  final bool interruptionNeedsEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = [
      for (final turn in turns)
        if (turn.text.trim().isNotEmpty) turn,
    ];
    if (visible.isEmpty) {
      return Center(
        child: Text(
          interruptionNeedsEnd
              ? '本次已识别的对话会显示在这里。'
              : phase == PracticeMediaPhase.active
              ? '可以直接开口，也可以自然插话。'
              : '连接建立后，你和 AI 的话会显示在这里。',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.only(top: 8),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final turn = visible[visible.length - 1 - index];
        return _TurnBubble(turn: turn);
      },
    );
  }
}

class _ChineseOpeningHint extends StatelessWidget {
  const _ChineseOpeningHint({
    required this.message,
    required this.subtitlesVisible,
  });

  final String message;
  final bool subtitlesVisible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('中文提示', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(message),
              ],
            ),
          ),
        ),
        if (!subtitlesVisible)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: _SubtitlesHidden(),
          ),
      ],
    );
  }
}

class AssistanceResultPanel extends StatelessWidget {
  const AssistanceResultPanel({
    super.key,
    required this.heading,
    this.result,
    this.sourceText,
    this.message,
    this.actionLabel,
    this.onAction,
    this.onClose,
  });

  final String heading;
  final String? result, sourceText, message, actionLabel;
  final VoidCallback? onAction, onClose;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      SectionHeading(heading),
      const SizedBox(height: 12),
      if (result case final phrase?) SelectableText(phrase),
      if (message case final status?)
        Semantics(liveRegion: true, child: Text(status)),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        children: [
          if (actionLabel case final label?)
            OutlinedButton(onPressed: onAction, child: Text(label)),
          TextButton(onPressed: onClose, child: const Text('关闭提示')),
        ],
      ),
      if (sourceText case final original?) ...[
        const SizedBox(height: 12),
        Text('原文', style: Theme.of(context).textTheme.labelLarge),
        SelectableText(original),
      ],
    ],
  );
}

class TranslationSelectionPanel extends StatelessWidget {
  const TranslationSelectionPanel({
    super.key,
    required this.turns,
    required this.onSelect,
    required this.onClose,
  });

  final List<ConversationTurn> turns;
  final ValueChanged<ConversationTurn> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final english = RegExp(r'[A-Za-z]{2}');
    final options = turns.reversed.where((turn) {
      final text = turn.text.trim();
      return turn.isFinal && text.runes.length <= 400 && english.hasMatch(text);
    }).toList();
    return ListView.builder(
      itemCount: options.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeading('选择要翻译的话轮'),
              TextButton(onPressed: onClose, child: const Text('关闭提示')),
              if (options.isEmpty) const Text('暂无可翻译的最终英文话轮。'),
            ],
          );
        }
        final turn = options[index - 1];
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: () => onSelect(turn),
            style: OutlinedButton.styleFrom(
              alignment: AlignmentDirectional.centerStart,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(turn.role == ConversationRole.user ? '你' : 'AI'),
                Text(turn.text),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SubtitlesHidden extends StatelessWidget {
  const _SubtitlesHidden();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        '字幕已关闭，可随时在右上角打开。',
        style: theme.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _TurnBubble extends StatelessWidget {
  const _TurnBubble({required this.turn});
  final ConversationTurn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = turn.role == ConversationRole.user;
    final scheme = theme.colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: user ? scheme.primary : scheme.surfaceContainerLow,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        child: Text(
          turn.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: user ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _RehearsalBanner extends StatelessWidget {
  const _RehearsalBanner({required this.quote, this.suggestion});
  final String quote;
  final String? suggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '重练片段：$quote',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (suggestion != null && suggestion!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '参考说法：$suggestion',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge,
            ),
          ],
        ],
      ),
    );
  }
}

class _SavedSection extends StatelessWidget {
  const _SavedSection({
    required this.isRehearsal,
    required this.completion,
    required this.pending,
    required this.errorCode,
    required this.stopReason,
    required this.onRetry,
    required this.onViewReview,
    required this.onViewRecord,
    required this.onBackToSourceReview,
    required this.onRehearseAgain,
    required this.onGoPractice,
  });
  final bool isRehearsal;
  final PracticeCompletionSummary? completion;
  final bool pending;
  final String? errorCode;
  final String? stopReason;
  final VoidCallback? onRetry;
  final VoidCallback? onViewReview;
  final VoidCallback? onViewRecord;
  final VoidCallback? onBackToSourceReview;
  final VoidCallback? onRehearseAgain;
  final VoidCallback? onGoPractice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sealed = completion?.status == PracticeCompletionStatus.sealed;
    final complete =
        completion?.coverage == PracticeCompletionCoverage.complete;
    final headline = errorCode != null
        ? '结束保存暂时失败'
        : pending
        ? '正在保存本次记录…'
        : sealed && complete
        ? '本次记录已保存'
        : sealed
        ? '已保存，仍有内容缺失'
        : completion?.status == PracticeCompletionStatus.ending
        ? '已停止收音，等待保存回执'
        : switch (stopReason) {
            final reason? => _errorMessage(reason),
            null => '本机语音已停止',
          };
    final detail = errorCode != null
        ? '内容可能已部分收到。重试不会重复创建练习。'
        : sealed && !complete
        ? '缺失项已如实记录，可在记录页查看具体缺口。'
        : '本地释放不代表上游已停止；记录状态以服务器为准。';
    return ListView(
      children: [
        const SizedBox(height: 8),
        Text(headline, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(detail, style: theme.textTheme.bodySmall),
        if (isRehearsal) ...[
          const SizedBox(height: 8),
          Text(
            sealed
                ? '可在重练评价中查看原意与目标问题两项判断；缺少可靠转写时不会直接宣布已掌握。'
                : '本次重练作为独立练习记录保存，不覆盖来源复盘。',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
        if (errorCode != null || pending)
          OutlinedButton(
            onPressed: errorCode != null ? onRetry : null,
            child: const Text('重试保存'),
          ),
        if (onViewReview != null) ...[
          const SizedBox(height: 12),
          FilledButton(onPressed: onViewReview, child: const Text('查看重练评价')),
          if (onViewRecord != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onViewRecord,
              child: const Text('查看本次记录'),
            ),
          ],
        ] else if (onViewRecord != null) ...[
          const SizedBox(height: 12),
          FilledButton(onPressed: onViewRecord, child: const Text('查看本次记录')),
        ],
        if (onBackToSourceReview != null ||
            onRehearseAgain != null ||
            onGoPractice != null) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (onBackToSourceReview != null)
                OutlinedButton(
                  onPressed: onBackToSourceReview,
                  child: const Text('回原复盘'),
                ),
              if (onRehearseAgain != null)
                OutlinedButton(
                  onPressed: onRehearseAgain,
                  child: const Text('再练一次'),
                ),
              if (onGoPractice != null)
                TextButton(onPressed: onGoPractice, child: const Text('回到练习')),
            ],
          ),
        ],
      ],
    );
  }
}

String _phaseChip(PracticeMediaPhase phase) => switch (phase) {
  PracticeMediaPhase.idle => '准备',
  PracticeMediaPhase.preparing => '登记',
  PracticeMediaPhase.connecting => '连接',
  PracticeMediaPhase.configuring => '确认配置',
  PracticeMediaPhase.active => '通话中',
  PracticeMediaPhase.draining => '收尾',
  PracticeMediaPhase.localClosed => '已结束',
};

String _statusText(
  PracticeMediaPhase phase,
  MediaPlayback playback,
  bool muted,
  String? errorCode,
  List<ConversationTurn> turns,
) {
  if (errorCode != null &&
      phase != PracticeMediaPhase.active &&
      phase != PracticeMediaPhase.localClosed) {
    return _errorMessage(errorCode);
  }
  return switch (phase) {
    PracticeMediaPhase.idle => '尚未开始',
    PracticeMediaPhase.preparing => '正在登记本次练习…',
    PracticeMediaPhase.connecting => '正在连接语音，请稍候…',
    PracticeMediaPhase.configuring => '正在确认语音配置，尚未开始收音…',
    PracticeMediaPhase.active => switch (playback) {
      MediaPlayback.playing => '正在说',
      MediaPlayback.blocked => '需要点击继续播放',
      MediaPlayback.waiting => '正在想怎么回应',
      MediaPlayback.paused => muted ? '麦克风已关闭' : '已暂停播放',
      MediaPlayback.idle =>
        muted
            ? '麦克风已关闭'
            : turns.isNotEmpty && turns.last.role == ConversationRole.user
            ? (turns.last.isFinal ? '正在想怎么回应' : '在听，请继续')
            : '正在听你说',
    },
    PracticeMediaPhase.draining => '正在收尾，等待最后一句识别…',
    PracticeMediaPhase.localClosed => '本次练习已结束',
  };
}

String _errorMessage(String code) => switch (code) {
  'realtime_unavailable' => '实时语音尚未就绪，本次无法开始交流。',
  'practice_in_progress' => '已有练习尚未结束，请返回练习查看当前状态。',
  'microphone_denied' || 'no_device' => '无法使用麦克风，请检查浏览器权限后重试。',
  'connection_timeout' || 'connection_failed' => '连接没有建立，请稍后重试。',
  'configuration_timeout' => '语音配置没有确认，已停止本次尝试。',
  'device_lost' => '麦克风输入已中断，本次练习已停止。',
  'capture_failed' => '语音收音失败，本次练习已停止。',
  'playback_failed' => '语音播放失败，本次练习已停止。',
  'remote_media_ended' => '对方语音已中断，本次练习已停止。',
  'account_changed' || 'unauthorized' => '当前登录已变化，请重新确认账号。',
  'local_lease_expired' => '连接占用已到期，本次练习已停止。',
  'background' => '练习已暂停，媒体已释放。',
  'tail_unconfirmed' => '最后一句没有确认，已按边界结束。',
  _ => '本次练习已停止，原因已记录。',
};
