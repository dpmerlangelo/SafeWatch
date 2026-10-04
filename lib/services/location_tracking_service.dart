import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../controllers/location_sharing_controller.dart';

/// App-wide GPS broadcaster. Runs only while a user is signed in AND the
/// Profile-tab switch is on, regardless of which screen is visible.
class LocationTrackingService {
  LocationTrackingService._();
  static final LocationTrackingService instance = LocationTrackingService._();

  final SupabaseClient _supabase = Supabase.instance.client;

  /// Latest known position, for screens that want to draw "me" on a map.
  final ValueNotifier<ll.LatLng?> position = ValueNotifier(null);

  StreamSubscription<AuthState>? _authSub;
  StreamSubscription<Position>? _posSub;
  Timer? _heartbeat;

  String? _activeUserId;
  String? _fullName;
  String? _role;
  Position? _lastPos;
  DateTime? _lastPush;
  bool _restoring = false;

  String? get _userId => _supabase.auth.currentUser?.id;
  bool get _sharing => LocationSharingController.instance.value;

  /// Call once, right after Supabase.initialize().
  void init() {
    LocationSharingController.instance.addListener(_onToggle);
    _authSub = _supabase.auth.onAuthStateChange.listen((data) {
      if (data.session != null) {
        _onSignedIn();
      } else {
        _onSignedOut();
      }
    });
    if (_supabase.auth.currentSession != null) _onSignedIn();
  }

  // --- AUTH ---------------------------------------------------------

  Future<void> _onSignedIn() async {
    final uid = _userId;
    if (uid == null || uid == _activeUserId) return; // ignore token refreshes
    _activeUserId = uid;

    await _loadProfile(uid);
    await _restoreSharingFlag(uid);

    if (_activeUserId == uid && _sharing) await _start();
  }

  void _onSignedOut() {
    _activeUserId = null;
    _stop();
    position.value = null;
    _fullName = null;
    _role = null;
    // Reset for the next account; it's re-restored from the server on login.
    _restoring = true;
    LocationSharingController.instance.setEnabled(true);
    _restoring = false;
  }

  /// Call BEFORE signOut() so the row can still be updated (needs a session).
  Future<void> stopAndMarkOffline() async {
    _stop();
    await _markSharingOff();
  }

  Future<void> _loadProfile(String uid) async {
    try {
      final row = await _supabase
          .from('profiles')
          .select('first_name, last_name, role')
          .eq('id', uid)
          .maybeSingle();
      if (row == null) return;
      final first = (row['first_name'] ?? '').toString().trim();
      final last = (row['last_name'] ?? '').toString().trim();
      _fullName = '$first $last'.trim();
      _role = (row['role'] ?? '').toString().trim();
    } catch (_) {}
  }

  // Restore the switch from the server so a restart can't silently
  // resume sharing after the user turned it off.
  Future<void> _restoreSharingFlag(String uid) async {
    try {
      final row = await _supabase
          .from('live_gps')
          .select('is_sharing')
          .eq('member_id', uid)
          .maybeSingle();
      _restoring = true;
      LocationSharingController.instance
          .setEnabled(row == null ? true : row['is_sharing'] != false);
      _restoring = false;
    } catch (_) {
      _restoring = false;
    }
  }

  // --- SWITCH -------------------------------------------------------

  void _onToggle() {
    if (_restoring || _activeUserId == null) return;
    if (_sharing) {
      _start();
    } else {
      _stop();
      _markSharingOff();
    }
  }

  // --- TRACKING -----------------------------------------------------

  Future<void> _start() async {
    if (_posSub != null || _activeUserId == null || !_sharing) return;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return;

    try {
      final pos = await Geolocator.getCurrentPosition();
      _onPosition(pos);
    } catch (_) {}

    // May have been switched off / signed out while waiting for the fix.
    if (!_sharing || _activeUserId == null || _posSub != null) return;

    _posSub = Geolocator.getPositionStream(locationSettings: _settings())
        .listen(_onPosition, onError: (_) {});

    // distanceFilter means a stationary user emits nothing, so the row
    // would look stale on the leader map. Re-push the last fix periodically.
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      final p = _lastPos;
      if (p != null) _push(p, force: true);
    });
  }

  LocationSettings _settings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 10),
        // Foreground service = keeps updating when the app is minimized.
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Location sharing is on',
          notificationText: 'Your purok leader can see your live location.',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 10,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(
        accuracy: LocationAccuracy.high, distanceFilter: 10);
  }

  void _onPosition(Position pos) {
    _lastPos = pos;
    position.value = ll.LatLng(pos.latitude, pos.longitude);
    _push(pos);
  }

  Future<void> _push(Position pos, {bool force = false}) async {
    final uid = _activeUserId;
    if (!_sharing || uid == null) return;

    final now = DateTime.now();
    if (!force &&
        _lastPush != null &&
        now.difference(_lastPush!).inSeconds < 5) {
      return;
    }
    _lastPush = now;
    try {
      await _supabase.from('live_gps').upsert({
        'member_id': uid,
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'updated_at': now.toUtc().toIso8601String(),
        'is_sharing': true,
        'full_name': _fullName,
        'role': _role,
      });
    } catch (_) {}
  }

  void _stop() {
    _posSub?.cancel();
    _posSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _lastPos = null;
  }

  Future<void> _markSharingOff() async {
    final uid = _userId;
    if (uid == null) return;
    try {
      await _supabase.from('live_gps').update({
        'is_sharing': false,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('member_id', uid);
    } catch (_) {}
  }
}