import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/playback_evidence_models.dart';
import 'package:simontalk_client/features/conversation/playback_evidence_read_models.dart';

import 'conversation_projection_test.dart' as f;
import '../practice/practice_fixtures.dart';

Map<String, dynamic> evidence(
  int sequence, {
  String kind = 'alignment',
  int transcript = 1,
  String generated = 'Hello there',
  bool finalText = false,
  int playback = 1,
  String status = 'partial',
  String played = 'Hello',
  int? until = 400,
  int? boundary,
  String? reason,
}) => {
  'event_id': '60000000-0000-4000-8000-${sequence.toString().padLeft(12, '0')}',
  'sequence': sequence,
  'kind': kind,
  'response_id': f.responseId,
  'turn_id': kind == 'revoke' ? null : f.aiTurn,
  'turn_index': kind == 'revoke' ? null : 2,
  'transcript_revision': kind == 'revoke' ? null : transcript,
  'generated_text': kind == 'revoke' ? null : generated,
  'transcript_final': kind == 'revoke' ? null : finalText,
  'playback_revision': kind == 'revoke' ? null : playback,
  'delivery_status': kind == 'revoke' ? null : status,
  'played_text': kind == 'revoke' ? null : played,
  'played_until_ms': kind == 'revoke' ? null : until,
  'evidence_source': kind == 'revoke'
      ? null
      : status == 'unknown'
      ? 'unknown'
      : 'device_output_aligned',
  'stop_boundary_ms': boundary,
  'reason': reason,
  'received_at': '2026-10-21T08:00:00Z',
};

Map<String, dynamic> page(
  List<Map<String, dynamic>> events, {
  int? total,
  int? bytes,
  int? last,
  int after = 0,
  bool more = false,
  bool sealed = false,
}) => {
  'source': 'client_reported',
  'account_id': accountId,
  'session_id': practiceId,
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'events': events,
  'last_sequence': last ?? events.lastOrNull?['sequence'] ?? 0,
  'total_events': total ?? events.length,
  'total_text_bytes':
      bytes ??
      events.fold<int>(
        0,
        (n, e) =>
            n +
            ((e['generated_text'] as String?)?.length ?? 0) +
            ((e['played_text'] as String?)?.length ?? 0),
      ),
  'next_after_sequence': events.lastOrNull?['sequence'] ?? after,
  'has_more': more,
  'sealed': sealed,
  'recoverable': false,
};

PlaybackEvidencePage parsed(
  Map<String, dynamic> json, {
  int after = 0,
  int limit = 16,
}) => PlaybackEvidencePage.fromJson(
  json,
  scope: f.scope(),
  afterSequence: after,
  limit: limit,
);

