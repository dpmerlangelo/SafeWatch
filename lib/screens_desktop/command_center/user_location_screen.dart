import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../constants/barangay_boundary.dart';
import '../../constants/app_colors.dart';
import '../../controllers/animated_map_controller.dart';

/// True on Windows/macOS/Linux desktop builds (not web, not mobile).
bool get _isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

PageRoute<T> _instantRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    opaque: true,
  );
}

// ---------------------------------------------------------------------------
// Shared colors / helpers (used by both the embedded map and the fullscreen
// map page)
// ---------------------------------------------------------------------------

const Color _onlineColor = Color(0xFF10B981);
const Color _offlineColor = Color(0xFFE53935);
const Color _cameraPinColor = Color(0xFF2082E2);
const Color _tanodPinColor = Color(0xFF2563EB); // professional blue
// Matches the boundary outline color used on the Device Location screen
// (its accent blue) so both maps read as part of the same app.
const Color _boundaryColor = Color(0xFF2563EB);

// Personnel pins pulled from `live_gps`, one color per role so they're
// visually distinct from cameras and from each other.
const Color _taskForcePinColor = Color(0xFFF59E0B); // amber
const Color _purokLeaderPinColor = Color(0xFF7C3AED); // purple

// --- Presence status (same rules as the Purok Leader map) -----------------
// A fix older than this is treated as "no signal" even if is_sharing is true.
const Duration _kStaleAfter = Duration(minutes: 3);
const double _kClusterCellPx = 64; // grouping cell when zoomed out
const double _kOverlapCellPx = 30; // grouping cell when zoomed in (overlaps)
const double _kClusterOffZoom = 18;
const double _kMaxMapZoom = 19;

// Same status colors as the Purok Leader map.
final Color _availableColor = AppColors.accentGreen;
final Color _onDispatchColor = AppColors.accentRed;
const Color _locationOffColor = Colors.grey;
const Color _noSignalColor = Color(0xFFFFB300); // amber
final Color _mixedClusterColor = AppColors.accentOrange; // cluster with mixed statuses

enum _PresenceStatus { available, onDispatch, locationOff, noSignal }

// A rectangle big enough to cover any reasonable map viewport. Used as
// the outer ring of the dim mask, with the barangay boundary punched
// out of it as a hole — so only the area *outside* the boundary is
// dimmed, and the boundary interior stays clear/focused.
const List<LatLng> _maskOuterRing = [
  LatLng(-85, -180),
  LatLng(-85, 180),
  LatLng(85, 180),
  LatLng(85, -180),
];

/// Plain OpenStreetMap tiles, keyless and free to use.
///
/// Light mode: a partial desaturation (keeps ~60% of the original color)
/// plus a very slight brightening screen blend, so roads/water/parks stay
/// visibly colored and legible instead of being flattened to gray — closer
/// to Google's clean light basemap look.
///
/// Dark mode is transformed purely with color filters to approximate
/// Google Maps' dark theme — dark navy land, lighter blue-gray roads —
/// without depending on a third-party dark tile provider that could
/// require a key or change terms (CARTO's raster basemaps started doing
/// exactly that in August 2026).
///
/// Three filters, chained innermost-to-outermost:
///  1. Grayscale — collapses each tile pixel to a single brightness value,
///     discarding OSM's original hues entirely.
///  2. Invert — flips that brightness, so OSM's white land/light areas
///     become dark and OSM's darker road lines/text become the lighter
///     features, which is the correct relationship for a dark map.
///  3. Duotone — maps brightness onto two fixed colors (dark navy for
///     shadows, light blue-gray for highlights) instead of rotating hues.
///     An earlier version used an invert+hue-rotate+tint chain, but
///     hue-rotation doesn't map every original OSM hue cleanly back to
///     blue-gray, and buildings/labels drifted toward purple/magenta.
///     Going through grayscale first removes that hue entirely, so the
///     output can only ever land on the navy/blue-gray duotone scale.
class _ThemedOsmTileLayer extends StatelessWidget {
  final bool isDark;

  const _ThemedOsmTileLayer({required this.isDark});

  // --- LIGHT MODE -----------------------------------------------------
  // Partial desaturation (retains ~60% of original saturation) instead of
  // full grayscale — keeps roads/water/parks visibly colored but muted,
  // similar to Google's clean light basemap, instead of flattening
  // everything to gray.
  static const List<double> _lightSaturationMatrix = <double>[
    0.68504, 0.28608, 0.02888, 0, 0,
    0.08504, 0.88608, 0.02888, 0, 0,
    0.08504, 0.28608, 0.62888, 0, 0,
    0, 0, 0, 1, 0,
  ];

  // Step 1: grayscale (standard luminance weights) — collapses each tile
  // pixel to a single brightness value so the later duotone step has no
  // leftover hue to drift toward purple/magenta.
  static const List<double> _grayscaleMatrix = <double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ];

  // Step 2: invert that brightness — OSM's white land/light roads become
  // dark, and OSM's darker road lines/text become the lighter features,
  // which is the correct relationship for a dark map.
  static const List<double> _invertMatrix = <double>[
    -1, 0, 0, 0, 255,
    0, -1, 0, 0, 255,
    0, 0, -1, 0, 255,
    0, 0, 0, 1, 0,
  ];

  // Step 3: duotone. After steps 1-2, R=G=B=brightness for every pixel.
  // Rather than rotating hues (which is what produced the purple cast),
  // this maps brightness directly onto two fixed colors — dark navy for
  // shadows (land/background) and a lighter blue-gray for highlights
  // (roads/labels) — the same two colors every time, so the result can
  // only ever land on that navy/blue-gray range, matching Google's dark
  // basemap.
  //   shadow   (brightness 0)   -> RGB(22, 32, 46)   dark navy
  //   highlight(brightness 255) -> RGB(148, 163, 184) light blue-gray
  static const List<double> _duotoneMatrix = <double>[
    0.4941, 0, 0, 0, 22,
    0, 0.5137, 0, 0, 32,
    0, 0, 0.5412, 0, 46,
    0, 0, 0, 1, 0,
  ];

  @override
  Widget build(BuildContext context) {
    final tiles = TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.yourcompany.admin_app', // set to your actual package name
    );

    if (!isDark) {
      // Light mode: partial desaturation + a slight brightening screen
      // blend, so it reads clean/white with visible detail — not gray.
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(_lightSaturationMatrix),
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(
            Colors.white.withOpacity(0.04),
            BlendMode.screen,
          ),
          child: tiles,
        ),
      );
    }

    // Dark mode: grayscale (innermost) -> invert -> duotone (outermost).
    // No hue-rotation step means no hue can drift toward purple/magenta —
    // every pixel ends up somewhere on the fixed navy-to-blue-gray scale
    // defined in _duotoneMatrix, matching Google Maps' dark theme.
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
}

Color _colorForStatus(String status) {
  return status.toUpperCase() == 'ONLINE' ? _onlineColor : _offlineColor;
}

/// Color for a `live_gps.role` value, used for the Task Force / Purok
/// Leader / Tanod personnel pins. Falls back to the tanod color for any
/// other role, though in practice only these three roles ever reach
/// this function — see `_PersonnelPin.fromMap`.
Color _colorForRole(String role) {
  switch (role.trim()) {
    case 'Task Force':
      return _taskForcePinColor;
    case 'Purok Leader':
      return _purokLeaderPinColor;
    default:
      return _tanodPinColor;
  }
}

