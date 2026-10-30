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
import 'package:simontalk_client/features/practice/practice_completion_client.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/practice/practice_repository.dart';
import 'package:simontalk_client/features/practice/submission_manifest.dart';

class _WireTokens implements TokenStore {
  _WireTokens(this.token);
  final String token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => throw UnsupportedError('read only');
  @override
  Future<void> delete() async {}
}

void main() {
  final fixturePath = Platform.environment['SIMONTALK_COMPLETION_WIRE_FIXTURE'];
  test(
    'actual HTTP seals declared input, preserves unknown occupancy and settles deadline loss',
    () async {
      final fixture = jsonDecode(
        await File(fixturePath!).readAsString(),
      ) as Map<String, dynamic>;
      ApiClient apiFor(Map<String, dynamic> identity) => ApiClient(
        baseUrl: Uri.parse(fixture['base_url'] as String),
        isWeb: false,
        tokenStore: _WireTokens(identity['access_token'] as String),
        client: http.Client(),
      )..expectedAccountId = identity['account_id'] as String;
      final a = fixture['a'] as Map<String, dynamic>,
          b = fixture['b'] as Map<String, dynamic>;
      final api = apiFor(a), other = apiFor(b);
      addTearDown(api.close);
      addTearDown(other.close);
      ConversationScope scopeOf(Map<String, dynamic> identity) {
        final c = ConnectionReservation.fromJson(
          identity['connection'] as Map<String, dynamic>,
        );
        return ConversationScope(
          accountId: identity['account_id'] as String,
          sessionId: c.sessionId,
          connectionId: c.id,
          clientInstanceId: c.clientInstanceId,
          epoch: c.epoch,
        );
      }

      final scope = scopeOf(a), bScope = scopeOf(b);
      final path =
          '/v1/practice-sessions/${scope.sessionId}/connections/${scope.connectionId}';
      final before = await api.request('GET', path, accountId: scope.accountId);
      expect(before['termination_status'], 'unknown');
      final transcripts = FinalTranscriptJournal(accountApi: api, scope: scope),
          playback = PlaybackEvidenceJournal(accountApi: api, scope: scope);
      final completion = PracticeCompletionClient(
        accountApi: api,
        scope: scope,
      );
      addTearDown(transcripts.abort);
      addTearDown(playback.abort);
      addTearDown(completion.abort);
      const user = TranscriptUpdate(
        turnId: '10000000-0000-4000-8000-000000000001',
        turnIndex: 1,
        role: ConversationRole.user,
        revision: 1,
        text: 'I enjoy learning English.',
        isFinal: true,
      );
      const interim = TranscriptUpdate(
        turnId: '10000000-0000-4000-8000-000000000002',
        turnIndex: 2,
        role: ConversationRole.assistant,
        revision: 1,
        text: 'Hello there',
        isFinal: false,
        responseId: '20000000-0000-4000-8000-000000000001',
      );
      const finalText = TranscriptUpdate(
        turnId: '10000000-0000-4000-8000-000000000002',
        turnIndex: 2,
        role: ConversationRole.assistant,
        revision: 2,
        text: 'Hello there!',
        isFinal: true,
        responseId: '20000000-0000-4000-8000-000000000001',
      );
      final projection = ConversationProjection(scope)..apply(interim);
      projection.apply(
        const PlaybackUpdate(
          turnId: '10000000-0000-4000-8000-000000000002',
          responseId: '20000000-0000-4000-8000-000000000001',
          transcriptRevision: 1,
          revision: 1,
          status: DeliveryStatus.partial,
          playedText: 'Hello',
          playedUntilMs: 400,
          source: PlaybackEvidenceSource.deviceOutputAligned,
        ),
      );
      playback.recordAlignment(projection.snapshot.turns.single);
      playback.recordFreeze(
        projection.snapshot.turns.single,
        stopBoundaryMs: 400,
        reason: InterruptedPrefixReason.normalEnd,
      );
      transcripts.record(user);
      await transcripts.retryPending();
      await playback.retryPending();
      expect(transcripts.errorCode, isNull);
      expect(playback.errorCode, isNull);
      completion.requestEnd();
      await completion.retryPending();
      expect(completion.summary!.status, PracticeCompletionStatus.ending);
      expect(
        completion.summary!.finalUploadDeadline.difference(
          completion.summary!.acceptedAt,
        ),
        const Duration(seconds: 30),
      );
      projection.apply(finalText);
      transcripts.record(finalText);
      await transcripts.retryPending();
      transcripts.finish();
      playback.finish();
      final manifest = PracticeCompletionManifest(
        scope: scope,
        transcripts: transcripts.submissionManifest!,
        playback: playback.submissionManifest!,
        tailStatus: PracticeCompletionTailStatus.unconfirmed,
      );
      completion.finish(manifest);
      await completion.retryPending();
      expect(completion.errorCode, isNull);
      expect(completion.state, PracticeCompletionClientState.sealed);
      expect(completion.hasPendingWork, isFalse);
      final summary = completion.summary!, receipt = completion.receipt!;
      expect(summary.coverage, PracticeCompletionCoverage.incomplete);
      expect(summary.gapCodes, contains('tail_unconfirmed'));
      expect(receipt.transcripts.events.length, 2);
      expect(receipt.playback.events.length, 2);
      transcripts.reconcileSealed(receipt.transcripts);
      playback.reconcileSealed(receipt.playback);
      expect(transcripts.permanentlyUnsavedCount, 0);
      expect(playback.permanentlyUnsavedCount, 0);
      final snapshot = await api.request(
        'GET',
        '$path/completion',
        accountId: scope.accountId,
      );
      final turns = snapshot['turns'] as List;
      final ai = turns.singleWhere(
        (dynamic row) => row['role'] == 'assistant',
      ) as Map<String, dynamic>;
      expect(ai['revision'], 2);
      expect(ai['final_prefix'], isNull);
      expect(
        (ai['interrupted_prefix']
            as Map<String, dynamic>)['transcript_revision'],
        1,
      );
      expect(snapshot['sealed'], isTrue);
      expect(snapshot['recoverable'], isFalse);
      final repo = PracticeRepository(api, accountId: scope.accountId);
      final page = await repo.loadPlaybackEvidence(
        ConnectionReservation.fromJson(a['connection'] as Map<String, dynamic>),
      );
      expect(page.sealed, isTrue);
      expect(page.recoverable, isFalse);
      final after = await api.request('GET', path, accountId: scope.accountId);
      expect(after['status'], 'unknown');
      expect(after['termination_status'], 'unknown');
      expect(after['lease_expires_at'], before['lease_expires_at']);
      expect(
        (await api.request(
          'GET',
          '/v1/practice-sessions/${scope.sessionId}',
          accountId: scope.accountId,
        ))['status'],
        'completed',
      );
      final replay = await api.request(
        'POST',
        '$path/end',
        accountId: scope.accountId,
        idempotencyKey: completion.endKey,
        body: {
          'client_instance_id': scope.clientInstanceId,
          'epoch': scope.epoch,
        },
      );
      expect(replay['input_hash'], summary.inputHash);
      expect(DateTime.parse(replay['sealed_at'] as String), summary.sealedAt);
      await expectLater(
        other.request(
          'GET',
          '/v1/practice-sessions/${scope.sessionId}/completion',
          accountId: bScope.accountId,
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      final raw = await api.request(
        'GET',
        '$path/transcripts',
        accountId: scope.accountId,
      );
      final event =
          Map<String, dynamic>.from((raw['events'] as List).first as Map)
            ..remove('received_at')
            ..remove('delivery_status');
      final ack = await api.request(
        'POST',
        '$path/transcripts',
        accountId: scope.accountId,
        body: {
          'client_instance_id': scope.clientInstanceId,
          'epoch': scope.epoch,
          'events': [event],
        },
      );
      expect(ack['total_events'], 2);
      final newEvent = {
        ...event,
        'event_id': '30000000-0000-4000-8000-000000000001',
        'sequence': 3,
        'revision': 2,
      };
      await expectLater(
        api.request(
          'POST',
          '$path/transcripts',
          accountId: scope.accountId,
          body: {
            'client_instance_id': scope.clientInstanceId,
            'epoch': scope.epoch,
            'events': [newEvent],
          },
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'practice_input_sealed',
          ),
        ),
      );
      final deadlineClient = PracticeCompletionClient(
        accountApi: other,
        scope: bScope,
      );
      addTearDown(deadlineClient.abort);
      deadlineClient.requestEnd();
      await deadlineClient.retryPending();
      expect(deadlineClient.summary!.status, PracticeCompletionStatus.ending);
      await Future<void>.delayed(const Duration(seconds: 31));
      final lateText = FinalTranscriptJournal(accountApi: other, scope: bScope);
      addTearDown(lateText.abort);
      lateText.record(user);
      await lateText.retryPending();
      expect(lateText.pendingCount, 1);
      expect(lateText.errorCode, 'practice_input_sealed');
      lateText.finish();
      deadlineClient.finish(
        PracticeCompletionManifest(
          scope: bScope,
          transcripts: lateText.submissionManifest!,
          playback: SubmissionManifest.empty(SubmissionLedger.playback),
          tailStatus: PracticeCompletionTailStatus.unconfirmed,
        ),
      );
      await deadlineClient.retryPending();
      expect(deadlineClient.state, PracticeCompletionClientState.sealed);
      expect(deadlineClient.receipt!.transcripts.events, isEmpty);
      lateText.reconcileSealed(deadlineClient.receipt!.transcripts);
      expect(lateText.pendingCount, 0);
      expect(lateText.permanentlyUnsavedCount, 1);
      expect(lateText.errorCode, 'sealed_unsaved');
      expect(deadlineClient.summary!.gapCodes, contains('manifest_missing'));
      expect(
        deadlineClient.summary!.coverage,
        PracticeCompletionCoverage.incomplete,
      );
    },
    skip: fixturePath == null
        ? 'Requires isolated local API fixture; see practice finalization verification.'
        : false,
    timeout: const Timeout(Duration(seconds: 75)),
  );
}
