import 'package:flutter/material.dart';

import '../services/alert_notifications.dart';
import '../constants/app_colors.dart';
import '../controllers/theme_controller.dart';

class AppTopHeader extends StatelessWidget {
  final String title;
  final String adminName;
  final String adminInitials;
  final ValueChanged<String>? onOpenCamera;

  const AppTopHeader({
    super.key,
    required this.title,
    required this.adminName,
    required this.adminInitials,
    this.onOpenCamera,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        border: Border(bottom: BorderSide(color: AppColors.border(context), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: AppColors.textMain(context),
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),

          // Right Section
          Row(
            children: [
              AlertBell(
                center: AlertNotificationCenter.instance,
                iconColor: AppColors.textMuted(context),
                textColor: AppColors.textMain(context),
                mutedTextColor: AppColors.textMuted(context),
                panelColor: AppColors.card(context),
                borderColor: AppColors.border(context),
                accentColor: AppColors.accentBlue,
                onOpenCamera: onOpenCamera,
              ),
              const SizedBox(width: 10),

              // Light/dark mode — a real bordered button with hover feedback.
              ListenableBuilder(
                listenable: themeController,
                builder: (context, _) {
                  final isDark = themeController.mode == ThemeMode.dark;
                  return Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: () => themeController.toggle(),
                      borderRadius: BorderRadius.circular(8),
                      hoverColor: AppColors.sunken(context),
                      splashColor: AppColors.accentBlue.withOpacity(0.15),
                      mouseCursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.border(context)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                          color: AppColors.textMuted(context),
                          size: 16,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              Container(width: 1, height: 18, color: AppColors.border(context)),
              const SizedBox(width: 12),
              Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accentBlue.withOpacity(0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: CircleAvatar(
                      backgroundColor: AppColors.accentBlue,
                      radius: 14,
                      child: Text(
                        adminInitials,
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    adminName,
                    style: TextStyle(color: AppColors.textMain(context), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}