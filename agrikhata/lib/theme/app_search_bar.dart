import 'package:agrikhata/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Reusable search field with optional filter widgets (prefix/suffix).
class AppSearchBar extends StatelessWidget {
  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final List<Widget> filters;
  final Widget? leading;
  final Widget? trailing;
  final double breakpoint;

  const AppSearchBar({
    super.key,
    this.controller,
    this.hintText = 'Search...',
    this.onChanged,
    this.filters = const [],
    this.leading,
    this.trailing,
    this.breakpoint = 600,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final search = _SearchField(
          controller: controller,
          hintText: hintText,
          onChanged: onChanged,
          leading: leading,
          trailing: trailing,
        );

        if (filters.isEmpty) return search;

        if (constraints.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: AppSpacing.sm + 2),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < filters.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.sm + 2),
                      filters[i],
                    ],
                  ],
                ),
              ),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: search),
            for (final filter in filters) ...[
              const SizedBox(width: AppSpacing.sm + 2),
              filter,
            ],
          ],
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final Widget? leading;
  final Widget? trailing;

  const _SearchField({
    this.controller,
    required this.hintText,
    this.onChanged,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        border: Border.all(color: AppColors.inputBorder, width: 0.5),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.sm),
          ] else ...[
            const Icon(Icons.search, size: 16, color: AppColors.textMuted),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: AppTextStyles.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                hintText: hintText,
                hintStyle: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.textHint,
                ),
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Dropdown filter chip matching [AppSearchBar] height.
class AppFilterDropdown extends StatelessWidget {
  final List<String> options;
  final String value;
  final ValueChanged<String?> onChanged;
  final double? width;

  const AppFilterDropdown({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        border: Border.all(color: AppColors.inputBorder, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 16,
            color: AppColors.textMuted,
          ),
          style: AppTextStyles.bodySmall.copyWith(color: AppColors.textMuted),
          items: options
              .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
