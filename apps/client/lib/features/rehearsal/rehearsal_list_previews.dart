import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'rehearsal_list_controller.dart';
import 'rehearsal_list_models.dart';
import 'rehearsal_list_view.dart';

/// Explicit isolated metadata examples. Never imported by the connected screen.
RehearsalListPage rehearsalListPreviewPage({
  bool empty = false,
}) => RehearsalListPage.fromJson(
  {
    'schema_version': 'rehearsal_list_v1',
    'source': 'server_recorded',
    'account_id': '11111111-1111-4111-8111-111111111111',
    'source_session_id': '22222222-2222-4222-8222-222222222222',
    'limit': 10,
    'items': empty
        ? <dynamic>[]
        : [
            for (var i = 10; i >= 1; i--)
              {
                'id':
                    '99999999-9999-4999-8999-${i.toString().padLeft(12, '0')}',
                'kind': 'rehearsal',
                'source_session_id': '22222222-2222-4222-8222-222222222222',
                'source_review_item_id': '77777777-7777-4777-8777-777777777777',
                'status': i == 10
                    ? 'created'
                    : i == 9
                    ? 'active'
                    : i == 8
                    ? 'ending'
                    : i == 7
                    ? 'failed'
                    : 'cancelled',
                'created_at': '2026-10-23T01:00:00.123456Z',
                'ended_at': i >= 8 ? null : '2026-10-23T01:05:00Z',
              },
          ],
    'next_before_id': empty ? null : '99999999-9999-4999-8999-000000000001',
  },
  accountId: '11111111-1111-4111-8111-111111111111',
  sourceSessionId: '22222222-2222-4222-8222-222222222222',
);
void rehearsalListPreviewNoop() {}
Widget _sample({
  Brightness brightness = Brightness.light,
  double scale = 1,
  bool empty = false,
  bool failed = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: RehearsalListView(
    state: failed ? RehearsalListState.failed : RehearsalListState.ready,
    page: rehearsalListPreviewPage(empty: empty),
    errorCode: failed ? 'network_error' : null,
    canNext: !empty,
    onRefresh: rehearsalListPreviewNoop,
    onNext: rehearsalListPreviewNoop,
    onBack: rehearsalListPreviewNoop,
    onOpen: (_) {},
  ),
);
@Preview(
  name: '关联列表 · 浅色',
  group: '逐句重练',
  size: Size(760, 1000),
  wrapper: previewWithFonts,
)
Widget rehearsalListLightPreview() => _sample();
@Preview(
  name: '关联列表 · 深320 · 200%',
  group: '逐句重练',
  size: Size(320, 900),
  wrapper: previewWithFonts,
)
Widget rehearsalListDarkPreview() =>
    _sample(brightness: Brightness.dark, scale: 2);
@Preview(
  name: '尚无关联重练',
  group: '逐句重练',
  size: Size(375, 760),
  wrapper: previewWithFonts,
)
Widget rehearsalListEmptyPreview() => _sample(empty: true);
@Preview(
  name: '翻页失败 · 保留原页',
  group: '逐句重练',
  size: Size(375, 900),
  wrapper: previewWithFonts,
)
Widget rehearsalListFailedPreview() => _sample(failed: true);
