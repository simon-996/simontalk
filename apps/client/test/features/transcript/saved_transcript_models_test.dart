import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/transcript/saved_transcript_models.dart';

import 'transcript_fixtures.dart';

void main() {
  SavedTranscriptPage parse(
    Map<String, dynamic> json, {
    int? offset,
    String? item,
  }) => SavedTranscriptPage.fromJson(
    json,
    target: target(),
    offset: offset,
    reviewItemId: item,
  );
  test('ordinary, empty and empty terminal pages obey cursors', () {
    expect(parse(pageJson(total: 23)).nextOffset, 16);
    expect(parse(pageJson(total: 0)).items, isEmpty);
    expect(parse(pageJson(total: 23, offset: 23), offset: 23).items, isEmpty);
  });
  test(
    'initial focus must begin with exact target; explicit offset can page away',
    () {
      expect(
        parse(
          pageJson(total: 23, offset: 18, focus: true, focusOrdinal: 19),
          item: itemId,
        ).items.first.ordinal,
        19,
      );
      expect(
        () => parse(
          pageJson(total: 23, focus: true, focusOrdinal: 19),
          item: itemId,
        ),
        throwsFormatException,
      );
      expect(
        parse(
          pageJson(total: 23, focus: true, focusOrdinal: 19),
          offset: 0,
          item: itemId,
        ).focus!.ordinal,
        19,
      );
    },
  );
  test('nullable keys are mandatory and all shape fields strict', () {
    var mutationIndex = 0;
    for (final change in <void Function(Map<String, dynamic>)>[
      (j) => j.remove('focus'),
      (j) => j['extra'] = true,
      // Dart Web uses JavaScript numbers: integral doubles satisfy `is int`.
      // Fractional values must be rejected on both platforms; VM also keeps
      // the distinct integral-double type check.
      (j) => j['total_turns'] = 1.5,
      if (!kIsWeb) (j) => j['total_turns'] = 1.0,
      (j) => j['total_turns'] = true,
      (j) => j['total_turns'] = -1,
      (j) => j['total_turns'] = 8193,
      (j) => j['next_offset'] = 1,
      (j) => j['limit'] = 17,
      (j) => j['source'] = 'client',
      (j) => j['account_id'] = requestKey,
      (j) => j['practice_input_hash'] = 'b' * 64,
      (j) => j['items'][0].remove('played_text'),
      (j) => j['items'][0]['revision'] = 0,
      (j) => j['items'][0]['ordinal'] = 2,
      (j) => j['items'][0]['final_text'] = '\u0000',
      (j) => j['items'][0]['final_text'] = '中' * 2731,
      (j) => j['items'][0]['final_text'] = '\ud800',
      (j) => j['items'][0]['final_text'] = '\udc00',
      (j) => j['items'][0]['playback_status'] = 'played',
      (j) => j['sealed_at'] = '2026-02-30T00:00:00Z',
      (j) => j['gap_codes'] = ['unknown'],
      (j) => j['coverage'] = 'complete',
    ]) {
      final json = pageJson();
      change(json);
      expect(
        () => parse(json),
        throwsFormatException,
        reason: 'shape mutation ${mutationIndex++}',
      );
    }
  });
  test(
    'every nullable wire field must be explicit and malformed roles never leak',
    () {
      for (final field in ['focus', 'previous_offset', 'next_offset']) {
        final j = pageJson()..remove(field);
        expect(() => parse(j), throwsFormatException);
      }
      for (final field in [
        'final_text',
        'final_source',
        'playback_status',
        'played_text',
        'played_revision',
      ]) {
        final j = pageJson();
        j['items'][0].remove(field);
        expect(() => parse(j), throwsFormatException);
      }
      for (final value in ['system', '', null, true]) {
        final j = pageJson();
        j['items'][0]['role'] = value;
        expect(() => parse(j), throwsFormatException);
      }
    },
  );
  test('assistant old prefix stays separate, rev0 is untranscribed and user empty valid', () {
    final j = pageJson();
    final t = j['items'][0];
    t['role'] = 'assistant';
    t['revision'] = 2;
    t['final_text'] = 'An entirely new final.';
    t['playback_status'] = 'partial';
    t['played_text'] = 'Old';
    t['played_revision'] = 1;
    expect(parse(j).items.first.playedText, 'Old');
    t['revision'] = 0;
    t['final_text'] = null;
    t['final_source'] = null;
    t['played_text'] = null;
    t['played_revision'] = null;
    t['playback_status'] = 'unknown';
    expect(parse(j).items.first.revision, 0);
    t['playback_status'] = 'revoked';
    expect(parse(j).items.first.playbackStatus, 'revoked');
    t['playback_status'] = 'not_played';
    expect(() => parse(j), throwsFormatException);
    final empty = pageJson();
    empty['items'][0]['final_text'] = '';
    expect(parse(empty).items.first.finalText, '');
  });
  test(
    'valid emoji and exact UTF8 bounds are retained without replacement',
    () {
      final j = pageJson();
      j['items'][0]['final_text'] = '😀' * 2048;
      expect(parse(j).items.first.finalText, '😀' * 2048);
      j['items'][0]['final_text'] = 'a' * 8192;
      expect(parse(j).items.first.finalText!.length, 8192);
      j['items'][0]['final_text'] = 'a' * 8193;
      expect(() => parse(j), throwsFormatException);
    },
  );
  test('same turn UUID in distinct connections is retained separately', () {
    final j = pageJson(total: 2);
    j['items'][1]['turn_id'] = turnId;
    j['items'][1]['connection_id'] = requestKey;
    j['items'][1]['epoch'] = 2;
    expect(parse(j).items.length, 2);
  });
  test('a nonempty whitespace playback prefix remains legal source text', () {
    final j = pageJson();
    j['items'][0] = turnJson(1, role: 'assistant')
      ..['final_text'] = ' Hello'
      ..['playback_status'] = 'partial'
      ..['played_text'] = ' '
      ..['played_revision'] = 1;
    expect(parse(j).items.first.playedText, ' ');
    final quoted = pageJson(focus: true);
    quoted['focus']['exact_quote'] = ' ';
    expect(() => parse(quoted, item: itemId), throwsFormatException);
  });
  test('focus quote, scope and immutable page anchors are enforced', () {
    final j = pageJson(focus: true);
    j['focus']['exact_quote'] = 'not present';
    expect(() => parse(j, item: itemId), throwsFormatException);
    final first = parse(pageJson(total: 23, focus: true), item: itemId);
    final later = parse(
      pageJson(total: 23, offset: 16, focus: true),
      offset: 16,
      item: itemId,
    );
    expect(first.hasSameAnchor(later), isTrue);
    final changed = pageJson(total: 24, offset: 16, focus: true);
    expect(
      first.hasSameAnchor(parse(changed, offset: 16, item: itemId)),
      isFalse,
    );
  });
}
