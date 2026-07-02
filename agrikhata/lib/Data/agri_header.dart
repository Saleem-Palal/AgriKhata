import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:flutter/material.dart';

class AgriHeader extends StatelessWidget {
  final List<String> breadcrumbs;
  final List<Widget> actions;
  final void Function(int index)? onBreadcrumbTap;

  const AgriHeader({
    super.key,
    required this.breadcrumbs,
    required this.actions,
    this.onBreadcrumbTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: AppColors.cardSurface,
        border: Border(
          bottom: BorderSide(color: Color.fromARGB(255, 65, 113, 54)),
        ),
      ),
      child: Row(
        children: [
          // Dynamic Breadcrumbs Left
          ...breadcrumbs.asMap().entries.map((entry) {
            int idx = entry.key;
            String text = entry.value;
            bool isLast = idx == breadcrumbs.length - 1;

            Widget crumb = Text(
              text,
              style: TextStyle(
                fontSize: 16,
                fontWeight: isLast ? FontWeight.w400 : FontWeight.w200,
                color: isLast ? Colors.black : AppColors.textMuted,
              ),
            );

            if (!isLast && onBreadcrumbTap != null) {
              crumb = MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => onBreadcrumbTap!(idx),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2.0,
                      vertical: 2.0,
                    ),
                    child: crumb,
                  ),
                ),
              );
            }

            return Row(
              children: [
                crumb,
                if (!isLast)
                  const Text(
                    "  ›  ",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w200),
                  ),
              ],
            );
          }).toList(),

          const Spacer(),

          // Dynamic Action Buttons Right
          ...actions.map(
            (action) => Padding(
              padding: const EdgeInsets.only(left: 12),
              child: action,
            ),
          ),
        ],
      ),
    );
  }
}
