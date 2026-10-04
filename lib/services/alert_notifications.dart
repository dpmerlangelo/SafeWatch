import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens_desktop/command_center/cctv_live_screen.dart' show AlertLevel;

/// One raised alert, ready to show in the notification tab.
class AlertNotification {
  final String id;
  final String cameraId;
  final String cameraName;
  final String alertType;
  final AlertLevel level;
  final DateTime timestamp;
  bool read;

  AlertNotification({
    required this.id,
    required this.cameraId,
    required this.cameraName,
    required this.alertType,
    required this.level,
    required this.timestamp,
    this.read = false,
  });

  String get shortLabel => switch (alertType) {
        'Accident' => 'Possible accident',
        'Violence' => 'Possible violence',
        'fire' => 'Possible fire',
        'curfew' => 'Possible curfew violation',
        'traffic' => 'Possible traffic incident',
        _ => alertType,
      };
}

// ---------------------------------------------------------------------------
// Role gate — alert sound + notifications are Cctv Manager-only
// ---------------------------------------------------------------------------

/// Loads and caches the signed-in user's `role`, re-checking whenever the
/// auth state changes (login/logout/switch account).
///
/// Change [usersTable] if your table is named e.g. `profiles` instead of
/// `users`, and [managerRoleValue] if the role string differs from the
/// exact text stored in the `role` column ("Cctv Manager").
class CurrentUserRole {
  CurrentUserRole._();
  static final CurrentUserRole instance = CurrentUserRole._();

  static const String usersTable = 'profiles';
  static const String managerRoleValue = 'Command Center';

  /// null while unknown/loading, empty string if no row found.
  final ValueNotifier<String?> role = ValueNotifier(null);

  bool _loading = false;
  StreamSubscription<AuthState>? _authSub;

  bool get isCctvManager => role.value == managerRoleValue;

  /// Call once (safe to call repeatedly) to start loading the role and
  /// keep it in sync with auth state changes.
  void ensureLoaded() {
    _authSub ??= Supabase.instance.client.auth.onAuthStateChange
        .listen((_) => _refresh());
    if (!_loading && role.value == null) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    _loading = true;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      role.value = null;
      _loading = false;
      return;
    }
    try {
      final row = await Supabase.instance.client
          .from(usersTable)
          .select('role')
          .eq('id', uid)
          .maybeSingle();
      role.value = ((row?['role'] as String?) ?? '').trim();
    } catch (e) {
      debugPrint('CurrentUserRole: failed to load role: $e');
      role.value = null;
    } finally {
      _loading = false;
    }
  }
}

// ---------------------------------------------------------------------------
// Sound
// ---------------------------------------------------------------------------

/// Plays a short tone whenever a new alert is raised.
///
/// Uses the `audioplayers` package. Add it to pubspec.yaml:
///   audioplayers: ^6.0.0
/// and add these files under assets/sounds/ (declared as flutter assets):
///   assets/sounds/alert_critical.mp3
///   assets/sounds/alert_priority.mp3
///   assets/sounds/alert_advisory.mp3
/// Any short (<2s) notification tone works — swap in your own file names
/// as long as the paths below match pubspec's `assets:` section.
class AlertSoundService {
  AlertSoundService._();
  static final AlertSoundService instance = AlertSoundService._();

  AudioPlayer? _player;
  bool muted = false;

  DateTime? _lastPlayedAt;
  static const Duration _minGap = Duration(milliseconds: 700);

  AudioPlayer get _playerInstance => _player ??= AudioPlayer();

  Future<void> playFor(AlertLevel level) async {
    if (muted) return;
    final now = DateTime.now();
    if (_lastPlayedAt != null && now.difference(_lastPlayedAt!) < _minGap) {
      // Several cameras can trip within the same instant — don't overlap.
      return;
    }
    _lastPlayedAt = now;

    // Use a single alert sound regardless of the alert level
    const asset = '';

    try {
      await _playerInstance.stop();
      await _playerInstance.play(AssetSource(asset));
    } catch (e) {
      debugPrint('AlertSoundService: failed to play "$asset": $e');
    }
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}

// ---------------------------------------------------------------------------
// Notification center
// ---------------------------------------------------------------------------

/// Holds recent alerts for the notification tab in the top bar.
class AlertNotificationCenter extends ChangeNotifier {
  AlertNotificationCenter._();
  static final AlertNotificationCenter instance = AlertNotificationCenter._();

  static const int _maxItems = 50;

