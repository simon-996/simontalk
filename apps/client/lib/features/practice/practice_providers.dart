import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import 'practice_preparation_controller.dart';
import 'practice_recovery_controller.dart';
import 'practice_repository.dart';

final recoveryHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => createHttpClient,
);

/// Merely reading this provider never queries state or starts media.
final practiceRecoveryProvider =
    Provider.autoDispose<PracticeRecoveryController?>((ref) {
      final accountId = ref.watch(
        accountControllerProvider.select(
          (state) => state.phase == SessionPhase.signedIn
              ? state.session?.user.id
              : null,
        ),
      );
      if (accountId == null) return null;
      final controller = PracticeRecoveryController(
        api: ref.watch(accountRepositoryProvider).api,
        accountId: accountId,
        httpClientFactory: ref.watch(recoveryHttpClientFactoryProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

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
