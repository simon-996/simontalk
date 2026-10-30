import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'rehearsal_controller.dart';
import 'rehearsal_models.dart';

typedef RehearsalLocation = ({String sessionId, String? itemId});
final rehearsalHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => createHttpClient,
);
final rehearsalProvider = Provider.autoDispose
    .family<RehearsalController?, RehearsalLocation>((ref, location) {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null ||
          !isPracticeUuid(location.sessionId) ||
          location.itemId != null && !isPracticeUuid(location.itemId!)) {
        return null;
      }
      final c = RehearsalController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: owner,
        sessionId: location.sessionId.toLowerCase(),
        itemId: location.itemId?.toLowerCase(),
        httpClientFactory: ref.watch(rehearsalHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      c.addListener(changed);
      ref.onDispose(() {
        c.removeListener(changed);
        c.dispose();
      });
      return c;
    });

/// Only verified ordinary sources expose the creation entry beside review items.
/// This independent, bounded GET never changes the review's own read/result state.
final rehearsalEligibilityProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, sid) async {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null || !isPracticeUuid(sid)) return false;
      final source = ref.watch(accountRepositoryProvider).api;
      final api = source.forkForAccount(
        accountId: owner,
        client: ref.watch(rehearsalHttpClientFactoryProvider)(),
      );
      ref.onDispose(api.close);
      try {
        final j = await api
            .request(
              'GET',
              '/v1/practice-sessions/$sid',
              accountId: owner,
              maxResponseBytes: 32768,
            )
            .timeout(const Duration(seconds: 8));
        return source.hasCurrentAccount(owner) &&
            rehearsalId(j['id']) == sid.toLowerCase() &&
            j['kind'] == 'ordinary' &&
            j['source_session_id'] == null &&
            j['source_review_item_id'] == null;
      } on Object {
        return false;
      } finally {
        api.close();
      }
    });
