import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'review_page_controller.dart';
import 'review_page_view.dart';
import 'review_providers.dart';
import '../rehearsal/rehearsal_providers.dart';
import 'review_models.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({
    super.key,
    required this.sessionId,
    this.fromHistory = false,
  });
  final String sessionId;
  final bool fromHistory;
  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  ReviewPageController? _started;
  bool _isCurrentPage() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final path = GoRouter.of(context)
        .routeInformationProvider
        .value
        .uri
        .pathSegments;
    return path.length == 3 &&
        path[0] == 'practice' &&
        path[1].toLowerCase() == widget.sessionId.toLowerCase() &&
        path[2] == 'review';
  }

  void _back() {
    if (!_isCurrentPage()) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(
        widget.fromHistory ? '/history/${widget.sessionId}' : '/account',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backLabel = widget.fromHistory ? '返回练习详情' : '返回练习偏好';
    final account = ref.watch(accountControllerProvider);
    if (!isPracticeUuid(widget.sessionId)) {
      return ReviewPageView(
        state: ReviewPageState.unavailable,
        errorCode: 'invalid_source',
        onBack: _back,
        backLabel: backLabel,
      );
    }
    if (account.phase != SessionPhase.signedIn) {
      final failed = account.phase == SessionPhase.unreachable;
      return AccountFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageIntro(
              title: failed ? '暂时连接不上' : '正在恢复你的账号',
              description: failed
                  ? '复盘地址已保留。重新连接并确认账号后，再读取本次记录。'
                  : '正在确认登录和个人设置，随后核对这份复盘。',
            ),
            if (failed) ...[
              const SizedBox(height: 16),
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
            ],
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _back, child: Text(backLabel)),
          ],
        ),
      );
    }
    final controller = ref.watch(reviewPageProvider(widget.sessionId));
    if (controller == null) {
      return ReviewPageView(
        state: ReviewPageState.unavailable,
        onBack: _back,
        backLabel: backLabel,
      );
    }
    if (!identical(_started, controller)) {
      _started = controller;
      unawaited(
        Future<void>.microtask(() async {
          if (mounted && identical(_started, controller)) {
            await controller.refresh();
          }
        }),
      );
    }
    final ordinary =
        controller.job?.status == ReviewJobStatus.succeeded &&
        ref
                .watch(rehearsalEligibilityProvider(widget.sessionId))
                .asData
                ?.value ==
            true;
    final displayedCompletion = controller.completion;
    final displayedJob = controller.job;
    bool canAct() {
      if (!_isCurrentPage()) return false;
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == controller.accountId &&
          identical(
            ref.read(reviewPageProvider(widget.sessionId)),
            controller,
          ) &&
          !controller.busy;
    }

    bool hasDisplayedSource() =>
        canAct() &&
        displayedCompletion != null &&
        identical(controller.completion, displayedCompletion);
    bool hasDisplayedJob() =>
        hasDisplayedSource() && identical(controller.job, displayedJob);
    return ReviewPageView(
      state: controller.state,
      completion: controller.completion,
      job: controller.job,
      busy: controller.busy,
      accountBusy: account.busy,
      errorCode: controller.errorCode,
      hasPendingAction: controller.hasPendingAction,
      canRequestReview: controller.canRequestReview,
      canRetryGeneration: controller.canRetryGeneration,
      onRefresh: () {
        if (canAct()) unawaited(controller.refresh());
      },
      onReadSavedText: () {
        if (hasDisplayedSource() && controller.canReadSavedText) {
          context.push('/practice/${widget.sessionId}/transcript');
        }
      },
      onLocateItem: (id) {
        if (hasDisplayedJob() && controller.canLocateItem(id)) {
          context.push('/practice/${widget.sessionId}/transcript/$id');
        }
      },
      onRehearseItem: ordinary
          ? (id) {
              if (hasDisplayedJob() &&
                  controller.canLocateItem(id) &&
                  ref
                          .read(rehearsalEligibilityProvider(widget.sessionId))
                          .asData
                          ?.value ==
                      true) {
                context.push('/practice/${widget.sessionId}/rehearse/$id');
              }
            }
          : null,
      onRequestReview: () {
        if (hasDisplayedSource() && controller.canRequestReview) {
          unawaited(controller.requestReview());
        }
      },
      onRetryGeneration: () {
        if (hasDisplayedJob() && controller.canRetryGeneration) {
          unawaited(controller.retryGeneration());
        }
      },
      onRetryPending: () {
        if (hasDisplayedJob() && controller.hasPendingAction) {
          unawaited(controller.retryPending());
        }
      },
      onConfirmAccount: () {
        if (canAct()) {
          unawaited(ref.read(accountControllerProvider.notifier).restore());
        }
      },
      onBack: _back,
      backLabel: backLabel,
    );
  }
}
