// lib/utils/activity_logger.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// A single field-level change to attach to a log entry — e.g. a camera's
/// status flipping from "Offline" to "Online", or a user's role changing
/// from "Tanod" to "Admin". Passing these instead of hand-writing "status
/// changed from X to Y" into a details string is what lets the Logs
/// screen render an actual from → to table instead of a wall of text.
class LogChange {
  final String field;
  final dynamic from;
  final dynamic to;

  const LogChange({required this.field, this.from, this.to});

  String get _fromDisplay => _display(from);
  String get _toDisplay => _display(to);

  static String _display(dynamic v) {
    if (v == null) return '—';
    final s = v.toString().trim();
    return s.isEmpty ? '—' : s;
  }

  /// Encodes as one line the Logs screen can parse back out. `|` and
  /// newlines are stripped from each part first so a stray character in a
  /// value (unlikely for the status/IP/role-style values this is meant
  /// for, but possible) can't corrupt the format.
  String _encode() {
    String clean(String s) => s.replaceAll('|', '/').replaceAll('\n', ' ');
    return '»${clean(field)}|${clean(_fromDisplay)}|${clean(_toDisplay)}';
  }
}

/// Writes entries to the `logs` table for anything worth surfacing in the
/// Logs screen — both user-initiated actions (create/update/delete) and
/// automated system events (e.g. the CCTV health monitor correcting a
/// camera's status or IP on its own).
///
/// Intentionally does NOT store `user_id`. The Logs screen is a
/// human-readable activity feed, not an audit table that needs a foreign
/// key back to auth.users — every entry already carries a resolved,
/// display-ready `user_name` (or "System" for automated events), which is
/// the only thing actually shown/searched in the UI. If you ever need a
/// hard link back to a specific auth user for compliance reasons, add
/// `user_id` back as its own explicit decision rather than by default.
class ActivityLogger {
  /// Logs a user-initiated action. Resolves the acting user's display name
  /// from `profiles` (falling back to their email, then "Unknown").
  ///
  /// Use this for anything a signed-in person actually did: adding a
  /// camera, editing a user, deleting a record, logging in, etc.
  ///
  /// [details] should read as a plain summary of *what* happened and to
  /// *whom* — e.g. `'Updated camera "Gate 2 Cam"'` or `'Changed role for
  /// user "Jane Dela Cruz"'`. Don't try to cram individual field values
  /// into this string; that's what [changes] is for.
  ///
  /// [changes] lists the specific field-level before/after values (e.g.
  /// `[LogChange(field: 'Status', from: 'Offline', to: 'Online')]`) and
  /// renders in the Logs screen as an actual from → to table under the
  /// summary, instead of getting flattened into unreadable text.
  ///
  /// [metadata] is a lighter-weight fallback for extra context that isn't
  /// really a "change" (e.g. an id or a match method) — it's appended to
  /// [details] as plain `key: value` text rather than rendered as a
  /// change row. Prefer [changes] whenever the value actually has an old
  /// and new state.
  static Future<void> log({
    required String action,
    required String details,
    List<LogChange>? changes,
    Map<String, dynamic>? metadata,
  }) async {
    final client = Supabase.instance.client;
    final currentUser = client.auth.currentUser;
    if (currentUser == null) return;

    String userName = currentUser.email ?? 'Unknown';
    try {
      final profile = await client
          .from('profiles')
          .select('first_name, last_name')
          .eq('id', currentUser.id)
          .maybeSingle();

      if (profile != null) {
        final firstName = (profile['first_name'] ?? '').toString().trim();
        final lastName = (profile['last_name'] ?? '').toString().trim();
        final fullName = '$firstName $lastName'.trim();
        if (fullName.isNotEmpty) userName = fullName;
      }
    } catch (_) {
      // Falls back to email if the profile lookup fails for any reason
    }

    await _insert(
      userId: currentUser.id,
      userName: userName,
      action: action,
      details: details,
      changes: changes,
      metadata: metadata,
    );
  }

  /// Logs an automated/system event — nothing here was driven by whoever
  /// happens to be signed in on this device, so there's no `profiles`
  /// lookup to make and no real person to attribute it to. Use this for
  /// background processes: the CCTV health monitor, scheduled jobs, etc.
  ///
  /// `user_name` is recorded as [systemLabel] ("System" by default — pass
  /// something like "System (Health Monitor)" if you want the Logs screen
  /// to distinguish which automated process made the change) instead of
  /// being left blank or, worse, silently attributed to the current
  /// session's user like a manual edit would be.
  ///
  /// See [log] for how [details], [changes], and [metadata] are used —
  /// same rules apply here.
  static Future<void> logSystem({
    required String action,
    required String details,
    String systemLabel = 'System',
    List<LogChange>? changes,
    Map<String, dynamic>? metadata,
  }) async {
    await _insert(
      userName: systemLabel,
      action: action,
      details: details,
      changes: changes,
      metadata: metadata,
    );
  }

  static Future<void> _insert({
    required String userName,
    required String action,
    required String details,
    String? userId,
    List<LogChange>? changes,
    Map<String, dynamic>? metadata,
  }) async {
    final client = Supabase.instance.client;

    // The `details` column stays a single text field (no schema change
    // needed), but its *shape* is: a plain summary line, then zero or
    // more "»field|from|to" change lines, then an optional trailing
    // metadata line. LogsScreen parses this back apart to render the
    // change rows — see LogsScreen._parseLogDetails.
    final buffer = StringBuffer(details);

    if (changes != null && changes.isNotEmpty) {
      for (final change in changes) {
        buffer.write('\n${change._encode()}');
      }
    }

    if (metadata != null && metadata.isNotEmpty) {
      buffer.write(
        '\n${metadata.entries.map((e) => '${e.key}: ${e.value}').join(', ')}',
      );
    }

    try {
      await client.from('logs').insert({
        'user_id': userId,
        'user_name': userName,
        'action': action,
        'details': buffer.toString(),
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      // A failed log write must never take down the caller's actual
      // operation (a camera save, a delete, a health-check update).
      // Swallow it here and just note it for debugging.
      // ignore: avoid_print
      print('[ActivityLogger] failed to write log entry: $e');
    }
  }
}