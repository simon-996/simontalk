import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import 'deletion_controller.dart';
import 'deletion_models.dart';
import 'deletion_view.dart';

void _noop() {}
Widget _example({
  bool dark = false,
  bool unknown = false,
  bool failed = false,
}) => MaterialApp(
  theme: buildAppTheme(dark ? Brightness.dark : Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(dark ? 2 : 1),
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: DeletionView(
    state: unknown
        ? DeletionState.unconfirmed
        : failed
        ? DeletionState.failed
        : DeletionState.ready,
    scope: unknown || failed
        ? null
        : DeletionScope.fromJson(
            {
              'schema_version': 'practice_deletion_scope_v1',
              'source': 'server_recorded',
              'account_id': '11111111-1111-4111-8111-111111111111',
              'session_id': '22222222-2222-4222-8222-222222222222',
              'kind': 'ordinary',
              'record_count': 3,
              'rehearsal_count': 2,
              'scope_version': 'a' * 64,
              'connection_pending': true,
            },
            accountId: '11111111-1111-4111-8111-111111111111',
            sessionId: '22222222-2222-4222-8222-222222222222',
          ),
    errorCode: failed ? 'deletion_scope_changed' : null,
    canReplay: unknown,
    onKeep: _noop,
    onConfirm: _noop,
    onLoad: _noop,
    onCheck: _noop,
    onReplay: _noop,
  ),
);
@Preview(name: '删除 · 完整范围', size: Size(760, 1000), wrapper: previewWithFonts)
Widget deletionScopePreview() => _example();
@Preview(name: '删除 · 深色320大字', size: Size(320, 1000), wrapper: previewWithFonts)
Widget deletionDarkPreview() => _example(dark: true);
@Preview(name: '删除 · 结果未知', size: Size(760, 900), wrapper: previewWithFonts)
Widget deletionUnknownPreview() => _example(unknown: true);
@Preview(name: '删除 · 范围已变化', size: Size(760, 900), wrapper: previewWithFonts)
Widget deletionChangedPreview() => _example(failed: true);
