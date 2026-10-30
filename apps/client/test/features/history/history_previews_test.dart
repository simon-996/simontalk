import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/history/history_previews.dart';

void main() {
  for (final preview in [
    historyListLightPreview,
    historyListDarkPreview,
    historyDetailPreview,
    historyEmptyPreview,
    historyErrorPreview,
  ]) {
    testWidgets('history preview ${preview.toString()}', (t) async {
      t.view.physicalSize = const Size(320, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(preview());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(Scaffold), findsOneWidget);
    });
  }
}