/// Professional, role-specific Material icons used consistently on the map
/// and in the legend.
IconData _iconForRole(String role) {
  switch (role.trim()) {
    case 'Task Force':
      return Icons.engineering_outlined;
    case 'Purok Leader':
      return Icons.home_work_outlined;
    case 'Tanod':
    default:
      return Icons.shield_outlined;
  }
}

// --- Presence helpers ------------------------------------------------------

Color _colorForPresence(_PresenceStatus s) {
  switch (s) {
    case _PresenceStatus.available:
      return _availableColor;
    case _PresenceStatus.onDispatch:
      return _onDispatchColor;
    case _PresenceStatus.locationOff:
      return _locationOffColor;
    case _PresenceStatus.noSignal:
      return _noSignalColor;
  }
}

IconData _iconForPresence(_PresenceStatus s) {
  switch (s) {
    case _PresenceStatus.available:
      return Icons.check;
    case _PresenceStatus.onDispatch:
      return Icons.notifications_active;
    case _PresenceStatus.locationOff:
      return Icons.location_off;
    case _PresenceStatus.noSignal:
      return Icons.signal_wifi_off;
  }
}

String _labelForPresence(_PresenceStatus s) {
  switch (s) {
    case _PresenceStatus.available:
      return 'Available';
    case _PresenceStatus.onDispatch:
      return 'On dispatch';
    case _PresenceStatus.locationOff:
      return 'Location off';
    case _PresenceStatus.noSignal:
      return 'No signal';
  }
}

/// Short tag shown next to the name. Null = nothing (available).
String? _tagForPresence(_PresenceStatus s) {
  switch (s) {
    case _PresenceStatus.available:
      return null;
    case _PresenceStatus.onDispatch:
      return 'BUSY';
    case _PresenceStatus.locationOff:
      return 'OFF';
    case _PresenceStatus.noSignal:
      return 'NO SIGNAL';
  }
}

String _roleAbbr(String role) {
  switch (role) {
    case 'Task Force':
      return 'TF';
    case 'Purok Leader':
      return 'PL';
    default:
      return 'T';
  }
}

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  // Negative = timestamp slightly in the future (clock skew) -> treat as now.
  if (diff.isNegative || diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  // Epoch fallback (bad/missing updated_at) => don't print thousands of days.
  if (diff.inDays > 3650) return 'unknown';
  return '${diff.inDays} d ago';
}

/// "3" -> "Purok 3"; "Purok 3" / "Sampaguita" are left as they are.
String _purokLabel(String purok) {
  final p = purok.trim();
  if (RegExp(r'^\d+$').hasMatch(p)) return 'Purok $p';
  return p;
}

/// Everyone in an active (non-completed) dispatch is "busy".
Set<String> _busyIdsFromRows(List<Map<String, dynamic>> rows) {
  final busy = <String>{};
  for (final row in rows) {
    final status = (row['status'] ?? '').toString();
    if (status == 'completed') continue;
    busy.addAll(((row['member_ids'] as List?) ?? []).map((e) => e.toString()));
  }
  return busy;
}

/// profiles.id -> purok (only for profiles that have one).
Future<Map<String, String>> _fetchPuroks() async {
  final map = <String, String>{};
  try {
    final rows = await Supabase.instance.client.from('profiles').select('id, purok');
    for (final r in (rows as List)) {
      final m = r as Map<String, dynamic>;
      final purok = (m['purok'] ?? '').toString().trim();
      if (purok.isNotEmpty) map[m['id'].toString()] = purok;
    }
  } catch (e) {
    debugPrint('profiles purok fetch failed: $e');
  }
  return map;
}

({double x, double y}) _worldPx(LatLng p, double zoom) {
  final scale = 256 * math.pow(2, zoom).toDouble();
  final sinLat = math.sin(p.latitude * math.pi / 180).clamp(-0.9999, 0.9999).toDouble();
  return (
    x: (p.longitude + 180) / 360 * scale,
    y: (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale,
  );
}

/// True if zooming in can still separate this group. False when the map is
/// already at (or basically at) max zoom, or everyone is on the exact same
/// spot — in that case the caller should show the "pick one" list instead.
bool _canZoomIntoCluster(AnimatedMapController c, List<_PersonnelPin> group) {
  if (c.camera.zoom >= _kMaxMapZoom - 0.1) return false;
  final b = LatLngBounds.fromPoints(group.map((p) => p.position).toList());
  final tiny = (b.north - b.south).abs() < 1e-7 && (b.east - b.west).abs() < 1e-7;
  return !tiny;
}

void _zoomIntoCluster(AnimatedMapController c, List<_PersonnelPin> group) {
  final points = group.map((p) => p.position).toList();
  c.animateFitCamera(
    CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      padding: const EdgeInsets.all(72),
      maxZoom: _kMaxMapZoom,
    ),
  );
}

/// Builds the personnel markers (all roles). Nearby pins are grouped into a
/// numbered bubble — with a coarse cell when zoomed out, and a small
/// "overlap" cell when zoomed in, so people standing on the same spot never
/// hide each other. Tapping a bubble either zooms in or (when it can't zoom
/// any further) opens the pick-one list.
/// Shared by the embedded map and the fullscreen page.
///
/// Every marker uses `alignment: Alignment.topCenter` so the tip of the
/// teardrop pin (bottom-center of the marker box) lands exactly on the
/// coordinate.
List<Marker> _buildPersonnelMarkers({
  required List<_PersonnelPin> pins,
  required Set<String> busyIds,
  required double zoom,
  required String? selectedId,
  required bool Function(String role) roleVisible,
  required void Function(_PersonnelPin pin) onPinTap,
  required void Function(List<_PersonnelPin> group) onClusterTap,
}) {
  final visible = pins.where((p) => roleVisible(p.role)).toList();

  Marker single(_PersonnelPin pin) => Marker(
        point: pin.position,
        width: 112,
        height: 66,
        alignment: Alignment.topCenter,
        child: _MapPinMarker(
          icon: _iconForRole(pin.role),
          color: _colorForRole(pin.role),
          label: pin.name,
          presence: pin.statusFor(busyIds),
          selected: pin.id == selectedId,
          onTap: () => onPinTap(pin),
        ),
      );

  final z = (zoom * 2).floor() / 2;
  final cellPx = z >= _kClusterOffZoom ? _kOverlapCellPx : _kClusterCellPx;

  final cells = <String, List<_PersonnelPin>>{};
  for (final p in visible) {
    final w = _worldPx(p.position, z);
    final key = '${(w.x / cellPx).floor()}:${(w.y / cellPx).floor()}';
    cells.putIfAbsent(key, () => []).add(p);
  }

  final markers = <Marker>[];
  for (final group in cells.values) {
    if (group.length == 1) {
      markers.add(single(group.first));
      continue;
    }
    var lat = 0.0, lng = 0.0;
    for (final p in group) {
      lat += p.position.latitude;
      lng += p.position.longitude;
    }
    markers.add(Marker(
      point: LatLng(lat / group.length, lng / group.length),
      width: 84,
      height: 74,
      alignment: Alignment.topCenter,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onClusterTap(group),
        child: _PersonnelClusterMarker(pins: group, busyIds: busyIds),
      ),
    ));
  }
  return markers;
}

