import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import '../review/review_providers.dart';
import '../practice/practice_providers.dart';
import '../practice/saved_practice_status_providers.dart';
import '../rehearsal/rehearsal_providers.dart';
import '../rehearsal/rehearsal_list_providers.dart';
import '../transcript/saved_transcript_providers.dart';
import 'deletion_controller.dart';
import 'deletion_view.dart';
import 'history_providers.dart';

class DeletionScreen extends ConsumerStatefulWidget {
  const DeletionScreen({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<DeletionScreen> createState() => _DeletionScreenState();
}

class _DeletionScreenState extends ConsumerState<DeletionScreen> {
  DeletionController? _started;
  bool _returning = false;
  void _keep() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/history/${widget.sessionId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountControllerProvider);
    if (account.phase != SessionPhase.signedIn) {
      return AccountFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageIntro(
              title: account.phase == SessionPhase.unreachable
                  ? '暂时连接不上'
                  : '正在恢复你的账号',
              description: '删除地址已保留，确认身份后仅核对范围。',
            ),
            if (account.phase == SessionPhase.unreachable)
              OutlinedButton(
                onPressed: () =>
                    ref.read(accountControllerProvider.notifier).restore(),
                child: const Text('重新连接'),
              ),
          ],
        ),
      );
    }
    final c = ref.watch(deletionProvider(widget.sessionId));
    if (c != null && !identical(c, _started)) {
      _started = c;
      unawaited(
        Future<void>.microtask(() async {
          if (mounted && identical(c, _started)) await c.load();
        }),
      );
    }
    if (c?.state == DeletionState.deleted && !_returning) {
      _returning = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || c!.receipt == null) return;
        ref.invalidate(historyProvider);
        ref.invalidate(reviewPageProvider);
        ref.invalidate(practiceReviewProvider);
        ref.invalidate(savedTranscriptProvider);
        ref.invalidate(savedPracticeStatusProvider);
        // End cached reading/target scopes, including retained readers and GETs.
        // Reservation/media lifecycles keep their independent safety state.
        ref.invalidate(practiceRecoveryProvider);
        ref.invalidate(rehearsalProvider);
        ref.invalidate(rehearsalEligibilityProvider);
        ref.invalidate(rehearsalListProvider);
        final receipt = c.receipt!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              receipt.connectionPending
                  ? '内容已删除，连接与用量仍待核对。'
                  : '已删除 ${receipt.recordCount} 条练习记录。',
            ),
          ),
        );
        context.go('/history');
      });
    }
    final displayedState = c?.state ?? DeletionState.failed;
    final displayedScope = c?.scope;
    final busy = (c?.busy ?? false) || account.busy;
    bool canAct() {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
      final path = GoRouter.of(context)
          .routeInformationProvider
          .value
          .uri
          .pathSegments;
      if (path.length != 3 ||
          path[0] != 'history' ||
          path[1].toLowerCase() != widget.sessionId.toLowerCase() ||
          path[2] != 'delete') {
        return false;
      }
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == account.session?.user.id &&
          identical(ref.read(deletionProvider(widget.sessionId)), c) &&
          (c == null ||
              current.session?.user.id == c.accountId &&
                  widget.sessionId.toLowerCase() == c.sessionId &&
                  !c.busy);
    }

    return PopScope(
      canPop: !busy,
      child: DeletionView(
        state: displayedState,
        scope: displayedScope,
        busy: busy,
        errorCode: c?.errorCode ?? (c == null ? 'invalid_source' : null),
        canReplay: c?.canReplay ?? false,
        onKeep: () {
          if (canAct() && c?.state != DeletionState.deleted) _keep();
        },
        onConfirm: () {
          if (canAct() &&
              displayedState == DeletionState.ready &&
              c?.state == DeletionState.ready &&
              displayedScope != null &&
              identical(c!.scope, displayedScope)) {
            unawaited(c.confirm());
          }
        },
        onLoad: () {
          if (canAct() && c?.state == DeletionState.failed) {
            unawaited(c!.load());
          }
        },
        onCheck: () {
          if (canAct() && c?.state == DeletionState.unconfirmed) {
            unawaited(c!.check());
          }
        },
        onReplay: () {
          if (canAct() &&
              c?.state == DeletionState.unconfirmed &&
              c!.canReplay) {
            unawaited(c.replay());
          }
        },
        onConfirmAccount: () =>
            ref.read(accountControllerProvider.notifier).restore(),
      ),
    );
  }
}
