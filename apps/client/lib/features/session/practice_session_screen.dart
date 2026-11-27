import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../account/account_controller.dart';
import '../conversation/conversation_models.dart';
import '../practice/daily_topic.dart';
import '../practice/practice_completion_models.dart';
import '../realtime/practice_media_controller.dart';
import '../realtime/practice_media_providers.dart';
import '../rehearsal/rehearsal_models.dart';
import '../rehearsal/rehearsal_providers.dart';
import 'practice_session_view.dart';
import 'session_assistance.dart';

/// The live practice page. It owns nothing about the provider protocol: it only
/// starts one media attempt, renders the coordinator's real state and forwards
/// explicit user actions (mute, resume playback, end).
class PracticeSessionScreen extends ConsumerStatefulWidget {
  const PracticeSessionScreen({super.key, this.rehearsal, this.topicLaunch});

  final RehearsalSessionLaunch? rehearsal;
  final TopicSessionLaunch? topicLaunch;

  @override
  ConsumerState<PracticeSessionScreen> createState() =>
      _PracticeSessionScreenState();
}

class _PracticeSessionScreenState extends ConsumerState<PracticeSessionScreen> {
  bool _started = false;
  bool _leaving = false;
  bool _cancelling = false;
  late bool _subtitlesVisible;
  late bool _chineseHintsVisible;
  SessionAssistance? _assistance;
  bool _assistanceOpen = false;
  bool _choosingTranslation = false;

