import 'package:agrikhata/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Column definition for [AppDataTable].
class AppDataColumn {
  /// Header label (rendered uppercase).
  final String title;
  final int flex;
  final Alignment alignment;

  const AppDataColumn({
    required this.title,
    this.flex = 1,
    this.alignment = Alignment.centerLeft,
  });

  /// Alias for [title] (legacy call sites).
  String get label => title;
}

/// Row definition — cells may be [Widget]s or plain [String]s.
class AppDataRow {
  final List<Object> cells;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? backgroundColor;

  const AppDataRow({
    required this.cells,
    this.onTap,
    this.trailing,
    this.backgroundColor,
  });
}

/// Convenience text cell matching design-system body styles.
class AppTableCellText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int maxLines;

  const AppTableCellText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style ?? AppTextStyles.bodySmall,
    );
  }
}

/// Full-width striped data table used across AgriKhata list screens.
class AppDataTable extends StatelessWidget {
  final List<AppDataColumn> columns;
  final List<AppDataRow> rows;
  final bool isScrollable;
  final double minWidth;
  final double trailingWidth;
  final Widget? empty;
  final bool showCardChrome;
  final EdgeInsetsGeometry? margin;

  static const double headerHeight = 40;
  static const double rowMinHeight = 42;

  static const Color headerBg = Color(0xFFF0F4EE);
  static const Color rowEven = Color(0xFFFFFFFF);
  static const Color rowOdd = Color(0xFFF8FAF6);
  static const Color rowBorder = Color(0xFFEEF3EC);
  static const Color headerText = Color(0xFF1B4332);

  const AppDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.isScrollable = true,
    this.minWidth = 720,
    this.trailingWidth = 0,
    this.empty,
    this.showCardChrome = true,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final table = _buildTableBody();

    if (!showCardChrome) {
      return SizedBox(width: double.infinity, child: table);
    }

    return Container(
      margin: margin,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: AppRadius.xlAll,
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: table,
    );
  }

  Widget _buildTableBody() {
    if (rows.isEmpty && empty != null) {
      return empty!;
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderRow(columns: columns, trailingWidth: trailingWidth),
        for (var i = 0; i < rows.length; i++)
          _DataRowView(
            columns: columns,
            row: rows[i],
            index: i,
            isLast: i == rows.length - 1,
            trailingWidth: trailingWidth,
          ),
      ],
    );

    if (!isScrollable) {
      return SizedBox(width: double.infinity, child: column);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final tableWidth = !maxW.isFinite
            ? minWidth
            : (maxW < minWidth ? minWidth : maxW);

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: column,
          ),
        );
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final List<AppDataColumn> columns;
  final double trailingWidth;

  const _HeaderRow({
    required this.columns,
    required this.trailingWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: AppDataTable.headerHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: const BoxDecoration(
        color: AppDataTable.headerBg,
        border: Border(
          bottom: BorderSide(color: AppDataTable.rowBorder, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          for (final col in columns)
            Expanded(
              flex: col.flex,
              child: Align(
                alignment: col.alignment,
                child: Text(
                  col.title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: AppDataTable.headerText,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          if (trailingWidth > 0) SizedBox(width: trailingWidth),
        ],
      ),
    );
  }
}

class _DataRowView extends StatelessWidget {
  final List<AppDataColumn> columns;
  final AppDataRow row;
  final int index;
  final bool isLast;
  final double trailingWidth;

  const _DataRowView({
    required this.columns,
    required this.row,
    required this.index,
    required this.isLast,
    required this.trailingWidth,
  });

  @override
  Widget build(BuildContext context) {
    assert(
      row.cells.length == columns.length,
      'AppDataRow.cells length must match columns',
    );

    final bg = row.backgroundColor ??
        (index.isEven ? AppDataTable.rowEven : AppDataTable.rowOdd);

    final child = Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: AppDataTable.rowMinHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: bg,
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: AppDataTable.rowBorder, width: 0.5),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < columns.length; i++)
            Expanded(
              flex: columns[i].flex,
              child: Align(
                alignment: columns[i].alignment,
                child: _cellWidget(row.cells[i]),
              ),
            ),
          if (row.trailing != null)
            row.trailing!
          else if (trailingWidth > 0)
            SizedBox(width: trailingWidth),
        ],
      ),
    );

    if (row.onTap == null) return child;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: row.onTap,
        hoverColor: AppColors.rowHover,
        child: child,
      ),
    );
  }

  Widget _cellWidget(Object cell) {
    if (cell is Widget) return cell;
    return Text(
      cell.toString(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.bodySmall,
    );
  }
}

/// Legacy alias for [AppDataColumn].
typedef AppTableColumn = AppDataColumn;
