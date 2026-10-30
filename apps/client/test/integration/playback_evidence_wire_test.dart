import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';
import 'package:simontalk_client/features/conversation/final_transcript_journal.dart';
import 'package:simontalk_client/features/conversation/playback_evidence_journal.dart';
import 'package:simontalk_client/features/conversation/playback_evidence_read_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';

final class _WireTokenStore implements TokenStore {
  _WireTokenStore(this.token);
  final String token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => throw UnsupportedError('read only');
  @override
  Future<void> delete() async {}
}

void main() {
  final fixturePath = Platform.environment['SIMONTALK_PLAYBACK_WIRE_FIXTURE'];
  test(
    'actual Dart HTTP persists versioned playback, late revocation and original isolation',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath!).readAsString(),
      ) as Map<String, dynamic>;
      ApiClient client(Map<String, dynamic> identity) => ApiClient(
        baseUrl: Uri.parse(fixture['base_url'] as String),
        isWeb: false,
        tokenStore: _WireTokenStore(identity['access_token'] as String),
        client: http.Client(),
      )..expectedAccountId = identity['account_id'] as String;
      final a = fixture['a'] as Map<String, dynamic>;
      final b = fixture['b'] as Map<String, dynamic>;
      final api = client(a);
      final otherApi = client(b);
      addTearDown(api.close);
      addTearDown(otherApi.close);
      final connection = ConnectionReservation.fromJson(
        a['connection'] as Map<String, dynamic>,
      );
      final scope = ConversationScope(
        accountId: a['account_id'] as String,
        sessionId: connection.sessionId,
        connectionId: connection.id,
        clientInstanceId: connection.clientInstanceId,
        epoch: connection.epoch,
      );
      final repository = PracticeRepository(api, accountId: scope.accountId);
      final path =
          '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}';
      final before = await api.request('GET', path, accountId: scope.accountId);
      final journal = PlaybackEvidenceJournal(accountApi: api, scope: scope);
      final transcripts = FinalTranscriptJournal(accountApi: api, scope: scope);
      addTearDown(journal.abort);
      addTearDown(transcripts.abort);
      const turnId = '10000000-0000-4000-8000-000000000002';
      const responseId = '20000000-0000-4000-8000-000000000001';
      final projection = ConversationProjection(scope);
      projection.apply(
        const TranscriptUpdate(
          turnId: turnId,
          turnIndex: 1,
          role: ConversationRole.assistant,
          revision: 1,
          text: 'Hello there',
          isFinal: false,
          responseId: responseId,
        ),
      );
      const playback = PlaybackUpdate(
        turnId: turnId,
        responseId: responseId,
        transcriptRevision: 1,
        revision: 1,
        status: DeliveryStatus.partial,
        playedText: 'Hello',
        playedUntilMs: 400,
        source: PlaybackEvidenceSource.deviceOutputAligned,
      );
      projection.apply(playback);
      journal.recordAlignment(projection.snapshot.turns.single);
      final original = projection.snapshot.turns.single;
      projection.freezeResponse(
        responseId,
        stopBoundaryMs: 400,
        reason: InterruptedPrefixReason.interrupted,
      );
      journal.recordFreeze(
        original,
        stopBoundaryMs: 400,
        reason: InterruptedPrefixReason.interrupted,
      );
      const finalText = TranscriptUpdate(
        turnId: turnId,
        turnIndex: 1,
        role: ConversationRole.assistant,
        revision: 2,
        text: 'Hello there!',
        isFinal: true,
        responseId: responseId,
      );
      projection.apply(finalText);
      transcripts.record(finalText);
      await transcripts.retryPending();
      expect(transcripts.errorCode, isNull);
      expect(transcripts.pendingCount, 0);
      projection.apply(
        const PlaybackUpdate(
          turnId: turnId,
          responseId: responseId,
          transcriptRevision: 2,
          revision: 1,
          status: DeliveryStatus.partial,
          playedText: 'Hello',
          playedUntilMs: 400,
          source: PlaybackEvidenceSource.deviceOutputAligned,
        ),
      );
      journal.recordAlignment(projection.snapshot.turns.single);
      await journal.retryPending();
      expect(journal.errorCode, isNull);
      expect(journal.pendingCount, 0);
      var history = PlaybackEvidenceHistory.empty(scope);
      do {
        history = history.append(
          await repository.loadPlaybackEvidence(
            connection,
            afterSequence: history.nextAfterSequence,
            limit: 1,
          ),
        );
      } while (history.hasMore);
      expect(history.events.length, 3);
      expect(history.recoverable, isFalse);
      expect(history.sealed, isFalse);
      expect(history.turns.single.latest.transcriptRevision, 2);
      expect(history.turns.single.frozenPrefix!.evidence.transcriptRevision, 1);
      expect(history.turns.single.frozenPrefix!.evidence.playedText, 'Hello');
      final immutable = history;
      journal.recordRevoke(responseId);
      await journal.retryPending();
      expect(journal.errorCode, isNull);
      expect(journal.pendingCount, 0);
      history = history.append(
        await repository.loadPlaybackEvidence(
          connection,
          afterSequence: history.nextAfterSequence,
          limit: 1,
        ),
      );
      expect(history.events.length, 4);
      expect(history.revokedResponseIds, contains(responseId));
      expect(history.turns.single.frozenPrefix, isNull);
      expect(
        immutable.turns.single.frozenPrefix!.evidence.transcriptRevision,
        1,
      );
      final replay = await api.request(
        'POST',
        '$path/playback-evidence',
        accountId: scope.accountId,
        body: {
          'client_instance_id': scope.clientInstanceId,
          'epoch': scope.epoch,
          'events': [history.events.first.toRequestJson()],
        },
      );
      expect(replay['total_events'], 4);
      expect(replay['last_sequence'], 4);
      final firstAgain = await repository.loadPlaybackEvidence(
        connection,
        limit: 1,
      );
      expect(
        firstAgain.events.single.receivedAt,
        history.events.first.receivedAt,
      );
      await expectLater(
        PracticeRepository(
          otherApi,
          accountId: b['account_id'] as String,
        ).loadPlaybackEvidence(connection),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      final ownOther =
          await PracticeRepository(
            otherApi,
            accountId: b['account_id'] as String,
          ).loadPlaybackEvidence(
            ConnectionReservation.fromJson(
              b['connection'] as Map<String, dynamic>,
            ),
          );
      expect(ownOther.events, isEmpty);
      final textPage = await api.request(
        'GET',
        '$path/transcripts',
        accountId: scope.accountId,
      );
      expect((textPage['events'] as List).single['delivery_status'], 'unknown');
      expect(
        await api.request('GET', path, accountId: scope.accountId),
        before,
      );
      journal.finish();
      transcripts.finish();
    },
    skip: fixturePath == null
        ? 'Requires an isolated local API fixture; see playback verification.'
        : false,
  );
}