/// The small popup shown at the bottom-left of the map: either the info card
/// for the selected person, or the "pick one" list for people stacked on the
/// same spot. Returns an empty widget when nothing is selected.
Widget _buildPersonnelPopup({
  required List<_PersonnelPin> pins,
  required Set<String> busyIds,
  required Map<String, String> purokById,
  required String? selectedId,
  required List<String> pickerIds,
  required void Function(_PersonnelPin pin) onPick,
  required VoidCallback onClose,
}) {
  String? purokFor(_PersonnelPin p) => purokById[p.id];

  if (pickerIds.isNotEmpty) {
    final group = pins.where((p) => pickerIds.contains(p.id)).toList();
    if (group.length > 1) {
      return Positioned(
        left: 12,
        bottom: 32,
        child: _PersonnelPickerCard(
          pins: group,
          busyIds: busyIds,
          purokFor: purokFor,
          onPick: onPick,
          onClose: onClose,
        ),
      );
    }
  }

  if (selectedId != null) {
    for (final p in pins) {
      if (p.id == selectedId) {
        return Positioned(
          left: 12,
          bottom: 32,
          child: _PersonnelInfoCard(
            pin: p,
            status: p.statusFor(busyIds),
            purok: purokFor(p),
            onClose: onClose,
          ),
        );
      }
    }
  }
  return const SizedBox.shrink();
}

/// Shows the tanods' location as an embedded, always-visible map —
/// no tap required — plus every saved camera that has coordinates,
/// pulled live from the same `cctv` table CctvScreen manages, plus
/// Task Force / Purok Leader / Tanod personnel pulled from `live_gps`
/// (each role's mobile app upserts its own member_id/lat/lng/full_name/
/// role row into that table — see the mobile-side location-push code).
/// This is its own sidebar tab, separate from the CCTV feed.
///
/// Uses flutter_map (OpenStreetMap tiles) instead of google_maps_flutter
/// because google_maps_flutter doesn't support Windows desktop, and this
/// app runs on Windows.
///
/// Camera rows (table: 'cctv') are only plotted if they carry
/// `latitude` / `longitude` fields (num). CctvScreen's current Add/Edit
/// form doesn't collect these yet — only a free-text `location` label —
/// so until those fields are added there, cameras simply won't appear on
/// the map. Any camera missing either field is skipped rather than
/// guessed at.
///
/// Tanods (table: 'tanods') are plotted the same way, and also listed
/// in a collapsible panel so an admin can jump straight to one on the map.
/// NOTE: this is the legacy `tanods` table plot, kept as-is. Live-tracked
/// Tanods that push through `live_gps` (see below) show up as personnel
/// pins instead — if a tanod appears in both sources you may see two pins
/// for them until the legacy `tanods` table location fields are retired.
///
/// Task Force / Purok Leader / Tanod personnel (table: 'live_gps',
/// which carries `member_id`, `latitude`, `longitude`, `full_name`,
/// `role`, `is_sharing`, `updated_at`) are plotted the same way too —
/// skipped if they don't have saved coordinates yet, or if their `role`
/// isn't one of the three this screen recognizes.
///
/// Each personnel pin keeps its ROLE icon/color, and shows a separate
/// STATUS (available / on dispatch / location off / no signal) via a ring
/// color, corner badge and tag. Tapping a pin opens a small popup with the
/// person's name, role, purok (from `profiles.purok`) and status. People on
/// the same spot are grouped into a bubble; when it can't be zoomed apart,
/// tapping it opens a list to pick one.
///
/// The barangay boundary (from ../constants/barangay_boundary.dart) is
/// drawn on top of the tiles: the area outside it is dimmed and the
/// boundary itself is outlined, so the barangay reads as the "focused"
/// area of the map.
class UserLocationScreen extends StatefulWidget {
  final bool isActive;

  const UserLocationScreen({super.key, required this.isActive});

  @override
  State<UserLocationScreen> createState() => _TanodLocationScreenState();
}

/// A camera pin ready to plot — parsed once per Supabase stream emission so the
/// build method itself stays simple.
class _CameraPin {
  final String id;
  final String name;
  final String location;
  final String status;
  final LatLng position;

  const _CameraPin({
    required this.id,
    required this.name,
    required this.location,
    required this.status,
    required this.position,
  });

  static _CameraPin? fromMap(Map<String, dynamic> data) {
    final lat = data['latitude'];
    final lng = data['longitude'];
    if (lat is! num || lng is! num) return null; // no coordinates saved yet
    return _CameraPin(
      id: data['id'].toString(),
      name: (data['name'] ?? 'Unnamed Camera').toString(),
      location: (data['location'] ?? '').toString(),
      status: (data['status'] ?? 'Offline').toString(),
      position: LatLng(lat.toDouble(), lng.toDouble()),
    );
  }
}

/// A tanod pin ready to plot — same parsing shape as _CameraPin so both
/// streams can share the fit-bounds / marker-building logic.
class _TanodPin {
  final String id;
  final String name;
  final String status;
  final LatLng position;

  const _TanodPin({
    required this.id,
    required this.name,
    required this.status,
    required this.position,
  });

  static _TanodPin? fromMap(Map<String, dynamic> data) {
    final lat = data['latitude'];
    final lng = data['longitude'];
    if (lat is! num || lng is! num) return null; // no coordinates saved yet
    return _TanodPin(
      id: data['id'].toString(),
      name: (data['name'] ?? 'Unnamed Tanod').toString(),
      status: (data['status'] ?? 'Offline').toString(),
      position: LatLng(lat.toDouble(), lng.toDouble()),
    );
  }
}

/// A Task Force / Purok Leader / Tanod pin, sourced from `live_gps`
/// (member_id, latitude, longitude, full_name, role, is_sharing, updated_at)
/// rather than the `tanods` or `profiles` tables. Any other role is filtered
/// out at parse time, so `role` here is guaranteed to be one of the
/// three values this screen cares about.
class _PersonnelPin {
  final String id;
  final String name;
  final String role;
  final LatLng position;
  final bool sharing;
  final DateTime updatedAt;

  const _PersonnelPin({
    required this.id,
    required this.name,
    required this.role,
    required this.position,
    required this.sharing,
    required this.updatedAt,
  });

  _PresenceStatus statusFor(Set<String> busyIds) {
    if (!sharing) return _PresenceStatus.locationOff;
    if (DateTime.now().difference(updatedAt) > _kStaleAfter) {
      return _PresenceStatus.noSignal;
    }
    if (busyIds.contains(id)) return _PresenceStatus.onDispatch;
    return _PresenceStatus.available;
  }

