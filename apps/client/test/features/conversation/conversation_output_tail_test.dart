import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';

import '../practice/practice_fixtures.dart';

const _user = '30000000-0000-4000-8000-000000000001';
const _assistant = '30000000-0000-4000-8000-000000000002';
const _response = '40000000-0000-4000-8000-000000000001';

ConversationProjection _projection() => ConversationProjection(
  ConversationScope(
    accountId: accountId,
    sessionId: practiceId,
    connectionId: connectionId,
    clientInstanceId: clientId,
    epoch: 1,
  ),
);

TranscriptUpdate _text({
  int revision = 1,
  String text = 'Hello there',
  bool isFinal = false,
}) => TranscriptUpdate(
  turnId: _assistant,
  turnIndex: 2,
  role: ConversationRole.assistant,
  revision: revision,
  text: text,
  isFinal: isFinal,
  responseId: _response,
);

PlaybackUpdate _playback({
  int revision = 1,
  int transcriptRevision = 1,
  String text = 'Hello',
  int until = 400,
}) => PlaybackUpdate(
  turnId: _assistant,
  responseId: _response,
  transcriptRevision: transcriptRevision,
  revision: revision,
  status: DeliveryStatus.partial,
  playedText: text,
  playedUntilMs: until,
  source: PlaybackEvidenceSource.deviceOutputAligned,
);

Matcher _invalid([String code = 'conversation_invalid']) =>
    throwsA(isA<ConversationFailure>().having((e) => e.code, 'code', code));

void _freeze(ConversationProjection p, {int boundary = 400}) =>
    p.freezeResponse(
      _response,
      stopBoundaryMs: boundary,
      reason: InterruptedPrefixReason.interrupted,
    );

