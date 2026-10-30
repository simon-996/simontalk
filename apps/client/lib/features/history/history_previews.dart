import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'history_controller.dart';
import 'history_models.dart';
import 'history_view.dart';

// Preview-only samples. Connected screens only receive repository data.
const _owner = '11111111-1111-4111-8111-111111111111';
Map<String, dynamic> _item(int id) => {
  'id': '22222222-2222-4222-8222-${'$id'.padLeft(12, '0')}',
  'kind': 'ordinary',
  'source_session_id': null,
  'status': 'completed',
  'created_at': '2026-10-23T10:30:00+08:00',
  'ended_at': '2026-10-23T10:34:00+08:00',
  'difficulty': 'beginner',
  'completion_status': 'sealed',
  'coverage': 'complete',
  'connection_pending': true,
};
void _noop() {}
Widget _example({
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool detail = false,
  bool empty = false,
  bool failed = false,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: HistoryView(
    state: failed ? HistoryState.failed : HistoryState.ready,
    detail: detail,
    page: detail || failed
        ? null
        : HistoryPage.fromJson({
            'schema_version': 'practice_history_v1',
            'source': 'server_recorded',
            'account_id': _owner,
            'limit': 10,
            'items': empty ? [] : [_item(2), _item(1)],
            'next_cursor': null,
          }, accountId: _owner),
    item: detail ? HistoryItem.fromJson(_item(1)) : null,
    errorCode: failed ? 'network_error' : null,
    onRefresh: _noop,
    onBack: _noop,
    onText: _noop,
    onReview: _noop,
    onPractice: _noop,
    onAccount: _noop,
    onOpen: (_) {},
  ),
);

@Preview(
  name: '记录 · 浅色列表',
  group: '练习历史',
  size: Size(760, 900),
  wrapper: previewWithFonts,
)
Widget historyListLightPreview() => _example();
@Preview(
  name: '记录 · 深色320 · 200%',
  group: '练习历史',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget historyListDarkPreview() =>
    _example(brightness: Brightness.dark, scale: 2);
@Preview(
  name: '记录 · 保存与连接独立',
  group: '练习历史',
  size: Size(375, 900),
  wrapper: previewWithFonts,
)
Widget historyDetailPreview() => _example(detail: true);
@Preview(
  name: '记录 · 空态',
  group: '练习历史',
  size: Size(375, 700),
  wrapper: previewWithFonts,
)
Widget historyEmptyPreview() => _example(empty: true);
@Preview(
  name: '记录 · 网络失败',
  group: '练习历史',
  size: Size(375, 700),
  wrapper: previewWithFonts,
)
Widget historyErrorPreview() => _example(failed: true);