  static _PersonnelPin? fromMap(Map<String, dynamic> data) {
    final lat = data['latitude'];
    final lng = data['longitude'];
    if (lat is! num || lng is! num) return null; // no coordinates saved yet

    final role = (data['role'] ?? '').toString().trim();
    if (role != 'Task Force' && role != 'Purok Leader' && role != 'Tanod') {
      return null;
    }

    final name = (data['full_name'] ?? '').toString().trim();
    // Missing/unparseable updated_at => epoch (stale), so a bad row never
    // looks fresh.
    final updatedAt = DateTime.tryParse(data['updated_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);

    return _PersonnelPin(
      id: (data['member_id'] ?? data['id']).toString(),
      name: name.isEmpty ? 'Unnamed' : name,
      role: role,
      position: LatLng(lat.toDouble(), lng.toDouble()),
      sharing: data['is_sharing'] != false,
      updatedAt: updatedAt,
    );
  }
}

class _TanodLocationScreenState extends State<UserLocationScreen>
    with TickerProviderStateMixin {
  // Fallback center used only if no tanods are found in the stream yet.
  static const LatLng _fallbackCenter = LatLng(14.6837, 121.0766);

  final MapController _mapController = MapController();
  late final AnimatedMapController _animatedMapController =
      AnimatedMapController(vsync: this, mapController: _mapController);

  final Stream<List<Map<String, dynamic>>> _cctvStream = Supabase.instance.client
      .from('cameras')
      .stream(primaryKey: ['id']);

  final Stream<List<Map<String, dynamic>>> _tanodStream = Supabase.instance.client
      .from('tanods')
      .stream(primaryKey: ['id']);

  // Task Force / Purok Leader / Tanod personnel — each role's mobile app
  // upserts its own row (member_id, latitude, longitude, full_name, role)
  // into `live_gps`. member_id is that table's primary key.
  final Stream<List<Map<String, dynamic>>> _profilesStream = Supabase.instance.client
      .from('live_gps')
      .stream(primaryKey: ['member_id']);

  /// Whether the filter panel is expanded.
  bool _showFilterPanel = false;

  /// Which pin categories are currently shown on the map. All on by default.
  bool _showCameras = true;
  bool _showTanods = true;
  bool _showTaskForce = true;
  bool _showPurokLeaders = true;

  /// Member ids currently on an active dispatch (any role).
  Set<String> _busyIds = {};

  /// profiles.id -> purok, for the popup.
  Map<String, String> _purokById = {};

  /// Tapped person (popup) / stacked people (pick-one list).
  String? _selectedId;
  List<String> _pickerIds = [];

  /// Current map zoom, tracked so clusters re-group while zooming.
  double _zoom = 16;

  StreamSubscription<List<Map<String, dynamic>>>? _dispatchSub;

  /// Re-evaluates "no signal" every 30 s even if no new rows arrive.
  Timer? _staleTimer;

  void _toggleFilterPanel() {
    setState(() {
      _showFilterPanel = !_showFilterPanel;
    });
  }

  @override
  void initState() {
    super.initState();
    // Once the map has laid out, frame the barangay boundary instead of
    // whatever the initial tanod/fallback center happens to be.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (BarangayBoundary.points.isNotEmpty) {
        _fitAllPoints(BarangayBoundary.points);
      }
    });

    _fetchPuroks().then((m) {
      if (mounted) setState(() => _purokById = m);
    });

    // Who is currently on an active dispatch (any role).
    _dispatchSub = Supabase.instance.client
        .from('tanod_dispatches')
        .stream(primaryKey: ['id'])
        .listen((rows) {
      _busyIds = _busyIdsFromRows(rows);
      if (mounted) setState(() {});
    }, onError: (e) => debugPrint('tanod_dispatches stream error: $e'));

