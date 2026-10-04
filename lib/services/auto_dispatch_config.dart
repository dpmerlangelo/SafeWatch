import 'package:supabase_flutter/supabase_flutter.dart';

/// What an alert level should do once it has waited long enough unhandled.
enum DispatchAction {
  none, // do nothing automatically — a human must act
  purokLeader, // auto-send a response request to the nearest Purok Leader
  taskForce, // auto-dispatch the nearest available Task Force members
}

DispatchAction _actionFromString(String? s) {
  switch (s) {
    case 'purok_leader':
      return DispatchAction.purokLeader;
    case 'task_force':
      return DispatchAction.taskForce;
    default:
      return DispatchAction.none;
  }
}

String _actionToString(DispatchAction a) {
  switch (a) {
    case DispatchAction.purokLeader:
      return 'purok_leader';
    case DispatchAction.taskForce:
      return 'task_force';
    case DispatchAction.none:
      return 'none';
  }
}

/// One alert level's auto-response rule: what to do, after how long, and
/// since when it's been active (so switching it on never fires on old
/// backlog incidents that occurred before the rule existed).
class LevelRule {
  final DispatchAction action;
  final int afterMinutes;
  final DateTime? since;

  const LevelRule({
    required this.action,
    required this.afterMinutes,
    required this.since,
  });

  static const LevelRule off = LevelRule(
    action: DispatchAction.none,
    afterMinutes: 5,
    since: null,
  );

  bool get isOn => action != DispatchAction.none;

  LevelRule copyWith({
    DispatchAction? action,
    int? afterMinutes,
    DateTime? since,
    bool clearSince = false,
  }) {
    return LevelRule(
      action: action ?? this.action,
      afterMinutes: afterMinutes ?? this.afterMinutes,
      since: clearSince ? null : (since ?? this.since),
    );
  }

  factory LevelRule.fromValue(Map<String, dynamic>? v) {
    if (v == null) return off;
    final action = _actionFromString(v['action'] as String?);
    final minutes = ((v['after_minutes'] as num?)?.toInt() ?? 5)
        .clamp(AutoDispatchConfig.minMinutes, AutoDispatchConfig.maxMinutes)
        .toInt();
    final since = DateTime.tryParse(v['since']?.toString() ?? '')?.toLocal();
    return LevelRule(action: action, afterMinutes: minutes, since: since);
  }

  Map<String, dynamic> toValue() => {
        'action': _actionToString(action),
        'after_minutes': afterMinutes,
        'since': since?.toUtc().toIso8601String(),
      };
}

/// Admin-configurable auto-response rules, stored in `app_settings` as
/// key = 'auto_dispatch', value = jsonb (see `toValue`).
///
/// Each alert level (e.g. Critical, High, Medium, Low — whatever your
/// `AlertLevel` enum defines) has its OWN rule: what action to take
/// (nothing / send to Purok Leader / dispatch Task Force) and how many
/// minutes an incident of that level may sit unhandled before it fires.
class AutoDispatchConfig {
  static const String settingsKey = 'auto_dispatch';

  static const int minMinutes = 1;
  static const int maxMinutes = 240;
  static const int minTeamSize = 1;
  static const int maxTeamSize = 10;

  /// Keyed by the alert level's enum name, lowercased (e.g. "critical",
  /// "high", "warning") — see `levelKey`. Independent of display label, so
  /// renaming a level's on-screen text elsewhere doesn't break saved config.
  final Map<String, LevelRule> levelRules;

  /// Responders per Task Force dispatch (auto-dispatch AND the number
  /// pre-checked in the manual dispatch picker).
  final int taskForceTeamSize;

  const AutoDispatchConfig({
    this.levelRules = const {},
    this.taskForceTeamSize = 3,
  });

  static const AutoDispatchConfig defaults = AutoDispatchConfig();

  /// Stable key for an AlertLevel — use this both to read and to write rules
  /// so it doesn't matter what `toString()` produces elsewhere.
  static String levelKey(Object alertLevelEnumValue) =>
      alertLevelEnumValue.toString().split('.').last.toLowerCase();

  LevelRule ruleFor(Object alertLevelEnumValue) =>
      levelRules[levelKey(alertLevelEnumValue)] ?? LevelRule.off;

  AutoDispatchConfig copyWithRule(Object alertLevelEnumValue, LevelRule rule) {
    final next = Map<String, LevelRule>.from(levelRules);
    next[levelKey(alertLevelEnumValue)] = rule;
    return AutoDispatchConfig(
      levelRules: next,
      taskForceTeamSize: taskForceTeamSize,
    );
  }

  AutoDispatchConfig copyWithTeamSize(int size) => AutoDispatchConfig(
        levelRules: levelRules,
        taskForceTeamSize: size.clamp(minTeamSize, maxTeamSize).toInt(),
      );

  factory AutoDispatchConfig.fromValue(Map<String, dynamic>? v) {
    if (v == null) return defaults;

    final rulesRaw = v['level_rules'];
    final rules = <String, LevelRule>{};
    if (rulesRaw is Map) {
      rulesRaw.forEach((key, value) {
        rules[key.toString()] = LevelRule.fromValue(
            value is Map ? Map<String, dynamic>.from(value) : null);
      });
    }

    final teamSize = ((v['task_force_team_size'] as num?)?.toInt() ?? 3)
        .clamp(minTeamSize, maxTeamSize)
        .toInt();

    return AutoDispatchConfig(levelRules: rules, taskForceTeamSize: teamSize);
  }

  /// Picks this config out of a raw `app_settings` row list (stream payload).
  factory AutoDispatchConfig.fromSettingsRows(List<Map<String, dynamic>> rows) {
    for (final r in rows) {
      if (r['key'] == settingsKey) {
        final v = r['value'];
        return AutoDispatchConfig.fromValue(
            v is Map ? Map<String, dynamic>.from(v) : null);
      }
    }
    return defaults;
  }

  Map<String, dynamic> toValue() => {
        'level_rules': levelRules.map((k, v) => MapEntry(k, v.toValue())),
        'task_force_team_size': taskForceTeamSize,
      };

  static Future<AutoDispatchConfig> load(SupabaseClient supabase) async {
    final row = await supabase
        .from('app_settings')
        .select('value')
        .eq('key', settingsKey)
        .maybeSingle();
    final v = row?['value'];
    return AutoDispatchConfig.fromValue(
        v is Map ? Map<String, dynamic>.from(v) : null);
  }
}