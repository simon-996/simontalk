import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import '../usage/usage_panel.dart';
import 'practice_models.dart';
import 'saved_practice_status_controller.dart';
import 'saved_practice_status_providers.dart';
import 'saved_practice_status_view.dart';

class SavedPracticeStatusScreen extends ConsumerStatefulWidget {
  const SavedPracticeStatusScreen({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<SavedPracticeStatusScreen> createState() =>
      _SavedPracticeStatusScreenState();
}

class _SavedPracticeStatusScreenState
    extends ConsumerState<SavedPracticeStatusScreen> {
  SavedPracticeStatusController? _started;
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
        path[2] == 'save-status';
  }

  void _back() {
    if (!_isCurrentPage()) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(
        isPracticeUuid(widget.sessionId)
            ? '/history/${widget.sessionId}'
            : '/history',
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
              description: '保存情况地址已保留，确认身份后再读取。',
            ),
            if (failed)
              OutlinedButton(
                onPressed: () {
                  if (_isCurrentPage() &&
                      ref.read(accountControllerProvider).phase ==
                          SessionPhase.unreachable) {
                    unawaited(
                      ref.read(accountControllerProvider.notifier).restore(),
                    );
                  }
                },
                child: const Text('重新连接'),
              ),
            OutlinedButton(onPressed: _back, child: const Text('返回练习详情')),
          ],
        ),
      );
    }
    final c = ref.watch(savedPracticeStatusProvider(widget.sessionId));
    if (c != null && !identical(c, _started)) {
      _started = c;
      unawaited(
        Future<void>.microtask(() async {
          if (mounted &&
              identical(c, _started) &&
              identical(
                ref.read(savedPracticeStatusProvider(widget.sessionId)),
                c,
              )) {
            await c.refresh();
          }
        }),
      );
    }
    bool canAct() {
      if (!_isCurrentPage()) return false;
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == account.session?.user.id &&
          c != null &&
          current.session?.user.id == c.accountId &&
          identical(ref.read(savedPracticeStatusProvider(widget.sessionId)), c);
    }

    return SavedPracticeStatusView(
      state: c?.state ?? SavedPracticeStatusState.unavailable,
      item: c?.item,
      completion: c?.completion,
      errorCode: c?.errorCode ?? (c == null ? 'invalid_source' : null),
      busy: c?.busy ?? false,
      accountBusy: account.busy,
      usageChild: account.session == null
          ? null
          : PracticeUsagePanel(
              key: ValueKey(
                'practice-usage-${account.session!.user.id}-${widget.sessionId.toLowerCase()}',
              ),
              sessionId: widget.sessionId,
            ),
      onRefresh: c == null
          ? null
          : () {
              if (canAct() && !c.busy) unawaited(c.refresh());
            },
      onBack: () {
        final current = ref.read(accountControllerProvider);
        if (current.phase == SessionPhase.signedIn &&
            current.session?.user.id == account.session?.user.id) {
          _back();
        }
      },
      onConfirmAccount: () {
        if (canAct()) {
          unawaited(ref.read(accountControllerProvider.notifier).restore());
        }
      },
    );
  }
}
