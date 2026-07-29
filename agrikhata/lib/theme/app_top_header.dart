import 'package:agrikhata/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Global page header with soft elevation and no bottom underline.
///
/// Fixed [height] keeps every screen's top bar identical to Dashboard.
/// Supports either breadcrumbs or an explicit title/subtitle pair.
class AppTopHeader extends StatelessWidget {
  /// Matches Dashboard chrome: 16px vertical padding + 38px action row.
  static const double height = 70;

  final List<String>? breadcrumbs;
  final String? title;
  final String? subtitle;
  final List<Widget> actions;
  final void Function(int index)? onBreadcrumbTap;

  const AppTopHeader({
    super.key,
    this.breadcrumbs,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.onBreadcrumbTap,
  }) : assert(
          (breadcrumbs != null && breadcrumbs.length > 0) || title != null,
          'Provide breadcrumbs or a title',
        );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
      decoration: const BoxDecoration(
        color: AppColors.cardSurface,
        boxShadow: AppShadows.header,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _buildLeading()),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.sm),
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
                          padding: const EdgeInsets.only(left: AppSpacing.md),
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

  Widget _buildLeading() {
    if (title != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.pageTitle,
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.pageSubtitle,
            ),
          ],
        ],
      );
    }

    final crumbs = breadcrumbs!;
    return Row(
      children: [
        for (final entry in crumbs.asMap().entries) ...[
          Flexible(
            child: _breadcrumbChip(
              text: entry.value,
              isLast: entry.key == crumbs.length - 1,
              onTap: entry.key != crumbs.length - 1 && onBreadcrumbTap != null
                  ? () => onBreadcrumbTap!(entry.key)
                  : null,
            ),
          ),
          if (entry.key != crumbs.length - 1)
            const Text('  ›  ', style: AppTextStyles.breadcrumbIdle),
        ],
      ],
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
      style: isLast
          ? AppTextStyles.breadcrumbActive
          : AppTextStyles.breadcrumbIdle,
    );

    if (onTap == null) return crumb;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: crumb,
        ),
      ),
    );
  }
}
