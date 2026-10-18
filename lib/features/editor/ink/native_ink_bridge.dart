import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A full-rate packet captured before Flutter's pointer-event pipeline.
///
/// Actual (including coalesced/historical) samples are sent to Dart. Predicted
/// samples stay native and are used only by the temporary low-latency preview,
/// so guesses can never enter the saved document.
class NativeInkPacket {
  const NativeInkPacket({
    required this.surfaceId,
    required this.pointer,
    required this.phase,
    required this.kind,
    required this.samples,
  });

  factory NativeInkPacket.fromMap(Map<Object?, Object?> value) {
    final List<Object?> encoded =
        (value['samples'] as List<Object?>?) ?? const <Object?>[];
    final List<NativeInkSample> samples = <NativeInkSample>[];
    for (int index = 0; index + 3 < encoded.length; index += 4) {
      final Object? pressure = encoded[index + 3];
      samples.add(
        NativeInkSample(
          position: Offset(
            (encoded[index] as num).toDouble(),
            (encoded[index + 1] as num).toDouble(),
          ),
          timestamp: Duration(
            microseconds: (encoded[index + 2] as num).round(),
          ),
          pressure: pressure == null ? null : (pressure as num).toDouble(),
        ),
      );
    }
    return NativeInkPacket(
      surfaceId: (value['surfaceId'] as num).toInt(),
      pointer: (value['pointer'] as num).toInt(),
      phase: NativeInkPhase.values.byName(value['phase'] as String),
      kind: value['kind'] == 'invertedStylus'
          ? NativeInkKind.invertedStylus
          : NativeInkKind.stylus,
      samples: samples,
    );
  }

  final int surfaceId;
  final int pointer;
  final NativeInkPhase phase;
  final NativeInkKind kind;
  final List<NativeInkSample> samples;
}

enum NativeInkPhase { down, move, up, cancel }

enum NativeInkKind { stylus, invertedStylus }

class NativeInkSample {
  const NativeInkSample({
    required this.position,
    required this.timestamp,
    required this.pressure,
  });

  final Offset position;
  final Duration timestamp;
  final double? pressure;
}

/// Everything native code needs to hit-test a page and render its transient
/// live-ink preview. The affine basis maps one canvas logical pixel to global
/// Flutter logical coordinates and therefore remains correct while zoomed.
class NativeInkSurface {
  const NativeInkSurface({
    required this.id,
    required this.size,
    required this.origin,
    required this.xBasis,
    required this.yBasis,
    required this.enabled,
    required this.previewEnabled,
    required this.color,
    required this.width,
    required this.pressureSensitivity,
  });

  final int id;
  final Size size;
  final Offset origin;
  final Offset xBasis;
  final Offset yBasis;
  final bool enabled;
  final bool previewEnabled;
  final Color color;
  final double width;
  final double pressureSensitivity;

  Map<String, Object> toMap() => <String, Object>{
    'surfaceId': id,
    'width': size.width,
    'height': size.height,
    'originX': origin.dx,
    'originY': origin.dy,
    'xx': xBasis.dx,
    'xy': xBasis.dy,
    'yx': yBasis.dx,
    'yy': yBasis.dy,
    'enabled': enabled,
    'previewEnabled': previewEnabled,
    'color': color.toARGB32(),
    'strokeWidth': width,
    'pressureSensitivity': pressureSensitivity,
  };
}

typedef NativeInkPacketHandler = void Function(NativeInkPacket packet);

/// Process-wide bridge for the native Android and iOS stylus observers.
///
/// It deliberately uses one method channel rather than a platform view per
/// page. That avoids hybrid-composition cost and lets ordinary Flutter widgets
/// remain responsible for the editor UI and finger gestures.
class NativeInkBridge {
  NativeInkBridge._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final NativeInkBridge instance = NativeInkBridge._();
  static const MethodChannel _channel = MethodChannel(
    'com.etonia.app/native_ink',
  );

  final Map<int, NativeInkPacketHandler> _handlers =
      <int, NativeInkPacketHandler>{};
  int _nextSurfaceId = 1;
  bool _platformMissing = false;

  int allocateSurfaceId() => _nextSurfaceId++;

  Future<bool> registerSurface(
    NativeInkSurface surface,
    NativeInkPacketHandler handler,
  ) async {
    if (_platformMissing ||
        kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return false;
    }
    _handlers[surface.id] = handler;
    try {
      final bool? registered = await _channel.invokeMethod<bool>(
        'registerSurface',
        surface.toMap(),
      );
      if (registered == true) {
        return true;
      }
    } on MissingPluginException {
      _platformMissing = true;
    } on PlatformException catch (error) {
      debugPrint('Native ink is unavailable: ${error.message}');
    }
    _handlers.remove(surface.id);
    return false;
  }

  Future<void> updateSurface(NativeInkSurface surface) async {
    if (!_handlers.containsKey(surface.id)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateSurface', surface.toMap());
    } on PlatformException catch (error) {
      debugPrint('Could not update native ink surface: ${error.message}');
    } on MissingPluginException {
      _platformMissing = true;
      _handlers.remove(surface.id);
    }
  }

  Future<void> unregisterSurface(int surfaceId) async {
    final bool hadSurface = _handlers.remove(surfaceId) != null;
    if (!hadSurface || _platformMissing) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('unregisterSurface', <String, Object>{
        'surfaceId': surfaceId,
      });
    } on MissingPluginException {
      _platformMissing = true;
    } on PlatformException catch (error) {
      debugPrint('Could not unregister native ink surface: ${error.message}');
    }
  }

  /// The document has incorporated the final actual samples, so the native
  /// transient overlay can disappear without exposing a frame-sized gap.
  Future<void> finishPreview(int surfaceId, int pointer) async {
    if (_platformMissing) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('finishPreview', <String, Object>{
        'surfaceId': surfaceId,
        'pointer': pointer,
      });
    } on MissingPluginException {
      _platformMissing = true;
    } on PlatformException catch (error) {
      debugPrint('Could not finish native ink preview: ${error.message}');
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'inkPacket' || call.arguments is! Map) {
      return;
    }
    final NativeInkPacket packet = NativeInkPacket.fromMap(
      Map<Object?, Object?>.from(call.arguments as Map),
    );
    _handlers[packet.surfaceId]?.call(packet);
  }
}
