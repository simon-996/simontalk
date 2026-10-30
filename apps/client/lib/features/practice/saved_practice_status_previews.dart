import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../conversation/conversation_models.dart';
import '../history/history_models.dart';
import 'practice_completion_models.dart';
import 'saved_practice_status_controller.dart';
import 'saved_practice_status_view.dart';

const _account = '11111111-1111-4111-8111-111111111111';
const _session = '22222222-2222-4222-8222-222222222222';
void _noop() {}

Widget _sample({
  bool dark = false,
  bool complete = false,
  bool saving = false,
  bool failed = false,
}) {
  final completion = PracticeCompletionSummary.fromJson(
    {
      'source': 'server_recorded',
      'account_id': _account,
      'session_id': _session,
      'origin_connection_id': '33333333-3333-4333-8333-333333333333',
      'client_instance_id': '44444444-4444-4444-8444-444444444444',
      'epoch': 1,
      'end_key': '55555555-5555-4555-8555-555555555555',
      'status': saving ? 'ending' : 'sealed',
      'accepted_at': '2026-10-24T08:00:00Z',
      'final_upload_deadline': '2026-10-24T08:00:30Z',
      'sealed_at': saving ? null : '2026-10-24T08:00:03Z',
      'input_revision': saving ? 0 : 1,
      'input_hash': saving ? null : 'a' * 64,
      'coverage': saving
          ? 'pending'
          : complete
          ? 'complete'
          : 'incomplete',
      'connection_count': 2,
      'gap_codes': saving || complete
          ? <String>[]
          : ['tail_unconfirmed', 'transcript_missing'],
    },
    scope: ConversationScope(
      accountId: _account,
      sessionId: _session,
      connectionId: '33333333-3333-4333-8333-333333333333',
      clientInstanceId: '44444444-4444-4444-8444-444444444444',
      epoch: 1,
    ),
  );
  final item = HistoryItem.fromJson({
    'id': _session,
    'kind': 'ordinary',
    'source_session_id': null,
    'status': saving ? 'ending' : 'completed',
    'created_at': '2026-10-24T07:55:00Z',
    'ended_at': '2026-10-24T08:00:00Z',
    'difficulty': 'beginner',
    'completion_status': saving ? 'ending' : 'sealed',
    'coverage': completion.coverage.name,
    'connection_pending': !complete,
  });
  return MaterialApp(
    theme: buildAppTheme(dark ? Brightness.dark : Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(dark ? 2 : 1),
        disableAnimations: true,
      ),
      child: child!,
    ),
    home: SavedPracticeStatusView(
      state: failed
          ? SavedPracticeStatusState.failed
          : SavedPracticeStatusState.ready,
      item: failed ? null : item,
      completion: failed ? null : completion,
      errorCode: failed ? 'network_error' : null,
      onBack: _noop,
      onRefresh: _noop,
    ),
  );
}

@Preview(name: '保存结果 · 完整', size: Size(760, 1000), wrapper: previewWithFonts)
Widget savedPracticeCompletePreview() => _sample(complete: true);
@Preview(
  name: '保存结果 · 缺口深色320大字',
  size: Size(320, 1100),
  wrapper: previewWithFonts,
)
Widget savedPracticeGapPreview() => _sample(dark: true);
@Preview(name: '保存结果 · 正在保存', size: Size(375, 1000), wrapper: previewWithFonts)
Widget savedPracticeSavingPreview() => _sample(saving: true);
@Preview(name: '保存结果 · 读取失败', size: Size(375, 900), wrapper: previewWithFonts)
Widget savedPracticeFailedPreview() => _sample(failed: true);
