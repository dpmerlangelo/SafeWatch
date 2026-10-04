import 'package:flutter/material.dart';
import '../models/nav_item.dart';
import '../constants/app_colors.dart';

/// Custom-drawn "sidebar toggle" icon: a bordered rounded square with a
/// slim filled bar down one side. Used instead of a built-in Material
/// icon so it renders identically regardless of Flutter/Material Icons
/// font version, and matches the exact look wanted for the collapse
/// button (no guessing whether some icon name compiles).
class SidebarToggleIcon extends StatelessWidget {
  final Color color;
  final double size;

  const SidebarToggleIcon({super.key, required this.color, this.size = 25});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: size * 0.40,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class AppSidebar extends StatelessWidget {
  final bool isCollapsed;
  final List<NavItem> navItems;
  final String activeRoute;
  final ValueChanged<String> onNavItemTap;
  final VoidCallback onLogout;
  final VoidCallback onToggleSidebar;

  const AppSidebar({
    super.key,
    required this.isCollapsed,
    required this.navItems,
    required this.activeRoute,
    required this.onNavItemTap,
    required this.onLogout,
    required this.onToggleSidebar,
  });

  Widget _buildSectionHeader(BuildContext context, String label) {
    return Padding(
      padding: EdgeInsets.only(top: 22, bottom: 8, left: isCollapsed ? 0 : 12),
      child: isCollapsed
          ? Divider(color: AppColors.border(context), height: 1, indent: 8, endIndent: 8)
          : Text(
              label.toUpperCase(),
              style: TextStyle(
                color: AppColors.textMuted(context),
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      width: isCollapsed ? 76 : 252,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card(context),
          border: Border(right: BorderSide(color: AppColors.border(context), width: 1)),
        ),
        child: ClipRect(
          child: OverflowBox(
            minWidth: isCollapsed ? 76 : 252,
            maxWidth: isCollapsed ? 76 : 252,
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: isCollapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                // --- HEADER: logo centered on the 76px collapsed rail,
                // same 40x40 footprint as nav icons so everything lines up ---
                SizedBox(
                  height: 64,
                  width: double.infinity,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 0 : 14),
                    child: isCollapsed
                        ? Center(
                            child: _HoverIconButton(
                              onTap: onToggleSidebar,
                              borderRadius: 10,
                              child: Container(
                                width: 40,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppColors.accentBlue,
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: [
                                    BoxShadow(color: AppColors.accentBlue.withOpacity(0.45), blurRadius: 14, offset: const Offset(0, 4)),
                                  ],
                                ),
                                child: const Icon(Icons.shield_outlined, color: Colors.white, size: 22),
                              ),
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: AppColors.accentBlue,
                                      borderRadius: BorderRadius.circular(10),
                                      boxShadow: [
                                        BoxShadow(color: AppColors.accentBlue.withOpacity(0.45), blurRadius: 14, offset: const Offset(0, 4)),
                                      ],
                                    ),
                                    child: const Icon(Icons.shield_outlined, color: Colors.white, size: 22),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    'SAFEWATCH',
                                    style: TextStyle(
                                      color: AppColors.textMain(context),
                                      fontWeight: FontWeight.w900,
                                      fontSize: 17,
                                      letterSpacing: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                              _HoverIconButton(
                                onTap: onToggleSidebar,
                                borderRadius: 8,
                                child: Padding(
                                  padding: const EdgeInsets.all(6.0),
                                  child: SidebarToggleIcon(
                                    color: AppColors.textMuted(context),
                                    size: 15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),

                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 10 : 14, vertical: 12),
                    child: Column(
                      crossAxisAlignment: isCollapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ListView(
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.zero,
                            children: [
                              for (int i = 0; i < navItems.length; i++) ...[
                                if (navItems[i].sectionHeader != null)
                                  _buildSectionHeader(context, navItems[i].sectionHeader!),
                                _NavItemTile(
                                  icon: navItems[i].icon,
                                  label: navItems[i].label,
                                  isActive: navItems[i].route == activeRoute,
                                  isCollapsed: isCollapsed,
                                  onTap: () => onNavItemTap(navItems[i].route),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Divider(color: AppColors.border(context), height: 1),
                        const SizedBox(height: 12),

                        // --- FOOTER: profile block removed, just a
                        // standalone logout control that adapts to
                        // collapsed/expanded width ---
                        _LogoutButton(isCollapsed: isCollapsed, onTap: onLogout),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoutButton extends StatefulWidget {
  final bool isCollapsed;
  final VoidCallback onTap;

  const _LogoutButton({required this.isCollapsed, required this.onTap});

  @override
  State<_LogoutButton> createState() => _LogoutButtonState();
}

class _LogoutButtonState extends State<_LogoutButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    final bg = _isHovered ? AppColors.sunken(context) : Colors.transparent;
    final borderColor = _isHovered ? AppColors.border(context) : Colors.transparent;

    final icon = Icon(Icons.logout_rounded, color: AppColors.textMuted(context), size: 18);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: radius,
          splashColor: AppColors.accentBlue.withOpacity(0.15),
          child: Container(
            width: widget.isCollapsed ? 40 : double.infinity,
            height: 40,
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: widget.isCollapsed ? 0 : 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: Border.all(color: borderColor),
            ),
            child: widget.isCollapsed
                ? icon
                : Row(
                    children: [
                      const SizedBox(width: 4),
                      icon,
                      const SizedBox(width: 12),
                      Text(
                        'Log out',
                        style: TextStyle(
                          color: AppColors.textMain(context),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _HoverIconButton extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  final double borderRadius;

  const _HoverIconButton({required this.onTap, required this.child, this.borderRadius = 8});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(borderRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(borderRadius),
        hoverColor: AppColors.sunken(context),
        splashColor: AppColors.accentBlue.withOpacity(0.15),
        mouseCursor: SystemMouseCursors.click,
        child: child,
      ),
    );
  }
}

class _NavItemTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _NavItemTile({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  State<_NavItemTile> createState() => _NavItemTileState();
}

class _NavItemTileState extends State<_NavItemTile> {
  // Hover managed explicitly so it can't get stuck across rebuilds
  // when switching between nav items.
  bool _isHovered = false;

  // Fixed 40x40 box, same footprint as the logo, so icons sit
  // in exactly the same column whether collapsed or expanded.
  static const double _boxSize = 40;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    final iconWidget = Icon(
      widget.icon,
      color: widget.isActive ? Colors.white : AppColors.textMuted(context),
      size: widget.isCollapsed ? 21 : 19,
    );

    final bg = widget.isActive
        ? AppColors.accentBlue
        : (_isHovered ? AppColors.sunken(context) : Colors.transparent);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      alignment: widget.isCollapsed ? Alignment.center : null,
      child: ClipRRect(
        borderRadius: radius,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: widget.isCollapsed ? _boxSize : double.infinity,
              height: _boxSize,
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: widget.isCollapsed ? 0 : 10),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                boxShadow: widget.isActive
                    ? [BoxShadow(color: AppColors.accentBlue.withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 3))]
                    : null,
              ),
              child: widget.isCollapsed
                  ? iconWidget
                  : Row(
                      children: [
                        const SizedBox(width: 4),
                        iconWidget,
                        const SizedBox(width: 12),
                        Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.isActive ? Colors.white : AppColors.textMain(context),
                            fontSize: 12.5,
                            fontWeight: widget.isActive ? FontWeight.w700 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}