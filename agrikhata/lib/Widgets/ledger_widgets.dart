import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../Database/database_helper.dart' show SaleJoinColumns;
import '../models/ledger_models.dart';
import '../services/whatsapp_urdu_service.dart';
import '../utils/pdf_generator.dart';
import '../utils/shop_settings.dart';
import '../theme/theme.dart';

final _currencyFormat = NumberFormat('#,##,##0');
final _dateFormat = DateFormat('dd MMM');
final _timeFormat = DateFormat('hh:mm a');

/// Expandable pricing breakdown for product-sale ledger rows.
/// Formula: Base + Seasonal Inc − Item Disc − Overall Disc = Net Payable.
class SaleDiscountBreakdownPanel extends StatelessWidget {
  final double grossSubtotal;
  final double seasonalIncrementTotal;
  final double itemDiscountsTotal;
  final double overallDiscount;
  final double netPayable;

  const SaleDiscountBreakdownPanel({
    super.key,
    required this.grossSubtotal,
    this.seasonalIncrementTotal = 0,
    required this.itemDiscountsTotal,
    required this.overallDiscount,
    required this.netPayable,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line('Base Sales Revenue', grossSubtotal),
          if (seasonalIncrementTotal > 0)
            _line(
              'Seasonal Increment',
              seasonalIncrementTotal,
              isSeasonal: true,
            ),
          if (itemDiscountsTotal > 0)
            _line('Item Discount', -itemDiscountsTotal, isDiscount: true),
          if (overallDiscount > 0)
            _line('Overall Discount', -overallDiscount, isDiscount: true),
          const Divider(height: 12, color: Color(0xFFE2EBE0)),
          _line('Net Payable', netPayable, bold: true),
        ],
      ),
    );
  }

  Widget _line(
    String label,
    double amount, {
    bool bold = false,
    bool isDiscount = false,
    bool isSeasonal = false,
  }) {
    final prefix = amount < 0 ? '-₨ ' : (isSeasonal ? '+₨ ' : '₨ ');
    final value = _currencyFormat.format(amount.abs());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
              color: const Color(0xFF6B8F71),
            ),
          ),
          Text(
            '$prefix$value',
            style: TextStyle(
              fontSize: 10,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
              color: isDiscount
                  ? const Color(0xFF28A745)
                  : isSeasonal
                      ? const Color(0xFF0C447C)
                      : const Color(0xFF1B4332),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact always-visible seasonal / discount lines for ledger table rows.
class SaleDiscountInlineSummary extends StatelessWidget {
  final double seasonalIncrementTotal;
  final double itemDiscountsTotal;
  final double overallDiscount;

  const SaleDiscountInlineSummary({
    super.key,
    this.seasonalIncrementTotal = 0,
    required this.itemDiscountsTotal,
    required this.overallDiscount,
  });

  @override
  Widget build(BuildContext context) {
    if (seasonalIncrementTotal <= 0 &&
        itemDiscountsTotal <= 0 &&
        overallDiscount <= 0) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (seasonalIncrementTotal > 0)
            Text(
              'Seasonal Inc: +₨ ${_currencyFormat.format(seasonalIncrementTotal)}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF0C447C),
              ),
            ),
          if (itemDiscountsTotal > 0)
            Text(
              'Item Disc: -₨ ${_currencyFormat.format(itemDiscountsTotal)}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF28A745),
              ),
            ),
          if (overallDiscount > 0)
            Text(
              'Overall Disc: -₨ ${_currencyFormat.format(overallDiscount)}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF28A745),
              ),
            ),
        ],
      ),
    );
  }
}

const _kInvoiceDescriptionWidth = 140.0;

/// Product lines + seasonal / discount adjustments (Items column).
class LedgerItemsColumn extends StatelessWidget {
  final String itemsText;
  final bool showPricingAdjustments;
  final double seasonalIncrementTotal;
  final double itemDiscountsTotal;
  final double overallDiscount;

  const LedgerItemsColumn({
    super.key,
    required this.itemsText,
    this.showPricingAdjustments = false,
    this.seasonalIncrementTotal = 0,
    this.itemDiscountsTotal = 0,
    this.overallDiscount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          itemsText,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF6B8F71),
            height: 1.4,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        if (showPricingAdjustments)
          SaleDiscountInlineSummary(
            seasonalIncrementTotal: seasonalIncrementTotal,
            itemDiscountsTotal: itemDiscountsTotal,
            overallDiscount: overallDiscount,
          ),
      ],
    );
  }
}

/// Free-text invoice remarks (separate from product / pricing lines).
class LedgerInvoiceDescriptionColumn extends StatelessWidget {
  final String text;

