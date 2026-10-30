import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../account/account_controller.dart';
import '../realtime/practice_media_controller.dart';
import '../realtime/practice_media_providers.dart';
import 'practice_session_view.dart';

/// The live practice page. It owns nothing about the provider protocol: it only
/// starts one media attempt, renders the coordinator's real state and forwards
/// explicit user actions (mute, resume playback, end).
class PracticeSessionScreen extends ConsumerStatefulWidget {
  const PracticeSessionScreen({super.key});

  @override
  ConsumerState<PracticeSessionScreen> createState() =>
      _PracticeSessionScreenState();
}

class _PracticeSessionScreenState extends ConsumerState<PracticeSessionScreen> {
  bool _started = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginIfIdle());
  }

  void _beginIfIdle() {
    if (!mounted || _started) return;
    final controller = ref.read(practiceMediaProvider);
    if (controller == null || !controller.repository.hasCurrentAccount) return;
    if (controller.phase != PracticeMediaPhase.idle) return;
    _started = true;
    unawaited(
      controller.begin(
        difficulty: ref
            .read(accountControllerProvider)
            .session
            ?.preferences
            .difficulty,
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

  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/practice');
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountControllerProvider);
    final controller = ref.watch(practiceMediaProvider);
    if (controller == null) return const SizedBox.shrink();
    final difficulty =
        account.session?.preferences.difficulty ??
        controller.practice?.configuration.effectiveDifficulty;
    if (difficulty == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final practiceId = controller.practice?.id;
        final completion = controller.practiceCompletion;
        final closed = controller.phase == PracticeMediaPhase.localClosed;
        return PracticeSessionView(
          difficulty: difficulty,
          phase: controller.phase,
          playback: controller.playback,
          muted: controller.muted,
          errorCode: controller.errorCode,
          turns: controller.conversation?.turns ?? const [],
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
          onViewRecord: closed && practiceId != null
              ? () {
                  if (!_canAct(controller)) return;
                  context.push('/practice/$practiceId/save-status');
                }
              : null,
          onLeave: closed ? _leave : null,
        );
      },
    );
  }
}