  @override
  void initState() {
    super.initState();
    // The stored preference only seeds the initial state; the in-call toggle is
    // session-scoped and never writes back to the account.
    final preferences = ref
        .read(accountControllerProvider)
        .session
        ?.preferences;
    _subtitlesVisible = preferences?.subtitleDefault ?? true;
    _chineseHintsVisible = preferences?.chineseHintsEnabled ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginIfIdle());
  }

  void _beginIfIdle() {
    if (!mounted || _started) return;
    final controller = ref.read(practiceMediaProvider);
    if (controller == null || !controller.repository.hasCurrentAccount) return;
    if (controller.phase != PracticeMediaPhase.idle) return;
    final topicLaunch = widget.topicLaunch;
    if (topicLaunch != null &&
        topicLaunch.accountId !=
            controller.repository.accountId.toLowerCase()) {
      return;
    }
    final rehearsalLaunch = widget.rehearsal;
    if (rehearsalLaunch != null) {
      if (rehearsalLaunch.accountId !=
          controller.repository.accountId.toLowerCase()) {
        return;
      }
      _started = true;
      unawaited(controller.begin(preparation: rehearsalLaunch.preparation));
      return;
    }
    _started = true;
    unawaited(
      controller.begin(
        topic: topicLaunch?.topic,
        difficulty:
            topicLaunch?.difficulty ??
            ref.read(accountControllerProvider).session?.preferences.difficulty,
      ),
    );
  }

  /// Every action re-checks the current page, the signed-in identity and the
  /// exact controller instance before touching media or navigating.
  bool _canAct(PracticeMediaController controller) {
    if (!mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final account = ref.read(accountControllerProvider);
    return account.phase == SessionPhase.signedIn &&
        account.session?.user.id == controller.repository.accountId &&
        controller.repository.hasCurrentAccount &&
        identical(ref.read(practiceMediaProvider), controller);
  }

  String _learnerVersion(PracticeMediaController controller) => [
    for (final turn
        in controller.conversation?.turns ?? const <ConversationTurn>[])
      if (turn.role == ConversationRole.user && turn.isFinal)
        '${turn.turnId}:${turn.revision}',
  ].join('/');

  bool _canAsk(PracticeMediaController controller) =>
      _canAct(controller) &&
      controller.phase == PracticeMediaPhase.active &&
      !controller.interruptionNeedsEnd &&
      controller.connection != null;

  bool _sourceIsCurrent(
    PracticeMediaController controller,
    ConversationTurn selected,
  ) =>
      controller.conversation?.turns.any(
        (turn) =>
            turn.turnId == selected.turnId &&
            turn.revision == selected.revision &&
            turn.isFinal,
      ) ??
      false;

  void _askForAssistance(
    PracticeMediaController controller, {
    ConversationTurn? source,
  }) {
    if (!_canAsk(controller)) return;
    if (source != null && !_sourceIsCurrent(controller, source)) return;
    if (source == null && controller.hasPendingAssistanceInput) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在保存刚才那句，请稍后再求助。')));
      return;
    }
    final existing = _assistance;
    if (existing != null &&
        existing.sourceTurn?.turnId == source?.turnId &&
        existing.sourceTurn?.revision == source?.revision &&
        existing.stillCurrent() &&
        !existing.canStartOver) {
      unawaited(existing.revalidateResult());
      setState(() {
        _choosingTranslation = false;
        _assistanceOpen = true;
      });
      return;
    }
    final connection = controller.connection!;
    final version = _learnerVersion(controller);
    final form = SessionAssistance(
      api: controller.repository.api,
      accountId: controller.repository.accountId,
      connection: connection,
      sourceTurn: source,
      stillCurrent: () =>
          _canAsk(controller) &&
          controller.connection?.id == connection.id &&
          controller.connection?.epoch == connection.epoch &&
          (source == null
              ? !controller.hasPendingAssistanceInput &&
                    _learnerVersion(controller) == version
              : _sourceIsCurrent(controller, source)),
    );
    _assistance?.dispose();
    setState(() {
      _assistance = form;
      _assistanceOpen = true;
      _choosingTranslation = false;
    });
    unawaited(form.start());
  }

  void _closeAssistance() {
    if (!mounted) return;
    setState(() {
      _assistanceOpen = false;
      _choosingTranslation = false;
    });
  }

  @override
  void dispose() {
    _assistance?.dispose();
    super.dispose();
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    // The product always runs under GoRouter; the plain Navigator branch keeps
    // the page testable without a router and behaves the same way.
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      Navigator.of(context).maybePop();
      return;
    }
    if (router.canPop()) {
      context.pop();
    } else if (widget.rehearsal case final rehearsal?) {
      context.go('/practice/${rehearsal.target.sourceSessionId}/review');
    } else {
      context.go('/practice');
    }
  }

  /// Cancelling before the first confirmed media is not "ending a practice":
  /// it stops the attempt, and only then leaves the page.
  Future<void> _cancelAttempt(PracticeMediaController controller) async {
    if (_cancelling || !_canAct(controller)) return;
    _cancelling = true;
    try {
      await controller.stop(reason: 'user_cancelled');
    } finally {
      _cancelling = false;
    }
    if (mounted) _leave();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountControllerProvider);
    final controller = ref.watch(practiceMediaProvider);
    if (controller == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '当前登录已变化，这次练习无法继续。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => context.go('/practice'),
                    child: const Text('返回练习'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final rehearsal = widget.rehearsal;
    final difficulty =
        controller.practice?.configuration.effectiveDifficulty ??
        rehearsal?.preparation.configuration.effectiveDifficulty ??
        widget.topicLaunch?.difficulty ??
        account.session?.preferences.difficulty;
    if (difficulty == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final practiceId = controller.practice?.id;
        final topic = controller.practice?.configuration.topic;
        final completion = controller.practiceCompletion;
        final closed = controller.phase == PracticeMediaPhase.localClosed;
        final sealed =
            completion?.summary?.status == PracticeCompletionStatus.sealed;
        final turns =
            controller.conversation?.turns ?? const <ConversationTurn>[];
        final form = _assistance;
        final canShowAssistance =
            _assistanceOpen && form != null && form.stillCurrent();
        final canAsk = _canAsk(controller);
        final showSelection = canAsk && _choosingTranslation;
        return PracticeSessionView(
          difficulty: difficulty,
          phase: controller.phase,
          playback: controller.playback,
          muted: controller.muted,
          rehearsalQuote: rehearsal?.target.exactQuote,
          rehearsalSuggestion: rehearsal?.target.suggestion,
          topicTitle: topic?.title ?? widget.topicLaunch?.topic.title,
          chineseOpeningHint: rehearsal == null
              ? topic?.goal ?? '可以先说一件今天发生的小事。'
              : null,
          chineseHintsVisible: _chineseHintsVisible,
          interruptionNeedsEnd: controller.interruptionNeedsEnd,
          errorCode: controller.errorCode,
          turns: turns,
          subtitlesVisible: _subtitlesVisible,
          speechPace: controller.speechPace,
          showSlowPaceStatus:
              !canShowAssistance &&
              !showSelection &&
              controller.supportsSlowPaceRequest,
          onRequestSlowPace:
              canShowAssistance ||
                  showSelection ||
                  !canAsk ||
                  !controller.canRequestSlowPace
              ? null
              : () {
                  if (_canAsk(controller)) {
                    controller.requestSlowPace();
                  }
                },
          showTakeOverAction:
              !canShowAssistance &&
              !showSelection &&
              controller.hasInterruptibleReply,
          onTakeOverTurn:
              canShowAssistance ||
                  showSelection ||
                  !canAsk ||
                  !controller.canTakeOverTurn
              ? null
              : () {
                  if (_canAsk(controller)) {
                    controller.requestTurnTakeover();
                  }
                },
          onAskForStarter: canShowAssistance || showSelection || !canAsk
              ? null
              : () => _askForAssistance(controller),
          onChooseTranslation: canShowAssistance || showSelection || !canAsk
              ? null
              : () {
                  if (_canAsk(controller)) {
                    setState(() => _choosingTranslation = true);
                  }
                },
          assistancePanel: showSelection
              ? TranslationSelectionPanel(
                  turns: turns,
                  onSelect: (source) =>
                      _askForAssistance(controller, source: source),
                  onClose: _closeAssistance,
                )
              : canShowAssistance
              ? ListenableBuilder(
                  listenable: form,
                  builder: (context, _) => AssistanceResultPanel(
                    heading: form.heading,
                    result: form.result,
                    sourceText: form.sourceTurn?.text,
                    message: form.message,
                    actionLabel: form.actionLabel,
                    onAction: () => unawaited(form.performAction()),
                    onClose: _closeAssistance,
                  ),
                )
              : null,
          completion: completion?.summary,
          completionPending: controller.completionHasPendingWork,
          completionErrorCode: controller.completionErrorCode,
          onToggleMute: controller.phase == PracticeMediaPhase.active
              ? () {
                  if (_canAct(controller)) {
                    controller.setMuted(!controller.muted);
                  }
                }
              : null,
          onResumePlayback: () {
            if (_canAct(controller)) unawaited(controller.resumePlayback());
          },
          onEnd: () {
            if (_canAct(controller)) unawaited(controller.end());
          },
          onRetryCompletion: () {
            if (_canAct(controller)) unawaited(controller.retryCompletion());
          },
          onViewReview:
              closed && sealed && rehearsal != null && practiceId != null
              ? () {
                  if (!_canAct(controller)) return;
                  context.push('/practice/$practiceId/review?from=history');
                }
              : null,
          onViewRecord: closed && practiceId != null
              ? () {
                  if (!_canAct(controller)) return;
                  context.push('/practice/$practiceId/save-status');
                }
              : null,
          onBackToSourceReview: closed && rehearsal != null
              ? () {
                  if (!_canAct(controller)) return;
                  context.go(
                    '/practice/${rehearsal.target.sourceSessionId}/review',
                  );
                }
              : null,
          onRehearseAgain:
              closed &&
                  rehearsal != null &&
                  !controller.completionHasPendingWork
              ? () {
                  if (!_canAct(controller)) return;
                  final target = rehearsal.target;
                  ref.invalidate(
                    rehearsalProvider((
                      sessionId: target.sourceSessionId,
                      itemId: target.itemId,
                    )),
                  );
                  context.go(
                    '/practice/${target.sourceSessionId}/rehearse/${target.itemId}',
                  );
                }
              : null,
          onGoPractice: closed && rehearsal != null
              ? () {
                  if (!_canAct(controller)) return;
                  context.go('/practice');
                }
              : null,
          onLeave: closed
              ? (rehearsal != null
                    ? () {
                        if (!_canAct(controller)) return;
                        context.go('/practice');
                      }
                    : _leave)
              : null,
          onCancelAttempt: _cancelling
              ? null
              : () => unawaited(_cancelAttempt(controller)),
          onToggleSubtitles:
              controller.phase == PracticeMediaPhase.active ||
                  controller.phase == PracticeMediaPhase.draining
              ? () => setState(() => _subtitlesVisible = !_subtitlesVisible)
              : null,
          onToggleChineseHints: controller.phase == PracticeMediaPhase.active
              ? () {
                  if (!_canAct(controller) ||
                      controller.phase != PracticeMediaPhase.active) {
                    return;
                  }
                  setState(() => _chineseHintsVisible = !_chineseHintsVisible);
                }
              : null,
        );
      },
    );
  }
}
