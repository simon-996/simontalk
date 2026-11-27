import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../account/account_controller.dart';
import 'usage_controller.dart';
import 'usage_providers.dart';
import 'usage_view.dart';

class AccountUsagePanel extends ConsumerWidget {
  const AccountUsagePanel({
    super.key,
    this.usageController,
    this.showAccountStatus = false,
  });

  final AccountUsageController? usageController;
  final bool showAccountStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = usageController ?? ref.watch(accountUsageProvider);
    final account = ref.watch(accountControllerProvider);
    if (controller == null) return const SizedBox.shrink();
    final displayedUri = GoRouter.maybeOf(context)
        ?.routeInformationProvider
        .value
        .uri;
    bool canAct({bool requireApiOwner = true}) {
      if (!context.mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          GoRouter.maybeOf(context)?.routeInformationProvider.value.uri !=
              displayedUri) {
        return false;
      }
      final current = ref.read(accountControllerProvider);
      final activePanel = context.widget;
      if (activePanel is! AccountUsagePanel) return false;
      final active =
          activePanel.usageController ?? ref.read(accountUsageProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == controller.accountId &&
          identical(controller, active) &&
          !controller.busy &&
          (!requireApiOwner ||
              ref
                  .read(accountRepositoryProvider)
                  .api
                  .hasCurrentAccount(controller.accountId));
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (_, _) => AccountUsageView(
        state: controller.state,
        summary: controller.summary,
        errorCode: controller.errorCode,
        busy: controller.busy,
        accountBusy: account.busy,
        showAccountStatus: showAccountStatus,
        onLoad: () {
          if (canAct()) unawaited(controller.refresh());
        },
        onRefresh: () {
          if (canAct()) unawaited(controller.refresh());
        },
        onConfirmAccount: () {
          if (canAct(requireApiOwner: false)) {
            unawaited(ref.read(accountControllerProvider.notifier).restore());
          }
        },
      ),
    );
  }
}

class PracticeUsagePanel extends ConsumerWidget {
  const PracticeUsagePanel({
    super.key,
    required this.sessionId,
    this.usageController,
  });

  final String sessionId;
  final PracticeUsageController? usageController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller =
        usageController ?? ref.watch(practiceUsageProvider(sessionId));
    final account = ref.watch(accountControllerProvider);
    if (controller == null) return const SizedBox.shrink();
    final displayedUri = GoRouter.maybeOf(context)
        ?.routeInformationProvider
        .value
        .uri;
    bool canAct({bool requireApiOwner = true}) {
      if (!context.mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          GoRouter.maybeOf(context)?.routeInformationProvider.value.uri !=
              displayedUri) {
        return false;
      }
      final current = ref.read(accountControllerProvider);
      final activePanel = context.widget;
      if (activePanel is! PracticeUsagePanel) return false;
      final active =
          activePanel.usageController ??
          ref.read(practiceUsageProvider(activePanel.sessionId));
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == controller.accountId &&
          activePanel.sessionId.toLowerCase() == controller.sessionId &&
          identical(controller, active) &&
          !controller.busy &&
          (!requireApiOwner ||
              ref
                  .read(accountRepositoryProvider)
                  .api
                  .hasCurrentAccount(controller.accountId));
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (_, _) => PracticeUsageView(
        state: controller.state,
        summary: controller.summary,
        errorCode: controller.errorCode,
        busy: controller.busy,
        accountBusy: account.busy,
        onLoad: () {
          if (canAct()) unawaited(controller.refresh());
        },
        onRefresh: () {
          if (canAct()) unawaited(controller.refresh());
        },
        onConfirmAccount: () {
          if (canAct(requireApiOwner: false)) {
            unawaited(ref.read(accountControllerProvider.notifier).restore());
          }
        },
      ),
    );
  }
}
