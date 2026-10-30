import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/http_client_factory.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'rehearsal_list_controller.dart';

final rehearsalListHttpClientFactoryProvider = Provider<http.Client Function()>(
  (ref) => createHttpClient,
);
final rehearsalListProvider = Provider.autoDispose
    .family<RehearsalListController?, String>((ref, sid) {
      final owner = ref.watch(
        accountControllerProvider.select(
          (s) => s.phase == SessionPhase.signedIn ? s.session?.user.id : null,
        ),
      );
      if (owner == null || !isPracticeUuid(sid)) {
        return null;
      }
      final c = RehearsalListController(
        accountApi: ref.watch(accountRepositoryProvider).api,
        accountId: owner,
        sourceSessionId: sid.toLowerCase(),
        httpClientFactory: ref.watch(rehearsalListHttpClientFactoryProvider),
      );
      void changed() => ref.notifyListeners();
      c.addListener(changed);
      ref.onDispose(() {
        c.removeListener(changed);
        c.dispose();
      });
      return c;
    });
