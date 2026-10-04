import 'package:flutter/material.dart';
import '../models/nav_item_mobile.dart';
import '../constants/app_colors.dart';

/// Bottom navigation bar used by [MobileShell].
///
/// Takes whatever nav item list the shell resolved for the current
/// role (Tanod / Task Force / Purok Leader) so this widget itself
/// stays role-agnostic.
class AppNavbar extends StatelessWidget {
  final List<NavItem> navItems;
  final String activeRoute;
  final ValueChanged<String> onNavItemTap;

  const AppNavbar({
    super.key,
    required this.navItems,
    required this.activeRoute,
    required this.onNavItemTap,
  });

  @override
  Widget build(BuildContext context) {
    final currentIndex = navItems.indexWhere((item) => item.route == activeRoute);
    final resolvedIndex = currentIndex == -1 ? 0 : currentIndex;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card(context),
        border: Border(
          top: BorderSide(color: AppColors.border(context), width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: List.generate(navItems.length, (index) {
              final item = navItems[index];
              final isActive = index == resolvedIndex;
              final color = isActive
                  ? AppColors.accentBlue
                  : AppColors.textMuted(context);

              return Expanded(
                child: GestureDetector(
                  onTap: () => onNavItemTap(item.route),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isActive ? (item.activeIcon ?? item.icon) : item.icon,
                        color: color,
                        size: 24,
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}