{{flutter_js}}
{{flutter_build_config}}

// Renderer and supported text assets are served with the app, including in China.
const config = {
  canvasKitBaseUrl: 'canvaskit/',
  fontFallbackBaseUrl: 'assets/font_fallback/',
};
const startupFailed = () => window.dispatchEvent(new Event('simontalk-startup-error'));
_flutter.loader.load({
  config,
  onEntrypointLoaded: async (engineInitializer) => {
    try {
      const appRunner = await engineInitializer.initializeEngine(config);
      await appRunner.runApp();
    } catch (_) {
      startupFailed();
    }
  },
}).catch(startupFailed);
