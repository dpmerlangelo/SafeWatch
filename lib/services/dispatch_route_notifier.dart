import 'package:flutter/foundation.dart';

/// Bridges `DispatchNotificationService`'s tap callback (fired from
/// outside the widget tree, e.g. while the app was backgrounded) to
/// `MobileShell`, which owns `_activeRoute` and can't be reached
/// directly without a global NavigatorKey.
///
/// Flow: main.dart sets `DispatchNotificationService.onNotificationTapped`
/// to call `TaskForceDispatchRouter.notifyTapped(...)`. `MobileShell`
/// listens on `pendingDispatchId` and, if the signed-in user is Task
/// Force, switches `_activeRoute` to '/dispatch' so they land straight
/// on the incident they were just paged for.
class TaskForceDispatchRouter {
  TaskForceDispatchRouter._();

  static final ValueNotifier<String?> pendingDispatchId = ValueNotifier(null);

  static void notifyTapped(String dispatchId) {
    pendingDispatchId.value = dispatchId;
  }

  /// Call after acting on the pending value so the same tap doesn't
  /// re-trigger a route switch on the next rebuild.
  static void consume() {
    pendingDispatchId.value = null;
  }
}