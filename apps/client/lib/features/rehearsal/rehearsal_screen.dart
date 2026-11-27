import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'rehearsal_controller.dart';
import 'rehearsal_models.dart';
import 'rehearsal_providers.dart';
import 'rehearsal_view.dart';

class RehearsalScreen extends ConsumerStatefulWidget {
  const RehearsalScreen({super.key, required this.sessionId, this.itemId});
  final String sessionId;
  final String? itemId;
  @override
  ConsumerState<RehearsalScreen> createState() => _RehearsalScreenState();
}

class _RehearsalScreenState extends ConsumerState<RehearsalScreen> {
  RehearsalController? _started;
  bool _isCurrentPage() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final path = GoRouter.of(context)
        .routeInformationProvider
        .value
        .uri
        .pathSegments;
    return path.length == (widget.itemId == null ? 3 : 4) &&
        path[0] == 'practice' &&
        path[1].toLowerCase() == widget.sessionId.toLowerCase() &&
        (widget.itemId == null
            ? path[2] == 'rehearsal-target'
            : path[2] == 'rehearse' &&
                  path[3].toLowerCase() == widget.itemId!.toLowerCase());
  }

  void _back() {
    if (!_isCurrentPage() || ref.read(accountControllerProvider).busy) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(
        widget.itemId == null
            ? '/history/${widget.sessionId}'
            : '/practice/${widget.sessionId}/review',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountControllerProvider);
    if (account.phase != SessionPhase.signedIn) {
      final failed = account.phase == SessionPhase.unreachable;
      return AccountFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageIntro(
              title: failed ? '暂时连接不上' : '正在恢复你的账号',
              description: '重练地址已保留，确认当前账号后再读取目标。',
            ),
            if (failed)
              PrimaryAction(
                label: '重新连接',
                onPressed: () {
                  if (!_isCurrentPage()) return;
                  final current = ref.read(accountControllerProvider);
                  if (current.phase == SessionPhase.unreachable &&
                      !current.busy) {
                    unawaited(
                      ref.read(accountControllerProvider.notifier).restore(),
                    );
                  }
                },
              ),
            OutlinedButton(onPressed: _back, child: const Text('返回原记录')),
          ],
        ),
      );
    }
    final c = ref.watch(
      rehearsalProvider((sessionId: widget.sessionId, itemId: widget.itemId)),
    );
    if (c != null && !identical(c, _started)) {
      _started = c;
      final difficulty = account.session?.preferences.difficulty;
      unawaited(
        Future<void>.microtask(() async {
          if (!mounted || !identical(c, _started)) return;
          if (difficulty != null) c.selectDifficulty(difficulty);
          await c.load();
        }),
      );
    }
    bool canAct({bool requireIdle = true}) {
      if (!_isCurrentPage() || c == null) return false;
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == c.accountId &&
          identical(
            c,
            ref.read(
              rehearsalProvider((
                sessionId: widget.sessionId,
                itemId: widget.itemId,
              )),
            ),
          ) &&
          (!requireIdle || !c.busy);
    }

    final displayedTarget = c?.target;
    final displayedDifficulty = c?.difficulty;
    final displayedPreparation = c?.preparation;
    bool hasTarget() =>
        canAct() &&
        displayedTarget != null &&
        identical(c?.target, displayedTarget);
    bool hasPreparation() =>
        canAct() &&
        displayedPreparation != null &&
        identical(c?.preparation, displayedPreparation);
    return RehearsalView(
      state: c?.state ?? RehearsalState.failed,
      target: c?.target,
      preparation: c?.preparation,
      readOnly: widget.itemId == null,
      requiresPreferences: account.session?.preferences.difficulty == null,
      difficulty: c?.difficulty,
      errorCode: c?.errorCode ?? (c == null ? 'invalid_source' : null),
      busy: c?.busy ?? false,
      accountBusy: account.busy,
      onDifficulty: c == null
          ? null
          : (value) {
              if (hasTarget()) c.selectDifficulty(value);
            },
      onConfirm:
          c?.canConfirm == true &&
              account.session?.preferences.difficulty != null
          ? () {
              if (hasTarget() &&
                  c!.canConfirm &&
                  c.difficulty == displayedDifficulty &&
                  ref
                          .read(accountControllerProvider)
                          .session
                          ?.preferences
                          .difficulty !=
                      null) {
                unawaited(c.confirm());
              }
            }
          : null,
      onReplay: c?.canReplay == true
          ? () {
              if (hasTarget() && c!.canReplay) unawaited(c.replay());
            }
          : null,
      onRefresh: c == null
          ? null
          : () {
              if (canAct()) unawaited(c.load());
            },
      onEnterSession:
          widget.itemId != null &&
              c?.state == RehearsalState.prepared &&
              displayedTarget != null &&
              displayedPreparation != null &&
              displayedPreparation.kind == 'rehearsal' &&
              displayedPreparation.status == PracticeStatus.created &&
              displayedPreparation.connectionEpoch == 0
          ? () {
              if (!hasTarget() ||
                  !hasPreparation() ||
                  c!.state != RehearsalState.prepared ||
                  displayedPreparation.status != PracticeStatus.created ||
                  displayedPreparation.connectionEpoch != 0) {
                return;
              }
              final launch = RehearsalSessionLaunch(
                accountId: c.accountId,
                preparation: displayedPreparation,
                target: displayedTarget,
              );
              if (context.canPop()) {
                context.pushReplacement('/practice/session', extra: launch);
              } else {
                context.go('/practice/session', extra: launch);
              }
            }
          : null,
      onDiscard: c?.canDiscard == true
          ? () {
              if (hasPreparation() && c!.canDiscard) unawaited(c.discard());
            }
          : null,
      onHistory: c?.preparation == null
          ? null
          : () {
              if (hasPreparation()) {
                context.push('/history/${displayedPreparation!.id}');
              }
            },
      onBack: c == null
          ? _back
          : () {
              if (canAct(requireIdle: false)) _back();
            },
      onPractice: () {
        if (canAct()) context.go('/practice');
      },
      onSettings: () {
        if (canAct()) context.push('/account');
      },
      onConfirmAccount: () {
        if (canAct()) {
          unawaited(ref.read(accountControllerProvider.notifier).restore());
        }
      },
    );
  }
}
