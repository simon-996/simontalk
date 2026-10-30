import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../account/account_controller.dart';
import 'practice_entry_provider.dart';
import 'practice_entry_view.dart';
import 'practice_providers.dart';
import 'practice_recovery_panel.dart';

bool _isCurrentPage(BuildContext context, String path) =>
    context.mounted &&
    ModalRoute.of(context)?.isCurrent == true &&
    GoRouter.of(context).routeInformationProvider.value.uri.path == path;

class PracticeHomeScreen extends ConsumerWidget {
  const PracticeHomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountControllerProvider);
    final difficulty = account.session?.preferences.difficulty;
    final recovery = ref.watch(practiceRecoveryProvider);
    if (difficulty == null || recovery == null) return const SizedBox.shrink();
    bool canNavigate({bool checkRoute = true}) {
      if (!context.mounted ||
          (checkRoute && !_isCurrentPage(context, '/practice'))) {
        return false;
      }
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == recovery.accountId &&
          ref
              .read(accountRepositoryProvider)
              .api
              .hasCurrentAccount(recovery.accountId) &&
          identical(ref.read(practiceRecoveryProvider), recovery);
    }

    bool canOpenPreparation({bool checkRoute = true}) {
      if (!canNavigate(checkRoute: checkRoute)) return false;
      final current = ref.read(accountControllerProvider);
      return current.session?.preferences.difficulty == difficulty &&
          !recovery.busy &&
          recovery.errorCode == null &&
          recovery.recovery?.practice == null;
    }

    return ListenableBuilder(
      listenable: recovery,
      builder: (context, _) => PracticeHomeView(
        difficulty: difficulty,
        onStart: canOpenPreparation(checkRoute: false)
            ? () {
                if (canOpenPreparation()) context.push('/practice/prepare');
              }
            : null,
        onSettings: account.busy
            ? null
            : () {
                if (canNavigate()) context.push('/account');
              },
        onHistory: account.busy
            ? null
            : () {
                if (canNavigate()) context.push('/history');
              },
        recovery: const PracticeRecoveryPanel(),
      ),
    );
  }
}

class PracticePreparationScreen extends ConsumerWidget {
  const PracticePreparationScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountControllerProvider);
    final difficulty = account.session?.preferences.difficulty;
    final entry = ref.watch(practiceEntryProvider);
    if (entry == null || difficulty == null) return const SizedBox.shrink();
    bool canActivate({bool requireApiOwner = true}) {
      if (!_isCurrentPage(context, '/practice/prepare')) return false;
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == entry.preparation.repository.accountId &&
          (!requireApiOwner ||
              entry.preparation.repository.hasCurrentAccount) &&
          identical(ref.read(practiceEntryProvider), entry);
    }

    return ListenableBuilder(
      listenable: entry,
      builder: (context, _) => PracticePreparationView(
        difficulty: entry.preparationDifficulty ?? difficulty,
        phase: entry.preparation.phase,
        errorCode: entry.preparation.errorCode,
        busy: entry.busy,
        accountBusy: account.busy,
        onStart: entry.canStart && !account.busy
            ? () {
                if (canActivate() &&
                    entry.canStart &&
                    ref
                            .read(accountControllerProvider)
                            .session
                            ?.preferences
                            .difficulty ==
                        difficulty) {
                  unawaited(entry.begin(difficulty));
                }
              }
            : null,
        onRetry: entry.canRetry && !account.busy
            ? () {
                if (canActivate() && entry.canRetry) unawaited(entry.retry());
              }
            : null,
        onCancel: () {
          if (canActivate()) unawaited(entry.cancel());
        },
        onConfirmAccount: account.busy
            ? null
            : () {
                if (canActivate(requireApiOwner: false)) {
                  unawaited(
                    ref.read(accountControllerProvider.notifier).restore(),
                  );
                }
              },
        recovery: PracticeRecoveryPanel(
          recoveryController: entry.recovery,
          showAccountStatus: false,
        ),
        onBack: () {
          if (!canActivate()) return;
          unawaited(entry.cancel());
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/practice');
          }
        },
      ),
    );
  }
}
