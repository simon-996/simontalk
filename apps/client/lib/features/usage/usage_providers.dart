import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'usage_controller.dart';

final usageHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => createHttpClient,
);

/// Account-scoped read-only usage summary; silent until explicitly requested.
final accountUsageProvider = Provider.autoDispose<AccountUsageController?>((
  ref,
) {
  final owner = ref.watch(
    accountControllerProvider.select(
      (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
    ),
  );
  if (owner == null || !isPracticeUuid(owner)) return null;
  final controller = AccountUsageController(
    accountApi: ref.watch(accountRepositoryProvider).api,
    accountId: owner,
    httpClientFactory: ref.watch(usageHttpClientFactoryProvider),
  );
  void changed() => ref.notifyListeners();
  controller.addListener(changed);
  ref.onDispose(() {
    controller.removeListener(changed);
    controller.dispose();
  });
  return controller;
});

/// Practice-scoped read-only usage summary; silent until explicitly requested.
final practiceUsageProvider = Provider.autoDispose
    .family<PracticeUsageController?, String>((ref, sessionId) {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null || !isPracticeUuid(sessionId)) return null;
      final controller = PracticeUsageController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: owner,
        sessionId: sessionId.toLowerCase(),
        httpClientFactory: ref.watch(usageHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      controller.addListener(changed);
      ref.onDispose(() {
        controller.removeListener(changed);
        controller.dispose();
      });
      return controller;
    });
