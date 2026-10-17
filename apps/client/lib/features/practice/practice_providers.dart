import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_controller.dart';
import 'practice_preparation_controller.dart';
import 'practice_repository.dart';

/// Creating the scope does not start a practice or request microphone access.
final practicePreparationProvider =
    Provider.autoDispose<PracticePreparationController?>((ref) {
      final accountId = ref.watch(
        accountControllerProvider.select(
          (state) => state.phase == SessionPhase.signedIn
              ? state.session?.user.id
              : null,
        ),
      );
      if (accountId == null) return null;
      final controller = PracticePreparationController(
        repository: PracticeRepository(
          ref.watch(accountRepositoryProvider).api,
          accountId: accountId,
        ),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });
