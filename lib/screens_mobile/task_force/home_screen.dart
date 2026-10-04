import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../constants/app_colors.dart';
import '../../controllers/location_sharing_controller.dart';
import '../../services/location_tracking_service.dart';
import '../../widgets/themed_map_layers.dart';

// NOTE: the long explanatory header comment from the previous version
// was condensed to keep this file manageable. All behaviour is unchanged
// except for the LOCATION SHARING change below.
//
// SCHEMA ASSUMPTIONS: `task_force_dispatches` (incident_id, camera_id,
// team_lead_id, member_ids jsonb, status, dispatched_at,
// source_tanod_dispatch_id, taskforce_request_id), `incidents`
// (alert_type, alert_level, image_path, occurred_at, status), `cameras`
// (name, location, latitude, longitude), `incident_reports`
// (incident_id, source_type, source_id, reported_by, report_text,
// report_sections jsonb, outcome, photo_paths jsonb, submitted_at,
// status), `live_gps` (member_id pk, latitude, longitude, updated_at,
// full_name, role, is_sharing), `app_settings` (key, value jsonb).
//
// TASK FORCE BACKUP: when `source_tanod_dispatch_id` is set, this
// dispatch backs up a tanod team. On SUBMIT REPORT the original tanod
// dispatch, its dispatch_requests row and the taskforce_requests row
// are all flipped to 'completed'. The roster also lists the tanod team
// under "TANOD TEAM" (needs SELECT RLS on `tanod_dispatches` and those
// members' `profiles`).
//
// REPORT STRUCTURE: `report_text` holds only the free-text narrative;
// structured answers go in `report_sections` (list of {header, value} or
// {header, items}). `photo_paths` holds Storage paths in the
// `incident_report` bucket under `reports/{dispatch_id}/...`.
//
// REPORT OWNERSHIP: only `team_lead_id == _userId` sees SUBMIT REPORT;
// double-taps are guarded by `_submittingDispatchIds`. UI-only — add an
// RLS check on `incident_reports` if you need real enforcement.
//
// RESPONSIVE SHEET / ROSTER: the mid snap size is computed from screen
// height + safe-area inset; the roster is only built while the sheet is
// dragged open, driven by a ValueNotifier (NOT setState / a persistent
// controller — both broke the drag gesture).
//
// EMERGENCY CALL: Fire Dept / Ambulance direct-dial buttons, numbers from
// `app_settings` (key = 'emergency_contacts', {"fire": "...",
// "ambulance": "..."}), live via a realtime stream.
//
// LOCATION SHARING (CHANGED): this screen no longer tracks or uploads
// GPS itself. That is done app-wide by `LocationTrackingService`
// (services/location_tracking_service.dart), which:
//   - starts on login and stops on logout,
//   - keeps running on every tab and while the app is in the background,
//   - is turned on/off by the Profile-tab switch
//     (`LocationSharingController`) and writes `live_gps.is_sharing`.
// This screen only DISPLAYS the position published by the service
// (`LocationTrackingService.instance.position`) and reads the switch to
// show "location off" states. `isActive` is kept in the constructor so
// AuthGate doesn't need to change, but it is no longer used for tracking.
//   - DATABASE: `alter table live_gps add column is_sharing boolean not
//     null default true;` plus RLS letting a user UPSERT/UPDATE/DELETE
//     their own row (member_id = auth.uid()).
//   - Whatever screen shows task force pins (e.g. desktop CCTV Manager)
//     must read `is_sharing` to show a "location off" state.
//
// MAP THEME: the basemap uses `ThemedMapLayers`
// (widgets/themed_map_layers.dart) — the same softened light / duotone
// dark tiles and barangay boundary mask (outside area dimmed, boundary
// outlined in blue) as the Purok Leader live map. Boundary comes from
// `BarangayBoundary.points`; if it's empty, only the themed tiles show.
//
// Add to pubspec.yaml if not already present:
//   flutter_map: ^7.0.0, latlong2: ^0.9.1, geolocator: ^13.0.0,
//   url_launcher: ^6.3.0, http: ^1.2.0, image_picker: ^1.1.2
// iOS: NSCameraUsageDescription / NSPhotoLibraryUsageDescription.
// Routing uses the public OSRM demo server (rate-limited) — swap for a
// self-hosted/paid router in production.

/// One row from `task_force_dispatches`, scoped to dispatches the
/// signed-in Task Force member is part of.
class _ActiveDispatch {
  final String id;
  final String incidentId;
  final String cameraId;
  final String? teamLeadId;
  final List<String> memberIds;
  final String status;
  final DateTime dispatchedAt;
  // TASK FORCE BACKUP: set when this dispatch exists to back up a
  // tanod team already on scene. Null for a normal, direct dispatch.
  final String? sourceTanodDispatchId;
  // TASK FORCE BACKUP: the `taskforce_requests` row this dispatch was
  // created to answer. Closed out on SUBMIT REPORT.
  final String? taskforceRequestId;

  _ActiveDispatch({
    required this.id,
    required this.incidentId,
    required this.cameraId,
    required this.teamLeadId,
    required this.memberIds,
    required this.status,
    required this.dispatchedAt,
    required this.sourceTanodDispatchId,
    required this.taskforceRequestId,
  });

  factory _ActiveDispatch.fromMap(Map<String, dynamic> row) {
    return _ActiveDispatch(
      id: row['id'].toString(),
      incidentId: row['incident_id'].toString(),
      cameraId: row['camera_id'].toString(),
      teamLeadId: row['team_lead_id']?.toString(),
      memberIds: ((row['member_ids'] as List?) ?? [])
          .map((e) => e.toString())
          .toList(),
      status: (row['status'] ?? 'dispatched').toString(),
      dispatchedAt: DateTime.tryParse(row['dispatched_at']?.toString() ?? '') ??
          DateTime.now(),
      sourceTanodDispatchId: row['source_tanod_dispatch_id']?.toString(),
      taskforceRequestId: row['taskforce_request_id']?.toString(),
    );
  }
}

class _IncidentInfo {
  final String alertType;
  final String alertLevel;
  final String imagePath;
  final DateTime occurredAt;

  _IncidentInfo({
    required this.alertType,
    required this.alertLevel,
    required this.imagePath,
    required this.occurredAt,
  });

  factory _IncidentInfo.fromMap(Map<String, dynamic> row) => _IncidentInfo(
        alertType: (row['alert_type'] ?? '').toString(),
        alertLevel: (row['alert_level'] ?? '').toString(),
        imagePath: (row['image_path'] ?? '').toString(),
        occurredAt:
            DateTime.tryParse(row['occurred_at']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
      );

  String get imageUrl =>
      Supabase.instance.client.storage.from('incidents').getPublicUrl(imagePath);
}

class _CameraInfo {
  final String name;
  final String? location;
  final double? latitude;
  final double? longitude;

  _CameraInfo({
    required this.name,
    required this.location,
    required this.latitude,
    required this.longitude,
  });