void main() {
  test(
    'old source and frozen prefix survive later source versions independently',
    () {
      final entries = [
        evidence(1),
        evidence(2, kind: 'freeze', boundary: 450, reason: 'interrupted'),
        evidence(
          3,
          transcript: 2,
          generated: 'Hello revised',
          finalText: true,
          playback: 1,
          status: 'unknown',
          played: '',
          until: null,
        ),
      ];
      final history = PlaybackEvidenceHistory.empty(f.scope())
          .append(parsed(page(entries)));
      expect(history.events.first.generatedText, 'Hello there');
      expect(
        history.turns.single.frozenPrefix!.evidence.generatedText,
        'Hello there',
      );
      expect(history.turns.single.frozenPrefix!.evidence.playedText, 'Hello');
      expect(history.turns.single.latest.transcriptRevision, 2);
      expect(history.sealed, isFalse);
      expect(history.recoverable, isFalse);
    },
  );
  test(
    'zero source freeze may gain only its first aligned prefix then be revoked',
    () {
      final entries = [
        evidence(
          1,
          kind: 'freeze',
          transcript: 0,
          generated: '',
          playback: 0,
          status: 'unknown',
          played: '',
          until: null,
          boundary: 500,
          reason: 'normal_end',
        ),
        evidence(2),
        evidence(3, playback: 2, played: 'Hello t', until: 450),
      ];
      final history = PlaybackEvidenceHistory.empty(f.scope())
          .append(parsed(page(entries)));
      expect(history.turns.single.frozenPrefix!.evidence.playbackRevision, 1);
      final revoked = history.append(
        parsed(
          page(
            [evidence(4, kind: 'revoke')],
            total: 4,
            bytes: 34,
            last: 4,
            after: 3,
          ),
          after: 3,
        ),
      );
      expect(revoked.turns.single.revoked, isTrue);
      expect(revoked.turns.single.frozenPrefix, isNull);
      expect(history.turns.single.frozenPrefix, isNotNull);
    },
  );
  test('cross-page invalid associations and playback rollback are atomic', () {
    final original = PlaybackEvidenceHistory.empty(f.scope()).append(
      parsed(
        page([evidence(1)], total: 2, bytes: 32, last: 2, more: true),
        limit: 1,
      ),
    );
    for (final invalid in [
      evidence(2, playback: 2, played: 'He', until: 200),
      {...evidence(2), 'generated_text': 'Changed text'},
      {...evidence(2), 'turn_index': 3},
    ]) {
      expect(
        () => original.append(
          parsed(page([invalid], total: 2, bytes: 32, after: 1), after: 1),
        ),
        throwsFormatException,
      );
    }
    expect(original.events.length, 1);
  });
  test(
    'strict types, bounded text, identity and unrecoverable flags are required',
    () {
      final event = evidence(1);
      for (final invalid in [
        {...event, 'transcript_final': 1},
        {...event, 'generated_text': 'private\u0000'},
        {...event, 'playback_revision': true},
        {...event, 'extra': 'private'},
        {...event, 'played_until_ms': 86400001},
        {...event, 'received_at': '2026-02-30T08:00:00Z'},
      ]) {
        expect(
          () => PlaybackEvidenceEvent.fromJson(invalid),
          throwsFormatException,
        );
      }
      for (final invalid in [
        {
          ...page([event]),
          'recoverable': true,
        },
        {
          ...page([event]),
          'sealed': 1,
        },
        {
          ...page([event]),
          'account_id': requestKey,
        },
        {
          ...page([event]),
          'total_events': true,
        },
        {
          ...page([event]),
          'extra': 'private',
        },
      ]) {
        expect(() => parsed(invalid), throwsFormatException);
      }
    },
  );
  test(
    'a frozen response accepts alignment only for its explicitly frozen turns',
    () {
      final freeze = evidence(
        1,
        kind: 'freeze',
        boundary: 500,
        reason: 'interrupted',
      );
      final introduced = {
        ...evidence(2),
        'turn_id': f.userTurn,
        'turn_index': 3,
      };
      expect(
        () => PlaybackEvidenceLedger.fromEvents([
          PlaybackEvidenceEvent.fromJson(freeze),
          PlaybackEvidenceEvent.fromJson(introduced),
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'new source revisions cannot rewind even when submitted as a freeze',
    () {
      final latest = evidence(1, transcript: 2, generated: 'Hello revised');
      final oldFreeze = evidence(
        2,
        kind: 'freeze',
        boundary: 500,
        reason: 'interrupted',
      );
      expect(
        () => PlaybackEvidenceLedger.fromEvents([
          PlaybackEvidenceEvent.fromJson(latest),
          PlaybackEvidenceEvent.fromJson(oldFreeze),
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'first freeze cannot retroactively shrink another turn output boundary',
    () {
      final prior = {
        ...evidence(1, until: 600),
        'turn_id': f.userTurn,
        'turn_index': 3,
      };
      final freeze = evidence(
        2,
        kind: 'freeze',
        boundary: 500,
        reason: 'interrupted',
      );
      expect(
        () => PlaybackEvidenceLedger.fromEvents([
          PlaybackEvidenceEvent.fromJson(prior),
          PlaybackEvidenceEvent.fromJson(freeze),
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'a tombstone may arrive first and permanently excludes later output',
    () {
      final revoke = PlaybackEvidenceEvent.fromJson(
        evidence(1, kind: 'revoke'),
      );
      final ledger = PlaybackEvidenceLedger.fromEvents([revoke]);
      expect(ledger.revokedResponseIds, {f.responseId});
      expect(
        () => ledger.append(PlaybackEvidenceEvent.fromJson(evidence(2))),
        throwsFormatException,
      );
      expect(
        () => ledger.append(
          PlaybackEvidenceEvent.fromJson(evidence(2, kind: 'revoke')),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'first freeze checks old aligned versions after a newer source reset',
    () {
      final entries = [
        evidence(1, until: 600),
        evidence(2, transcript: 2, status: 'unknown', played: '', until: null),
        evidence(
          3,
          kind: 'freeze',
          transcript: 2,
          status: 'unknown',
          played: '',
          until: null,
          boundary: 500,
          reason: 'interrupted',
        ),
      ];
      expect(
        () => PlaybackEvidenceLedger.fromEvents(
          entries.map(PlaybackEvidenceEvent.fromJson),
        ),
        throwsFormatException,
      );
    },
  );
  test('a final source cannot be replaced by a later nonfinal source', () {
    final entries = [evidence(1, finalText: true), evidence(2, transcript: 2)];
    expect(
      () => PlaybackEvidenceLedger.fromEvents(
        entries.map(PlaybackEvidenceEvent.fromJson),
      ),
      throwsFormatException,
    );
  });
  test('seal is one-way and freezes server totals across remaining pages', () {
    final first = evidence(1);
    final history = PlaybackEvidenceHistory.empty(f.scope())
        .append(parsed(page([first])));
    final sealed = history.append(
      parsed(
        page([], total: 1, bytes: 16, last: 1, after: 1, sealed: true),
        after: 1,
      ),
    );
    expect(sealed.sealed, true);
    expect(history.sealed, false);
    expect(sealed.recoverable, false);
    for (final invalid in [
      page([], total: 1, bytes: 16, last: 1, after: 1),
      page([evidence(2)], total: 2, bytes: 32, last: 2, after: 1, sealed: true),
    ]) {
      expect(
        () => sealed.append(parsed(invalid, after: 1)),
        throwsFormatException,
      );
    }
    final initialSealed = PlaybackEvidenceHistory.empty(f.scope()).append(
      parsed(
        page([first], total: 2, bytes: 32, last: 2, more: true, sealed: true),
        limit: 1,
      ),
    );
    final finished = initialSealed.append(
      parsed(
        page(
          [evidence(2, playback: 2)],
          total: 2,
          bytes: 32,
          last: 2,
          after: 1,
          sealed: true,
        ),
        after: 1,
      ),
    );
    expect(finished.events.length, 2);
    expect(finished.sealed, true);
  });
}