  final List<AlertNotification> _items = [];
  List<AlertNotification> get items => List.unmodifiable(_items);

  int get unreadCount => _items.where((n) => !n.read).length;

  void add(AlertNotification notification) {
    _items.insert(0, notification);
    if (_items.length > _maxItems) {
      _items.removeRange(_maxItems, _items.length);
    }
    notifyListeners();
  }

  void markAllRead() {
    var changed = false;
    for (final n in _items) {
      if (!n.read) {
        n.read = true;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void markRead(String id) {
    final match = _items.where((n) => n.id == id);
    if (match.isEmpty) return;
    match.first.read = true;
    notifyListeners();
  }

  void clear() {
    _items.clear();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Watcher: bridges Supabase `camera_detections` -> sound + notification center
// ---------------------------------------------------------------------------

/// Listens to the `camera_detections` table across ALL cameras and, on each
/// new alert (a transition from "no active alert" to an active alert type),
/// plays a sound and adds an entry to [AlertNotificationCenter].
///
/// This is a singleton so it can be started once (e.g. from the CCTV
/// screen) and keeps running app-wide, so the notification bell in the top
/// bar stays live even while the user is on a different tab/screen.
class AlertWatcher {
  AlertWatcher._({required this.center});
  static final AlertWatcher instance =
      AlertWatcher._(center: AlertNotificationCenter.instance);

  final AlertNotificationCenter center;
  bool soundEnabled = true;

  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  final Map<String, String?> _lastAlertTypeByCamera = {};
  Map<String, String> _cameraNamesById = {};

  void updateCameraNames(Map<String, String> namesById) {
    _cameraNamesById = namesById;
  }

  /// Starts (or stops) the underlying Supabase subscription based on
  /// whether the signed-in user is a Cctv Manager. Safe to call multiple
  /// times — it just re-applies the current role gate.
  void start() {
    CurrentUserRole.instance.ensureLoaded();
    CurrentUserRole.instance.role.removeListener(_applyRoleGate);
    CurrentUserRole.instance.role.addListener(_applyRoleGate);
    _applyRoleGate();
  }

  void _applyRoleGate() {
    final allowed = CurrentUserRole.instance.isCctvManager;
    if (allowed) {
      _sub ??= Supabase.instance.client
          .from('camera_detections')
          .stream(primaryKey: ['camera_id'])
          .listen(_onRows, onError: (e) => debugPrint('AlertWatcher error: $e'));
    } else {
      _sub?.cancel();
      _sub = null;
      _lastAlertTypeByCamera.clear();
    }
  }

  void _onRows(List<Map<String, dynamic>> rows) {
    for (final row in rows) {
      final cameraId = row['camera_id']?.toString();
      if (cameraId == null) continue;

      final alertType = row['active_alert_type'] as String?;
      final previousType = _lastAlertTypeByCamera[cameraId];
      _lastAlertTypeByCamera[cameraId] = alertType;

      final isNewAlert = alertType != null && alertType != previousType;
      if (!isNewAlert) continue;

      final updatedAtStr = row['updated_at']?.toString();
      final updatedAt = updatedAtStr != null
          ? (DateTime.tryParse(updatedAtStr)?.toLocal() ?? DateTime.now())
          : DateTime.now();

      // Skip stale rows from the initial snapshot on app start/reconnect —
      // only alert on things that just happened.
      if (DateTime.now().difference(updatedAt) > const Duration(seconds: 5)) {
        continue;
      }

      final level =
          AlertLevel.fromString(row['active_alert_level'] as String?) ??
              AlertLevel.forAlertType(alertType);

      final notification = AlertNotification(
        id: '${cameraId}_${updatedAt.microsecondsSinceEpoch}',
        cameraId: cameraId,
        cameraName: _cameraNamesById[cameraId] ?? 'Camera',
        alertType: alertType,
        level: level,
        timestamp: updatedAt,
      );

      center.add(notification);
      if (soundEnabled) AlertSoundService.instance.playFor(level);
    }
  }

  void stop() {
    CurrentUserRole.instance.role.removeListener(_applyRoleGate);
    _sub?.cancel();
    _sub = null;
  }
}

// ---------------------------------------------------------------------------
// Bell widget for the top bar
// ---------------------------------------------------------------------------

/// Small bell icon + unread badge for the top header. Tapping it opens a
/// dropdown panel listing recent alerts.
class AlertBell extends StatefulWidget {
  final AlertNotificationCenter center;
  final Color iconColor;
  final Color textColor;
  final Color mutedTextColor;
  final Color panelColor;
  final Color borderColor;
  final Color accentColor;

  /// Called with a camera id when the user taps a notification — wire this
  /// to switch to the CCTV screen and open that camera individually.
  final ValueChanged<String>? onOpenCamera;

  const AlertBell({
    super.key,
    required this.center,
    this.iconColor = const Color(0xFF8A8F9B),
    this.textColor = const Color(0xFFE1E4EA),
    this.mutedTextColor = const Color(0xFF8A8F9B),
    this.panelColor = const Color(0xFF1A1C20),
    this.borderColor = const Color(0xFF262930),
    this.accentColor = const Color(0xFF2082E2),
    this.onOpenCamera,
  });

  @override
  State<AlertBell> createState() => _AlertBellState();
}

class _AlertBellState extends State<AlertBell> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    CurrentUserRole.instance.ensureLoaded();
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _toggle() {
    if (_open) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Tap-away barrier.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _removeOverlay,
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 10),
            child: _NotificationPanel(
              center: widget.center,
              textColor: widget.textColor,
              mutedTextColor: widget.mutedTextColor,
              panelColor: widget.panelColor,
              borderColor: widget.borderColor,
              accentColor: widget.accentColor,
              onOpenCamera: (cameraId) {
                widget.onOpenCamera?.call(cameraId);
                _removeOverlay();
              },
            ),
          ),
        ],
      ),
    );
    overlay.insert(_overlayEntry!);
    setState(() => _open = true);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: CurrentUserRole.instance.role,
      builder: (context, role, _) {
        if (role != CurrentUserRole.managerRoleValue) {
          return const SizedBox.shrink();
        }
        return _buildBell();
      },
    );
  }

  Widget _buildBell() {
    return CompositedTransformTarget(
      link: _link,
      child: AnimatedBuilder(
        animation: widget.center,
        builder: (context, _) {
          final unread = widget.center.unreadCount;
          return SizedBox(
            width: 32,
            height: 32,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: Icon(
                    unread > 0
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_none_rounded,
                    color: unread > 0 ? widget.accentColor : widget.iconColor,
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _toggle,
                ),
                if (unread > 0)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 15),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B30),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        unread > 9 ? '9+' : '$unread',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NotificationPanel extends StatelessWidget {
  final AlertNotificationCenter center;
  final Color textColor;
  final Color mutedTextColor;
  final Color panelColor;
  final Color borderColor;
  final Color accentColor;
  final ValueChanged<String> onOpenCamera;

  const _NotificationPanel({
    required this.center,
    required this.textColor,
    required this.mutedTextColor,
    required this.panelColor,
    required this.borderColor,
    required this.accentColor,
    required this.onOpenCamera,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 320,
        constraints: const BoxConstraints(maxHeight: 420),
        decoration: BoxDecoration(
          color: panelColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
          boxShadow: const [
            BoxShadow(color: Colors.black45, blurRadius: 16, offset: Offset(0, 8)),
          ],
        ),
        child: AnimatedBuilder(
          animation: center,
          builder: (context, _) {
            final items = center.items;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'ALERTS',
                        style: TextStyle(
                          color: mutedTextColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                      Row(
                        children: [
                          if (items.isNotEmpty)
                            TextButton(
                              onPressed: center.markAllRead,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text('Mark all read',
                                  style: TextStyle(color: accentColor, fontSize: 11)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: items.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'No alerts yet.',
                            style: TextStyle(color: mutedTextColor, fontSize: 12),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: items.length,
                          separatorBuilder: (_, __) =>
                              Divider(height: 1, color: borderColor),
                          itemBuilder: (context, index) {
                            final n = items[index];
                            return InkWell(
                              onTap: () {
                                center.markRead(n.id);
                                onOpenCamera(n.cameraId);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      margin: const EdgeInsets.only(top: 4),
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: n.read
                                            ? Colors.transparent
                                            : n.level.color,
                                        shape: BoxShape.circle,
                                        border: n.read
                                            ? Border.all(color: borderColor)
                                            : null,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            n.cameraName,
                                            style: TextStyle(
                                              color: textColor,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            n.shortLabel,
                                            style: TextStyle(
                                              color: mutedTextColor,
                                              fontSize: 11,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            _relativeTime(n.timestamp),
                                            style: TextStyle(
                                              color: mutedTextColor
                                                  .withOpacity(0.7),
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}