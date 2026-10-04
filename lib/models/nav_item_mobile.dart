import 'package:flutter/material.dart';

/// Nav item model for the mobile bottom navigation bar.
///
/// Kept separate from the desktop `NavItem` model since mobile nav
/// items support a distinct "active" icon (filled vs outline), which
/// the desktop sidebar doesn't need.
class NavItem {
  final String label;
  final IconData icon;
  final IconData? activeIcon;
  final String route;

  const NavItem({
    required this.label,
    required this.icon,
    this.activeIcon,
    required this.route,
  });
}

// --- Tanod -----------------------------------------------------------
// Patrol duty: track live location, review past reports filed.
const List<NavItem> kTanodNavItems = [
  NavItem(
    label: 'Location',
    icon: Icons.location_on_outlined,
    activeIcon: Icons.location_on,
    route: '/location',
  ),
  NavItem(
    label: 'Report History',
    icon: Icons.history_outlined,
    activeIcon: Icons.history,
    route: '/report-history',
  ),
  NavItem(
    label: 'Profile',
    icon: Icons.person_outline,
    activeIcon: Icons.person,
    route: '/profile',
  ),
];

// --- Task Force --------------------------------------------------------
// Task Force doesn't track ambient patrol location — their home tab is
// the active dispatch (map + directions + status + report).
const List<NavItem> kTaskForceNavItems = [
  NavItem(
    label: 'Dispatch',
    icon: Icons.shield_outlined,
    activeIcon: Icons.shield,
    route: '/dispatch',
  ),
  NavItem(
    label: 'Report History',
    icon: Icons.history_outlined,
    activeIcon: Icons.history,
    route: '/report-history',
  ),
  NavItem(
    label: 'Profile',
    icon: Icons.person_outline,
    activeIcon: Icons.person,
    route: '/profile',
  ),
];

// --- Purok Leader --------------------------------------------------------
// CHANGED: first tab was labeled "Location" but actually showed the
// dispatch-requests inbox (Pending/Active/History) — relabeled to
// "Requests" to match what's really there. Added a dedicated "Map" tab
// (PurokLeaderMapScreen) that shows live tanod positions + active
// incident pins — this used to be a buried icon button in the old
// home screen's app bar; it's now a first-class tab since monitoring
// is a distinct job from acting on requests.
const List<NavItem> kPurokLeaderNavItems = [
  NavItem(
    label: 'Requests',
    icon: Icons.inbox_outlined,
    activeIcon: Icons.inbox,
    route: '/requests',
  ),
  NavItem(
    label: 'Map',
    icon: Icons.map_outlined,
    activeIcon: Icons.map,
    route: '/map',
  ),
  NavItem(
    label: 'Report History',
    icon: Icons.history_outlined,
    activeIcon: Icons.history,
    route: '/report-history',
  ),
  NavItem(
    label: 'Profile',
    icon: Icons.person_outline,
    activeIcon: Icons.person,
    route: '/profile',
  ),
];