void main() {
  test(
    'an interrupted interim only enters context through a frozen prefix',
    () {
      final p = _projection();
      p.apply(_text());
      p.apply(_playback());
      expect(p.snapshot.context.entries, isEmpty);

      _freeze(p);

      expect(p.snapshot.context.entries.single.text, 'Hello');
      expect(p.snapshot.turns.single.isFinal, isFalse);
      expect(
        p.snapshot.context.entries.single.kind,
        ConversationContextKind.interruptedPrefix,
      );
      expect(p.snapshot.context.entries.single.transcriptRevision, 1);
      expect(p.snapshot.context.entries.single.playbackRevision, 1);
      final prefix = p.snapshot.turns.single.frozenPrefix!;
      expect(prefix.stopBoundaryMs, 400);
      expect(prefix.playedUntilMs, 400);
      expect(prefix.reason, InterruptedPrefixReason.interrupted);
      expect(prefix.source, PlaybackEvidenceSource.deviceOutputAligned);
    },
  );

  test('a late final preserves a prefix bound to its original versions', () {
    final p = _projection();
    p.apply(_text());
    p.apply(_playback(revision: 2));
    _freeze(p);
    final before = p.snapshot;
    p.apply(_text(revision: 2, text: 'Good evening', isFinal: true));
    expect(p.snapshot.turns.single.text, 'Good evening');
    expect(p.snapshot.turns.single.playback.status, DeliveryStatus.unknown);
    final entry = p.snapshot.context.entries.single;
    expect(entry.text, 'Hello');
    expect(entry.transcriptRevision, 1);
    expect(entry.playbackRevision, 2);
    expect(entry.kind, ConversationContextKind.interruptedPrefix);
    expect(before.turns.single.text, 'Hello there');
    expect(before.context.entries.single.text, 'Hello');
  });

  test('a separately aligned new final may supply current final context', () {
    final p = _projection();
    p.apply(_text());
    p.apply(_playback());
    _freeze(p);
    p.apply(_text(revision: 2, text: 'Good evening', isFinal: true));
    p.apply(_playback(transcriptRevision: 2, text: 'Good', until: 300));
    final entry = p.snapshot.context.entries.single;
    expect(entry.text, 'Good');
    expect(entry.transcriptRevision, 2);
    expect(entry.kind, ConversationContextKind.finalTranscript);
    expect(p.snapshot.turns.single.frozenPrefix!.transcriptRevision, 1);
  });

  test('freezing unknown generation never fabricates heard text', () {
    final p = _projection();
    p.apply(_text(isFinal: true));
    _freeze(p, boundary: 0);
    expect(p.snapshot.turns.single.frozenPrefix, isNull);
    expect(p.snapshot.context.entries, isEmpty);
    expect(p.snapshot.hasUnconfirmedPlayback, isTrue);
    expect(() => p.apply(_playback(until: 1)), _invalid());
  });

  test(
    'late aligned evidence must remain inside the frozen device boundary',
    () {
      final p = _projection();
      p.apply(_text());
      _freeze(p);
      expect(() => p.apply(_playback(until: 401)), _invalid());
      expect(p.snapshot.context.entries, isEmpty);
      p.apply(_playback());
      expect(p.snapshot.context.entries.single.text, 'Hello');
      expect(
        () => p.apply(_playback(revision: 2, text: 'Hello t', until: 500)),
        _invalid(),
      );
      expect(p.snapshot.context.entries.single.text, 'Hello');
    },
  );

  test('repeat freezes are exact and cannot move their bound or reason', () {
    final p = _projection();
    p.apply(_text());
    p.apply(_playback());
    _freeze(p);
    final revision = p.snapshot.revision;
    expect(
      p.freezeResponse(
        _response,
        stopBoundaryMs: 400,
        reason: InterruptedPrefixReason.interrupted,
      ),
      ConversationApplyResult.duplicate,
    );
    expect(() => _freeze(p, boundary: 500), _invalid());
    expect(() => _freeze(p, boundary: 300), _invalid());
    expect(
      () => p.freezeResponse(
        _response,
        stopBoundaryMs: 400,
        reason: InterruptedPrefixReason.normalEnd,
      ),
      _invalid(),
    );
    expect(p.snapshot.revision, revision);
  });

  test('explicitly disproven alignment is revoked and cannot be reused', () {
    final p = _projection();
    p.apply(_text());
    p.apply(_playback());
    _freeze(p);
    final old = p.snapshot;
    expect(p.revokeFrozenPrefix(_response), ConversationApplyResult.applied);
    expect(p.snapshot.context.entries, isEmpty);
    expect(p.snapshot.turns.single.frozenPrefix, isNull);
    expect(p.snapshot.turns.single.playback.status, DeliveryStatus.unknown);
    expect(p.revokeFrozenPrefix(_response), ConversationApplyResult.duplicate);
    expect(p.apply(_playback(revision: 2)), ConversationApplyResult.stale);
    p.apply(_text(revision: 2, isFinal: true));
    expect(p.snapshot.context.entries, isEmpty);
    expect(old.context.entries.single.text, 'Hello');
  });

  test('prefix text uses the aggregate memory budget and freeze is atomic', () {
    final p = _projection();
    p.apply(_text(text: 'x' * 8192));
    p.apply(_playback(text: 'x' * 4096));
    for (var i = 0; i < 30; i++) {
      p.apply(
        TranscriptUpdate(
          turnId: '50000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          turnIndex: i + 3,
          role: ConversationRole.user,
          revision: 1,
          text: 'x' * 8192,
          isFinal: true,
        ),
      );
    }
    p.apply(
      const TranscriptUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
        revision: 1,
        text: 'x',
        isFinal: true,
      ),
    );
    final before = p.snapshot.revision;
    expect(() => _freeze(p), _invalid('conversation_limit_reached'));
    expect(p.snapshot.revision, before);
    expect(
      p.snapshot.turns.where((t) => t.turnId == _assistant).single.frozenPrefix,
      isNull,
    );
    p.apply(
      TranscriptUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
        revision: 2,
        text: '',
        isFinal: true,
      ),
    );
    _freeze(p);
    expect(
      p.snapshot.context.entries
          .where((e) => e.turnId == _assistant)
          .single
          .text
          .length,
      4096,
    );
  });

  test('a sealed or cleared projection cannot create or revoke prefixes', () {
    final p = _projection();
    p.apply(_text());
    p.apply(_playback());
    _freeze(p);
    p.seal();
    expect(
      p.freezeResponse(
        _response,
        stopBoundaryMs: 400,
        reason: InterruptedPrefixReason.interrupted,
      ),
      ConversationApplyResult.closed,
    );
    expect(p.revokeFrozenPrefix(_response), ConversationApplyResult.closed);
    p.clear();
    expect(p.snapshot.turns, isEmpty);
    expect(p.snapshot.context.entries, isEmpty);
  });

  test(
    'started input without captions accepts only its own late item binding',
    () {
      final p = _projection();
      const started = TurnStartedUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
      );
      p.apply(started);
      expect(p.snapshot.turns.single.revision, 0);
      expect(p.snapshot.turns.single.text, '');
      expect(p.snapshot.turns.single.isFinal, isFalse);
      expect(p.snapshot.context.entries, isEmpty);
      expect(p.apply(started), ConversationApplyResult.duplicate);
      p.apply(
        const TranscriptUpdate(
          turnId: _user,
          turnIndex: 1,
          role: ConversationRole.user,
          revision: 1,
          text: 'My final words',
          isFinal: true,
          providerItemId: 'item-late',
        ),
      );
      expect(p.snapshot.context.entries.single.text, 'My final words');
      expect(p.snapshot.turns.single.providerItemId, 'item-late');
      expect(
        () => p.apply(
          const TurnStartedUpdate(
            turnId: _user,
            turnIndex: 1,
            role: ConversationRole.user,
            providerItemId: 'other-item',
          ),
        ),
        _invalid(),
      );
    },
  );

  test('a provider item binds once before final and cannot belong to another input', () {
    final p = _projection();
    p.apply(
      const TurnStartedUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
      ),
    );
    p.apply(
      const TranscriptUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
        revision: 1,
        text: 'Hel',
        isFinal: false,
      ),
    );
    p.apply(
      const TurnStartedUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
        providerItemId: 'item-late',
      ),
    );
    expect(p.snapshot.turns.single.revision, 1);
    expect(p.snapshot.turns.single.text, 'Hel');
    expect(
      () => p.apply(
        const TurnStartedUpdate(
          turnId: _assistant,
          turnIndex: 2,
          role: ConversationRole.user,
          providerItemId: 'item-late',
        ),
      ),
      _invalid(),
    );
    expect(p.snapshot.turns.length, 1);
    p.apply(
      const TranscriptUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
        revision: 2,
        text: 'Hello',
        isFinal: true,
        providerItemId: 'item-late',
      ),
    );
    expect(p.snapshot.context.entries.single.text, 'Hello');
  });

  test('late item metadata can bind without changing an interim revision', () {
    final p = _projection();
    p.apply(
      const TranscriptUpdate(
        turnId: _user,
        turnIndex: 1,
        role: ConversationRole.user,
        revision: 1,
        text: 'Hel',
        isFinal: false,
      ),
    );
    expect(
      p.apply(
        const TranscriptUpdate(
          turnId: _user,
          turnIndex: 1,
          role: ConversationRole.user,
          revision: 1,
          text: 'Hel',
          isFinal: false,
          providerItemId: 'item-late',
        ),
      ),
      ConversationApplyResult.applied,
    );
    expect(p.snapshot.turns.single.providerItemId, 'item-late');
    expect(p.snapshot.turns.single.revision, 1);
  });

  test(
    'item identity cannot be introduced after its first final was accepted',
    () {
      final p = _projection();
      p.apply(
        const TranscriptUpdate(
          turnId: _user,
          turnIndex: 1,
          role: ConversationRole.user,
          revision: 1,
          text: 'Hello',
          isFinal: true,
        ),
      );
      final before = p.snapshot.revision;
      expect(
        () => p.apply(
          const TurnStartedUpdate(
            turnId: _user,
            turnIndex: 1,
            role: ConversationRole.user,
            providerItemId: 'item-too-late',
          ),
        ),
        _invalid(),
      );
      expect(p.snapshot.revision, before);
      expect(p.snapshot.turns.single.providerItemId, isNull);
    },
  );

  test('started assistant without text can freeze unknown output safely', () {
    final p = _projection();
    p.apply(
      const TurnStartedUpdate(
        turnId: _assistant,
        turnIndex: 2,
        role: ConversationRole.assistant,
        responseId: _response,
      ),
    );
    _freeze(p, boundary: 0);
    p.apply(_text(isFinal: true));
    expect(p.snapshot.context.entries, isEmpty);
    expect(p.snapshot.turns.single.playback.status, DeliveryStatus.unknown);
    expect(
      () => p.apply(
        const TranscriptUpdate(
          turnId: _user,
          turnIndex: 1,
          role: ConversationRole.assistant,
          revision: 1,
          text: 'new output',
          isFinal: true,
          responseId: _response,
        ),
      ),
      _invalid(),
    );
  });
}
