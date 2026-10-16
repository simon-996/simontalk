import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/app_theme.dart';

void main() {
  test('card labels keep readable semantic foreground in both themes', () {
    for (final brightness in Brightness.values) {
      final theme = buildAppTheme(brightness);
      expect(theme.textTheme.labelLarge!.color, theme.colorScheme.onSurface);
    }
  });
}