  const LedgerInvoiceDescriptionColumn({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final display = text.trim().isEmpty ? '—' : text.trim();
    return SizedBox(
      width: _kInvoiceDescriptionWidth,
      child: Text(
        display,
        style: TextStyle(
          fontSize: 11,
          color: display == '—'
              ? const Color(0xFF95B89A)
              : const Color(0xFF6B8F71),
          height: 1.4,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 3,
      ),
    );
  }
}

class SeasonDropdown extends StatelessWidget {
  final Season selectedSeason;
  final List<Season> availableSeasons;
  final ValueChanged<Season?> onChanged;

  const SeasonDropdown({
    super.key,
    required this.selectedSeason,
    required this.availableSeasons,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC6DEC9), width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Season>(
          value: selectedSeason,
          items: availableSeasons.map((season) {
            return DropdownMenuItem<Season>(
              value: season,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.calendar_today_outlined,
                    size: 14,
                    color: Color(0xFF1B4332),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    season.displayName,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1B4332),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: onChanged,
          icon: const SizedBox.shrink(),
          isDense: true,
        ),
      ),
    );
  }
}

class _MainLedgerExpandableRow extends StatefulWidget {
  final LedgerEntry entry;
  final bool isLast;
  final Function(LedgerEntry)? onEdit;
  final Function(LedgerEntry)? onDelete;
  final VoidCallback onShowDetail;
  final Widget Function(PaymentStatus status, double outstanding) buildStatusBadge;

  const _MainLedgerExpandableRow({
    required this.entry,
    required this.isLast,
    required this.onEdit,
    required this.onDelete,
    required this.onShowDetail,
    required this.buildStatusBadge,
  });

  @override
  State<_MainLedgerExpandableRow> createState() =>
      _MainLedgerExpandableRowState();
}

class _MainLedgerExpandableRowState extends State<_MainLedgerExpandableRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final canExpand = entry.hasSaleDiscountBreakdown;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: widget.isLast ? Colors.transparent : const Color(0xFFE2EBE0),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: canExpand
                ? () => setState(() => _expanded = !_expanded)
                : widget.onShowDetail,
            hoverColor: const Color(0xFFF0F7EB),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (canExpand) ...[
                              Icon(
                                _expanded
                                    ? Icons.expand_more
                                    : Icons.chevron_right,
                                size: 14,
                                color: const Color(0xFF6B8F71),
                              ),
                              const SizedBox(width: 2),
                            ],
                            Expanded(
                              child: Text(
                                entry.invoiceNumber,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF1B4332),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_dateFormat.format(entry.date)} · ${_timeFormat.format(entry.date)}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF95B89A),
                          ),
                        ),
                        if (entry.createdByUserName != null &&
                            entry.createdByUserName!.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Recorded By: ${entry.createdByUserName!.trim()}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF6B8F71),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.stakeholderName,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1B4332),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (entry.kisaanName != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Kisaan: ${entry.kisaanName}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF6B8F71),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  Expanded(
                    child: LedgerItemsColumn(
                      itemsText: entry.itemsSummary,
                      showPricingAdjustments: entry.isProductSale &&
                          entry.hasVisiblePricingAdjustments,
                      seasonalIncrementTotal:
                          entry.seasonalIncrementTotal ?? 0,
                      itemDiscountsTotal: entry.itemDiscountsTotal ?? 0,
                      overallDiscount: entry.overallDiscount ?? 0,
                    ),
                  ),
                  LedgerInvoiceDescriptionColumn(
                    text: entry.invoiceDescriptionText,
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (entry.isProductSale &&
                            entry.hasVisiblePricingAdjustments &&
                            entry.grossSubtotal != null)
                          Text(
                            '₨ ${_currencyFormat.format(entry.preDiscountTotal)}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF95B89A),
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                        Text(
                          '₨ ${_currencyFormat.format(entry.total)}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1B4332),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      '₨ ${_currencyFormat.format(entry.paid)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF2D6A4F),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: widget.buildStatusBadge(
                        entry.status,
                        entry.outstanding,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.onEdit != null)
                          InkWell(
                            onTap: () => widget.onEdit!(entry),
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: const Color(0xFFC6DEC9),
                                  width: 0.5,
                                ),
                              ),
                              child: const Icon(
                                Icons.edit_outlined,
                                size: 14,
                                color: Color(0xFF1B4332),
                              ),
                            ),
                          ),
                        if (widget.onEdit != null) const SizedBox(width: 6),
                        if (widget.onDelete != null)
                          InkWell(
                            onTap: () => widget.onDelete!(entry),
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: const Color(0xFFF5C6C6),
                                  width: 0.5,
                                ),
                              ),
                              child: const Icon(
                                Icons.delete_outline,
                                size: 14,
                                color: Color(0xFFDC3545),
                              ),
                            ),
                          ),
                        if (widget.onDelete != null) const SizedBox(width: 6),
                        InkWell(
                          onTap: widget.onShowDetail,
                          borderRadius: BorderRadius.circular(7),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: const Color(0xFFC6DEC9),
                                width: 0.5,
                              ),
                            ),
                            child: const Icon(
                              Icons.visibility_outlined,
                              size: 14,
                              color: Color(0xFF6B8F71),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded && canExpand)
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 14, bottom: 10),
              child: SaleDiscountBreakdownPanel(
                grossSubtotal: entry.grossSubtotal!,
                seasonalIncrementTotal: entry.seasonalIncrementTotal ?? 0,
                itemDiscountsTotal: entry.itemDiscountsTotal ?? 0,
                overallDiscount: entry.overallDiscount ?? 0,
                netPayable: entry.netPayable,
              ),
            ),
        ],
      ),
    );
  }
}

class LedgerTable extends StatelessWidget {
  final List<LedgerEntry> entries;
  final VoidCallback? onRefresh;
  final Function(LedgerEntry)? onEdit;
  final Function(LedgerEntry)? onDelete;

