import 'package:supabase_flutter/supabase_flutter.dart';

/// Ensures at most ONE realtime channel subscription exists per table for
/// the whole app, and broadcasts it to every listener. Calling `.stream()`
/// more than once on the same table creates two subscriptions competing
/// for the same default channel name, which Supabase's Realtime server
/// rejects with `RealtimeSubscribeException(status: channelError, ...)`.
/// Routing every screen through this shared stream avoids that entirely.
class RealtimeStreamService {
  RealtimeStreamService._();
  static final RealtimeStreamService instance = RealtimeStreamService._();

  final Map<String, Stream<List<Map<String, dynamic>>>> _cache = {};

  Stream<List<Map<String, dynamic>>> streamTable(
    String table, {
    required List<String> primaryKey,
  }) {
    return _cache.putIfAbsent(table, () {
      return Supabase.instance.client
          .from(table)
          .stream(primaryKey: primaryKey)
          .asBroadcastStream(); // lets multiple widgets share ONE subscription
    });
  }

  /// Reads the current session if it's already restored — otherwise waits
  /// for Supabase to finish restoring/refreshing it from disk (this is the
  /// part that only happens on cold start, not on relogin, since relogin
  /// already has the session in memory). Falls back after 5s so the UI
  /// never hangs forever even if something's genuinely wrong.
  Future<Session?> waitForSession() async {
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession != null) return auth.currentSession;

    try {
      final state = await auth.onAuthStateChange
          .firstWhere((s) => s.session != null)
          .timeout(const Duration(seconds: 5));
      return state.session;
    } catch (_) {
      return auth.currentSession; // still null if restore genuinely failed
    }
  }

  /// Call on logout so a fresh login re-subscribes cleanly instead of
  /// reusing a stale/closed channel from the previous session.
  void clear() {
    _cache.clear();
  }
}