{{flutter_js}}
{{flutter_build_config}}

// Renderer and supported text assets are served with the app, including in China.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'assets/font_fallback/',
  },
});
