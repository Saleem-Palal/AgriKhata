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
          Expanded(
            child: Row(
              children: [
                for (final entry in breadcrumbs.asMap().entries) ...[
                  Flexible(
                    child: _breadcrumbChip(
                      text: entry.value,
                      isLast: entry.key == breadcrumbs.length - 1,
                      onTap: entry.key != breadcrumbs.length - 1 &&
                              onBreadcrumbTap != null
                          ? () => onBreadcrumbTap!(entry.key)
                          : null,
                    ),
                  ),
                  if (entry.key != breadcrumbs.length - 1)
                    const Text(
                      '  ›  ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w200,
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final action in actions)
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: action,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _breadcrumbChip({
    required String text,
    required bool isLast,
    VoidCallback? onTap,
  }) {
    Widget crumb = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 16,
        fontWeight: isLast ? FontWeight.w400 : FontWeight.w200,
        color: isLast ? Colors.black : AppColors.textMuted,
      ),
    );

    if (onTap == null) return crumb;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 2.0),
          child: crumb,
        ),
      ),
    );
  }
}
