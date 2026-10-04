import 'package:flutter/foundation.dart';

/// App-wide flag: should this device broadcast the signed-in user's GPS?
/// Listened to by TanodHomeScreen (starts/stops tracking + updates
/// live_gps.is_sharing) and toggled from ProfileScreen.
class LocationSharingController extends ValueNotifier<bool> {
  LocationSharingController._() : super(true);
  static final LocationSharingController instance =
      LocationSharingController._();

  void setEnabled(bool enabled) => value = enabled;
}