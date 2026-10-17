import 'package:flutter/material.dart';

import '../core/app_fonts.dart';

Future<void>? _fonts;

/// Previewer has its own main() and packages this application's assets as a dependency.
/// Load fonts once for all cards, before any preview text is laid out.
Widget previewWithFonts(Widget child) =>
    PreviewFontGate(fonts: _fonts ??= _loadPreviewFonts(), child: child);

Future<void> _loadPreviewFonts() async {
  // The previewer's own card labels use Roboto and cannot inherit a card's theme.
  // Give that family the same verified CJK coverage in the preview process only.
  await loadAppFonts(
    assetPrefix: 'packages/simontalk_client/',
    aliases: const ['Roboto'],
  );
}

class PreviewFontGate extends StatelessWidget {
  const PreviewFontGate({super.key, required this.fonts, required this.child});
  final Future<void> fonts;
  final Widget child;

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: fonts,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(
          child: Text(
            'Preview fonts unavailable. Restart after checking local assets.',
          ),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CircularProgressIndicator(
            semanticsLabel: 'Loading preview fonts',
          ),
        );
      }
      return child;
    },
  );
}
