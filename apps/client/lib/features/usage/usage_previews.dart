import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/account_components.dart';
import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'usage_controller.dart';
import 'usage_models.dart';
import 'usage_view.dart';

const _account = '11111111-1111-4111-8111-111111111111';
const _session = '22222222-2222-4222-8222-222222222222';
void _noop() {}

Map<String, dynamic> _voiceJson({
  required int count,
  int? deleted,
  int incomplete = 0,
  int detailIncomplete = 0,
  int input = 0,
  int output = 0,
  int inText = 0,
  int inAudio = 0,
  int outText = 0,
  int outAudio = 0,
}) => {
  'response_count': count,
  'deleted_response_count': ?deleted,
  'incomplete_count': incomplete,
  'detail_incomplete_count': detailIncomplete,
  'known_input_tokens': input,
  'known_output_tokens': output,
  'known_input_text_tokens': inText,
  'known_input_audio_tokens': inAudio,
  'known_output_text_tokens': outText,
  'known_output_audio_tokens': outAudio,
};

Widget _accountSample({bool dark = false, bool empty = false}) {
  final summary = AccountUsageSummary.fromJson({
    'schema_version': 'account_usage_v1',
    'source': 'server_recorded',
    'account_id': _account,
    'checked_at': '2026-11-25T06:00:00Z',
    'latest_recorded_at': empty ? null : '2026-11-25T05:55:00Z',
    'connection_pending_count': empty ? 0 : 1,
    'deleted_practice_count': empty ? 0 : 2,
    'voice_ordinary': empty
        ? _voiceJson(count: 0, deleted: 0)
        : _voiceJson(
            count: 3,
            deleted: 1,
            incomplete: 1,
            detailIncomplete: 1,
            input: 1540,
            output: 74,
            inText: 1456,
            inAudio: 84,
            outText: 17,
            outAudio: 57,
          ),
    'voice_rehearsal': empty
        ? _voiceJson(count: 0, deleted: 0)
        : _voiceJson(
            count: 1,
            deleted: 1,
            input: 310,
            output: 18,
            inText: 290,
            inAudio: 20,
            outText: 5,
            outAudio: 13,
          ),
    'review': {
      'attempt_count': empty ? 0 : 2,
      'deleted_attempt_count': empty ? 0 : 1,
      'incomplete_count': empty ? 0 : 1,
      'known_input_tokens': empty ? 0 : 645,
      'known_output_tokens': empty ? 0 : 5,
    },
  }, accountId: _account);
  return MaterialApp(
    theme: buildAppTheme(dark ? Brightness.dark : Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(dark ? 2 : 1),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: AccountFrame(
      wide: true,
      child: AccountUsageView(
        state: UsageReadState.ready,
        summary: summary,
        onRefresh: _noop,
      ),
    ),
  );
}

Widget _practiceSample() {
  final summary = PracticeUsageSummary.fromJson(
    {
      'schema_version': 'practice_usage_v1',
      'source': 'server_recorded',
      'account_id': _account,
      'session_id': _session,
      'kind': 'ordinary',
      'checked_at': '2026-11-25T06:00:00Z',
      'latest_recorded_at': '2026-11-25T05:55:00Z',
      'connection_count': 1,
      'connection_pending': true,
      'voice': _voiceJson(
        count: 1,
        input: 770,
        output: 29,
        inText: 728,
        inAudio: 42,
        outText: 7,
        outAudio: 22,
      ),
      'review': {
        'attempt_count': 1,
        'incomplete_count': 0,
        'known_input_tokens': 645,
        'known_output_tokens': 5,
      },
    },
    accountId: _account,
    sessionId: _session,
  );
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: AccountFrame(
      child: PracticeUsageView(
        state: UsageReadState.ready,
        summary: summary,
        onRefresh: _noop,
      ),
    ),
  );
}

@Preview(name: '本人用量 · 含删除与缺口', size: Size(760, 980), wrapper: previewWithFonts)
Widget accountUsageFullPreview() => _accountSample();

@Preview(
  name: '本人用量 · 深色320大字',
  size: Size(320, 1280),
  wrapper: previewWithFonts,
)
Widget accountUsageDarkCompactPreview() => _accountSample(dark: true);

@Preview(name: '本人用量 · 空态', size: Size(390, 760), wrapper: previewWithFonts)
Widget accountUsageEmptyPreview() => _accountSample(empty: true);

@Preview(name: '单次练习用量 · 已记录', size: Size(390, 760), wrapper: previewWithFonts)
Widget practiceUsageReadyPreview() => _practiceSample();
