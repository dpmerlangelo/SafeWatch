import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Wraps a [MapController] to give every *programmatic* camera move —
/// recenter buttons, "fit all points", focusing on a tapped pin, the
/// +/- zoom buttons — a smooth, Google-Maps-style animated transition
/// instead of an instant jump.
///
/// Two-finger pinch and one-finger drag are already smooth on their own
/// since flutter_map drives those straight off raw pointer events; this
/// class only replaces the old instant `MapController.move(...)` calls
/// that were used for buttons/taps.
///
/// Usage: mix `TickerProviderStateMixin` into the State that owns the
/// `MapController`, then create one of these alongside it:
///
/// ```dart
/// class _MyScreenState extends State<MyScreen> with TickerProviderStateMixin {
///   final MapController _mapController = MapController();
///   late final AnimatedMapController _animatedMapController =
///       AnimatedMapController(vsync: this, mapController: _mapController);
///
///   @override
///   void dispose() {
///     _animatedMapController.dispose();
///     super.dispose();
///   }
/// }
/// ```
class AnimatedMapController {
  AnimatedMapController({
    required TickerProvider vsync,
    required this.mapController,
    this.duration = const Duration(milliseconds: 550),
    this.curve = Curves.easeOutCubic,
  }) : _vsync = vsync;

  final MapController mapController;
  final TickerProvider _vsync;
  final Duration duration;
  final Curve curve;

  AnimationController? _ticker;

  /// Passthrough to the wrapped controller's current camera, so callers
  /// (like a zoom +/- button) can read the live zoom/center without
  /// needing to hold their own reference to `mapController`.
  MapCamera get camera => mapController.camera;

  /// Animates from the current center/zoom to [destCenter] / [destZoom].
  /// Either can be omitted to only animate the other (e.g. just zooming
  /// in place). Cancels any in-flight animation first, so mashing a zoom
  /// button rapidly doesn't make two animations fight over the position.
  void animateTo({LatLng? destCenter, double? destZoom}) {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;

    final startCenter = camera.center;
    final startZoom = camera.zoom;
    final endCenter = destCenter ?? startCenter;
    final endZoom = destZoom ?? startZoom;

    final latTween = Tween<double>(begin: startCenter.latitude, end: endCenter.latitude);
    final lngTween = Tween<double>(begin: startCenter.longitude, end: endCenter.longitude);
    final zoomTween = Tween<double>(begin: startZoom, end: endZoom);

    final controller = AnimationController(vsync: _vsync, duration: duration);
    _ticker = controller;
    final animation = CurvedAnimation(parent: controller, curve: curve);

    animation.addListener(() {
      mapController.move(
        LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
        zoomTween.evaluate(animation),
      );
    });

    controller.forward().whenCompleteOrCancel(() {
      if (identical(_ticker, controller)) _ticker = null;
      controller.dispose();
    });
  }

  /// Animated equivalent of `mapController.fitCamera(fit)`. Computes the
  /// destination center/zoom that [fit] would land on (the same call
  /// flutter_map's own instant `fitCamera` uses internally), then
  /// animates there instead of snapping to it.
  void animateFitCamera(CameraFit fit) {
    final destination = fit.fit(camera);
    animateTo(destCenter: destination.center, destZoom: destination.zoom);
  }

  void dispose() {
    _ticker?.dispose();
    _ticker = null;
  }
}