import 'dart:async';
import 'dart:convert';

/// A controller that enables programmatic interaction with a [ModelViewer]
/// rendered via Three.js on Windows.
///
/// Pass a [ModelViewerController] instance to [ModelViewer.controller].
/// After the WebView finishes loading all methods become available.
///
/// ```dart
/// final _controller = ModelViewerController();
///
/// ModelViewer(
///   src: 'assets/model.glb',
///   controller: _controller,
///   javascriptChannels: {
///     JavascriptChannel('onReady', onMessageReceived: (msg) {
///       final data = jsonDecode(msg.message);
///       print(data['animations']); // ['Idle', 'Walk', 'Run']
///     }),
///   },
/// )
///
/// // Later:
/// _controller.playAnimation('Walk');
/// _controller.setIdleAnimation('Idle');
/// _controller.setAfterFinishMode('idle');     // return to idle after clip ends
/// _controller.playSequence(['Walk', 'Run']);   // play in order then idle
/// _controller.setMaterialView(true);
/// ```
class ModelViewerController {
  final Completer<dynamic> _completer = Completer<dynamic>();

  /// Called internally by the platform implementation when the native
  /// WebView controller becomes available. Do not call this yourself.
  void attach(dynamic nativeController) {
    if (!_completer.isCompleted) _completer.complete(nativeController);
  }

  /// Whether the controller is ready to accept commands.
  bool get isReady => _completer.isCompleted;

  // ── Low-level ─────────────────────────────────────────────────────────────

  /// Evaluates arbitrary JavaScript source in the WebView.
  Future<dynamic> evaluateJavascript(String js) async {
    final ctrl = await _completer.future;
    return (ctrl as dynamic).evaluateJavascript(source: js);
  }

  // ── Animation query ───────────────────────────────────────────────────────

  /// Returns all animation clip names embedded in the loaded GLB.
  ///
  /// The [onReady] JS channel delivers the same list on first load, so you
  /// usually only need this for a late / on-demand query.
  Future<List<String>> getAnimations() async {
    final raw = await evaluateJavascript(
      "window.MVApi ? window.MVApi.getAnimationNames() : '[]';",
    );
    try {
      return List<String>.from(jsonDecode(raw as String? ?? '[]') as List);
    } catch (_) {
      return const [];
    }
  }

  /// Returns the name of the clip currently playing.
  Future<String?> getCurrentAnimation() async {
    final raw = await evaluateJavascript(
      "window.MVApi ? window.MVApi.getCurrentAnimation() : '';",
    );
    return raw as String?;
  }

  /// Returns the name of the clip designated as the idle / default state.
  Future<String?> getIdleAnimation() async {
    final raw = await evaluateJavascript(
      "window.MVApi ? window.MVApi.getIdleAnimation() : '';",
    );
    return raw as String?;
  }

  /// Returns the current after-finish mode: `'loop'`, `'idle'`, or `'hold'`.
  Future<String?> getAfterFinishMode() async {
    final raw = await evaluateJavascript(
      "window.MVApi ? window.MVApi.getAfterFinishMode() : 'loop';",
    );
    return raw as String?;
  }

  // ── Animation control ─────────────────────────────────────────────────────

  /// Cross-fades to the animation clip with the given [name].
  Future<void> playAnimation(String name) => evaluateJavascript(
    "window.MVApi && window.MVApi.playAnimation('${_esc(name)}');",
  );

  /// Designates [name] as the **idle** clip — the animation the viewer returns
  /// to after a one-shot clip finishes (when [setAfterFinishMode] is `'idle'`).
  Future<void> setIdleAnimation(String name) => evaluateJavascript(
    "window.MVApi && window.MVApi.setIdleAnimation('${_esc(name)}');",
  );

  /// Controls what happens when a one-shot animation clip finishes:
  ///
  /// - `'loop'`  — repeat the same clip (default).
  /// - `'idle'`  — cross-fade back to the idle clip.
  /// - `'hold'`  — freeze on the last frame.
  Future<void> setAfterFinishMode(String mode) => evaluateJavascript(
    "window.MVApi && window.MVApi.setAfterFinishMode('${_esc(mode)}');",
  );

  /// Plays [sequence] clips one-after-another then cross-fades to idle.
  ///
  /// Example:
  /// ```dart
  /// controller.playSequence(['Walk', 'Run', 'Jump']);
  /// ```
  Future<void> playSequence(List<String> sequence) => evaluateJavascript(
    "window.MVApi && window.MVApi.playSequence(${jsonEncode(sequence)});",
  );

  /// Sets the cross-fade blend duration in seconds (default `0.3`).
  Future<void> setBlendDuration(double seconds) => evaluateJavascript(
    "window.MVApi && window.MVApi.setBlendDuration($seconds);",
  );

  /// Sets the animation playback speed multiplier (default `1.0`).
  Future<void> setAnimationSpeed(double speed) => evaluateJavascript(
    "window.MVApi && window.MVApi.setAnimationSpeed($speed);",
  );

  // ── Display ───────────────────────────────────────────────────────────────

  /// Enables or disables **material view** (unlit / no-PBR rendering).
  ///
  /// When `true`, all mesh materials are replaced with `MeshBasicMaterial`
  /// so textures and vertex colours show without lighting calculations.
  /// When `false`, original PBR materials are restored.
  Future<void> setMaterialView(bool enabled) => evaluateJavascript(
    "window.MVApi && window.MVApi.setMaterialView($enabled);",
  );

  /// Enables or disables continuous auto-rotation of the model.
  Future<void> setAutoRotate(bool enabled) => evaluateJavascript(
    "window.MVApi && window.MVApi.setAutoRotate($enabled);",
  );

  /// Shows or hides the debug grid floor.
  Future<void> showGrid(bool visible) =>
      evaluateJavascript("window.MVApi && window.MVApi.showGrid($visible);");

  /// Sets the renderer exposure / tone-mapping brightness.
  Future<void> setExposure(double value) =>
      evaluateJavascript("window.MVApi && window.MVApi.setExposure($value);");

  /// Sets the shadow intensity (0 = no shadow, 1 = full shadow).
  Future<void> setShadowIntensity(double value) => evaluateJavascript(
    "window.MVApi && window.MVApi.setShadowIntensity($value);",
  );

  /// Sets the scene background to a CSS colour string or `'transparent'`.
  Future<void> setBackground(String color) => evaluateJavascript(
    "window.MVApi && window.MVApi.setBackground('${_esc(color)}');",
  );

  /// Resets the camera to fit the loaded model.
  Future<void> resetCamera() =>
      evaluateJavascript("window.MVApi && window.MVApi.resetCamera();");

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// JS-safe single-quote escape.
  static String _esc(String s) =>
      s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
}
