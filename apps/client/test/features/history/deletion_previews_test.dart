import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/history/deletion_previews.dart';

void main() {
  for (final sample in [
    deletionScopePreview,
    deletionDarkPreview,
    deletionUnknownPreview,
    deletionChangedPreview,
  ]) {
    testWidgets('deletion sample $sample is independently renderable', (
      t,
    ) async {
      t.view.physicalSize = const Size(320, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(sample());
      await t.pumpAndSettle();
      expect(find.text('删除练习记录'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
