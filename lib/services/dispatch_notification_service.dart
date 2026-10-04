import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ASSUMPTION: local-only notifications, per request — no FCM/APNs wiring
// here. That means this only fires while the app process is alive
// (foreground or backgrounded-but-not-killed). If Task Force members need
// to be reachable with the app fully closed/killed, that requires a push
// path (Supabase Edge Function -> FCM/APNs) as a follow-up, not covered
// here.
//
// Add to pubspec.yaml if not already present:
//   dependencies:
//     flutter_local_notifications: ^17.2.2
//
// Android manifest: add the POST_NOTIFICATIONS permission (API 33+) —
//   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
// iOS: no extra manifest entry needed beyond the runtime permission
// request this service already does in init().

/// Singleton wrapper around flutter_local_notifications that shows an
/// alert whenever the signed-in Task Force member appears in
/// `member_ids` on a newly-inserted `task_force_dispatches` row.
///
/// Call `init()` once at app startup (before login is fine), then call
/// `startListening()` right after the Task Force member's session is
/// established (so `auth.currentUser` is populated), and `stopListening()`
/// on sign-out.
class DispatchNotificationService {
  DispatchNotificationService._();
  static final DispatchNotificationService instance =
      DispatchNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  RealtimeChannel? _channel;
  bool _initialized = false;

  /// Called when the user taps a dispatch notification. Wire this to
  /// navigation (e.g. push TaskForceHomeScreen / jump to the active
  /// dispatch tab) from main.dart.
  void Function(String dispatchId, String incidentId)? onNotificationTapped;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null) return;
        final data = jsonDecode(payload) as Map<String, dynamic>;
        onNotificationTapped?.call(
          data['dispatch_id'].toString(),
          data['incident_id'].toString(),
        );
      },
    );

    // Android 13+ requires this to be requested explicitly at runtime —
    // without it, .show() silently does nothing on those devices.
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Subscribes to `task_force_dispatches` inserts. Filtering on the
  /// `member_ids` jsonb array can't be done in the Postgres Changes
  /// filter syntax, so every insert on the table is received and
  /// filtered client-side against the current user's id.
  void startListening() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    _channel?.unsubscribe();
    _channel = Supabase.instance.client
        .channel('task_force_dispatches_notify_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'task_force_dispatches',
          callback: (payload) => _handleInsert(payload.newRecord, userId),
        )
        .subscribe();
  }

  void stopListening() {
    _channel?.unsubscribe();
    _channel = null;
  }

  void _handleInsert(Map<String, dynamic> row, String userId) {
    final memberIds =
        (row['member_ids'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[];
    if (!memberIds.contains(userId)) return;

    final isLead = row['team_lead_id']?.toString() == userId;
    final dispatchId = row['id'].toString();
    final incidentId = row['incident_id'].toString();

    _show(
      id: dispatchId.hashCode,
      title: isLead ? "You're the team lead — new dispatch" : "You've been dispatched",
      body: 'Command center has dispatched the task force to an incident. '
          'Tap to view details and get directions.',
      payload: jsonEncode({'dispatch_id': dispatchId, 'incident_id': incidentId}),
    );
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) {
    const androidDetails = AndroidNotificationDetails(
      'task_force_dispatch',
      'Task Force Dispatch',
      channelDescription:
          'Alerts a Task Force member when command center dispatches them to an incident',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.call,
    );
    const iosDetails = DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    const details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);
    return _plugin.show(id, title, body, details, payload: payload);
  }
}