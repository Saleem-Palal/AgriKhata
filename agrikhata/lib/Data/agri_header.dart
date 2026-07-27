import 'package:agrikhata/theme/app_top_header.dart';
import 'package:flutter/material.dart';

/// Legacy alias — delegates to [AppTopHeader] for global header consistency.
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
    return AppTopHeader(
      breadcrumbs: breadcrumbs,
      actions: actions,
      onBreadcrumbTap: onBreadcrumbTap,
    );
  }
}
