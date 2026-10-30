import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'history_controller.dart';
import 'deletion_controller.dart';

final historyHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => createHttpClient,
);
final historyProvider = Provider.autoDispose
    .family<HistoryController?, String?>((ref, sessionId) {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null || sessionId != null && !isPracticeUuid(sessionId)) {
        return null;
      }
      final c = HistoryController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: owner,
        sessionId: sessionId?.toLowerCase(),
        httpClientFactory: ref.watch(historyHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      c.addListener(changed);
      ref.onDispose(() {
        c.removeListener(changed);
        c.dispose();
      });
      return c;
    });

final deletionProvider = Provider.autoDispose
    .family<DeletionController?, String>((ref, sessionId) {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null || !isPracticeUuid(sessionId)) return null;
      final c = DeletionController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: owner,
        sessionId: sessionId.toLowerCase(),
        httpClientFactory: ref.watch(historyHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      c.addListener(changed);
      ref.onDispose(() {
        c.removeListener(changed);
        c.dispose();
      });
      return c;
    });
