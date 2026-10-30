import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../account/account_controller.dart';
import '../conversation/final_transcript_journal.dart';
import '../conversation/playback_evidence_journal.dart';
import '../practice/practice_completion_client.dart';
import '../practice/practice_repository.dart';
import '../practice/practice_models.dart';
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
typedef RealtimeSignallerCreator = RealtimeSignaller Function(
  ApiClient accountApi,
  String accountId,
  ConnectionReservation connection,
  String clientInstanceId,
);

final realtimeSignallerCreatorProvider = Provider<RealtimeSignallerCreator>(
  (ref) =>
      (api, accountId, connection, clientInstanceId) => ApiRealtimeSignaller(
        accountApi: api,
        accountId: accountId,
        clientInstanceId: clientInstanceId,
        connection: connection,
      ),
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
final realtimeTranscriptJournalFactoryProvider =
    Provider<TranscriptJournalCreator>(
      (ref) =>
          (api, scope) => FinalTranscriptJournal(accountApi: api, scope: scope),
    );
final realtimePlaybackEvidenceJournalFactoryProvider =
    Provider<PlaybackEvidenceJournalCreator>(
      (ref) =>
          (api, scope) =>
              PlaybackEvidenceJournal(accountApi: api, scope: scope),
    );
final practiceCompletionClientFactoryProvider =
    Provider<PracticeCompletionCreator>(
      (ref) =>
          (api, scope) =>
              PracticeCompletionClient(accountApi: api, scope: scope),
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
  final createSignaller = ref.watch(realtimeSignallerCreatorProvider);
  final createTranscriptJournal = ref.watch(
    realtimeTranscriptJournalFactoryProvider,
  );
  final createPlaybackJournal = ref.watch(
    realtimePlaybackEvidenceJournalFactoryProvider,
  );
  final createCompletion = ref.watch(practiceCompletionClientFactoryProvider);
  final controller = PracticeMediaController(
    repository: PracticeRepository(api, accountId: accountId),
    transportFactory: ref.watch(realtimeTransportFactoryProvider),
    protocolFactory: ref.watch(realtimeProtocolFactoryProvider),
    observationJournalFactory: (connection, clientInstanceId) =>
        createJournal(api, accountId, connection, clientInstanceId),
    transcriptJournalFactory: (scope) => createTranscriptJournal(api, scope),
    playbackEvidenceJournalFactory: (scope) =>
        createPlaybackJournal(api, scope),
    practiceCompletionFactory: (scope) => createCompletion(api, scope),
    signallerFactory: (connection, clientInstanceId) =>
        createSignaller(api, accountId, connection, clientInstanceId),
  );
  // Keep the original account's drain and unconfirmed text beyond page lifetime.
  // Once closed and acknowledged, normal auto-disposal releases the body.
  RealtimeTranscriptJournal? journal;
  RealtimePlaybackEvidenceJournal? playbackJournal;
  void Function()? releaseRetention;
  var disposed = false;
  var synchronizing = false;
  void synchronizeRetention() {
    if (disposed || synchronizing) return;
    synchronizing = true;
    try {
      if (!api.hasCurrentAccount(accountId)) {
        unawaited(controller.stop(reason: 'account_changed'));
      }
      final current = controller.transcriptJournal;
      if (!identical(journal, current)) {
        journal?.removeListener(synchronizeRetention);
        journal = current;
        journal?.addListener(synchronizeRetention);
      }
      final currentPlayback = controller.playbackEvidenceJournal;
      if (!identical(playbackJournal, currentPlayback)) {
        playbackJournal?.removeListener(synchronizeRetention);
        playbackJournal = currentPlayback;
        playbackJournal?.addListener(synchronizeRetention);
      }
      final retain =
          controller.phase == PracticeMediaPhase.draining ||
          controller.completionHasPendingWork ||
          (journal?.pendingCount ?? 0) > 0 ||
          (playbackJournal?.pendingCount ?? 0) > 0;
      if (retain) {
        releaseRetention ??= ref.keepAlive().close;
      } else {
        final release = releaseRetention;
        releaseRetention = null;
        release?.call();
      }
    } finally {
      synchronizing = false;
    }
  }

  controller.addListener(synchronizeRetention);
  ref.onCancel(() {
    if (controller.phase != PracticeMediaPhase.draining &&
        controller.phase != PracticeMediaPhase.localClosed) {
      unawaited(controller.stop(reason: 'page_left'));
    }
  });
  ref.onDispose(() {
    disposed = true;
    controller.removeListener(synchronizeRetention);
    journal?.removeListener(synchronizeRetention);
    playbackJournal?.removeListener(synchronizeRetention);
    releaseRetention = null;
    controller.dispose();
  });
  return controller;
});
