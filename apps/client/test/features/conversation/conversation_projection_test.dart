import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/conversation/conversation_projection.dart';

import '../practice/practice_fixtures.dart';

const userTurn = '10000000-0000-4000-8000-000000000001';
const aiTurn = '10000000-0000-4000-8000-000000000002';
const responseId = '20000000-0000-4000-8000-000000000001';

ConversationScope scope() => ConversationScope(
  accountId: accountId,
  sessionId: practiceId,
  connectionId: connectionId,
  clientInstanceId: clientId,
  epoch: 1,
);

TranscriptUpdate user({
  int revision = 1,
  String text = 'Hello',
  bool finalText = true,
  String id = userTurn,
  int index = 1,
}) => TranscriptUpdate(
  turnId: id,
  turnIndex: index,
  role: ConversationRole.user,
  revision: revision,
  text: text,
  isFinal: finalText,
);

TranscriptUpdate ai({
  int revision = 1,
  String text = 'Hello there',
  bool finalText = true,
  String response = responseId,
}) => TranscriptUpdate(
  turnId: aiTurn,
  turnIndex: 2,
  role: ConversationRole.assistant,
  revision: revision,
  text: text,
  isFinal: finalText,
  responseId: response,
);

PlaybackUpdate playback({
  int revision = 1,
  int transcriptRevision = 1,
  DeliveryStatus status = DeliveryStatus.partial,
  String text = 'Hello',
  int? until = 400,
  PlaybackEvidenceSource source = PlaybackEvidenceSource.deviceOutputAligned,
  String response = responseId,
}) => PlaybackUpdate(
  turnId: aiTurn,
  responseId: response,
  revision: revision,
  transcriptRevision: transcriptRevision,
  status: status,
  playedText: text,
  playedUntilMs: until,
  source: source,
);

Matcher invalid([String code = 'conversation_invalid']) =>
    throwsA(isA<ConversationFailure>().having((e) => e.code, 'code', code));

