import 'package:flutter/material.dart';

class NavItem {
  final IconData icon;
  final String label;
  final String route; // used for navigation

  // Optional label rendered as a small section header directly above this
  // item in the sidebar (e.g. "DEVICES"). Only the first item in a group
  // needs to set this — items after it in the same group should leave it
  // null so the header isn't repeated.
  final String? sectionHeader;

  const NavItem({
    required this.icon,
    required this.label,
    required this.route,
    this.sectionHeader,
  });
}

const List<NavItem> kAppNavItems = [
  NavItem(icon: Icons.dashboard_outlined, label: 'Dashboard', route: '/dashboard'),
  NavItem(icon: Icons.badge_outlined, label: 'Users', route: '/users'),
  NavItem(icon: Icons.history, label: 'Logs', route: '/logs'),
  NavItem(
    icon: Icons.videocam_outlined,
    label: 'CCTV',
    route: '/cctv',
    sectionHeader: 'DEVICES',
  ),
  NavItem(
    icon: Icons.campaign_outlined,
    label: 'Speakers',
    route: '/speakers',
  ),
  NavItem(
    icon: Icons.map_outlined,
    label: 'Device Map',
    route: '/device-map',
  ),
    NavItem(
    icon: Icons.settings_outlined,
    label: 'Settings',
    route: '/settings',
    sectionHeader: 'ADMIN',
  ),
];

// Nav items shown to the "CCTV manager" / command center role.
const List<NavItem> kCommandCenterNavItems = [
  NavItem(
    icon: Icons.dashboard_outlined,
    label: 'Dashboard',
    route: '/dashboard',
    sectionHeader: 'OVERVIEW',
  ),
  NavItem(
    icon: Icons.videocam_outlined,
    label: 'CCTV',
    route: '/cctv',
    sectionHeader: 'MONITORING',
  ),
  NavItem(
    icon: Icons.warning_amber_rounded,
    label: 'Incidents',
    route: '/incidents',
  ),
  NavItem(
    icon: Icons.assignment_outlined,
    label: 'Reports',
    route: '/incident-reports',
  ),
  NavItem(
    icon: Icons.location_on_outlined,
    label: 'Location',
    route: '/location',
  ),
];