    _staleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _dispatchSub?.cancel();
    _staleTimer?.cancel();
    _animatedMapController.dispose();
    super.dispose();
  }

  /// Zooms/pans so every plotted point is visible at once. Safe to call
  /// with just one point too — LatLngBounds.fromPoints requires at least
  /// one point, which is always satisfied here.
  void _fitAllPoints(List<LatLng> points) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      _animatedMapController.animateTo(destCenter: points.first, destZoom: 16);
      return;
    }
    final bounds = LatLngBounds.fromPoints(points);
    _animatedMapController.animateFitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)),
    );
  }

  void _focusOnTanod(_TanodPin pin) {
    _animatedMapController.animateTo(destCenter: pin.position, destZoom: 17);
  }

  void _selectPin(_PersonnelPin pin) {
    setState(() {
      _selectedId = pin.id;
      _pickerIds = [];
    });
    // Center on the person without changing the zoom level.
    _animatedMapController.animateTo(destCenter: pin.position);
  }

  void _onClusterTap(List<_PersonnelPin> group) {
    if (_canZoomIntoCluster(_animatedMapController, group)) {
      _zoomIntoCluster(_animatedMapController, group);
    } else {
      // Can't zoom apart any further -> let the admin pick one.
      setState(() {
        _pickerIds = group.map((p) => p.id).toList();
        _selectedId = null;
      });
    }
  }

  void _clearSelection() {
    if (_selectedId == null && _pickerIds.isEmpty) return;
    setState(() {
      _selectedId = null;
      _pickerIds = [];
    });
  }

  Future<void> _openFullscreen(
    List<_TanodPin> tanodPins,
    List<_CameraPin> cameraPins,
    List<_PersonnelPin> personnelPins,
  ) async {
    // Carry over exactly where the embedded map is currently centered/zoomed
    // so fullscreen opens on the same view instead of re-fitting the
    // boundary — same idea as CCTV passing its zoomed-camera id in.
    final camera = _mapController.camera;
    final result = await Navigator.of(context).push<_MapCameraState>(
      _instantRoute(
        (_) => _MapFullscreenPage(
          tanodPins: tanodPins,
          cameraPins: cameraPins,
          personnelPins: personnelPins,
          busyIds: _busyIds,
          purokById: _purokById,
          initialCenter: camera.center,
          initialZoom: camera.zoom,
        ),
      ),
    );
    if (!mounted || result == null) return;
    // Carry the position back the other way when exiting fullscreen, so
    // panning/zooming while fullscreen sticks after returning.
    _mapController.move(result.center, result.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppColors.border(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _cctvStream,
        builder: (context, camSnapshot) {
          final cameraPins = <_CameraPin>[];
          if (camSnapshot.hasData) {
            for (final row in camSnapshot.data!) {
              final pin = _CameraPin.fromMap(row);
              if (pin != null) cameraPins.add(pin);
            }
          }

          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: _tanodStream,
            builder: (context, tanodSnapshot) {
              final tanodPins = <_TanodPin>[];
              if (tanodSnapshot.hasData) {
                for (final row in tanodSnapshot.data!) {
                  final pin = _TanodPin.fromMap(row);
                  if (pin != null) tanodPins.add(pin);
                }
              }

              return StreamBuilder<List<Map<String, dynamic>>>(
                stream: _profilesStream,
                builder: (context, profileSnapshot) {
                  final personnelPins = <_PersonnelPin>[];
                  if (profileSnapshot.hasData) {
                    for (final row in profileSnapshot.data!) {
                      final pin = _PersonnelPin.fromMap(row);
                      if (pin != null) personnelPins.add(pin);
                    }
                  }

                  final initialCenter = BarangayBoundary.points.isNotEmpty
                      ? BarangayBoundary.points.first
                      : (tanodPins.isNotEmpty
                          ? tanodPins.first.position
                          : _fallbackCenter);

                  return Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: initialCenter,
                          initialZoom: 16,
                          // Stops users from zooming out past a barangay-scale
                          // view (tiles get blurry/empty-looking beyond this)
                          // and caps how far in they can go.
                          minZoom: 14,
                          maxZoom: _kMaxMapZoom,
                          // Tap empty map => close the popup.
                          onTap: (_, __) => _clearSelection(),
                          onPositionChanged: (camera, _) {
                            if ((camera.zoom * 2).floor() != (_zoom * 2).floor()) {
                              _zoom = camera.zoom;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) setState(() {});
                              });
                            }
                          },
                        ),
                        children: [
                          // Keyless OSM tiles, desaturated + tinted to match
                          // the app's current theme — same technique as the
                          // Device Location screen, no API key required.
                          _ThemedOsmTileLayer(isDark: isDark),
                          // Dims everything outside the barangay boundary and
                          // outlines the boundary itself, so the barangay reads
                          // as the "focused" area of the map.
                          if (BarangayBoundary.points.isNotEmpty)
                            PolygonLayer(
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
                                  borderColor: _boundaryColor,
                                  borderStrokeWidth: 3,
                                  isFilled: false,
                                ),
                              ],
                            ),
                          MarkerLayer(
                            markers: [
                              // One pin per tanod (legacy `tanods` table) that
                              // has saved coordinates.
                              if (_showTanods)
                                for (final pin in tanodPins)
                                  Marker(
                                    point: pin.position,
                                    width: 112,
                                    height: 66,
                                    alignment: Alignment.topCenter,
                                    child: _MapPinMarker(
                                      icon: _iconForRole('Tanod'),
                                      color: _tanodPinColor,
                                      label: pin.name,
                                      statusRingColor: _colorForStatus(pin.status),
                                      pulse: pin.status.toUpperCase() == 'ONLINE',
                                      onTap: () => _focusOnTanod(pin),
                                    ),
                                  ),
                              // One pin per camera that has saved coordinates.
                              if (_showCameras)
                                for (final pin in cameraPins)
                                  Marker(
                                    point: pin.position,
                                    width: 112,
                                    height: 66,
                                    alignment: Alignment.topCenter,
                                    child: _MapPinMarker(
                                      icon: Icons.videocam_outlined,
                                      color: _cameraPinColor,
                                      label: pin.name,
                                      statusRingColor: _colorForStatus(pin.status),
                                      pulse: pin.status.toUpperCase() == 'ONLINE',
                                      onTap: () => _animatedMapController.animateTo(
                                          destCenter: pin.position, destZoom: 17),
                                    ),
                                  ),
                              // Task Force / Purok Leader / Tanod personnel from
                              // live_gps: role icon + color stay on the pin,
                              // status shows as ring/badge/tag. Grouped when
                              // close/overlapping. Each role filterable.
                              ..._buildPersonnelMarkers(
                                pins: personnelPins,
                                busyIds: _busyIds,
                                zoom: _zoom,
                                selectedId: _selectedId,
                                roleVisible: (role) =>
                                    (role == 'Tanod' && _showTanods) ||
                                    (role == 'Task Force' && _showTaskForce) ||
                                    (role == 'Purok Leader' && _showPurokLeaders),
                                onPinTap: _selectPin,
                                onClusterTap: _onClusterTap,
                              ),
                            ],
                          ),
                          RichAttributionWidget(
                            alignment: AttributionAlignment.bottomLeft,
                            showFlutterMapAttribution: false,
                            attributions: [
                              TextSourceAttribution('OpenStreetMap contributors'),
                            ],
                          ),
                        ],
                      ),

                      // Boundary recenter button.
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Material(
                          color: AppColors.card(context),
                          shape: const CircleBorder(),
                          elevation: 3,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _fitAllPoints(BarangayBoundary.points),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                Icons.crop_free,
                                color: AppColors.textMain(context),
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Filter toggle button — sits below the boundary button.
                      Positioned(
                        top: 60,
                        right: 12,
                        child: Material(
                          color: AppColors.card(context),
                          shape: const CircleBorder(),
                          elevation: 3,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: _toggleFilterPanel,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                _showFilterPanel ? Icons.close : Icons.filter_list,
                                color: AppColors.textMain(context),
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Collapsible filter panel — toggle which pin
                      // categories are shown on the map.
                      if (_showFilterPanel)
                        Positioned(
                          top: 108,
                          right: 12,
                          child: _FilterPanel(
                            showCameras: _showCameras,
                            showTanods: _showTanods,
                            showTaskForce: _showTaskForce,
                            showPurokLeaders: _showPurokLeaders,
                            onCamerasChanged: (v) => setState(() => _showCameras = v),
                            onTanodsChanged: (v) => setState(() => _showTanods = v),
                            onTaskForceChanged: (v) => setState(() => _showTaskForce = v),
                            onPurokLeadersChanged: (v) => setState(() => _showPurokLeaders = v),
                          ),
                        ),

                      // Small legend, top-left.
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _MapLegend(
                          tanodCount: personnelPins.where((p) => p.role == 'Tanod').length,
                          cameraCount: cameraPins.length,
                          taskForceCount:
                              personnelPins.where((p) => p.role == 'Task Force').length,
                          purokLeaderCount:
                              personnelPins.where((p) => p.role == 'Purok Leader').length,
                        ),
                      ),

                      // Zoom controls + fullscreen button, stacked together
                      // at the bottom-right.
                      Positioned(
                        bottom: 12,
                        right: 12,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _ZoomControls(animatedMapController: _animatedMapController),
                            const SizedBox(height: 8),
                            Material(
                              color: AppColors.card(context),
                              shape: const CircleBorder(),
                              elevation: 3,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () =>
                                    _openFullscreen(tanodPins, cameraPins, personnelPins),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Icon(
                                    Icons.fullscreen,
                                    color: AppColors.textMain(context),
                                    size: 18,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Tap popup (name / role / purok / status) or the
                      // "pick one" list for people on the same spot.
                      _buildPersonnelPopup(
                        pins: personnelPins,
                        busyIds: _busyIds,
                        purokById: _purokById,
                        selectedId: _selectedId,
                        pickerIds: _pickerIds,
                        onPick: _selectPin,
                        onClose: _clearSelection,
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets (used by both the embedded map and the fullscreen map page)
// ---------------------------------------------------------------------------

class _MapLegend extends StatelessWidget {
  final int tanodCount;
  final int cameraCount;
  final int taskForceCount;
  final int purokLeaderCount;

  const _MapLegend({
    required this.tanodCount,
    required this.cameraCount,
    required this.taskForceCount,
    required this.purokLeaderCount,
  });

  @override
  Widget build(BuildContext context) {
    Widget header(String t) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            t,
            style: TextStyle(
              color: AppColors.textMuted(context),
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card(context).withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          header('ROLE'),
          _legendRow(
            context: context,
            icon: _iconForRole('Tanod'),
            color: _tanodPinColor,
            label: 'Tanod ($tanodCount)',
          ),
          const SizedBox(height: 4),
          _legendRow(
            context: context,
            icon: _iconForRole('Task Force'),
            color: _taskForcePinColor,
            label: 'Task Force ($taskForceCount)',
          ),
          const SizedBox(height: 4),
          _legendRow(
            context: context,
            icon: _iconForRole('Purok Leader'),
            color: _purokLeaderPinColor,
            label: 'Purok Leader ($purokLeaderCount)',
          ),
          const SizedBox(height: 4),
          _legendRow(
            context: context,
            icon: Icons.videocam,
            color: _cameraPinColor,
            label: 'Camera ($cameraCount)',
            ringColor: _onlineColor,
          ),
          const SizedBox(height: 8),
          header('STATUS'),
          for (final s in _PresenceStatus.values) ...[
            _legendRow(
              context: context,
              icon: _iconForPresence(s),
              color: _colorForPresence(s),
              label: _labelForPresence(s),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _legendRow({
    required BuildContext context,
    required IconData icon,
    required Color color,
    required String label,
    Color? ringColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: ringColor != null
                ? Border.all(color: ringColor, width: 1.5)
                : null,
          ),
          child: Icon(icon, color: Colors.white, size: 11),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: AppColors.textMuted(context), fontSize: 11),
        ),
      ],
    );
  }
}

/// Lets an admin toggle which pin categories show on the map — handy when
/// the map gets crowded with cameras, tanods, task force, and purok leader
/// pins all at once.
class _FilterPanel extends StatelessWidget {
  final bool showCameras;
  final bool showTanods;
  final bool showTaskForce;
  final bool showPurokLeaders;
  final ValueChanged<bool> onCamerasChanged;
  final ValueChanged<bool> onTanodsChanged;
  final ValueChanged<bool> onTaskForceChanged;
  final ValueChanged<bool> onPurokLeadersChanged;

  const _FilterPanel({
    required this.showCameras,
    required this.showTanods,
    required this.showTaskForce,
    required this.showPurokLeaders,
    required this.onCamerasChanged,
    required this.onTanodsChanged,
    required this.onTaskForceChanged,
    required this.onPurokLeadersChanged,
  });

  Widget _row({
    required BuildContext context,
    required String label,
    required Color color,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: AppColors.textMain(context), fontSize: 12.5),
              ),
            ),
            Icon(
              value ? Icons.check_box : Icons.check_box_outline_blank,
              color: value ? color : AppColors.textMuted(context),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card(context).withOpacity(0.97),
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      child: Container(
        width: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                'SHOW ON MAP',
                style: TextStyle(
                  color: AppColors.textMuted(context),
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            _row(
              context: context,
              label: 'Cameras',
              color: _cameraPinColor,
              value: showCameras,
              onChanged: onCamerasChanged,
            ),
            _row(
              context: context,
              label: 'Tanod',
              color: _tanodPinColor,
              value: showTanods,
              onChanged: onTanodsChanged,
            ),
            _row(
              context: context,
              label: 'Task Force',
              color: _taskForcePinColor,
              value: showTaskForce,
              onChanged: onTaskForceChanged,
            ),
            _row(
              context: context,
              label: 'Purok Leader',
              color: _purokLeaderPinColor,
              value: showPurokLeaders,
              onChanged: onPurokLeadersChanged,
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Round icon badge with a small Life360-style pointer at the bottom, drawn
/// with a status-colored [fill] badge, a white border, and a solid white pointer.
/// The pointer's tip is at bottom-center of [size], so a Marker with
/// `alignment: Alignment.topCenter` puts that tip exactly on the coordinate.
class _PinPainter extends CustomPainter {
  final Color fill;
  final double borderWidth;
  final bool selected;

  const _PinPainter({
    required this.fill,
    this.borderWidth = 2.5,
    this.selected = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final outerR = size.width / 2;
    final r = outerR - borderWidth / 2; // border stays inside the badge width
    final cy = outerR;
    final hw = outerR * 0.36; // half-width of the pointer base
    final baseY = cy + outerR * 0.85; // base sits inside the circle
    final tipY = size.height;

    final circle = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    final pointer = Path()
      ..moveTo(cx - hw, baseY)
      ..lineTo(cx, tipY)
      ..lineTo(cx + hw, baseY)
      ..close();
    final shape = Path.combine(PathOperation.union, circle, pointer);

    canvas.drawShadow(shape, Colors.black, 3, true);

    // Selected: dark halo around the white border so it stands out.
    if (selected) {
      canvas.drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = borderWidth + 5
          ..color = Colors.black.withOpacity(0.55),
      );
    }

    // Pointer is solid white; the badge is the status color with a white border.
    canvas.drawPath(pointer, Paint()..color = Colors.white);
    canvas.drawPath(circle, Paint()..color = fill);
    canvas.drawPath(
      circle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_PinPainter o) =>
      o.fill != fill || o.borderWidth != borderWidth || o.selected != selected;
}

/// A single, consistent round-badge marker with a small bottom pointer, shared by tanods, cameras, and
/// personnel: a badge (role icon + role color) with the entity's name in a
/// compact label above it. The pointer tip is the bottom-most point of the
/// marker, so with `Marker.alignment: Alignment.topCenter` the tip sits
/// exactly on the coordinate.
///
/// For live_gps personnel, [presence] adds the STATUS on top without hiding
/// the role: a status-colored outline, a small corner badge icon, and a short
/// tag next to the name (BUSY / OFF / NO SIGNAL). Cameras and legacy tanods
/// keep using [statusRingColor]/[pulse]. [selected] adds a white glow.
class _MapPinMarker extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final Color? statusRingColor;
  final bool pulse;
  final bool selected;
  final _PresenceStatus? presence;
  final VoidCallback onTap;

  const _MapPinMarker({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.statusRingColor,
    this.pulse = false,
    this.selected = false,
    this.presence,
  });

  @override
  Widget build(BuildContext context) {
    final p = presence;
    final ringColor = p != null ? _colorForPresence(p) : statusRingColor;
    final doPulse = p != null ? p == _PresenceStatus.onDispatch : pulse;
    final dimmed = p == _PresenceStatus.locationOff || p == _PresenceStatus.noSignal;

    const pinW = 30.0, pinH = 38.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        // Bottom-aligned so the pin tip is the very bottom of the marker box.
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Name label (+ status tag), above the pin.
          Container(
            constraints: const BoxConstraints(maxWidth: 108),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.card(context).withOpacity(0.92),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: dimmed
                    ? AppColors.textMuted(context)
                    : AppColors.textMain(context),
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: pinW,
            height: pinH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Expanding ring around the pin head for "online" / "on dispatch".
                if (doPulse && ringColor != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: pinW,
                    child: Center(child: _PulseRing(color: ringColor)),
                  ),
                Opacity(
                  opacity: dimmed ? 0.7 : 1,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CustomPaint(
                        size: const Size(pinW, pinH),
                        painter: _PinPainter(
                          fill: ringColor ?? color, // status color (role color if none)
                          selected: selected,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: pinW,
                        child: Center(child: Icon(icon, color: Colors.white, size: 15)),
                      ),
                    ],
                  ),
                ),
                // Status badge (personnel only), on the pin head's corner.
                if (p != null)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _colorForPresence(p),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.2),
                      ),
                      child: Icon(_iconForPresence(p), color: Colors.white, size: 9),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Numbered badge with a bottom pointer for a group of nearby / overlapping personnel of any role.
/// The tip marks the group's average position.
///  - fill  = role color if everyone is the same role, slate if mixed
///  - number = status summary color (green all available, red all busy, yellow
///            mixed, grey/orange if everyone is off / no signal)
///  - label = role composition, e.g. "T2 · TF1 · PL1"
class _PersonnelClusterMarker extends StatelessWidget {
  final List<_PersonnelPin> pins;
  final Set<String> busyIds;

  const _PersonnelClusterMarker({required this.pins, required this.busyIds});

  @override
  Widget build(BuildContext context) {
    final statuses = pins.map((p) => p.statusFor(busyIds)).toList();
    final off = statuses
        .where((s) => s == _PresenceStatus.locationOff || s == _PresenceStatus.noSignal)
        .length;
    final noSig = statuses.where((s) => s == _PresenceStatus.noSignal).length;
    final busy = statuses.where((s) => s == _PresenceStatus.onDispatch).length;
    final active = pins.length - off;

    final Color ring;
    if (active == 0) {
      ring = (noSig > 0 && noSig == off) ? _noSignalColor : _locationOffColor;
    } else if (busy == 0 && off == 0) {
      ring = _availableColor;
    } else if (busy == active && off == 0) {
      ring = _onDispatchColor;
    } else {
      ring = _mixedClusterColor;
    }

    final counts = <String, int>{};
    for (final p in pins) {
      counts[p.role] = (counts[p.role] ?? 0) + 1;
    }
    final composition = [
      for (final r in const ['Tanod', 'Task Force', 'Purok Leader'])
        if (counts[r] != null) '${_roleAbbr(r)}${counts[r]}',
    ].join(' · ');

    const pinW = 40.0, pinH = 48.0;

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          decoration: BoxDecoration(
            color: AppColors.card(context).withOpacity(0.92),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white),
          ),
          child: Text(
            composition,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: AppColors.textMain(context),
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: pinW,
          height: pinH,
          child: Stack(
            children: [
              CustomPaint(
                size: const Size(pinW, pinH),
                painter: _PinPainter(fill: ring, borderWidth: 3),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: pinW,
                child: Center(
                  child: Text(
                    pins.length > 99 ? '99+' : '${pins.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Small status pill (icon + label) used in the popup cards.
Widget _statusPill(_PresenceStatus s) {
  final c = _colorForPresence(s);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: c.withOpacity(0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_iconForPresence(s), size: 12, color: c),
        const SizedBox(width: 4),
        Text(
          _labelForPresence(s).toUpperCase(),
          style: TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

/// Small popup for one person: name, role, purok (if any) and status.
class _PersonnelInfoCard extends StatelessWidget {
  final _PersonnelPin pin;
  final _PresenceStatus status;
  final String? purok;
  final VoidCallback onClose;

  const _PersonnelInfoCard({
    required this.pin,
    required this.status,
    required this.purok,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final roleColor = _colorForRole(pin.role);
    final hasPurok = purok != null && purok!.trim().isNotEmpty;
    final seen = _relativeTime(pin.updatedAt);

    final String detail;
    switch (status) {
      case _PresenceStatus.locationOff:
        detail = 'Turned off location sharing • last seen $seen';
        break;
      case _PresenceStatus.noSignal:
        detail = 'Lost signal • last seen $seen';
        break;
      case _PresenceStatus.onDispatch:
        detail = 'Responding to an active dispatch • updated $seen';
        break;
      case _PresenceStatus.available:
        detail = 'Updated $seen';
        break;
    }

    return Material(
      color: AppColors.card(context),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 270,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: roleColor, shape: BoxShape.circle),
                  child: Icon(_iconForRole(pin.role), color: Colors.white, size: 17),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pin.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMain(context),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        hasPurok ? '${pin.role} • ${_purokLabel(purok!)}' : pin.role,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted(context),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 18, color: AppColors.textMuted(context)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _statusPill(status),
            const SizedBox(height: 6),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.textMuted(context), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Pick one" list for several people standing on the same spot (shown when
/// the map can't be zoomed in any further to separate them).
class _PersonnelPickerCard extends StatelessWidget {
  final List<_PersonnelPin> pins;
  final Set<String> busyIds;
  final String? Function(_PersonnelPin pin) purokFor;
  final void Function(_PersonnelPin pin) onPick;
  final VoidCallback onClose;

  const _PersonnelPickerCard({
    required this.pins,
    required this.busyIds,
    required this.purokFor,
    required this.onPick,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card(context),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 270,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${pins.length} people here — pick one',
                      style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: onClose,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child:
                          Icon(Icons.close, size: 18, color: AppColors.textMuted(context)),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppColors.border(context)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final p in pins) _row(context, p),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _PersonnelPin p) {
    final s = p.statusFor(busyIds);
    final sc = _colorForPresence(s);
    final purok = purokFor(p);
    final sub = (purok != null && purok.trim().isNotEmpty)
        ? '${p.role} • ${_purokLabel(purok)}'
        : p.role;
    return InkWell(
      onTap: () => onPick(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: _colorForRole(p.role),
                shape: BoxShape.circle,
                border: Border.all(color: sc, width: 2.2),
              ),
              child: Icon(_iconForRole(p.role), color: Colors.white, size: 13),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(_iconForPresence(s), size: 13, color: sc),
            const SizedBox(width: 3),
            Text(
              _labelForPresence(s),
              style: TextStyle(color: sc, fontSize: 10, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

/// A soft, looping expanding ring behind an "online" marker — a quick
/// peripheral-vision cue for who's currently active, on top of the
/// legend's static color coding.
class _PulseRing extends StatefulWidget {
  final Color color;

  const _PulseRing({required this.color});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Container(
          width: 28 + (t * 16),
          height: 28 + (t * 16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.color.withOpacity((1 - t) * 0.55),
              width: 2,
            ),
          ),
        );
      },
    );
  }
}

/// Compact +/- zoom control, since scroll-to-zoom / pinch-to-zoom isn't
/// always obvious, especially on desktop with a mouse. Steps are animated
/// via [AnimatedMapController] so tapping +/- eases smoothly instead of
/// snapping to the new zoom level.
class _ZoomControls extends StatelessWidget {
  final AnimatedMapController animatedMapController;

  const _ZoomControls({required this.animatedMapController});

  void _step(double delta) {
    final camera = animatedMapController.camera;
    final next = (camera.zoom + delta).clamp(14.0, _kMaxMapZoom);
    animatedMapController.animateTo(destZoom: next);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card(context),
      borderRadius: BorderRadius.circular(8),
      elevation: 3,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              onTap: () => _step(1),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.add, color: AppColors.textMain(context), size: 16),
              ),
            ),
            Divider(height: 1, color: AppColors.border(context)),
            InkWell(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
              onTap: () => _step(-1),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.remove, color: AppColors.textMain(context), size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card(context).withOpacity(0.85),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: AppColors.textMain(context), size: size),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dedicated fullscreen map page (mirrors CctvLiveScreen's
// _LayoutFullscreenPage: hides the native title bar and goes true
// fullscreen on desktop, immersive edge-to-edge on mobile).
// ---------------------------------------------------------------------------

/// A map camera position (center + zoom) — used to carry the current view
/// into fullscreen and hand back wherever the user ends up panning/zooming
/// to when they exit, the same way CCTV carries its zoomed-camera id.
class _MapCameraState {
  final LatLng center;
  final double zoom;

  const _MapCameraState({required this.center, required this.zoom});
}

class _MapFullscreenPage extends StatefulWidget {
  final List<_TanodPin> tanodPins;
  final List<_CameraPin> cameraPins;
  final List<_PersonnelPin> personnelPins;
  final Set<String> busyIds;
  final Map<String, String> purokById;
  final LatLng initialCenter;
  final double initialZoom;

  const _MapFullscreenPage({
    required this.tanodPins,
    required this.cameraPins,
    required this.personnelPins,
    required this.busyIds,
    required this.purokById,
    required this.initialCenter,
    required this.initialZoom,
  });

  @override
  State<_MapFullscreenPage> createState() => _MapFullscreenPageState();
}

class _MapFullscreenPageState extends State<_MapFullscreenPage>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  late final AnimatedMapController _animatedMapController =
      AnimatedMapController(vsync: this, mapController: _mapController);

  /// Whether the filter panel is expanded.
  bool _showFilterPanel = false;

  /// Which pin categories are currently shown on the map. All on by default.
  bool _showCameras = true;
  bool _showTanods = true;
  bool _showTaskForce = true;
  bool _showPurokLeaders = true;

  double _zoom = 16;
  Timer? _staleTimer;

  String? _selectedId;
  List<String> _pickerIds = [];

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
    // Re-evaluate "no signal" every 30 s even if nothing else rebuilds.
    _staleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });

    if (_isDesktopPlatform) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          // Hide the native title bar explicitly — on Windows, setFullScreen
          // alone can leave the OS title bar/chrome visible if the window
          // was created with titleBarStyle: TitleBarStyle.normal.
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          await windowManager.setFullScreen(true);
        } catch (e, st) {
          debugPrint('>>> map fullscreen setup FAILED: $e\n$st');
        }
      });
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    _staleTimer?.cancel();
    _animatedMapController.dispose();
    if (_isDesktopPlatform) {
      windowManager.setFullScreen(false);
      // Restore the normal title bar when leaving fullscreen.
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  void _selectPin(_PersonnelPin pin) {
    setState(() {
      _selectedId = pin.id;
      _pickerIds = [];
    });
    _animatedMapController.animateTo(destCenter: pin.position);
  }

  void _onClusterTap(List<_PersonnelPin> group) {
    if (_canZoomIntoCluster(_animatedMapController, group)) {
      _zoomIntoCluster(_animatedMapController, group);
    } else {
      setState(() {
        _pickerIds = group.map((p) => p.id).toList();
        _selectedId = null;
      });
    }
  }

  void _clearSelection() {
    if (_selectedId == null && _pickerIds.isEmpty) return;
    setState(() {
      _selectedId = null;
      _pickerIds = [];
    });
  }

  void _fitAllPoints() {
    final points = <LatLng>[
      ...BarangayBoundary.points,
      ...widget.tanodPins.map((p) => p.position),
      ...widget.cameraPins.map((p) => p.position),
      ...widget.personnelPins.map((p) => p.position),
    ];
    if (points.isEmpty) return;
    if (points.length == 1) {
      _animatedMapController.animateTo(destCenter: points.first, destZoom: 16);
      return;
    }
    _animatedMapController.animateFitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: const EdgeInsets.all(60),
      ),
    );
  }

  void _pop() {
    final camera = _mapController.camera;
    Navigator.of(context).pop(
      _MapCameraState(center: camera.center, zoom: camera.zoom),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope<_MapCameraState>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.bg(context),
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: widget.initialCenter,
                initialZoom: widget.initialZoom,
                minZoom: 14,
                maxZoom: _kMaxMapZoom,
                onTap: (_, __) => _clearSelection(),
                onPositionChanged: (camera, _) {
                  if ((camera.zoom * 2).floor() != (_zoom * 2).floor()) {
                    _zoom = camera.zoom;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() {});
                    });
                  }
                },
              ),
              children: [
                _ThemedOsmTileLayer(isDark: isDark),
                if (BarangayBoundary.points.isNotEmpty)
                  PolygonLayer(
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
                        borderColor: _boundaryColor,
                        borderStrokeWidth: 3,
                        isFilled: false,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (_showTanods)
                      for (final pin in widget.tanodPins)
                        Marker(
                          point: pin.position,
                          width: 112,
                          height: 66,
                          alignment: Alignment.topCenter,
                          child: _MapPinMarker(
                            icon: _iconForRole('Tanod'),
                            color: _tanodPinColor,
                            label: pin.name,
                            statusRingColor: _colorForStatus(pin.status),
                            pulse: pin.status.toUpperCase() == 'ONLINE',
                            onTap: () => _animatedMapController.animateTo(
                                destCenter: pin.position, destZoom: 17),
                          ),
                        ),
                    if (_showCameras)
                      for (final pin in widget.cameraPins)
                        Marker(
                          point: pin.position,
                          width: 112,
                          height: 66,
                          alignment: Alignment.topCenter,
                          child: _MapPinMarker(
                            icon: Icons.videocam_outlined,
                            color: _cameraPinColor,
                            label: pin.name,
                            statusRingColor: _colorForStatus(pin.status),
                            pulse: pin.status.toUpperCase() == 'ONLINE',
                            onTap: () => _animatedMapController.animateTo(
                                destCenter: pin.position, destZoom: 17),
                          ),
                        ),
                    ..._buildPersonnelMarkers(
                      pins: widget.personnelPins,
                      busyIds: widget.busyIds,
                      zoom: _zoom,
                      selectedId: _selectedId,
                      roleVisible: (role) =>
                          (role == 'Tanod' && _showTanods) ||
                          (role == 'Task Force' && _showTaskForce) ||
                          (role == 'Purok Leader' && _showPurokLeaders),
                      onPinTap: _selectPin,
                      onClusterTap: _onClusterTap,
                    ),
                  ],
                ),
                RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  showFlutterMapAttribution: false,
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),

            // Legend, top-left.
            Positioned(
              top: 12,
              left: 12,
              child: SafeArea(
                child: _MapLegend(
                  tanodCount:
                      widget.personnelPins.where((p) => p.role == 'Tanod').length,
                  cameraCount: widget.cameraPins.length,
                  taskForceCount:
                      widget.personnelPins.where((p) => p.role == 'Task Force').length,
                  purokLeaderCount:
                      widget.personnelPins.where((p) => p.role == 'Purok Leader').length,
                ),
              ),
            ),

            // "Fit all" button, top-right.
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: Material(
                  color: AppColors.card(context),
                  shape: const CircleBorder(),
                  elevation: 3,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _fitAllPoints,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.center_focus_strong,
                        color: AppColors.textMain(context),
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Filter toggle button, below "Fit all".
            Positioned(
              top: 60,
              right: 12,
              child: SafeArea(
                child: Material(
                  color: AppColors.card(context),
                  shape: const CircleBorder(),
                  elevation: 3,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _showFilterPanel = !_showFilterPanel),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        _showFilterPanel ? Icons.close : Icons.filter_list,
                        color: AppColors.textMain(context),
                        size: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Collapsible filter panel.
            if (_showFilterPanel)
              Positioned(
                top: 108,
                right: 12,
                child: SafeArea(
                  child: _FilterPanel(
                    showCameras: _showCameras,
                    showTanods: _showTanods,
                    showTaskForce: _showTaskForce,
                    showPurokLeaders: _showPurokLeaders,
                    onCamerasChanged: (v) => setState(() => _showCameras = v),
                    onTanodsChanged: (v) => setState(() => _showTanods = v),
                    onTaskForceChanged: (v) => setState(() => _showTaskForce = v),
                    onPurokLeadersChanged: (v) => setState(() => _showPurokLeaders = v),
                  ),
                ),
              ),

            // Zoom controls + exit-fullscreen button, stacked together at
            // the bottom-right.
            Positioned(
              bottom: 12,
              right: 12,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _ZoomControls(animatedMapController: _animatedMapController),
                    const SizedBox(height: 8),
                    _RoundIconButton(
                      icon: Icons.fullscreen_exit,
                      onTap: _pop,
                    ),
                  ],
                ),
              ),
            ),

            // Tap popup / pick-one list.
            _buildPersonnelPopup(
              pins: widget.personnelPins,
              busyIds: widget.busyIds,
              purokById: widget.purokById,
              selectedId: _selectedId,
              pickerIds: _pickerIds,
              onPick: _selectPin,
              onClose: _clearSelection,
            ),
          ],
        ),
      ),
    );
  }
}