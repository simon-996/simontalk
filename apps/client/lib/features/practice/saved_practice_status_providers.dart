import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import 'practice_models.dart';
import 'saved_practice_status_controller.dart';

final savedPracticeStatusHttpClientFactoryProvider =
    Provider<http.Client Function()>((ref) => createHttpClient);

/// A URL and current owner identify one silent, independent read scope.
final savedPracticeStatusProvider = Provider.autoDispose
    .family<SavedPracticeStatusController?, String>((ref, sessionId) {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null || !isPracticeUuid(sessionId)) return null;
      final controller = SavedPracticeStatusController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: owner,
        sessionId: sessionId.toLowerCase(),
        httpClientFactory: ref.watch(
          savedPracticeStatusHttpClientFactoryProvider,
        ),
      );
      void changed() => ref.notifyListeners();
      controller.addListener(changed);
      ref.onDispose(() {
        controller.removeListener(changed);
        controller.dispose();
      });
      return controller;
    });
