import 'dart:async';
import 'dart:convert' show json, utf8;
import 'dart:io'
    show File, HttpResponse, HttpServer, HttpStatus, InternetAddress;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import 'model_viewer_plus.dart';
import 'model_viewer_plus_io.dart';

class ModelViewerWindowsState extends State<WindowsModelViewer> {
  HttpServer? _proxy;
  late String _proxyURL;
  bool _isInitialized = false;

  ModelViewer get modelWidget => widget.widget;

  @override
  void initState() {
    super.initState();
    unawaited(_initProxy().then((_) => setState(() => _isInitialized = true)));
  }

  @override
  void dispose() {
    if (_proxy != null) {
      unawaited(_proxy!.close(force: true));
      _proxy = null;
    }
    super.dispose();
  }

  @override
  Widget build(final BuildContext context) {
    if (_proxy == null || !_isInitialized) {
      return const Center(
        child: CircularProgressIndicator(
          semanticsLabel: 'Loading Model Viewer',
        ),
      );
    }

    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_proxyURL)),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        disableContextMenu: true,
        supportZoom: false,
        javaScriptEnabled: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onWebViewCreated: (controller) {
        // Attach the native controller so ModelViewerController.evaluateJavascript works
        modelWidget.controller?.attach(controller);

        // Register JavaScript channels if provided
        if (modelWidget.javascriptChannels != null) {
          for (final channel in modelWidget.javascriptChannels!) {
            controller.addJavaScriptHandler(
              handlerName: channel.name,
              callback: (args) {
                final message = args.isNotEmpty ? args[0].toString() : '';
                channel.onMessageReceived(message);
              },
            );
          }
        }

        // onWebViewCreated expects a webview_flutter WebViewController.
        // InAppWebView uses a different controller type on Windows; callers
        // should use javascriptChannels or ModelViewerController instead.
        if (modelWidget.onWebViewCreated != null) {
          debugPrint(
            'ModelViewer (Windows/Three.js): onWebViewCreated is not '
            'supported on this platform. Use javascriptChannels or '
            'ModelViewerController instead.',
          );
        }

        if (modelWidget.debugLogging) {
          debugPrint('ModelViewer (Three.js) initializing… <$_proxyURL>');
        }
      },
      onLoadStop: (controller, url) {
        if (modelWidget.debugLogging) {
          debugPrint('ModelViewer (Three.js) loaded: $url');
        }
      },
      onConsoleMessage: (controller, consoleMessage) {
        if (modelWidget.debugLogging) {
          debugPrint('[Three.js] ${consoleMessage.message}');
        }
      },
    );
  }

  // ── CONFIG INJECTION ─────────────────────────────────────────────────────────
  // Builds the window.MVConfig JSON object read by the Three.js template.
  String _buildConfigScript() {
    final mw = modelWidget;

    // Convert Flutter Color → CSS hex string
    String colorToCss(Color c) {
      if (c == Colors.transparent) return 'transparent';
      final argb = c.value;
      final r = (argb >> 16) & 0xFF;
      final g = (argb >> 8) & 0xFF;
      final b = argb & 0xFF;
      return '#${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}';
    }

    final Map<String, dynamic> config = {
      // Camera
      'cameraControls': mw.cameraControls ?? true,
      'disablePan': mw.disablePan ?? false,
      'disableTap': mw.disableTap ?? false,
      'disableZoom': mw.disableZoom ?? false,
      if (mw.orbitSensitivity != null) 'orbitSensitivity': mw.orbitSensitivity,
      if (mw.fieldOfView != null) 'fieldOfView': mw.fieldOfView,
      if (mw.cameraOrbit != null) 'cameraOrbit': mw.cameraOrbit,
      if (mw.cameraTarget != null) 'cameraTarget': mw.cameraTarget,
      if (mw.maxCameraOrbit != null) 'maxCameraOrbit': mw.maxCameraOrbit,
      if (mw.minCameraOrbit != null) 'minCameraOrbit': mw.minCameraOrbit,
      if (mw.maxFieldOfView != null) 'maxFieldOfView': mw.maxFieldOfView,
      if (mw.minFieldOfView != null) 'minFieldOfView': mw.minFieldOfView,
      if (mw.interpolationDecay != null)
        'interpolationDecay': mw.interpolationDecay,

      // Auto-rotate
      'autoRotate': mw.autoRotate ?? false,
      if (mw.autoRotateDelay != null) 'autoRotateDelay': mw.autoRotateDelay,
      if (mw.rotationPerSecond != null)
        'rotationPerSecond': mw.rotationPerSecond,

      // Lighting & environment
      if (mw.exposure != null) 'exposure': mw.exposure,
      if (mw.shadowIntensity != null) 'shadowIntensity': mw.shadowIntensity,
      if (mw.shadowSoftness != null) 'shadowSoftness': mw.shadowSoftness,
      if (mw.environmentImage != null) 'environmentImage': mw.environmentImage,
      if (mw.skyboxImage != null) 'skyboxImage': mw.skyboxImage,

      // Display
      'backgroundColor': colorToCss(mw.backgroundColor),
      'debugLogging': mw.debugLogging,

      // Animation
      if (mw.animationName != null) 'animationName': mw.animationName,
      if (mw.animationCrossfadeDuration != null)
        'animationCrossfadeDuration': mw.animationCrossfadeDuration,
      'autoPlay': mw.autoPlay ?? false,

      // Scene graph
      if (mw.orientation != null) 'orientation': mw.orientation,
      if (mw.scale != null) 'scale': mw.scale,

      // Custom JS (evaluated after model loads)
      if (mw.relatedJs != null) 'relatedJs': mw.relatedJs,

      // Names of Dart-registered JS channels — JS uses this to guard callHandler
      // calls and avoid crashing when no handler is registered on the Dart side.
      'jsChannels':
          mw.javascriptChannels?.map((c) => c.name).toList() ?? <String>[],
    };

    return 'window.MVConfig = ${json.encode(config)};';
  }

  // ── HTML ASSEMBLY ─────────────────────────────────────────────────────────────
  // Injects config script (and optional relatedCss) into the template.
  String _assembleHTML(String template) {
    var html = template;

    // Inject relatedCss into the placeholder inside the <style> block
    if (modelWidget.relatedCss != null) {
      html = html.replaceFirst(
        '  /* related-css */',
        '  /* related-css */\n  ${modelWidget.relatedCss}',
      );
    }

    // Inject config script just before </head>
    final configScript = '<script>\n${_buildConfigScript()}\n</script>\n';
    html = html.replaceFirst('</head>', '$configScript</head>');

    return html;
  }

  // ── PROXY ─────────────────────────────────────────────────────────────────────
  Future<void> _initProxy() async {
    _proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    final String host = _proxy!.address.address;
    final int port = _proxy!.port;
    _proxyURL = 'http://$host:$port/';

    _proxy!.listen((request) async {
      final Uri modelUri = Uri.parse(modelWidget.src);
      final HttpResponse response = request.response;

      // CORS header on every response
      response.headers.add('Access-Control-Allow-Origin', '*');

      switch (request.uri.path) {
        case '/':
        case '/index.html':
          final String template = await rootBundle.loadString(
            'packages/model_viewer_plus/assets/threejs_windows_template.html',
          );
          final Uint8List html = utf8.encode(_assembleHTML(template));
          response
            ..statusCode = HttpStatus.ok
            ..headers.add('Content-Type', 'text/html;charset=UTF-8')
            ..headers.add('Content-Length', html.length.toString())
            ..add(html);
          await response.close();

        case '/model':
          if (modelWidget.src.startsWith('data:')) {
            // Data-URI models are embedded in window.MVConfig.src directly;
            // the /model route is unused in that case.
            response.statusCode = HttpStatus.noContent;
            await response.close();
          } else if (modelUri.isAbsolute && !modelUri.isScheme('file')) {
            await response.redirect(modelUri);
          } else {
            final Uint8List data = await (modelUri.isScheme('file')
                ? _readFile(modelUri.path)
                : _readAsset(modelUri.path));
            response
              ..statusCode = HttpStatus.ok
              ..headers.add('Content-Type', 'application/octet-stream')
              ..headers.add('Content-Length', data.lengthInBytes.toString())
              ..add(data);
            await response.close();
          }

        case '/favicon.ico':
          final Uint8List text = utf8.encode(
            "Resource '${request.uri}' not found",
          );
          response
            ..statusCode = HttpStatus.notFound
            ..headers.add('Content-Type', 'text/plain;charset=UTF-8')
            ..headers.add('Content-Length', text.length.toString())
            ..add(text);
          await response.close();

        default:
          // Redirect absolute URIs directly (CDN imports, env maps, etc.)
          if (request.uri.isAbsolute) {
            debugPrint('Redirect: ${request.uri}');
            await response.redirect(request.uri);
          } else if (request.uri.hasAbsolutePath) {
            // Resolve relative to model source directory
            final List<String> pathSegments = [...modelUri.pathSegments]
              ..removeLast();
            final String origin = modelUri.isAbsolute
                ? modelUri.origin
                : 'http://$host:$port';
            final String tryDestination = p.joinAll([
              origin,
              ...pathSegments,
              request.uri.path.replaceFirst('/', ''),
            ]);
            debugPrint('Try: $tryDestination');
            await response.redirect(Uri.parse(tryDestination));
          } else {
            debugPrint('404: ${request.uri}');
            final Uint8List text = utf8.encode(
              "Resource '${request.uri}' not found",
            );
            response
              ..statusCode = HttpStatus.notFound
              ..headers.add('Content-Type', 'text/plain;charset=UTF-8')
              ..headers.add('Content-Length', text.length.toString())
              ..add(text);
            await response.close();
          }
      }
    });
  }

  Future<Uint8List> _readAsset(final String key) async {
    final ByteData data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<Uint8List> _readFile(final String path) async {
    return File(path).readAsBytes();
  }
}
