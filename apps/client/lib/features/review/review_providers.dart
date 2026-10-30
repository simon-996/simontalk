import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import 'practice_review_client.dart';
import 'review_models.dart';
import '../practice/practice_models.dart';
import 'review_page_controller.dart';

final reviewHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => createHttpClient,
);

/// Listening is silent. Leaving the page releases all in-memory review content.
final practiceReviewProvider = Provider.autoDispose
    .family<PracticeReviewClient?, ReviewTarget>((ref, target) {
      final accountId = ref.watch(
        accountControllerProvider.select(
          (state) => state.phase == SessionPhase.signedIn
              ? state.session?.user.id
              : null,
        ),
      );
      if (accountId == null || target.accountId != accountId) return null;
      final client = PracticeReviewClient(
        accountApi: ref.watch(accountRepositoryProvider).api,
        target: target,
        httpClientFactory: ref.watch(reviewHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      client.addListener(changed);
      ref.onDispose(() {
        client.removeListener(changed);
        client.dispose();
      });
      return client;
    });

/// The URL is the only key. Current account changes dispose its previous owner.
final reviewPageProvider = Provider.autoDispose
    .family<ReviewPageController?, String>((ref, sessionId) {
      final accountId = ref.watch(
        accountControllerProvider.select(
          (state) => state.phase == SessionPhase.signedIn
              ? state.session?.user.id
              : null,
        ),
      );
      if (accountId == null || !isPracticeUuid(sessionId)) return null;
      final controller = ReviewPageController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: accountId,
        sessionId: sessionId.toLowerCase(),
        httpClientFactory: ref.watch(reviewHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      controller.addListener(changed);
      ref.onDispose(() {
        controller.removeListener(changed);
        controller.dispose();
      });
      return controller;
    });