  const LedgerTable({
    super.key,
    required this.entries,
    this.onRefresh,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                'No transactions found',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
      ),
      child: Column(
        children: [
          _buildTableHeader(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                onRefresh?.call();
              },
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  return _buildTableRow(
                    context,
                    entries[index],
                    index == entries.length - 1,
                    onEdit,
                    onDelete,
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            child: Text(
              'Showing ${entries.length} of 47 entries · ₨ ${_currencyFormat.format(entries.fold<double>(0, (sum, e) => sum + e.outstanding))} currently outstanding',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF95B89A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F9F4),
        border: Border(
          bottom: BorderSide(color: Color(0xFFE2EBE0), width: 0.5),
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              'INVOICE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(
            width: 160,
            child: Text(
              'STAKEHOLDER',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'ITEMS',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(
            width: _kInvoiceDescriptionWidth,
            child: Text(
              'INVOICE DESCRIPTION',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              'TOTAL',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              'PAID',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              'STATUS',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B8F71),
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(width: 110),
        ],
      ),
    );
  }

  Widget _buildTableRow(
    BuildContext context,
    LedgerEntry entry,
    bool isLast,
    Function(LedgerEntry)? onEdit,
    Function(LedgerEntry)? onDelete,
  ) {
    return _MainLedgerExpandableRow(
      entry: entry,
      isLast: isLast,
      onEdit: onEdit,
      onDelete: onDelete,
      onShowDetail: () => _showInvoiceDetail(context, entry),
      buildStatusBadge: _buildStatusBadge,
    );
  }

  Widget _buildStatusBadge(PaymentStatus status, double outstanding) {
    Color backgroundColor;
    Color textColor;
    String text;

    switch (status) {
      case PaymentStatus.paid:
        backgroundColor = const Color(0xFFD8F3DC);
        textColor = const Color(0xFF2D6A4F);
        text = 'Paid';
        break;
      case PaymentStatus.partial:
        backgroundColor = const Color(0xFFFAEEDA);
        textColor = const Color(0xFF633806);
        text = 'Partial · ₨ ${_currencyFormat.format(outstanding)} due';
        break;
      case PaymentStatus.unpaid:
        backgroundColor = const Color(0xFFFCEBEB);
        textColor = const Color(0xFF791F1F);
        text = 'Unpaid Credit';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  void _showInvoiceDetail(BuildContext context, LedgerEntry entry) {
    showDialog(
      context: context,
      builder: (context) => InvoiceDetailDialog(entry: entry),
    );
  }
}

/// Row model for Zamindar profile ledger tables (overview + ledger tab).
class ZamindarLedgerRow {
  final Map<String, dynamic> source;
  final bool isDebit;
  final String category;
  final String invoiceDisplay;
  final DateTime dateTime;
  final String kisaanName;
  final String itemsText;
  final String invoiceDescriptionText;
  final double total;
  final double paid;
  final PaymentStatus? paymentStatus;
  final String? statusLabel;
  final bool isEdited;
  final String? paymentId;
  final double? grossSubtotal;
  final double? seasonalIncrementTotal;
  final double? itemDiscountsTotal;
  final double? overallDiscount;
  final double? netPayableAmount;

  const ZamindarLedgerRow({
    required this.source,
    required this.isDebit,
    required this.category,
    required this.invoiceDisplay,
    required this.dateTime,
    required this.kisaanName,
    required this.itemsText,
    this.invoiceDescriptionText = '—',
    required this.total,
    required this.paid,
    this.paymentStatus,
    this.statusLabel,
    this.isEdited = false,
    this.paymentId,
    this.grossSubtotal,
    this.seasonalIncrementTotal,
    this.itemDiscountsTotal,
    this.overallDiscount,
    this.netPayableAmount,
  });

  bool get isSaleDebit => category == 'SALE' && isDebit;

  bool get hasSaleDiscountBreakdown =>
      isSaleDebit &&
      (grossSubtotal != null ||
          (seasonalIncrementTotal ?? 0) > 0 ||
          (itemDiscountsTotal ?? 0) > 0 ||
          (overallDiscount ?? 0) > 0);

  bool get hasVisibleDiscounts =>
      (itemDiscountsTotal ?? 0) > 0 || (overallDiscount ?? 0) > 0;

  bool get hasVisiblePricingAdjustments =>
      (seasonalIncrementTotal ?? 0) > 0 || hasVisibleDiscounts;

  double get preDiscountTotal =>
      (grossSubtotal ?? 0) + (seasonalIncrementTotal ?? 0);

  double get outstanding => (total - paid).clamp(0.0, double.infinity);

  bool get isEditablePayment {
    if (isDebit || paymentId == null || paymentId!.isEmpty) return false;
    switch (category) {
      case 'PAYMENT':
      case 'CASH_PAYMENT':
      case 'DEBT_SETTLEMENT':
      case 'ADVANCE_PAYMENT':
      case 'ADVANCE':
        return true;
      case 'WALLET_DEDUCTION':
        return false;
      default:
        return false;
    }
  }

  static List<ZamindarLedgerRow> fromTransactions({
    required List<Map<String, dynamic>> transactions,
    required Map<String, String> itemSummaries,
    required Map<String, Map<String, double>> collections,
    Map<String, Map<String, double>>? saleDiscounts,
    Map<String, String>? saleRemarks,
  }) {
    return transactions.map((row) {
      final type = row['type'] as String? ?? '';
      final category = (row['category'] as String? ?? '').toUpperCase();
      final isDebit = type == 'DEBIT';
      final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
      final description = row['description'] as String? ?? '';
      final kisaanName = (row['kisaan_name'] as String?)?.trim() ?? '';
      final invoiceNumber = (row['invoice_number'] as String?)?.trim();
      final hasInvoice = invoiceNumber != null && invoiceNumber.isNotEmpty;
      final dateRaw = row['date_time'] as String?;
      final dateTime =
          dateRaw != null ? (DateTime.tryParse(dateRaw) ?? DateTime.now()) : DateTime.now();

      final itemsFromInvoice =
          hasInvoice ? (itemSummaries[invoiceNumber] ?? '') : '';
      final collection =
          hasInvoice ? collections[invoiceNumber] : null;
      final isSale = category == 'SALE' && isDebit;
      final isAdvanceCategory = category == 'ADVANCE_LOAN_RECORD' ||
          category == 'CASH_ADVANCE' ||
          category == 'DIESEL_ADVANCE' ||
          category == 'PETROL_ADVANCE';
      final paymentId = (row['payment_id'] as String?)?.trim();
      final editedRaw = row['payment_edited_at'] as String?;
      final isEdited = editedRaw != null && editedRaw.trim().isNotEmpty;

      String itemsText;
      String invoiceDescriptionText = '—';
      // Advances store a generic line item ("Cash Advance x1"); prefer the
      // ledger description so remarks are visible in the invoice description column.
      if (isAdvanceCategory) {
        final trimmed = description.trim();
        if (trimmed.isEmpty || RegExp(r':\s*$').hasMatch(trimmed)) {
          itemsText = _statusLabelForCategory(category);
        } else {
          itemsText = _statusLabelForCategory(category);
          invoiceDescriptionText = trimmed;
        }
      } else if (category == 'WALLET_DEDUCTION') {
        itemsText = PaymentLedgerEntry.formatAdvanceDeductionSummary(
          itemsFromInvoice.isNotEmpty ? itemsFromInvoice : description,
        );
        if (description.trim().isNotEmpty) {
          invoiceDescriptionText = description.trim();
        }
      } else if (isSale) {
        itemsText = itemsFromInvoice.isNotEmpty ? itemsFromInvoice : '—';
        final joinedDescription =
            (row[SaleJoinColumns.description] as String?)?.trim() ?? '';
        final joinedRemarks =
            (row[SaleJoinColumns.remarks] as String?)?.trim() ?? '';
        final batchRemarks = hasInvoice
            ? (saleRemarks?[invoiceNumber]?.trim() ?? '')
            : '';
        final note = joinedDescription.isNotEmpty
            ? joinedDescription
            : (joinedRemarks.isNotEmpty ? joinedRemarks : batchRemarks);
        if (note.isNotEmpty) invoiceDescriptionText = note;
      } else if (itemsFromInvoice.isNotEmpty) {
        itemsText = itemsFromInvoice;
      } else if (description.isNotEmpty) {
        itemsText = description;
      } else {
        itemsText = '—';
      }

      if (!isSale && !isAdvanceCategory && category != 'WALLET_DEDUCTION') {
        final paymentNotes = (row['payment_notes'] as String?)?.trim() ?? '';
        if (paymentNotes.isNotEmpty) {
          invoiceDescriptionText = paymentNotes;
        } else if (description.trim().isNotEmpty) {
          invoiceDescriptionText = description.trim();
        }
      }

      double total;
      double paid;
      PaymentStatus? paymentStatus;
      String? statusLabel;

      if (isSale && collection != null) {
        total = collection['total'] ?? amount;
        paid = collection['paid'] ?? 0.0;
        if (paid >= total && total > 0) {
          paymentStatus = PaymentStatus.paid;
        } else if (paid > 0) {
          paymentStatus = PaymentStatus.partial;
        } else {
          paymentStatus = PaymentStatus.unpaid;
        }
      } else if (isSale) {
        total = amount;
        paid = 0.0;
        paymentStatus = PaymentStatus.unpaid;
      } else {
        total = amount;
        paid = isDebit ? 0.0 : amount;
        statusLabel = _statusLabelForCategory(category);
      }

      Map<String, double>? discountFromBatch;
      if (hasInvoice && saleDiscounts != null) {
        discountFromBatch = saleDiscounts[invoiceNumber];
      }
      final joinedSubtotal =
          (row[SaleJoinColumns.subtotal] as num?)?.toDouble();
      final joinedSeasonal =
          (row[SaleJoinColumns.seasonalIncrementTotal] as num?)?.toDouble();
      final joinedItemDiscounts =
          (row[SaleJoinColumns.itemDiscountsTotal] as num?)?.toDouble();
      final joinedOverallDiscount =
          (row[SaleJoinColumns.overallDiscount] as num?)?.toDouble();
      final batchSubtotal = discountFromBatch != null
          ? discountFromBatch['subtotal']
          : null;
      final batchSeasonal = discountFromBatch != null
          ? discountFromBatch['seasonal_increment_total']
          : null;
      final batchItemDiscounts = discountFromBatch != null
          ? discountFromBatch['item_discounts_total']
          : null;
      final batchOverallDiscount = discountFromBatch != null
          ? discountFromBatch['overall_discount']
          : null;
      final grossSubtotal = isSale
          ? joinedSubtotal ?? batchSubtotal
          : null;
      final seasonalIncrementTotal = isSale
          ? joinedSeasonal ?? batchSeasonal ?? 0
          : null;
      final itemDiscountsTotal = isSale
          ? joinedItemDiscounts ?? batchItemDiscounts ?? 0
          : null;
      final overallDiscount = isSale
          ? joinedOverallDiscount ?? batchOverallDiscount ?? 0
          : null;

      return ZamindarLedgerRow(
        source: row,
        isDebit: isDebit,
        category: category,
        invoiceDisplay: hasInvoice ? invoiceNumber : '—',
        dateTime: dateTime,
        kisaanName: kisaanName.isEmpty ? '—' : kisaanName,
        itemsText: itemsText,
        invoiceDescriptionText: invoiceDescriptionText,
        total: total,
        paid: paid,
        paymentStatus: paymentStatus,
        statusLabel: statusLabel,
        isEdited: isEdited,
        paymentId: paymentId,
        grossSubtotal: grossSubtotal,
        seasonalIncrementTotal: seasonalIncrementTotal,
        itemDiscountsTotal: itemDiscountsTotal,
        overallDiscount: overallDiscount,
        netPayableAmount: isSale ? amount : null,
      );
    }).toList();
  }

  static String _statusLabelForCategory(String category) {
    switch (category) {
      case 'PAYMENT':
      case 'CASH_PAYMENT':
      case 'DEBT_SETTLEMENT':
        return 'Payment';
      case 'WALLET_DEDUCTION':
        return 'Wallet';
      case 'ADVANCE':
      case 'ADVANCE_PAYMENT':
        return 'Advance';
      case 'CASH_ADVANCE':
        return 'Cash Advance';
      case 'DIESEL_ADVANCE':
        return 'Diesel Advance';
      case 'PETROL_ADVANCE':
        return 'Petrol Advance';
      case 'ADVANCE_LOAN_RECORD':
        return 'Advance Loan';
      default:
        return category.isEmpty ? '—' : category;
    }
  }
}

class _ZamindarLedgerExpandableRow extends StatefulWidget {
  final ZamindarLedgerRow row;
  final bool isLast;
  final bool showActions;
  final double actionsWidth;
  final Widget Function(BuildContext context, ZamindarLedgerRow row)?
      actionsBuilder;

  const _ZamindarLedgerExpandableRow({
    required this.row,
    required this.isLast,
    required this.showActions,
    required this.actionsWidth,
    this.actionsBuilder,
  });

  @override
  State<_ZamindarLedgerExpandableRow> createState() =>
      _ZamindarLedgerExpandableRowState();
}

class _ZamindarLedgerExpandableRowState
    extends State<_ZamindarLedgerExpandableRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final canExpand = row.hasSaleDiscountBreakdown;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: widget.isLast ? Colors.transparent : const Color(0xFFE2EBE0),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: canExpand
                ? () => setState(() => _expanded = !_expanded)
                : null,
            hoverColor: const Color(0xFFF0F7EB),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(top: 5, right: 10),
                    decoration: BoxDecoration(
                      color: row.isDebit
                          ? const Color(0xFFC0DD97)
                          : const Color(0xFF85B7EB),
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(
                    width: 120,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (canExpand) ...[
                              Icon(
                                _expanded
                                    ? Icons.expand_more
                                    : Icons.chevron_right,
                                size: 14,
                                color: const Color(0xFF6B8F71),
                              ),
                              const SizedBox(width: 2),
                            ],
                            Expanded(
                              child: Text(
                                row.invoiceDisplay,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF1B4332),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_dateFormat.format(row.dateTime)} · ${_timeFormat.format(row.dateTime)}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF95B89A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: Text(
                      row.kisaanName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF1B4332),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: LedgerItemsColumn(
                      itemsText: row.itemsText,
                      showPricingAdjustments: row.isSaleDebit &&
                          row.hasVisiblePricingAdjustments,
                      seasonalIncrementTotal:
                          row.seasonalIncrementTotal ?? 0,
                      itemDiscountsTotal: row.itemDiscountsTotal ?? 0,
                      overallDiscount: row.overallDiscount ?? 0,
                    ),
                  ),
                  LedgerInvoiceDescriptionColumn(
                    text: row.invoiceDescriptionText,
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (row.isSaleDebit &&
                            row.hasVisiblePricingAdjustments &&
                            row.grossSubtotal != null)
                          Text(
                            '₨ ${_currencyFormat.format(row.preDiscountTotal)}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF95B89A),
                              decoration: TextDecoration.lineThrough,
                            ),
                          ),
                        Text(
                          '₨ ${_currencyFormat.format(row.total)}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1B4332),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      '₨ ${_currencyFormat.format(row.paid)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF2D6A4F),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (row.isEdited) ...[
                            _ZamindarLedgerStatusBadges.edited(),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: row.paymentStatus != null
                                ? _ZamindarLedgerStatusBadges.paymentStatus(
                                    row.paymentStatus!,
                                    row.outstanding,
                                  )
                                : _ZamindarLedgerStatusBadges.category(
                                    row.statusLabel ?? '—',
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.showActions)
                    SizedBox(
                      width: widget.actionsWidth,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: widget.actionsBuilder!(context, row),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded && canExpand)
            Padding(
              padding: const EdgeInsets.only(left: 31, right: 14, bottom: 10),
              child: SaleDiscountBreakdownPanel(
                grossSubtotal: row.grossSubtotal!,
                seasonalIncrementTotal: row.seasonalIncrementTotal ?? 0,
                itemDiscountsTotal: row.itemDiscountsTotal ?? 0,
                overallDiscount: row.overallDiscount ?? 0,
                netPayable: row.netPayableAmount ?? row.total,
              ),
            ),
        ],
      ),
    );
  }
}

/// Sales-style ledger table for Zamindar profile screens.
/// Keeps debit/credit type dots; optional trailing [actionsBuilder] per row.
class ZamindarLedgerTable extends StatelessWidget {
  final List<ZamindarLedgerRow> rows;
  final bool shrinkWrap;
  /// When true, skips the outer bordered container (for use inside a parent card).
  final bool embedded;
  final Widget Function(BuildContext context, ZamindarLedgerRow row)?
      actionsBuilder;
  final double actionsWidth;

  const ZamindarLedgerTable({
    super.key,
    required this.rows,
    this.shrinkWrap = false,
    this.embedded = false,
    this.actionsBuilder,
    this.actionsWidth = 200,
  });

  bool get _showActions => actionsBuilder != null;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      final empty = const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            'No transactions found',
            style: TextStyle(fontSize: 12, color: Color(0xFF95B89A)),
          ),
        ),
      );
      if (embedded) return empty;
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        ),
        child: empty,
      );
    }

    final table = Column(
      mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      children: [
        _buildHeader(),
        if (shrinkWrap)
          for (var i = 0; i < rows.length; i++)
            _buildRow(context, rows[i], i == rows.length - 1)
        else
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                return _buildRow(
                  context,
                  rows[index],
                  index == rows.length - 1,
                );
              },
            ),
          ),
      ],
    );

    if (embedded) return table;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
      ),
      child: table,
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        border: const Border(
          bottom: BorderSide(color: Color(0xFFE2EBE0), width: 0.5),
        ),
        borderRadius: embedded
            ? BorderRadius.zero
            : const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 17),
          const SizedBox(
            width: 120,
            child: Text('INVOICE', style: _headerStyle),
          ),
          const SizedBox(
            width: 140,
            child: Text('KISAAN', style: _headerStyle),
          ),
          const Expanded(
            child: Text('ITEMS', style: _headerStyle),
          ),
          SizedBox(
            width: _kInvoiceDescriptionWidth,
            child: const Text(
              'INVOICE DESCRIPTION',
              style: _headerStyle,
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(
            width: 90,
            child: Text(
              'TOTAL',
              textAlign: TextAlign.right,
              style: _headerStyle,
            ),
          ),
          const SizedBox(
            width: 90,
            child: Text(
              'PAID',
              textAlign: TextAlign.right,
              style: _headerStyle,
            ),
          ),
          const SizedBox(
            width: 140,
            child: Text(
              'STATUS',
              textAlign: TextAlign.right,
              style: _headerStyle,
            ),
          ),
          if (_showActions) SizedBox(width: actionsWidth),
        ],
      ),
    );
  }

  static const _headerStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    color: Color(0xFF6B8F71),
    letterSpacing: 0.3,
  );

  Widget _buildRow(BuildContext context, ZamindarLedgerRow row, bool isLast) {
    return _ZamindarLedgerExpandableRow(
      row: row,
      isLast: isLast,
      showActions: _showActions,
      actionsWidth: actionsWidth,
      actionsBuilder: actionsBuilder,
    );
  }
}