void main() {
  late ConversationProjection p;
  setUp(() => p = ConversationProjection(scope()));

  test(
    'interim stays separate and final revisions replace the original turn',
    () {
      p.apply(user(text: 'Hel', finalText: false));
      expect(p.snapshot.context.entries, isEmpty);
      expect(p.snapshot.hasUnfinalizedText, isTrue);
      p.apply(user(revision: 2));
      final old = p.snapshot;
      p.apply(user(revision: 3, text: 'Hello!'));
      expect(p.snapshot.turns.length, 1);
      expect(old.turns.single.text, 'Hello');
      expect(p.snapshot.context.entries.single.text, 'Hello!');
      expect(p.snapshot.context.scope.accountId, accountId);
      expect(p.snapshot.context.source, 'client_reported');
    },
  );

  test(
    'full interim replacement does not concatenate retransmitted deltas',
    () {
      p.apply(user(text: 'Hel', finalText: false));
      p.apply(user(revision: 2, text: 'Hello', finalText: false));
      expect(p.snapshot.turns.single.text, 'Hello');
      expect(
        p.apply(user(revision: 2, text: 'Hello', finalText: false)),
        ConversationApplyResult.duplicate,
      );
    },
  );

  test('explicit turn indexes order final events arriving out of order', () {
    p.apply(ai());
    p.apply(user());
    expect(p.snapshot.turns.map((t) => t.turnId), [userTurn, aiTurn]);
    expect(p.snapshot.context.entries.map((t) => t.turnId), [userTurn]);
    expect(p.snapshot.hasUnconfirmedPlayback, isTrue);
  });

  test(
    'old revisions are ignored but conflicting same versions fail atomically',
    () {
      p.apply(user(revision: 2));
      expect(p.apply(user()), ConversationApplyResult.stale);
      expect(p.apply(user(revision: 2)), ConversationApplyResult.duplicate);
      expect(() => p.apply(user(revision: 2, text: 'changed')), invalid());
      expect(p.snapshot.revision, 1);
      expect(p.snapshot.turns.single.text, 'Hello');
    },
  );

  test('a final cannot be downgraded to interim', () {
    p.apply(user());
    expect(() => p.apply(user(revision: 2, finalText: false)), invalid());
    expect(p.snapshot.context.entries.single.text, 'Hello');
  });

  test(
    'empty final preserves lack of recognized text without fabricating context',
    () {
      p.apply(user(text: ''));
      expect(p.snapshot.turns.single.isFinal, isTrue);
      expect(p.snapshot.context.entries, isEmpty);
    },
  );

  test('identity, role, response and index are immutable', () {
    p.apply(ai());
    expect(() => p.apply(ai(revision: 2, response: userTurn)), invalid());
    expect(() => p.apply(user(id: aiTurn, index: 2, revision: 2)), invalid());
    expect(() => p.apply(user(index: 2)), invalid());
    expect(() => p.apply(user(id: aiTurn, index: 3, revision: 3)), invalid());
    expect(p.snapshot.turns.length, 1);
  });

  test(
    'generated final alone never means played, and observed prefix is exact',
    () {
      p.apply(ai());
      expect(p.snapshot.turns.single.playback.status, DeliveryStatus.unknown);
      expect(p.snapshot.context.entries, isEmpty);
      p.apply(playback());
      expect(p.snapshot.turns.single.text, 'Hello there');
      expect(p.snapshot.context.entries.single.text, 'Hello');
      p.apply(
        playback(
          revision: 2,
          status: DeliveryStatus.played,
          text: 'Hello there',
          until: 900,
        ),
      );
      expect(p.snapshot.context.entries.single.text, 'Hello there');
      expect(p.snapshot.hasUnconfirmedPlayback, isFalse);
    },
  );

  test(
    'known nonplayed final is excluded and cannot later turn into playback',
    () {
      p.apply(ai());
      p.apply(playback(status: DeliveryStatus.notPlayed, text: '', until: 0));
      expect(p.snapshot.context.entries, isEmpty);
      expect(p.snapshot.hasUnconfirmedPlayback, isFalse);
      expect(() => p.apply(playback(revision: 2)), invalid());
    },
  );

  test(
    'interim assistant text is never restored even with a prefix observation',
    () {
      p.apply(ai(finalText: false));
      p.apply(playback());
      expect(p.snapshot.context.entries, isEmpty);
      expect(
        () => p.apply(
          playback(
            revision: 2,
            status: DeliveryStatus.played,
            text: 'Hello there',
          ),
        ),
        invalid(),
      );
    },
  );

  test('new generated revision invalidates old aligned playback', () {
    p.apply(ai());
    p.apply(playback());
    p.apply(ai(revision: 2, text: 'Good evening'));
    expect(p.snapshot.context.entries, isEmpty);
    expect(p.snapshot.turns.single.playback.status, DeliveryStatus.unknown);
    expect(p.apply(playback(revision: 2)), ConversationApplyResult.stale);
    p.apply(playback(transcriptRevision: 2, text: 'Good', until: 300));
    expect(p.snapshot.context.entries.single.text, 'Good');
  });

  test('future or unassociated playback is not buffered or trusted', () {
    expect(p.apply(playback()), ConversationApplyResult.awaitingTranscript);
    expect(p.snapshot.turns, isEmpty);
    p.apply(ai());
    expect(
      p.apply(playback(transcriptRevision: 2)),
      ConversationApplyResult.awaitingTranscript,
    );
    p.apply(ai(revision: 2));
    expect(p.snapshot.context.entries, isEmpty);
    p.apply(playback(transcriptRevision: 2));
    expect(p.snapshot.context.entries.single.text, 'Hello');
  });

  test('playback duplicate, stale and conflicting revisions keep accepted evidence', () {
    p.apply(ai());
    p.apply(playback(revision: 2));
    expect(p.apply(playback()), ConversationApplyResult.stale);
    expect(p.apply(playback(revision: 2)), ConversationApplyResult.duplicate);
    expect(() => p.apply(playback(revision: 2, until: 500)), invalid());
    expect(p.snapshot.turns.single.playback.playedUntilMs, 400);
  });

  for (final u in [
    playback(text: 'there'),
    playback(text: 'Hello there'),
    playback(text: ''),
    playback(until: 0),
    playback(until: -1),
    playback(until: 86400001),
    playback(source: PlaybackEvidenceSource.unknown),
    playback(status: DeliveryStatus.played),
    playback(status: DeliveryStatus.notPlayed),
    playback(status: DeliveryStatus.unknown),
    playback(response: userTurn),
    playback(revision: 0),
  ]) {
    test(
      'rejects invalid playback ${u.status} ${u.playedText} ${u.playedUntilMs} ${u.source} ${u.responseId} ${u.revision}',
      () {
        p.apply(ai());
        final before = p.snapshot.revision;
        expect(() => p.apply(u), invalid());
        expect(p.snapshot.revision, before);
        expect(p.snapshot.context.entries, isEmpty);
      },
    );
  }

  test('progress cannot regress in text, time or evidence', () {
    p.apply(ai());
    p.apply(playback());
    expect(() => p.apply(playback(revision: 2, text: 'Hell')), invalid());
    expect(() => p.apply(playback(revision: 2, until: 399)), invalid());
    expect(
      () => p.apply(
        playback(
          revision: 2,
          status: DeliveryStatus.unknown,
          text: '',
          until: null,
          source: PlaybackEvidenceSource.unknown,
        ),
      ),
      invalid(),
    );
    p.apply(
      playback(
        revision: 2,
        status: DeliveryStatus.played,
        text: 'Hello there',
        until: 900,
      ),
    );
    expect(() => p.apply(playback(revision: 3, until: 1000)), invalid());
  });

  test('unknown is an explicit absence of playback evidence', () {
    p.apply(ai());
    p.apply(
      playback(
        status: DeliveryStatus.unknown,
        text: '',
        until: null,
        source: PlaybackEvidenceSource.unknown,
      ),
    );
    expect(p.snapshot.hasUnconfirmedPlayback, isTrue);
    expect(p.snapshot.context.entries, isEmpty);
  });

  for (final u in [
    user(revision: 0),
    user(index: 0),
    user(id: 'bad'),
    user(text: '汉' * 2731),
    ai(response: 'bad'),
    const TranscriptUpdate(
      turnId: userTurn,
      turnIndex: 1,
      role: ConversationRole.user,
      revision: 1,
      text: 'Hello',
      isFinal: true,
      responseId: responseId,
    ),
  ]) {
    test(
      'rejects invalid transcript ${u.turnId} ${u.turnIndex} ${u.revision} ${u.text.length} ${u.responseId}',
      () {
        expect(() => p.apply(u), invalid());
        expect(p.snapshot.turns, isEmpty);
      },
    );
  }

  test('UTF8 aggregate limit is atomic and replacing text releases its budget', () {
    for (var i = 0; i < 32; i++) {
      p.apply(
        user(
          id: '10000000-0000-4000-8000-${(i + 10).toString().padLeft(12, '0')}',
          index: i + 1,
          text: 'x' * 8192,
        ),
      );
    }
    expect(
      () => p.apply(user(index: 40)),
      invalid('conversation_limit_reached'),
    );
    p.apply(
      user(id: '10000000-0000-4000-8000-000000000010', revision: 2, text: ''),
    );
    p.apply(user(index: 40));
    expect(p.snapshot.turns.length, 33);
  });

  test('aligned played prefixes consume the same aggregate memory budget', () {
    p.apply(ai(text: 'x' * 8192));
    for (var i = 0; i < 31; i++) {
      p.apply(
        user(
          id: '10000000-0000-4000-8000-${(i + 10).toString().padLeft(12, '0')}',
          index: i + 3,
          text: 'x' * 8192,
        ),
      );
    }
    expect(
      () => p.apply(playback(text: 'x', until: 1)),
      invalid('conversation_limit_reached'),
    );
    expect(p.snapshot.turns.first.playback.status, DeliveryStatus.unknown);
    expect(p.snapshot.turns.length, 32);
  });

  test('provider association cannot change on a revised final', () {
    TranscriptUpdate item(String provider, int revision) => TranscriptUpdate(
      turnId: userTurn,
      turnIndex: 1,
      role: ConversationRole.user,
      revision: revision,
      text: 'Hello',
      isFinal: true,
      providerItemId: provider,
    );
    p.apply(item('item-1', 1));
    expect(() => p.apply(item('item-2', 2)), invalid());
    expect(p.snapshot.turns.single.providerItemId, 'item-1');
  });

  test('malformed Unicode is rejected and blank finals are not context', () {
    expect(() => p.apply(user(text: String.fromCharCode(0xd800))), invalid());
    p.apply(user(text: ' \n\t'));
    expect(p.snapshot.context.entries, isEmpty);
  });

  test(
    'notPlayed is a final delivery decision rather than temporary waiting',
    () {
      p.apply(ai(finalText: false));
      expect(
        () => p.apply(
          playback(status: DeliveryStatus.notPlayed, text: '', until: 0),
        ),
        invalid(),
      );
      expect(p.snapshot.turns.single.playback.status, DeliveryStatus.unknown);
    },
  );

  test('turn count is bounded without evicting confirmed history', () {
    for (var i = 0; i < 256; i++) {
      p.apply(
        user(
          id: '10000000-0000-4000-8000-${(i + 10).toString().padLeft(12, '0')}',
          index: i + 1,
        ),
      );
    }
    expect(
      () => p.apply(user(index: 300)),
      invalid('conversation_limit_reached'),
    );
    expect(p.snapshot.turns.length, 256);
  });

  test(
    'snapshots and context lists are immutable and seal ignores late text',
    () {
      p.apply(user());
      final before = p.snapshot;
      expect(() => before.turns.clear(), throwsUnsupportedError);
      expect(() => before.context.entries.clear(), throwsUnsupportedError);
      p.seal();
      expect(
        p.apply(user(revision: 2, text: 'late')),
        ConversationApplyResult.closed,
      );
      expect(p.snapshot.isSealed, isTrue);
      expect(p.snapshot.turns.single.text, 'Hello');
      p.clear();
      expect(p.snapshot.turns, isEmpty);
      expect(p.snapshot.isSealed, isTrue);
      expect(before.turns.single.text, 'Hello');
    },
  );

  test('invalid scope never creates a projection', () {
    expect(
      () => ConversationScope(
        accountId: 'bad',
        sessionId: practiceId,
        connectionId: connectionId,
        clientInstanceId: clientId,
        epoch: 1,
      ),
      invalid(),
    );
    expect(
      () => ConversationScope(
        accountId: accountId,
        sessionId: practiceId,
        connectionId: connectionId,
        clientInstanceId: clientId,
        epoch: 0,
      ),
      invalid(),
    );
  });
}