  factory _CameraInfo.fromMap(Map<String, dynamic> row) => _CameraInfo(
        name: (row['name'] ?? 'Unknown camera').toString(),
        // Human-readable street/place, e.g. "Rizal St. corner Mabini Ave".
        location: (row['location'] as String?)?.trim().isNotEmpty == true
            ? (row['location'] as String).trim()
            : null,
        latitude: (row['latitude'] as num?)?.toDouble(),
        longitude: (row['longitude'] as num?)?.toDouble(),
      );

  bool get hasLocation => latitude != null && longitude != null;

  /// Street/place if we have one, falling back to the camera's own
  /// name/id. The camera's internal name is never shown as a separate
  /// label in the UI.
  String get displayLocation => location ?? name;
}

/// A single assigned member's profile, resolved from `profiles` for
/// display in the dispatch panel's team roster.
class _MemberProfile {
  final String id;
  final String fullName;
  final String role;

  _MemberProfile({required this.id, required this.fullName, required this.role});

  factory _MemberProfile.fromMap(Map<String, dynamic> row) {
    final first = (row['first_name'] ?? '').toString().trim();
    final last = (row['last_name'] ?? '').toString().trim();
    final name = '$first $last'.trim();
    return _MemberProfile(
      id: row['id'].toString(),
      fullName: name.isEmpty ? 'Unnamed member' : name,
      role: (row['role'] ?? '').toString().trim(),
    );
  }

  String get initials {
    final parts = fullName.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}

class _DispatchDetails {
  final _ActiveDispatch dispatch;
  final _IncidentInfo incident;
  final _CameraInfo camera;

  _DispatchDetails({required this.dispatch, required this.incident, required this.camera});
}

/// Result of a road-routing lookup: path geometry plus road distance
/// and travel time.
class _RouteResult {
  final List<ll.LatLng> points;
  final double distanceKm;
  final double durationMin;

  const _RouteResult({required this.points, required this.distanceKm, required this.durationMin});
}

/// Thin wrapper around the public OSRM demo routing API.
class _RoutingService {
  static Future<_RouteResult?> fetchRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    try {
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$fromLng,$fromLat;$toLng,$toLat'
        '?overview=full&geometries=geojson',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;

      final route = routes.first as Map<String, dynamic>;
      final coords = (route['geometry']['coordinates'] as List).cast<List>();
      final points = coords
          .map((c) => ll.LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();

      return _RouteResult(
        points: points,
        distanceKm: (route['distance'] as num).toDouble() / 1000,
        durationMin: (route['duration'] as num).toDouble() / 60,
      );
    } catch (_) {
      return null;
    }
  }
}

class TaskForceHomeScreen extends StatefulWidget {
  /// Kept so AuthGate doesn't need to change. No longer used for location
  /// tracking — that's app-wide now (see LocationTrackingService).
  final bool isActive;

  const TaskForceHomeScreen({super.key, required this.isActive});

  @override
  State<TaskForceHomeScreen> createState() => _TaskForceHomeScreenState();
}

class _TaskForceHomeScreenState extends State<TaskForceHomeScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  late final Stream<List<Map<String, dynamic>>> _dispatchStream;
  StreamSubscription<List<Map<String, dynamic>>>? _dispatchSub;

  // Position comes from LocationTrackingService (or a one-off local fix
  // when sharing is off and the service has nothing to show).
  ll.LatLng? _myPosition;

  final MapController _mapController = MapController();
  bool _mapReady = false;

  // Whether the bottom sheet is dragged open past its mid size. A
  // ValueNotifier (not setState) on purpose — see header note.
  final ValueNotifier<bool> _sheetExpandedNotifier = ValueNotifier(false);

  List<_ActiveDispatch> _activeDispatches = [];
  _DispatchDetails? _details;
  bool _loadingDetails = false;

  List<_MemberProfile> _teamMembers = [];
  bool _loadingTeam = false;

  // TASK FORCE BACKUP: the original tanod team you're backing up.
  List<_MemberProfile> _tanodMembers = [];
  bool _loadingTanodTeam = false;
  String? _loadedTanodDispatchId;

  _RouteResult? _route;
  bool _loadingRoute = false;
  String? _routeOriginKey;

  final Set<String> _submittingDispatchIds = {};

  // EMERGENCY CALL: admin-configurable fire/ambulance numbers.
  Map<String, String> _emergencyNumbers = {};
  StreamSubscription<List<Map<String, dynamic>>>? _emergencyContactsSub;

  static const double _kDispatchPanelContentHeight = 250;
  static const double _kMinMidFraction = 0.20;
  static const double _kMaxMidFraction = 0.46;

  String get _userId => _supabase.auth.currentUser?.id ?? '';

  // LOCATION SHARING: current value of the Profile-tab switch (display only).
  bool get _sharing => LocationSharingController.instance.value;

  @override
  void initState() {
    super.initState();
    _dispatchStream = _supabase
        .from('task_force_dispatches')
        .stream(primaryKey: ['id'])
        .order('dispatched_at', ascending: false);
    _dispatchSub = _dispatchStream.listen(_handleDispatchRows);

    _emergencyContactsSub = _supabase
        .from('app_settings')
        .stream(primaryKey: ['key'])
        .eq('key', 'emergency_contacts')
        .listen(_handleEmergencyContactsRows);

    // LOCATION SHARING: follow the app-wide service + the Profile switch.
    LocationTrackingService.instance.position.addListener(_onPositionChanged);
    LocationSharingController.instance.addListener(_rebuild);
    _myPosition = LocationTrackingService.instance.position.value;
    _ensureLocalFix();
  }

  // Rebuild status pill / standing-by text when the switch flips.
  void _rebuild() {
    if (mounted) setState(() {});
  }

  // Position published by LocationTrackingService (runs app-wide).
  void _onPositionChanged() {
    final p = LocationTrackingService.instance.position.value;
    if (!mounted || p == null) return;
    final first = _myPosition == null;
    setState(() => _myPosition = p);
    // Only auto-follow while nothing is actively dispatched.
    if (_details == null) {
      _fitMap(animate: !first);
    } else {
      _fetchRouteIfNeeded();
    }
  }

