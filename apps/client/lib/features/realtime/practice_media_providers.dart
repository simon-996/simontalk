import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_controller.dart';
import '../practice/practice_repository.dart';
import 'api_realtime_signaller.dart';
import 'connection_observation_journal.dart';
import 'practice_media_controller.dart';
import 'realtime_session_protocol.dart';
import 'realtime_transport.dart';
import 'realtime_transport_factory.dart';

final realtimeTransportFactoryProvider = Provider<RealtimeTransport Function()>(
  (ref) => createRealtimeTransport,
);
final realtimeProtocolFactoryProvider = Provider<RealtimeProtocolFactory>(
  (ref) => unavailableRealtimeProtocol,
);
final realtimeObservationJournalFactoryProvider =
    Provider<ObservationJournalCreator>(
      (ref) =>
          (api, accountId, connection, clientInstanceId) =>
              ConnectionObservationJournal(
                accountApi: api,
                accountId: accountId,
                connection: connection,
                clientInstanceId: clientInstanceId,
              ),
    );

/// An account-owned scope. Reading it never starts practice, signalling or capture.
final practiceMediaProvider = Provider.autoDispose<PracticeMediaController?>((
  ref,
) {
  final accountId = ref.watch(
    accountControllerProvider.select(
      (state) =>
          state.phase == SessionPhase.signedIn ? state.session?.user.id : null,
    ),
  );
  if (accountId == null) return null;
  final api = ref.watch(accountRepositoryProvider).api;
  final createJournal = ref.watch(realtimeObservationJournalFactoryProvider);
  final controller = PracticeMediaController(
    repository: PracticeRepository(api, accountId: accountId),
    transportFactory: ref.watch(realtimeTransportFactoryProvider),
    protocolFactory: ref.watch(realtimeProtocolFactoryProvider),
    observationJournalFactory: (connection, clientInstanceId) =>
        createJournal(api, accountId, connection, clientInstanceId),
    signallerFactory: (connection, clientInstanceId) => ApiRealtimeSignaller(
      accountApi: api,
      accountId: accountId,
      clientInstanceId: clientInstanceId,
      connection: connection,
    ),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
