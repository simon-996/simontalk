import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_controller.dart';
import 'practice_entry_controller.dart';
import 'practice_preparation_controller.dart';
import 'practice_recovery_controller.dart';
import 'practice_providers.dart';
import 'practice_repository.dart';

final practiceEntryProvider = Provider.autoDispose<PracticeEntryController?>((
  ref,
) {
  final id = ref.watch(
    accountControllerProvider.select(
      (state) =>
          state.phase == SessionPhase.signedIn ? state.session?.user.id : null,
    ),
  );
  if (id == null) return null;
  final api = ref.watch(accountRepositoryProvider).api;
  final controller = PracticeEntryController(
    recovery: PracticeRecoveryController(
      api: api,
      accountId: id,
      httpClientFactory: ref.watch(recoveryHttpClientFactoryProvider),
    ),
    preparation: PracticePreparationController(
      repository: PracticeRepository(api, accountId: id),
    ),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