  // If sharing is off (or the service hasn't got a fix yet) the map would
  // spin forever. Take a single LOCAL fix just to draw the map — this
  // never uploads anything.
  Future<void> _ensureLocalFix() async {
    if (_myPosition != null) return;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted || _myPosition != null) return;
      setState(() => _myPosition = ll.LatLng(pos.latitude, pos.longitude));
      _fitMap(animate: false);
    } catch (_) {
      // The service's stream will fill this in once a fix comes through.
    }
  }

  // EMERGENCY CALL: `value` is jsonb -> Map, but guard for a raw string.
  void _handleEmergencyContactsRows(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return;
    final raw = rows.first['value'];
    Map<String, dynamic> value;
    if (raw is Map<String, dynamic>) {
      value = raw;
    } else if (raw is String && raw.isNotEmpty) {
      try {
        value = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        value = {};
      }
    } else {
      value = {};
    }
    if (!mounted) return;
    setState(() {
      _emergencyNumbers = value.map((k, v) => MapEntry(k, (v ?? '').toString()));
    });
  }

  @override
  void dispose() {
    LocationTrackingService.instance.position.removeListener(_onPositionChanged);
    LocationSharingController.instance.removeListener(_rebuild);
    _sheetExpandedNotifier.dispose();
    _dispatchSub?.cancel();
    _emergencyContactsSub?.cancel();
    super.dispose();
  }

  // --- DISPATCH DATA -----------------------------------------------

  void _handleDispatchRows(List<Map<String, dynamic>> rows) {
    final mine = rows
        .map((r) => _ActiveDispatch.fromMap(r))
        .where((d) => d.memberIds.contains(_userId))
        .toList()
      ..sort((a, b) => b.dispatchedAt.compareTo(a.dispatchedAt));
    final active = mine.where((d) => d.status != 'completed').toList();

    if (!mounted) return;
    setState(() => _activeDispatches = active);

    final top = active.isEmpty ? null : active.first;

    if (top == null) {
      if (_details != null) {
        setState(() {
          _details = null;
          _route = null;
          _routeOriginKey = null;
          _teamMembers = [];
          _tanodMembers = [];
          _loadedTanodDispatchId = null;
        });
      }
      _fitMap(animate: true);
      return;
    }

    if (_details == null || _details!.dispatch.id != top.id) {
      _loadDetailsFor(top);
    } else if (_details!.dispatch.status != top.status) {
      // Same dispatch, status moved on — patch it in without re-fetching.
      setState(() {
        _details = _DispatchDetails(
          dispatch: top,
          incident: _details!.incident,
          camera: _details!.camera,
        );
      });
    }
  }

  // Dispatch ids that already failed to load, so a permanently blocked
  // row (e.g. RLS) doesn't re-trigger a snackbar every realtime tick.
  final Set<String> _failedDispatchIds = {};

  Future<void> _loadDetailsFor(_ActiveDispatch dispatch) async {
    if (_failedDispatchIds.contains(dispatch.id)) return;
    setState(() => _loadingDetails = true);
    try {
      final incidentRow = await _supabase
          .from('incidents')
          .select()
          .eq('id', dispatch.incidentId)
          .maybeSingle();
      if (incidentRow == null) {
        throw StateError(
            "Incident not found or you don't have access to it (check RLS policies on `incidents`).");
      }

      final cameraRow = await _supabase
          .from('cameras')
          .select()
          .eq('id', dispatch.cameraId)
          .maybeSingle();
      if (cameraRow == null) {
        throw StateError(
            "Camera not found or you don't have access to it (check RLS policies on `cameras`).");
      }

      if (!mounted) return;
      setState(() {
        _details = _DispatchDetails(
          dispatch: dispatch,
          incident: _IncidentInfo.fromMap(incidentRow),
          camera: _CameraInfo.fromMap(cameraRow),
        );
        _loadingDetails = false;
      });
      _loadTeamMembers(dispatch);
      _loadTanodTeam(dispatch);
      _fitMap(animate: true);
      // Directions only appear once the responder tapped ON MY WAY —
      // unless the app was reopened mid-response.
      if (dispatch.status != 'dispatched') {
        _fetchRouteIfNeeded(force: true);
      }
    } catch (e) {
      if (!mounted) return;
      _failedDispatchIds.add(dispatch.id);
      setState(() => _loadingDetails = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load dispatch details: $e')),
      );
    }
  }

  /// Loads name/role for every member of this dispatch (lead first,
  /// then alphabetical). Non-fatal on failure.
  Future<void> _loadTeamMembers(_ActiveDispatch dispatch) async {
    if (dispatch.memberIds.isEmpty) {
      if (mounted) setState(() => _teamMembers = []);
      return;
    }
    if (mounted) setState(() => _loadingTeam = true);
    try {
      final rows = await _supabase
          .from('profiles')
          .select('id, first_name, last_name, role')
          .inFilter('id', dispatch.memberIds);

      final members = (rows as List)
          .map((r) => _MemberProfile.fromMap(r as Map<String, dynamic>))
          .toList()
        ..sort((a, b) {
          final aLead = a.id == dispatch.teamLeadId;
          final bLead = b.id == dispatch.teamLeadId;
          if (aLead == bLead) return a.fullName.compareTo(b.fullName);
          return aLead ? -1 : 1; // lead always first
        });

      if (!mounted) return;
      setState(() {
        _teamMembers = members;
        _loadingTeam = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTeam = false);
    }
  }

  /// TASK FORCE BACKUP: when this dispatch backs up a tanod team
  /// (`sourceTanodDispatchId` set), resolve that tanod dispatch's
  /// members for the "TANOD TEAM" roster group. No lead is tracked for
  /// this group — the task force lead is the dispatch leader now.
  Future<void> _loadTanodTeam(_ActiveDispatch dispatch) async {
    final tanodId = dispatch.sourceTanodDispatchId;

    if (tanodId == null) {
      _loadedTanodDispatchId = null;
      if (mounted && (_tanodMembers.isNotEmpty || _loadingTanodTeam)) {
        setState(() {
          _tanodMembers = [];
          _loadingTanodTeam = false;
        });
      }
      return;
    }

    if (tanodId == _loadedTanodDispatchId) return;
    _loadedTanodDispatchId = tanodId;
    if (mounted) setState(() => _loadingTanodTeam = true);

    try {
      final tanodRow = await _supabase
          .from('tanod_dispatches')
          .select('team_lead_id, member_ids')
          .eq('id', tanodId)
          .maybeSingle();
      if (tanodRow == null) {
        throw StateError(
            "Tanod dispatch not found or you don't have access to it (check RLS policies on `tanod_dispatches`).");
      }

      // The (former) lead id is only used to make sure they're included.
      final leadId = tanodRow['team_lead_id']?.toString();
      final memberIds = ((tanodRow['member_ids'] as List?) ?? [])
          .map((e) => e.toString())
          .toList();
      if (leadId != null && !memberIds.contains(leadId)) memberIds.add(leadId);

      var members = <_MemberProfile>[];
      if (memberIds.isNotEmpty) {
        final rows = await _supabase
            .from('profiles')
            .select('id, first_name, last_name, role')
            .inFilter('id', memberIds);
        members = (rows as List)
            .map((r) => _MemberProfile.fromMap(r as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.fullName.compareTo(b.fullName));
      }

      // Ignore stale results if the dispatch changed while loading.
      if (!mounted || _loadedTanodDispatchId != tanodId) return;
      setState(() {
        _tanodMembers = members;
        _loadingTanodTeam = false;
      });
    } catch (_) {
      if (!mounted) return;
      // Allow a retry on the next dispatch update.
      _loadedTanodDispatchId = null;
      setState(() => _loadingTanodTeam = false);
    }
  }

  /// Fetches (or refreshes) the road route to the assigned camera,
  /// throttled to roughly a 100m grid unless `force` is set.
  Future<void> _fetchRouteIfNeeded({bool force = false}) async {
    final camera = _details?.camera;
    final pos = _myPosition;
    if (camera == null || !camera.hasLocation || pos == null) return;

    final originKey = '${pos.latitude.toStringAsFixed(3)},${pos.longitude.toStringAsFixed(3)}';
    if (!force && originKey == _routeOriginKey) return;
    _routeOriginKey = originKey;

    if (mounted) setState(() => _loadingRoute = true);
    final result = await _RoutingService.fetchRoute(
      fromLat: pos.latitude,
      fromLng: pos.longitude,
      toLat: camera.latitude!,
      toLng: camera.longitude!,
    );
    if (!mounted) return;
    setState(() {
      _route = result;
      _loadingRoute = false;
    });
    _fitMap(animate: true);
  }

  // --- MAP CAMERA CONTROL --------------------------------------------

  void _onMapReady() {
    _mapReady = true;
    _fitMap(animate: false);
  }

  void _fitMap({required bool animate}) {
    if (!_mapReady) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      final camera = _details?.camera;
      if (camera != null && camera.hasLocation && _myPosition != null) {
        final points = [
          _myPosition!,
          ll.LatLng(camera.latitude!, camera.longitude!),
          if (_route != null) ..._route!.points,
        ];
        final bounds = LatLngBounds.fromPoints(points);
        _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.fromLTRB(48, 120, 48, 260)),
        );
      } else if (_myPosition != null) {
        _mapController.move(_myPosition!, 16);
      }
    });
  }

  Future<void> _updateStatus(String dispatchId, String status) async {
    try {
      await _supabase
          .from('task_force_dispatches')
          .update({'status': status}).eq('id', dispatchId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to update status: $e')));
    }
  }

  // EMERGENCY CALL: opens the phone dialer. Never hardcodes a number.
  Future<void> _callNumber(String label, String? number) async {
    if (number == null || number.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$label number isn\'t configured yet — ask your admin to set it up.'),
        ),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: number.trim());
    try {
      final launched = await launchUrl(uri);
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start a call to $label')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start a call to $label: $e')),
      );
    }
  }

  Future<void> _submitReport(_DispatchDetails details) async {
    final dispatchId = details.dispatch.id;

    // Double-tap / in-flight guard (source of truth; the button is also
    // visually disabled while submitting).
    if (_submittingDispatchIds.contains(dispatchId)) return;

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReportSheet(incidentType: details.incident.alertType),
    );
    if (result == null) return;

    if (!mounted) return;
    setState(() => _submittingDispatchIds.add(dispatchId));

    // Blocking indicator while photos upload on a weak signal.
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => Center(
          child: CircularProgressIndicator(color: AppColors.accentBlue),
        ),
      );
    }

    try {
      final images = (result['images'] as List<XFile>?) ?? [];
      final photoPaths = <String>[];
      for (var i = 0; i < images.length; i++) {
        final bytes = await images[i].readAsBytes();
        final ext = images[i].name.contains('.') ? images[i].name.split('.').last : 'jpg';
        final path =
            'reports/$dispatchId/${DateTime.now().millisecondsSinceEpoch}_$i.$ext';
        await _supabase.storage.from('incident_report').uploadBinary(
              path,
              bytes,
              fileOptions: const FileOptions(upsert: true),
            );
        photoPaths.add(path);
      }

      await _supabase.from('incident_reports').insert({
        'incident_id': details.dispatch.incidentId,
        'source_type': 'task_force',
        'source_id': dispatchId,
        'reported_by': _userId,
        'report_text': result['report_text'],
        'report_sections': result['report_sections'],
        'outcome': result['outcome'],
        'photo_paths': photoPaths,
        'status': 'submitted',
        'submitted_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _updateStatus(dispatchId, 'completed');
      await _supabase
          .from('incidents')
          .update({'status': 'resolved'}).eq('id', details.dispatch.incidentId);

      // TASK FORCE BACKUP: submitting the report also closes out the
      // tanod dispatch being backed up (the actual handoff), and its
      // originating dispatch_requests row — that's what the Purok
      // Leader's Pending/Active/For Review tabs filter on.
      final sourceTanodDispatchId = details.dispatch.sourceTanodDispatchId;
      if (sourceTanodDispatchId != null) {
        final tanodRow = await _supabase
            .from('tanod_dispatches')
            .update({'status': 'completed'})
            .eq('id', sourceTanodDispatchId)
            .select('dispatch_request_id')
            .maybeSingle();

        final dispatchRequestId = tanodRow?['dispatch_request_id']?.toString();
        if (dispatchRequestId != null) {
          await _supabase
              .from('dispatch_requests')
              .update({'status': 'completed'})
              .eq('id', dispatchRequestId);
        }
      }

      // TASK FORCE BACKUP: also close out the `taskforce_requests` row
      // this dispatch answers — scoped to this dispatch's own request id.
      final taskforceRequestId = details.dispatch.taskforceRequestId;
      if (taskforceRequestId != null) {
        await _supabase.from('taskforce_requests').update({
          'status': 'completed',
          'resolved_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', taskforceRequestId);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // dismiss the spinner
      setState(() => _submittingDispatchIds.remove(dispatchId));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to submit report: $e')));
      return;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // dismiss the spinner
    setState(() => _submittingDispatchIds.remove(dispatchId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: const Text('Report submitted'), backgroundColor: AppColors.accentGreen),
    );
  }

  ({String label, Color color, IconData icon}) _statusMeta(String status) {
    switch (status) {
      case 'dispatched':
        return (label: 'DISPATCHED', color: AppColors.accentRed, icon: Icons.notifications_active);
      case 'en_route':
        return (label: 'EN ROUTE', color: AppColors.accentBlue, icon: Icons.directions_run);
      default:
        return (
          label: status.toUpperCase(),
          color: AppColors.textMuted(context),
          icon: Icons.info_outline
        );
    }
  }

  /// Formats travel minutes as "under a minute", "N min", or "H hr M min".
  String _durationLabel(double minutes) {
    final total = minutes.round();
    if (total < 1) return 'under a minute';
    if (total < 60) return '$total min';
    final hours = total ~/ 60;
    final mins = total % 60;
    return mins == 0 ? '$hours hr' : '$hours hr $mins min';
  }

  double _straightLineKm(ll.LatLng a, ll.LatLng b) {
    const earthRadiusKm = 6371.0;
    double degToRad(double d) => d * (math.pi / 180);
    final dLat = degToRad(b.latitude - a.latitude);
    final dLng = degToRad(b.longitude - a.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(degToRad(a.latitude)) *
            math.cos(degToRad(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return earthRadiusKm * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  /// Mid snap fraction for the draggable sheet, from real screen height
  /// and the safe-area bottom inset instead of a hardcoded percentage.
  double _midSheetFraction(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenHeight = mq.size.height;
    if (screenHeight <= 0) return _kMinMidFraction;
    final target = _kDispatchPanelContentHeight + mq.padding.bottom;
    final fraction = target / screenHeight;
    return fraction.clamp(_kMinMidFraction, _kMaxMidFraction);
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    final camera = details?.camera;
    final hasRoute = camera != null && camera.hasLocation && _myPosition != null;

    final bottomSafeInset = MediaQuery.of(context).padding.bottom;
    final midFraction = _midSheetFraction(context);
    final standByFraction =
        ((90 + bottomSafeInset) / MediaQuery.of(context).size.height)
            .clamp(0.12, midFraction);

    return Container(
      color: AppColors.bg(context),
      child: Stack(
        children: [
          // --- FULL-SCREEN LIVE MAP ---
          Positioned.fill(
            child: _myPosition == null
                ? Center(child: CircularProgressIndicator(color: AppColors.accentBlue))
                : FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _myPosition!,
                      initialZoom: 16,
                      minZoom: 13,
                      maxZoom: 19,
                      onMapReady: _onMapReady,
                    ),
                    children: [
                      // MAP THEME: light/dark aware basemap.
                      ThemedMapLayers.tileLayer(
                        context,
                        userAgentPackageName: 'com.barangay.task_force',
                      ),
                      // MAP THEME: barangay boundary (outside dimmed).
                      if (ThemedMapLayers.hasBoundary)
                        ThemedMapLayers.boundaryLayer(context),
                      if (hasRoute)
                        PolylineLayer(polylines: [
                          if (_route != null)
                            // Real road-following route.
                            Polyline(
                              points: _route!.points,
                              color: AppColors.accentBlue.withOpacity(0.85),
                              strokeWidth: 4,
                            )
                          else
                            // Loading / lookup failed — straight dotted fallback.
                            Polyline(
                              points: [
                                _myPosition!,
                                ll.LatLng(camera!.latitude!, camera.longitude!),
                              ],
                              color: AppColors.accentBlue.withOpacity(0.5),
                              strokeWidth: 3,
                              pattern: const StrokePattern.dotted(),
                            ),
                        ]),
                      MarkerLayer(markers: [
                        // The assigned camera — the ONLY camera this
                        // screen ever plots.
                        if (camera != null && camera.hasLocation)
                          Marker(
                            point: ll.LatLng(camera.latitude!, camera.longitude!),
                            width: 40,
                            height: 40,
                            child: _Pin(icon: Icons.videocam, color: AppColors.accentRed),
                          ),
                        // Your own live position — pulsing dot.
                        Marker(
                          point: _myPosition!,
                          width: 60,
                          height: 60,
                          child: _LiveLocationMarker(color: AppColors.accentBlue),
                        ),
                      ]),
                    ],
                  ),
          ),

          // --- TOP STATUS PILL ---
          Positioned(
            top: 14,
            left: 16,
            right: 16,
            child: SafeArea(
              bottom: false,
              child: _TopStatusPill(
                hasActive: details != null,
                statusMeta: details == null ? null : _statusMeta(details.dispatch.status),
                extraCount: _activeDispatches.length > 1 ? _activeDispatches.length - 1 : 0,
                sharing: _sharing,
              ),
            ),
          ),

          // --- RECENTER BUTTON ---
          Positioned(
            right: 16,
            bottom: MediaQuery.of(context).size.height * 0.30,
            child: FloatingActionButton.small(
              heroTag: 'recenter',
              backgroundColor: AppColors.card(context),
              foregroundColor: AppColors.accentBlue,
              onPressed: () => _fitMap(animate: true),
              child: const Icon(Icons.my_location),
            ),
          ),

          // --- BOTTOM SHEET ---
          // NotificationListener instead of a DraggableScrollableController
          // (a controller left the drag gesture stuck after one cycle).
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (notification) {
              final midFraction = _midSheetFraction(context);
              final expanded = notification.extent > midFraction + 0.02;
              // Direct assignment — NOT setState() (fires every drag frame).
              if (_sheetExpandedNotifier.value != expanded) {
                _sheetExpandedNotifier.value = expanded;
              }
              return false;
            },
            child: DraggableScrollableSheet(
              initialChildSize: details == null ? standByFraction : midFraction,
              minChildSize: standByFraction,
              maxChildSize: 0.82,
              snap: true,
              snapSizes: [standByFraction, midFraction, 0.82],
              builder: (context, scrollController) {
                return Container(
                  decoration: BoxDecoration(
                    color: AppColors.card(context),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    border: Border(
                      top: BorderSide(color: AppColors.border(context)),
                      left: BorderSide(color: AppColors.border(context)),
                      right: BorderSide(color: AppColors.border(context)),
                    ),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 20),
                    ],
                  ),
                  child: ListView(
                    controller: scrollController,
                    // Includes the safe-area inset so content never sits
                    // under the gesture bar.
                    padding: EdgeInsets.fromLTRB(18, 10, 18, 24 + bottomSafeInset),
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: AppColors.border(context),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      if (_loadingDetails)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: CircularProgressIndicator(color: AppColors.accentBlue),
                          ),
                        )
                      else if (details == null)
                        _standingByPanel()
                      else
                        _dispatchPanel(details),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _standingByPanel() {
    final sharing = _sharing;
    final color = sharing ? AppColors.accentGreen : AppColors.textMuted(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(sharing ? Icons.shield_outlined : Icons.location_off,
                  color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Standing by',
                      style: TextStyle(
                          color: AppColors.textMain(context),
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                      sharing
                          ? 'No active dispatch — your location is being tracked live.'
                          : 'No active dispatch — location sharing is off.',
                      style: TextStyle(
                          color: AppColors.textMuted(context), fontSize: 12, height: 1.3)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _dispatchPanel(_DispatchDetails details) {
    final meta = _statusMeta(details.dispatch.status);
    final isLead = details.dispatch.teamLeadId == _userId;
    final timeLabel = DateFormat('MMM d • h:mm a').format(details.dispatch.dispatchedAt);
    final camera = details.camera;
    final distanceLabel = _route != null
        ? '${_route!.distanceKm.toStringAsFixed(1)} km • ${_durationLabel(_route!.durationMin)} by road'
        : (_loadingRoute
            ? 'Calculating fastest route…'
            : (camera.hasLocation && _myPosition != null
                ? '${_straightLineKm(_myPosition!, ll.LatLng(camera.latitude!, camera.longitude!)).toStringAsFixed(1)} km away (straight line)'
                : null));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(meta.icon, color: meta.color, size: 20),
            const SizedBox(width: 8),
            Text(meta.label,
                style: TextStyle(color: meta.color, fontSize: 13, fontWeight: FontWeight.w800)),
            if (isLead) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accentRed.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('YOU ARE LEAD',
                    style: TextStyle(
                        color: AppColors.accentRed, fontSize: 9.5, fontWeight: FontWeight.w800)),
              ),
            ],
            const Spacer(),
            Text(timeLabel, style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
          ],
        ),
        // TASK FORCE BACKUP: shown when this dispatch backs up a tanod
        // team already on scene.
        if (details.dispatch.sourceTanodDispatchId != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.accentBlue.withOpacity(0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 15, color: AppColors.accentBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Backing up a tanod team already on scene — you will file the final report.',
                    style: TextStyle(
                        color: AppColors.accentBlue, fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text(details.incident.alertType.toUpperCase(),
            style: TextStyle(
                color: AppColors.textMain(context), fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 3),
        // Street/place the camera is at — the camera's own name/id is
        // intentionally not shown here.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.place_outlined, size: 14, color: AppColors.textMuted(context)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(camera.displayLocation,
                  style: TextStyle(
                      color: AppColors.textMain(context), fontSize: 13, height: 1.25)),
            ),
          ],
        ),
        if (distanceLabel != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.social_distance, size: 13, color: AppColors.textMuted(context)),
              const SizedBox(width: 5),
              Text(distanceLabel,
                  style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _actionButton(details, isLead: isLead),
        const SizedBox(height: 16),

        Divider(height: 1, color: AppColors.border(context)),
        const SizedBox(height: 14),

        // EMERGENCY CALL: available to everyone on the dispatch.
        Text('EMERGENCY CONTACTS',
            style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6)),
        const SizedBox(height: 10),
        _emergencyCallRow(),

        // Own ValueListenableBuilder so a drag only rebuilds the roster.
        ValueListenableBuilder<bool>(
          valueListenable: _sheetExpandedNotifier,
          builder: (context, expanded, _) =>
              expanded ? _teamSection(details) : const SizedBox.shrink(),
        ),
      ],
    );
  }

  // EMERGENCY CALL: direct-dial row for Fire Dept / Ambulance.
  Widget _emergencyCallRow() {
    return Row(
      children: [
        Expanded(
          child: _emergencyCallButton(
            icon: Icons.local_fire_department_outlined,
            label: 'FIRE DEPT',
            color: AppColors.accentRed,
            onTap: () => _callNumber('Fire Department', _emergencyNumbers['fire']),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _emergencyCallButton(
            icon: Icons.local_hospital_outlined,
            label: 'AMBULANCE',
            color: AppColors.accentBlue,
            onTap: () => _callNumber('Ambulance', _emergencyNumbers['ambulance']),
          ),
        ),
      ],
    );
  }

  Widget _emergencyCallButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppColors.sunken(context),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 15, color: color),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text('CALL $label',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: color,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Team roster shown below the action button: a "TEAM" group (lead
  /// first, badged), plus a "TANOD TEAM" group when backing up a tanod
  /// team. Only built while the sheet is dragged open.
  Widget _teamSection(_DispatchDetails details) {
    final backingUpTanod = details.dispatch.sourceTanodDispatchId != null;
    final groups = <Widget>[];

    if (_loadingTeam) {
      groups.add(_teamLoadingRow('Loading team…'));
    } else if (_teamMembers.isNotEmpty) {
      groups.add(_teamGroup(
        backingUpTanod ? 'TASK FORCE' : 'TEAM',
        _teamMembers,
        details.dispatch.teamLeadId,
      ));
    }

    // No lead id here on purpose — see `_loadTanodTeam`.
    if (backingUpTanod) {
      if (_loadingTanodTeam) {
        groups.add(_teamLoadingRow('Loading tanod team…'));
      } else if (_tanodMembers.isNotEmpty) {
        groups.add(_teamGroup('TANOD TEAM', _tanodMembers, null));
      }
    }

    if (groups.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            groups[i],
          ],
        ],
      ),
    );
  }

  Widget _teamLoadingRow(String label) {
    return Row(
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accentBlue),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
      ],
    );
  }

  Widget _teamGroup(String title, List<_MemberProfile> members, String? leadId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
        const SizedBox(height: 10),
        for (final member in members) _teamMemberRow(member, leadId),
      ],
    );
  }

  Widget _teamMemberRow(_MemberProfile member, String? teamLeadId) {
    final isLead = member.id == teamLeadId;
    final isMe = member.id == _userId;
    final accent = isLead ? AppColors.accentRed : AppColors.accentBlue;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: accent.withOpacity(0.15), shape: BoxShape.circle),
            child: Center(
              child: Text(member.initials,
                  style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    isMe ? '${member.fullName} (You)' : member.fullName,
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (member.role.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('· ${member.role}',
                        style: TextStyle(color: AppColors.textMuted(context), fontSize: 11.5),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ],
            ),
          ),
          if (isLead) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accentRed.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star, size: 10, color: AppColors.accentRed),
                  const SizedBox(width: 3),
                  Text('LEAD',
                      style: TextStyle(
                          color: AppColors.accentRed, fontSize: 9, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Primary action for the current dispatch status. `isLead` gates the
  /// `en_route` -> SUBMIT REPORT step: only the team lead gets a
  /// tappable submit button (it flips shared status columns). Everyone
  /// else sees a passive "your lead will file this" card.
  Widget _actionButton(_DispatchDetails details, {required bool isLead}) {
    switch (details.dispatch.status) {
      case 'dispatched':
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () async {
              await _updateStatus(details.dispatch.id, 'en_route');
              await _fetchRouteIfNeeded(force: true);
            },
            icon: const Icon(Icons.directions_run, size: 18),
            label: const Text('ON MY WAY'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );

      case 'en_route':
        if (!isLead) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: AppColors.sunken(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border(context)),
            ),
            child: Row(
              children: [
                Icon(Icons.hourglass_top, size: 17, color: AppColors.textMuted(context)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your team lead will file the incident report.',
                    style: TextStyle(
                      color: AppColors.textMuted(context),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final isSubmitting = _submittingDispatchIds.contains(details.dispatch.id);
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            // Disabled while a submission is in flight.
            onPressed: isSubmitting ? null : () => _submitReport(details),
            icon: isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                  )
                : const Icon(Icons.description_outlined, size: 18),
            label: Text(isSubmitting ? 'SUBMITTING…' : 'SUBMIT REPORT'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentRed,
              disabledBackgroundColor: AppColors.accentRed.withOpacity(0.5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }
}

/// Small pill floating at the top of the map. Plain "standing by" when
/// there's no dispatch (grey "location sharing off" when the Profile
/// switch is off), or the active dispatch's status.
class _TopStatusPill extends StatelessWidget {
  final bool hasActive;
  final ({String label, Color color, IconData icon})? statusMeta;
  final int extraCount;
  final bool sharing;

  const _TopStatusPill({
    required this.hasActive,
    required this.statusMeta,
    required this.extraCount,
    this.sharing = true,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = statusMeta?.color ??
        (sharing ? AppColors.accentGreen : AppColors.textMuted(context));
    final IconData icon =
        statusMeta?.icon ?? (sharing ? Icons.gps_fixed : Icons.location_off);
    final String label = statusMeta?.label ??
        (sharing ? 'STANDING BY — LIVE LOCATION ON' : 'STANDING BY — LOCATION SHARING OFF');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card(context).withOpacity(0.94),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AppColors.border(context)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 10),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800)),
          ),
          if (extraCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.sunken(context),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('+$extraCount more',
                  style: TextStyle(
                      color: AppColors.textMain(context),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Life360-style pulsing dot for the responder's own live position.
class _LiveLocationMarker extends StatefulWidget {
  final Color color;
  const _LiveLocationMarker({required this.color});

  @override
  State<_LiveLocationMarker> createState() => _LiveLocationMarkerState();
}

class _LiveLocationMarkerState extends State<_LiveLocationMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
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
      builder: (context, _) {
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: (1 - t).clamp(0.0, 1.0),
              child: Container(
                width: 60 * t,
                height: 60 * t,
                decoration: BoxDecoration(
                  color: widget.color.withOpacity(0.35),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4)],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _Pin({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4)],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

/// Bottom-sheet incident report form: outcome, headcount, injuries, an
/// incident-type-specific block (curfew / accident / violence / fire),
/// photos, and a narrative. Pops the data back as a map; the caller
/// writes it into `incident_reports`.
class _ReportSheet extends StatefulWidget {
  final String incidentType;
  const _ReportSheet({required this.incidentType});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _narrativeController = TextEditingController();
  final _individualsController = TextEditingController();
  final _injuryDetailsController = TextEditingController();

  String _outcome = 'resolved';
  String _injuriesReported = 'no';
  // Curfew-specific
  final _curfewViolatorsController = TextEditingController();
  String _curfewAction = 'warned';

  // Accident-specific
  final _vehiclesInvolvedController = TextEditingController();
  String _hitAndRun = 'no';

  // Violence-specific
  String _weaponInvolved = 'no';
  final _suspectsApprehendedController = TextEditingController();

  // Fire-specific
  String _fireStatus = 'contained';
  final _structuresAffectedController = TextEditingController();
  String _fireDeptNotified = 'yes';

  // Photo / camera evidence — uploaded to Storage on submit.
  final ImagePicker _picker = ImagePicker();
  final List<XFile> _photos = [];
  static const int _maxPhotos = 6;

  // Keys must match the DB's `incident_reports_outcome_check` constraint
  // (see fix_outcome_constraint.sql). 'ongoing' is the DB's spelling.
  static const _outcomes = {
    'resolved': 'Resolved on scene',
    'escalated': 'Escalated to authorities',
    'ongoing': 'Ongoing — monitoring',
    'false_alarm': 'False alarm',
    'no_action_needed': 'No action needed',
  };

  static const _yesNo = {'yes': 'Yes', 'no': 'No'};

  static const _curfewActions = {
    'warned': 'Verbally warned',
    'cited': 'Cited / ticketed',
    'detained': 'Detained for processing',
    'released': 'Released to guardian',
  };

  static const _fireStatuses = {
    'contained': 'Contained',
    'spreading': 'Spreading',
    'extinguished': 'Extinguished',
  };

  /// Buckets the raw alert_type into one of four incident families;
  /// anything else gets a generic report with no extra section.
  String get _typeCategory {
    final t = widget.incidentType.toLowerCase();
    if (t.contains('curfew')) return 'curfew';
    if (t.contains('accident') || t.contains('collision') || t.contains('crash')) {
      return 'accident';
    }
    if (t.contains('violence') || t.contains('assault') || t.contains('fight')) {
      return 'violence';
    }
    if (t.contains('fire') || t.contains('blaze')) return 'fire';
    return 'general';
  }

  String get _typeSectionTitle {
    switch (_typeCategory) {
      case 'curfew':
        return 'Curfew Details';
      case 'accident':
        return 'Accident Details';
      case 'violence':
        return 'Incident Details';
      case 'fire':
        return 'Fire Details';
      default:
        return '';
    }
  }

  IconData get _typeSectionIcon {
    switch (_typeCategory) {
      case 'curfew':
        return Icons.nights_stay_outlined;
      case 'accident':
        return Icons.car_crash_outlined;
      case 'violence':
        return Icons.warning_amber_rounded;
      case 'fire':
        return Icons.local_fire_department_outlined;
      default:
        return Icons.info_outline;
    }
  }

  @override
  void dispose() {
    _narrativeController.dispose();
    _individualsController.dispose();
    _injuryDetailsController.dispose();
    _curfewViolatorsController.dispose();
    _vehiclesInvolvedController.dispose();
    _suspectsApprehendedController.dispose();
    _structuresAffectedController.dispose();
    super.dispose();
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );

  Widget _boxDropdown<T>({
    required T value,
    required Map<T, String> options,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.card(context),
          style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
          items: options.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _boxTextField(
    TextEditingController controller,
    String hint, {
    int maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      onChanged: onChanged,
      style: TextStyle(color: AppColors.textMain(context), fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textMuted(context), fontSize: 13),
        filled: true,
        fillColor: AppColors.bg(context),
        contentPadding: const EdgeInsets.all(12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border(context)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.border(context)),
        ),
      ),
    );
  }

  Future<void> _addPhoto(ImageSource source) async {
    if (_photos.length >= _maxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Up to $_maxPhotos photos per report')),
      );
      return;
    }
    try {
      final file = await _picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (file != null) setState(() => _photos.add(file));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't get photo: $e")));
    }
  }

  void _removePhoto(int index) => setState(() => _photos.removeAt(index));

  Widget _photoThumbnail(int index) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder<Uint8List>(
            future: _photos[index].readAsBytes(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return Container(
                  width: 72,
                  height: 72,
                  color: AppColors.bg(context),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accentBlue),
                    ),
                  ),
                );
              }
              return Image.memory(
                snapshot.data!,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
              );
            },
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            onTap: () => _removePhoto(index),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: AppColors.accentRed, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _photoPickerButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accentBlue,
          side: BorderSide(color: AppColors.border(context)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  List<Widget> _typeSpecificFields() {
    switch (_typeCategory) {
      case 'curfew':
        return [
          _fieldLabel('CURFEW VIOLATORS APPREHENDED'),
          _boxTextField(_curfewViolatorsController, 'e.g. 3',
              keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          _fieldLabel('ACTION TAKEN'),
          _boxDropdown<String>(
            value: _curfewAction,
            options: _curfewActions,
            onChanged: (v) => setState(() => _curfewAction = v ?? _curfewAction),
          ),
        ];
      case 'accident':
        return [
          _fieldLabel('VEHICLES INVOLVED'),
          _boxTextField(_vehiclesInvolvedController, 'e.g. 2',
              keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          _fieldLabel('HIT AND RUN'),
          _boxDropdown<String>(
            value: _hitAndRun,
            options: _yesNo,
            onChanged: (v) => setState(() => _hitAndRun = v ?? _hitAndRun),
          ),
        ];
      case 'violence':
        return [
          _fieldLabel('WEAPON INVOLVED'),
          _boxDropdown<String>(
            value: _weaponInvolved,
            options: _yesNo,
            onChanged: (v) => setState(() => _weaponInvolved = v ?? _weaponInvolved),
          ),
          const SizedBox(height: 12),
          _fieldLabel('SUSPECT(S) APPREHENDED'),
          _boxTextField(_suspectsApprehendedController, 'e.g. 1',
              keyboardType: TextInputType.number),
        ];
      case 'fire':
        return [
          _fieldLabel('FIRE STATUS'),
          _boxDropdown<String>(
            value: _fireStatus,
            options: _fireStatuses,
            onChanged: (v) => setState(() => _fireStatus = v ?? _fireStatus),
          ),
          const SizedBox(height: 12),
          _fieldLabel('STRUCTURES AFFECTED'),
          _boxTextField(_structuresAffectedController, 'e.g. 1',
              keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          _fieldLabel('FIRE DEPARTMENT NOTIFIED'),
          _boxDropdown<String>(
            value: _fireDeptNotified,
            options: _yesNo,
            onChanged: (v) => setState(() => _fireDeptNotified = v ?? _fireDeptNotified),
          ),
        ];
      default:
        return const [];
    }
  }

  /// One plain-English line per filled-in type-specific field, folded
  /// into the `_typeSectionTitle` section of `report_sections`.
  List<String> _typeSpecificSummaryLines() {
    switch (_typeCategory) {
      case 'curfew':
        final violators = _curfewViolatorsController.text.trim();
        return [
          if (violators.isNotEmpty) 'Violators apprehended: $violators',
          'Action taken: ${_curfewActions[_curfewAction]}',
        ];
      case 'accident':
        final vehicles = _vehiclesInvolvedController.text.trim();
        return [
          if (vehicles.isNotEmpty) 'Vehicles involved: $vehicles',
          'Hit and run: ${_yesNo[_hitAndRun]}',
        ];
      case 'violence':
        final suspects = _suspectsApprehendedController.text.trim();
        return [
          'Weapon involved: ${_yesNo[_weaponInvolved]}',
          if (suspects.isNotEmpty) 'Suspect(s) apprehended: $suspects',
        ];
      case 'fire':
        final structures = _structuresAffectedController.text.trim();
        return [
          'Fire status: ${_fireStatuses[_fireStatus]}',
          if (structures.isNotEmpty) 'Structures affected: $structures',
          'Fire department notified: ${_yesNo[_fireDeptNotified]}',
        ];
      default:
        return const [];
    }
  }

  /// Builds the report as structured sections (`header` + `value` or
  /// `items`) stored in the `report_sections` jsonb column, so headers
  /// can be renamed in the Supabase table editor without an app deploy.
  List<Map<String, dynamic>> _buildReportSections() {
    final individuals = _individualsController.text.trim();
    final injuries = _injuriesReported == 'yes';
    final injuryDetails = _injuryDetailsController.text.trim();
    final specificLines = _typeSpecificSummaryLines();

    return [
      {
        'header': 'Individuals Involved',
        'value': individuals.isEmpty ? 'Not specified' : individuals,
      },
      {
        'header': 'Injuries / Casualties',
        'value': injuries
            ? (injuryDetails.isEmpty ? 'Yes' : 'Yes — $injuryDetails')
            : 'No',
      },
      if (specificLines.isNotEmpty)
        {
          'header': _typeSectionTitle,
          'items': specificLines,
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(color: AppColors.border(context)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                        color: AppColors.border(context), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Text('Incident Report',
                    style: TextStyle(
                        color: AppColors.textMain(context),
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${widget.incidentType.toUpperCase()} — filed by you',
                    style: TextStyle(color: AppColors.textMuted(context), fontSize: 12)),
                const SizedBox(height: 18),

                _fieldLabel('OUTCOME'),
                _boxDropdown<String>(
                  value: _outcome,
                  options: _outcomes,
                  onChanged: (v) => setState(() => _outcome = v ?? _outcome),
                ),
                const SizedBox(height: 16),

                _fieldLabel('INDIVIDUALS INVOLVED'),
                _boxTextField(_individualsController, 'e.g. 2',
                    keyboardType: TextInputType.number),
                const SizedBox(height: 16),

                _fieldLabel('INJURIES / CASUALTIES'),
                _boxDropdown<String>(
                  value: _injuriesReported,
                  options: _yesNo,
                  onChanged: (v) => setState(() => _injuriesReported = v ?? _injuriesReported),
                ),
                if (_injuriesReported == 'yes') ...[
                  const SizedBox(height: 10),
                  _boxTextField(
                    _injuryDetailsController,
                    'Briefly describe injuries and any medical response…',
                    maxLines: 2,
                    onChanged: (_) => setState(() {}),
                  ),
                ],
                const SizedBox(height: 16),

                if (_typeSectionTitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.bg(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border(context)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(_typeSectionIcon, size: 14, color: AppColors.accentRed),
                            const SizedBox(width: 6),
                            Text(_typeSectionTitle.toUpperCase(),
                                style: TextStyle(
                                    color: AppColors.textMain(context),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ..._typeSpecificFields(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                ],

                const SizedBox(height: 14),
                _fieldLabel('PHOTOS / EVIDENCE'),
                Row(
                  children: [
                    _photoPickerButton(
                      icon: Icons.camera_alt_outlined,
                      label: 'Take Photo',
                      onTap: () => _addPhoto(ImageSource.camera),
                    ),
                    const SizedBox(width: 10),
                    _photoPickerButton(
                      icon: Icons.photo_library_outlined,
                      label: 'Choose from Gallery',
                      onTap: () => _addPhoto(ImageSource.gallery),
                    ),
                  ],
                ),
                if (_photos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (var i = 0; i < _photos.length; i++) _photoThumbnail(i),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${_photos.length}/$_maxPhotos photos attached',
                      style: TextStyle(color: AppColors.textMuted(context), fontSize: 11)),
                ],

                const SizedBox(height: 18),
                _fieldLabel('WHAT HAPPENED'),
                _boxTextField(
                  _narrativeController,
                  'Describe what you found and what action was taken…',
                  maxLines: 5,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _narrativeController.text.trim().isEmpty
                        ? null
                        : () => Navigator.of(context).pop({
                              // Narrative stays free text in `report_text`;
                              // structured categories go in `report_sections`.
                              'report_text': _narrativeController.text.trim(),
                              'report_sections': _buildReportSections(),
                              'outcome': _outcome,
                              'images': _photos,
                            }),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentBlue,
                      disabledBackgroundColor: AppColors.accentBlue.withOpacity(0.4),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('SUBMIT REPORT',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}