class _ZamindarLedgerStatusBadges {
  static Widget edited() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF3E5F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCE93D8), width: 0.5),
      ),
      child: const Text(
        '(Edited)',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w500,
          color: Color(0xFF6A1B9A),
        ),
      ),
    );
  }

  static Widget paymentStatus(PaymentStatus status, double outstanding) {
    Color backgroundColor;
    Color textColor;
    String text;

    switch (status) {
      case PaymentStatus.paid:
        backgroundColor = const Color(0xFFD8F3DC);
        textColor = const Color(0xFF2D6A4F);
        text = 'Paid';
        break;
      case PaymentStatus.partial:
        backgroundColor = const Color(0xFFFAEEDA);
        textColor = const Color(0xFF633806);
        text = 'Partial · ₨ ${_currencyFormat.format(outstanding)} due';
        break;
      case PaymentStatus.unpaid:
        backgroundColor = const Color(0xFFFCEBEB);
        textColor = const Color(0xFF791F1F);
        text = 'Unpaid Credit';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  static Widget category(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF4F0),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          color: Color(0xFF4A6B50),
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class InvoiceDetailDialog extends StatefulWidget {
  final LedgerEntry entry;

  const InvoiceDetailDialog({
    super.key,
    required this.entry,
  });

  @override
  State<InvoiceDetailDialog> createState() => _InvoiceDetailDialogState();
}

class _InvoiceDetailDialogState extends State<InvoiceDetailDialog> {
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInvoiceInfo(),
                    const SizedBox(height: 24),
                    _buildItemsList(),
                    const SizedBox(height: 24),
                    _buildTotalSection(),
                  ],
                ),
              ),
            ),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: Color(0xFF1B4332),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.receipt_long,
            color: Colors.white,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Invoice Details',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  widget.entry.invoiceNumber,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          _buildInfoRow('Stakeholder:', widget.entry.stakeholderName),
          if (widget.entry.kisaanName != null)
            _buildInfoRow('Kisaan:', widget.entry.kisaanName!),
          _buildInfoRow('Date:', _dateFormat.format(widget.entry.date)),
          _buildInfoRow('Time:', _timeFormat.format(widget.entry.date)),
          _buildInfoRow('Season:', widget.entry.season),
          if (widget.entry.description != null &&
              widget.entry.description!.trim().isNotEmpty)
            _buildInfoRow('Description:', widget.entry.description!.trim()),
          if (widget.entry.createdByUserName != null &&
              widget.entry.createdByUserName!.trim().isNotEmpty)
            _buildInfoRow(
              'Recorded By:',
              widget.entry.createdByUserName!.trim(),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1B4332),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Items',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1B4332),
          ),
        ),
        const SizedBox(height: 12),
        ...widget.entry.items.map((item) => _buildItemCard(item)),
      ],
    );
  }

  Widget _buildItemCard(LineItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[300]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.productName,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Quantity: ${item.quantity} ${item.unit}',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
              Text(
                'Unit Price: Rs ${_currencyFormat.format(item.unitPrice)}',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ],
          ),
          if (item.seasonalIncrement > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Seasonal Increment: Rs ${_currencyFormat.format(item.seasonalIncrement)} per unit',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
          if (item.discount > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Discount: Rs ${_currencyFormat.format(item.discount)} per unit',
              style: const TextStyle(fontSize: 12, color: Color(0xFF28A745)),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Subtotal: Rs ${_currencyFormat.format(item.total)}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1B4332),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalSection() {
    final entry = widget.entry;
    final children = <Widget>[];

    if (entry.hasSaleDiscountBreakdown) {
      children.addAll([
        _buildTotalRow('Base Sales Revenue:', entry.grossSubtotal!),
        if ((entry.seasonalIncrementTotal ?? 0) > 0)
          _buildTotalRow(
            'Seasonal Increment:',
            entry.seasonalIncrementTotal!,
            color: const Color(0xFF0C447C),
          ),
        if ((entry.itemDiscountsTotal ?? 0) > 0)
          _buildTotalRow(
            'Item Discount:',
            entry.itemDiscountsTotal!,
            color: const Color(0xFF28A745),
          ),
        if ((entry.overallDiscount ?? 0) > 0)
          _buildTotalRow(
            'Overall Discount:',
            entry.overallDiscount!,
            color: const Color(0xFF28A745),
          ),
        const Divider(height: 16),
        _buildTotalRow('Net Payable:', entry.netPayable, bold: true),
      ]);
    } else {
      children.add(_buildTotalRow('Total Amount:', entry.total, bold: true));
    }

    children.addAll([
      const Divider(height: 24),
      _buildTotalRow('Paid:', entry.paid),
      const Divider(height: 24),
      _buildTotalRow(
        'Outstanding:',
        entry.outstanding,
        bold: true,
        color: entry.outstanding > 0
            ? const Color(0xFFDC3545)
            : const Color(0xFF28A745),
      ),
    ]);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        border: Border.all(color: const Color(0xFF1B4332), width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildTotalRow(
    String label,
    double amount, {
    bool bold = false,
    Color? color,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          'Rs ${_currencyFormat.format(amount)}',
          style: TextStyle(
            fontSize: 14,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            onPressed: _isProcessing ? null : () => _handlePrint(context),
            icon: const Icon(Icons.print),
            label: const Text('Print Invoice'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1B4332),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _isProcessing ? null : () => _handleShare(context),
            icon: const Icon(Icons.share),
            label: const Text('Share via WhatsApp'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF25D366),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B4332),
              foregroundColor: Colors.white,
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handlePrint(BuildContext context) async {
    setState(() => _isProcessing = true);
    try {
      await PdfGenerator.printInvoice(widget.entry);
      if (mounted) {
        AppToast.showSuccess(context, 'Invoice sent to printer');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to print: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _handleShare(BuildContext context) async {
    setState(() => _isProcessing = true);
    try {
      final file = await PdfGenerator.saveInvoiceToFile(widget.entry);
      final shopName = await ShopSettings.getShopName();

      try {
        await WhatsAppUrduService.sharePdfWithUrduCaption(
          phone: '',
          zamindarName: widget.entry.stakeholderName,
          shopName: shopName,
          amount: widget.entry.total,
          pdfPath: file.path,
          detailLines: [
            'انوائس نمبر: ${widget.entry.invoiceNumber}',
            'ادا شدہ: Rs ${_currencyFormat.format(widget.entry.paid.round())}',
          ],
          subject: 'AgriKhata Invoice ${widget.entry.invoiceNumber}',
        );
        if (mounted) {
          AppToast.showSuccess(context, 'Invoice ready to share');
        }
      } catch (shareError) {
        if (mounted) {
          AppToast.showSuccess(context, 'PDF saved to: ${file.path}');
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to share: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }
}

class PaymentsLedgerTable extends StatelessWidget {
  final List<PaymentLedgerEntry> entries;
  final void Function(PaymentLedgerEntry entry)? onEditPayment;

  const PaymentsLedgerTable({
    super.key,
    required this.entries,
    this.onEditPayment,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFD4E8D8), width: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.receipt_long, size: 48, color: Color(0xFF95B89A)),
              SizedBox(height: 12),
              Text(
                'No payment settlements recorded',
                style: TextStyle(fontSize: 14, color: Color(0xFF95B89A)),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD4E8D8), width: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                return _buildRow(entries[index], index);
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            child: Text(
              'Showing ${entries.length} payment${entries.length == 1 ? '' : 's'} · '
              '₨ ${_currencyFormat.format(entries.fold<double>(0, (sum, e) => sum + e.amountPaid))} received',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF6B8F71),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFFE8F4EA),
        border: Border(
          bottom: BorderSide(color: Color(0xFFD4E8D8), width: 0.5),
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 84,
            child: Text(
              'RECEIPT',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 16),
          const SizedBox(
            width: 68,
            child: Text(
              'INVOICE LINKED',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            flex: 2,
            child: Text(
              'STAKEHOLDER',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            flex: 2,
            child: Text(
              'ITEMS SUMMARY',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(
            width: 88,
            child: Text(
              'AMOUNT',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            flex: 2,
            child: Text(
              'METHOD',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
                letterSpacing: 0.3,
              ),
            ),
          ),
          if (onEditPayment != null)
            const SizedBox(
              width: 44,
              child: Text(
                '',
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCompactTag(
    String text, {
    required Color backgroundColor,
    required Color borderColor,
    required Color textColor,
    FontWeight fontWeight = FontWeight.w600,
    double? maxWidth,
    int maxLines = 1,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: fontWeight,
            color: textColor,
            height: 1.1,
          ),
        ),
      ),
    );
  }

  Widget _buildRow(PaymentLedgerEntry entry, int index) {
    final isEven = index.isEven;
    final isWallet = entry.isWalletDeduction;
    final canEdit = onEditPayment != null && !isWallet;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: isEven ? const Color(0xFFF3FAF5) : Colors.white,
        border: const Border(
          bottom: BorderSide(color: Color(0xFFE8F0EA), width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCompactTag(
                  entry.paymentId,
                  backgroundColor: const Color(0xFFE8F4EA),
                  borderColor: const Color(0xFF52B788),
                  textColor: const Color(0xFF1B4332),
                  maxWidth: 84,
                ),
                const SizedBox(height: 3),
                Text(
                  '${_dateFormat.format(entry.date)} · ${_timeFormat.format(entry.date)}',
                  style: const TextStyle(
                    fontSize: 9,
                    color: Color(0xFF95B89A),
                  ),
                ),
                if (entry.isEdited) ...[
                  const SizedBox(height: 3),
                  const Text(
                    '(Edited)',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6A1B9A),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 68,
            child: Align(
              alignment: Alignment.centerLeft,
              child: entry.invoiceNumber != null
                  ? _buildCompactTag(
                      entry.invoiceNumber!,
                      backgroundColor: const Color(0xFFE8F5E9),
                      borderColor: const Color(0xFF81C784),
                      textColor: const Color(0xFF2D6A4F),
                      fontWeight: FontWeight.w500,
                      maxWidth: 68,
                    )
                  : _buildCompactTag(
                      'Advance',
                      backgroundColor: const Color(0xFFFFF8E1),
                      borderColor: const Color(0xFFFFB74D),
                      textColor: const Color(0xFFE65100),
                      fontWeight: FontWeight.w500,
                      maxWidth: 68,
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.zamindarName,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1B4332),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.kisaanName != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.kisaanName!,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF6B8F71),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              entry.itemsSummary.trim().isEmpty ? '—' : entry.itemsSummary.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontStyle:
                    entry.isAdvanceSummary ? FontStyle.italic : FontStyle.normal,
                color: entry.isAdvanceSummary
                    ? const Color(0xFF95B89A)
                    : const Color(0xFF6B8F71),
              ),
            ),
          ),
          SizedBox(
            width: 88,
            child: Text(
              '₨ ${_currencyFormat.format(entry.amountPaid)}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D6A4F),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isWallet
                      ? const Color(0xFFE3F2FD)
                      : entry.paymentMethod.toLowerCase() == 'cash'
                          ? const Color(0xFFFFF3E0)
                          : const Color(0xFFF3E5F5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isWallet
                        ? const Color(0xFF64B5F6)
                        : entry.paymentMethod.toLowerCase() == 'cash'
                            ? const Color(0xFFFFCC80)
                            : const Color(0xFFCE93D8),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  entry.paymentMethod,
                  textAlign: TextAlign.right,
                  softWrap: true,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: isWallet
                        ? const Color(0xFF1565C0)
                        : entry.paymentMethod.toLowerCase() == 'cash'
                            ? const Color(0xFFE65100)
                            : const Color(0xFF6A1B9A),
                  ),
                ),
              ),
            ),
          ),
          if (onEditPayment != null)
            SizedBox(
              width: 44,
              child: canEdit
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Tooltip(
                        message: 'Edit Payment',
                        child: InkWell(
                          onTap: () => onEditPayment!(entry),
                          borderRadius: BorderRadius.circular(7),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: const Color(0xFFC6DEC9),
                                width: 0.5,
                              ),
                            ),
                            child: const Icon(
                              Icons.edit_outlined,
                              size: 14,
                              color: Color(0xFF1B4332),
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }
}

/// Purchase Ledger matrix: Date, Invoice, Wholesaler, Products, Total, Terms.
class PurchaseLedgerTable extends StatelessWidget {
  final List<LedgerEntry> entries;
  final VoidCallback? onRefresh;

  const PurchaseLedgerTable({
    super.key,
    required this.entries,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.shopping_bag_outlined,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                'No Purchase Invoices Match the Selected Filters',
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: const BoxDecoration(
              color: Color(0xFFF7F9F4),
              border: Border(
                bottom: BorderSide(color: Color(0xFFE2EBE0), width: 0.5),
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: const Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    'DATE / TIME',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B8F71),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: Text(
                    'INVOICE',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B8F71),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: Text(
                    'WHOLESALER',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B8F71),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'PRODUCTS DETAILS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B8F71),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: Text(
                    'GRAND TOTAL',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B8F71),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    'TERMS',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF6B8F71),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => onRefresh?.call(),
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  return _buildRow(
                    entries[index],
                    index == entries.length - 1,
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            alignment: Alignment.centerLeft,
            child: Text(
              'Showing ${entries.length} purchase invoice${entries.length == 1 ? '' : 's'}'
              ' · ₨ ${_currencyFormat.format(entries.fold<double>(0, (s, e) => s + e.outstanding))} outstanding supplier debt',
              style: const TextStyle(fontSize: 11, color: Color(0xFF95B89A)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(LedgerEntry entry, bool isLast) {
    final terms = entry.purchaseTerms ??
        (entry.status == PaymentStatus.paid
            ? 'Cash'
            : entry.status == PaymentStatus.partial
                ? 'Partial'
                : 'Udhaar');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0xFFE2EBE0), width: 0.5),
              ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dateFormat.format(entry.date),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1B4332),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _timeFormat.format(entry.date),
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Color(0xFF95B89A),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              entry.invoiceNumber,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1B4332),
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              entry.stakeholderName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1B4332),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.ledgerSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF6B8F71),
                  ),
                ),
                if (entry.createdByUserName != null &&
                    entry.createdByUserName!.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Recorded By: ${entry.createdByUserName!.trim()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF95B89A),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              '₨ ${_currencyFormat.format(entry.total.round())}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1B4332),
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Center(child: _termsBadge(terms)),
          ),
        ],
      ),
    );
  }

  Widget _termsBadge(String terms) {
    late Color bg;
    late Color fg;
    switch (terms) {
      case 'Cash':
        bg = const Color(0xFFD8F3DC);
        fg = const Color(0xFF2D6A4F);
      case 'Partial':
        bg = const Color(0xFFFAEEDA);
        fg = const Color(0xFF633806);
      default:
        bg = const Color(0xFFFCEBEB);
        fg = const Color(0xFF791F1F);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        terms,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }
}
