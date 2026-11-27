import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../account/account_models.dart';
import '../practice/practice_models.dart';
import 'rehearsal_controller.dart';
import 'rehearsal_models.dart';
import 'rehearsal_view.dart';

/// Isolated samples only. Connected screens never import preview content.
RehearsalTarget rehearsalPreviewTarget() => RehearsalTarget.fromJson(
  {
    'schema_version': 'rehearsal_target_v1',
    'source': 'server_derived',
    'evidence_source': 'client_reported',
    'account_id': '11111111-1111-4111-8111-111111111111',
    'source_session_id': '22222222-2222-4222-8222-222222222222',
    'source_kind': 'ordinary',
    'item_id': '77777777-7777-4777-8777-777777777777',
    'job_id': '66666666-6666-4666-8666-666666666666',
    'result_hash': 'c' * 64,
    'input_revision': 1,
    'practice_input_hash': 'a' * 64,
    'review_input_hash': 'b' * 64,
    'policy_version': 'review_input_v1',
    'generation_policy_version': 'review_generation_v1',
    'source_connection_id': '33333333-3333-4333-8333-333333333333',
    'source_client_instance_id': '44444444-4444-4444-8444-444444444444',
    'source_epoch': 1,
    'source_turn_id': '88888888-8888-4888-8888-888888888888',
    'revision': 1,
    'source_text': 'I want to talk about my weekend. I enjoy English.',
    'exact_quote': 'I enjoy English.',
    'kind': 'polish',
    'basis': 'text_only',
    'explanation': '说出具体喜欢的活动，让意思更清楚。',
    'suggestion': 'I enjoy learning English.',
    'situation_mode': 'source_original',
    'context_before': <dynamic>[],
    'target_hash': 'd' * 64,
  },
  accountId: '11111111-1111-4111-8111-111111111111',
  sourceSessionId: '22222222-2222-4222-8222-222222222222',
  itemId: '77777777-7777-4777-8777-777777777777',
);
void rehearsalPreviewNoop() {}
Widget _sample({
  Brightness brightness = Brightness.light,
  double scale = 1,
  RehearsalState state = RehearsalState.ready,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: RehearsalView(
    state: state,
    target: state == RehearsalState.failed ? null : rehearsalPreviewTarget(),
    difficulty: Difficulty.beginner,
    errorCode: state == RehearsalState.failed
        ? 'realtime_unavailable'
        : state == RehearsalState.unconfirmed
        ? 'network_error'
        : null,
    onConfirm: rehearsalPreviewNoop,
    onDifficulty: (_) {},
    onRefresh: rehearsalPreviewNoop,
    onReplay: rehearsalPreviewNoop,
    onBack: rehearsalPreviewNoop,
  ),
);
@Preview(
  name: '目标确认 · 浅色',
  group: '逐句重练',
  size: Size(760, 1050),
  wrapper: previewWithFonts,
)
Widget rehearsalLightPreview() => _sample();
@Preview(
  name: '目标确认 · 深色320 · 200%',
  group: '逐句重练',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget rehearsalDarkPreview() => _sample(brightness: Brightness.dark, scale: 2);
@Preview(
  name: '准备结果待确认',
  group: '逐句重练',
  size: Size(375, 1050),
  wrapper: previewWithFonts,
)
Widget rehearsalUnknownPreview() => _sample(state: RehearsalState.unconfirmed);
@Preview(
  name: '服务尚未就绪',
  group: '逐句重练',
  size: Size(375, 760),
  wrapper: previewWithFonts,
)
Widget rehearsalUnavailablePreview() => _sample(state: RehearsalState.failed);

@Preview(
  name: '已登记准备 · 可进入重练通话',
  group: '逐句重练',
  size: Size(760, 1050),
  wrapper: previewWithFonts,
)
Widget rehearsalPreparedPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.light),
  home: RehearsalView(
    state: RehearsalState.prepared,
    target: rehearsalPreviewTarget(),
    preparation: PracticePreparation.fromJson({
      'id': '99999999-9999-4999-8999-999999999999',
      'mode': 'free_chat',
      'kind': 'rehearsal',
      'source_session_id': '22222222-2222-4222-8222-222222222222',
      'source_review_item_id': '77777777-7777-4777-8777-777777777777',
      'status': 'created',
      'connection_epoch': 0,
      'configuration': {
        'schema_version': 1,
        'preferences': {
          'difficulty': 'beginner',
          'speech_pace': 'normal',
          'subtitle_default': true,
          'chinese_hints_enabled': true,
          'translation_mode': 'on_demand',
          'version': 1,
        },
        'effective_difficulty': 'intermediate',
        'provider': {
          'provider': 'dashscope',
          'region': 'cn-beijing',
          'model': 'qwen3.8-omni-flash-realtime',
          'config_id': 'preview-v1',
        },
      },
      'created_at': '2026-11-25T00:00:00Z',
      'ended_at': null,
    }),
    difficulty: Difficulty.intermediate,
    onEnterSession: rehearsalPreviewNoop,
    onHistory: rehearsalPreviewNoop,
    onDiscard: rehearsalPreviewNoop,
    onBack: rehearsalPreviewNoop,
    onPractice: rehearsalPreviewNoop,
  ),
);
