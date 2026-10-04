import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../constants/app_colors.dart';
import '../constants/barangay_boundary.dart';

const List<ll.LatLng> _maskOuterRing = [
  ll.LatLng(-85, -180),
  ll.LatLng(-85, 180),
  ll.LatLng(85, 180),
  ll.LatLng(85, -180),
];

const List<double> _lightSaturationMatrix = <double>[
  0.68504, 0.28608, 0.02888, 0, 0,
  0.08504, 0.88608, 0.02888, 0, 0,
  0.08504, 0.28608, 0.62888, 0, 0,
  0, 0, 0, 1, 0,
];
const List<double> _grayscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];
const List<double> _invertMatrix = <double>[
  -1, 0, 0, 0, 255,
  0, -1, 0, 0, 255,
  0, 0, -1, 0, 255,
  0, 0, 0, 1, 0,
];
const List<double> _duotoneMatrix = <double>[
  0.4941, 0, 0, 0, 22,
  0, 0.5137, 0, 0, 32,
  0, 0, 0.5412, 0, 46,
  0, 0, 0, 1, 0,
];

/// Shared basemap styling so every map screen looks the same.
class ThemedMapLayers {
  /// OSM tiles, softened in light mode and duotone-inverted in dark mode.
  static Widget tileLayer(
    BuildContext context, {
    required String userAgentPackageName,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tiles = TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: userAgentPackageName,
    );
    if (!isDark) {
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(_lightSaturationMatrix),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(Colors.white.withOpacity(0.04), BlendMode.screen),
          child: tiles,
        ),
      );
    }
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_duotoneMatrix),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(_invertMatrix),
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(_grayscaleMatrix),
          child: tiles,
        ),
      ),
    );
  }

  static bool get hasBoundary => BarangayBoundary.points.isNotEmpty;

  /// Dims everything outside the barangay and outlines the boundary.
  /// Only add this when [hasBoundary] is true.
  static Widget boundaryLayer(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PolygonLayer(
      polygons: [
        Polygon(
          points: _maskOuterRing,
          holePointsList: [BarangayBoundary.points],
          color: AppColors.bg(context).withOpacity(isDark ? 0.90 : 0.80),
          isFilled: true,
        ),
        Polygon(
          points: BarangayBoundary.points,
          color: Colors.transparent,
          borderColor: AppColors.accentBlue,
          borderStrokeWidth: 3,
          isFilled: false,
        ),
      ],
    );
  }
}