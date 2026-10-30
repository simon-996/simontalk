import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'saved_transcript_controller.dart';

final savedTranscriptHttpClientFactoryProvider =
    Provider<http.Client Function()>((ref) => createHttpClient);
typedef SavedTranscriptLocation = ({String sessionId, String? reviewItemId});
final savedTranscriptProvider = Provider.autoDispose
    .family<SavedTranscriptController?, SavedTranscriptLocation>((
      ref,
      location,
    ) {
      final accountId = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (accountId == null ||
          !isPracticeUuid(location.sessionId) ||
          (location.reviewItemId != null &&
              !isPracticeUuid(location.reviewItemId!))) {
        return null;
      }
      final c = SavedTranscriptController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: accountId,
        sessionId: location.sessionId.toLowerCase(),
        reviewItemId: location.reviewItemId?.toLowerCase(),
        httpClientFactory: ref.watch(savedTranscriptHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      c.addListener(changed);
      ref.onDispose(() {
        c.removeListener(changed);
        c.dispose();
      });
      return c;
    });
