import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Shared currency / date formatters for KPI drill-down dialogs.
class _KpiFmt {
  static final NumberFormat currency = NumberFormat('#,##,##0');
  static final DateFormat date = DateFormat('d MMM yyyy');

  static String rs(double amount) {
    final rounded = amount.round();
    final sign = rounded < 0 ? '-' : '';
    return '₨ $sign${currency.format(rounded.abs())}';
  }
}

// =============================================================================
// Receivables — You Will Get
// =============================================================================

Future<void> showReceivablesBreakdownDialog({
  required BuildContext context,
  required void Function(int zamindarId) onOpenZamindarLedger,
}) {
  return AppDialog.show<void>(
    context: context,
    title: 'You Will Get — Receivables',
    subtitle: 'Lene Hain (Zamindar Udhaar)',
    maxWidth: 760,
    content: _ReceivablesBreakdownBody(
      onOpenZamindarLedger: onOpenZamindarLedger,
    ),
  );
}

class _ReceivablesBreakdownBody extends StatefulWidget {
  const _ReceivablesBreakdownBody({required this.onOpenZamindarLedger});

  final void Function(int zamindarId) onOpenZamindarLedger;

  @override
  State<_ReceivablesBreakdownBody> createState() =>
      _ReceivablesBreakdownBodyState();
}

class _ReceivablesBreakdownBodyState extends State<_ReceivablesBreakdownBody> {
  bool _loading = true;
  String? _error;
  List<DashboardReceivableRow> _rows = const [];
  double _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await DatabaseHelper.instance.getReceivablesBreakdown();
      final total = rows.fold<double>(0, (s, r) => s + r.outstandingBalance);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _total = total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load receivables.\n$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DialogLoading();
    if (_error != null) return _DialogError(message: _error!);

    return SizedBox(
      height: 460,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryHeader(
            label: 'Total Receivables',
            amount: _total,
            accent: AppColors.mediumGreen,
            background: AppColors.tagGreenBg,
          ),
          const SizedBox(height: 10),
          const _FormulaCard(
            text: 'Sum of all positive Zamindar ledger balances '
                '(outstanding invoice dues after collections)',
          ),
          const SizedBox(height: 12),
          const _TableHeader(columns: [
            (flex: 32, label: 'ZAMINDAR'),
            (flex: 22, label: 'PHONE'),
            (flex: 22, label: 'LAST TXN'),
            (flex: 24, label: 'OUTSTANDING'),
          ]),
          const Divider(height: 1, thickness: 0.5, color: AppColors.border),
          Expanded(
            child: _rows.isEmpty
                ? const _EmptyList(text: 'No outstanding zamindar dues')
                : ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      thickness: 0.5,
                      color: Color(0xFFF0F4EE),
                    ),
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      final canOpen = row.zamindarId != null;
                      return _ClickableRow(
                        enabled: canOpen,
                        onTap: canOpen
                            ? () {
                                Navigator.of(context).pop();
                                widget.onOpenZamindarLedger(row.zamindarId!);
                              }
                            : null,
                        child: Row(
                          children: [
                            Expanded(
                              flex: 32,
                              child: Text(
                                row.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 22,
                              child: Text(
                                (row.phone?.isNotEmpty == true)
                                    ? row.phone!
                                    : '—',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 22,
                              child: Text(
                                row.lastTransactionAt == null
                                    ? '—'
                                    : _KpiFmt.date.format(row.lastTransactionAt!),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 24,
                              child: Text(
                                _KpiFmt.rs(row.outstandingBalance),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.mediumGreen,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Payables — You Will Give
// =============================================================================

Future<void> showPayablesBreakdownDialog({
  required BuildContext context,
  required void Function(int wholesalerId) onOpenWholesaler,
}) {
  return AppDialog.show<void>(
    context: context,
    title: 'You Will Give — Payables',
    subtitle: 'Dene Hain (Wholesalers / Suppliers)',
    maxWidth: 700,
    content: _PayablesBreakdownBody(onOpenWholesaler: onOpenWholesaler),
  );
}

class _PayablesBreakdownBody extends StatefulWidget {
  const _PayablesBreakdownBody({required this.onOpenWholesaler});

  final void Function(int wholesalerId) onOpenWholesaler;

  @override
  State<_PayablesBreakdownBody> createState() => _PayablesBreakdownBodyState();
}

class _PayablesBreakdownBodyState extends State<_PayablesBreakdownBody> {
  bool _loading = true;
  String? _error;
  List<DashboardPayableRow> _rows = const [];
  double _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await DatabaseHelper.instance.getPayablesBreakdown();
      final total = rows.fold<double>(0, (s, r) => s + r.pendingAmount);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _total = total;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load payables.\n$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DialogLoading();
    if (_error != null) return _DialogError(message: _error!);

    return SizedBox(
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryHeader(
            label: 'Total Payables',
            amount: _total,
            accent: const Color(0xFFA32D2D),
            background: AppColors.tagRedBg,
          ),
          const SizedBox(height: 10),
          const _FormulaCard(
            text: 'Sum of all outstanding Wholesaler / Supplier balances',
          ),
          const SizedBox(height: 12),
          const _TableHeader(columns: [
            (flex: 40, label: 'WHOLESALER / SUPPLIER'),
            (flex: 30, label: 'CONTACT'),
            (flex: 30, label: 'PENDING (₨)'),
          ]),
          const Divider(height: 1, thickness: 0.5, color: AppColors.border),
          Expanded(
            child: _rows.isEmpty
                ? const _EmptyList(text: 'No outstanding wholesaler dues')
                : ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      thickness: 0.5,
                      color: Color(0xFFF0F4EE),
                    ),
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      final canOpen = row.wholesalerId != null;
                      return _ClickableRow(
                        enabled: canOpen,
                        onTap: canOpen
                            ? () {
                                Navigator.of(context).pop();
                                widget.onOpenWholesaler(row.wholesalerId!);
                              }
                            : null,
                        child: Row(
                          children: [
                            Expanded(
                              flex: 40,
                              child: Text(
                                row.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 30,
                              child: Text(
                                (row.contact?.isNotEmpty == true)
                                    ? row.contact!
                                    : '—',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 30,
                              child: Text(
                                _KpiFmt.rs(row.pendingAmount),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFA32D2D),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Cash in Hand
// =============================================================================

Future<void> showCashInHandBreakdownDialog({
  required BuildContext context,
  required VoidCallback onViewCashLedger,
}) {
  return AppDialog.show<void>(
    context: context,
    title: 'Cash in Hand — Calculation',
    subtitle: 'Cash drawer flow breakdown',
    maxWidth: 640,
    content: _CashBreakdownBody(onViewCashLedger: onViewCashLedger),
  );
}

class _CashBreakdownBody extends StatefulWidget {
  const _CashBreakdownBody({required this.onViewCashLedger});

  final VoidCallback onViewCashLedger;

  @override
  State<_CashBreakdownBody> createState() => _CashBreakdownBodyState();
}

class _CashBreakdownBodyState extends State<_CashBreakdownBody> {
  bool _loading = true;
  String? _error;
  CashInHandBreakdown _data = CashInHandBreakdown.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await DatabaseHelper.instance.getCashInHandBreakdown();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load cash breakdown.\n$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DialogLoading();
    if (_error != null) return _DialogError(message: _error!);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryHeader(
          label: 'Current Cash in Hand',
          amount: _data.netCashInHand,
          accent: AppColors.tagBlueText,
          background: AppColors.tagBlueBg,
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              _CashLine(
                sign: '+',
                label: 'Opening Cash Balance',
                amount: _data.openingBalance,
              ),
              _CashLine(
                sign: '+',
                label: 'Cash Sales Received',
                amount: _data.cashSalesReceived,
              ),
              _CashLine(
                sign: '+',
                label: 'Zamindar Cash Recoveries',
                amount: _data.zamindarCashRecoveries,
              ),
              _CashLine(
                sign: '−',
                label: 'Expenses Paid',
                amount: _data.expensesPaid,
                negative: true,
              ),
              _CashLine(
                sign: '−',
                label: 'Wholesaler Cash Payments',
                amount: _data.wholesalerCashPayments,
                negative: true,
              ),
              _CashLine(
                sign: '−',
                label: 'Partner Drawings',
                amount: _data.partnerDrawingsNet,
                negative: true,
              ),
              if (_data.partnerDrawingsReturned > 0.005)
                Padding(
                  padding: const EdgeInsets.only(left: 28, bottom: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '(Taken ${_KpiFmt.rs(_data.partnerDrawingsTaken)} − '
                      'Returned ${_KpiFmt.rs(_data.partnerDrawingsReturned)})',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textHint,
                      ),
                    ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(height: 1, thickness: 0.5, color: AppColors.border),
              ),
              _CashLine(
                sign: '=',
                label: 'Net Cash in Hand',
                amount: _data.netCashInHand,
                emphasize: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: AppButton.primary(
            label: 'View Full Cash Ledger / Report',
            icon: Icons.menu_book_outlined,
            onPressed: () {
              Navigator.of(context).pop();
              widget.onViewCashLedger();
            },
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Shared UI pieces
// =============================================================================

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.label,
    required this.amount,
    required this.accent,
    required this.background,
  });

  final String label;
  final double amount;
  final Color accent;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
          Text(
            _KpiFmt.rs(amount),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormulaCard extends StatelessWidget {
  const _FormulaCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.functions, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.columns});

  final List<({int flex, String label})> columns;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          for (final col in columns)
            Expanded(
              flex: col.flex,
              child: Text(
                col.label,
                textAlign: col.label.contains('OUTSTANDING') ||
                        col.label.contains('PENDING') ||
                        col.label.contains('AMOUNT') ||
                        col.label.contains('REVENUE') ||
                        col.label.contains('COGS') ||
                        col.label.contains('MARGIN')
                    ? TextAlign.right
                    : TextAlign.left,
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ClickableRow extends StatefulWidget {
  const _ClickableRow({
    required this.child,
    required this.enabled,
    this.onTap,
  });

  final Widget child;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  State<_ClickableRow> createState() => _ClickableRowState();
}

class _ClickableRowState extends State<_ClickableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => _hovered = false) : null,
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Material(
        color: _hovered ? const Color(0xFFF0F7EB) : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _CashLine extends StatelessWidget {
  const _CashLine({
    required this.sign,
    required this.label,
    required this.amount,
    this.negative = false,
    this.emphasize = false,
    this.emphasizeColor,
  });

  final String sign;
  final String label;
  final double amount;
  final bool negative;
  final bool emphasize;
  final Color? emphasizeColor;

  @override
  Widget build(BuildContext context) {
    final color = emphasize
        ? (emphasizeColor ?? AppColors.tagBlueText)
        : (negative ? const Color(0xFFA32D2D) : AppColors.textPrimary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              sign,
              style: TextStyle(
                fontSize: emphasize ? 14 : 13,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: emphasize ? 13 : 12,
                fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ),
          Text(
            _KpiFmt.rs(amount),
            style: TextStyle(
              fontSize: emphasize ? 14 : 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogLoading extends StatelessWidget {
  const _DialogLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 180,
      child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
    );
  }
}

class _DialogError extends StatelessWidget {
  const _DialogError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        message,
        style: const TextStyle(fontSize: 12.5, color: Color(0xFFA32D2D)),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
      ),
    );
  }
}

// =============================================================================
// Reports — Net Profit / P&L Audit
// =============================================================================

Future<void> showNetProfitAuditDialog({
  required BuildContext context,
  String? season,
}) {
  return AppDialog.show<void>(
    context: context,
    title: 'Net Profit Audit & Calculation',
    subtitle: 'Seasonal Profit & Loss breakdown',
    maxWidth: 760,
    content: _NetProfitAuditBody(season: season),
  );
}

class _NetProfitAuditBody extends StatefulWidget {
  const _NetProfitAuditBody({this.season});

  final String? season;

  @override
  State<_NetProfitAuditBody> createState() => _NetProfitAuditBodyState();
}

class _NetProfitAuditBodyState extends State<_NetProfitAuditBody> {
  bool _loading = true;
  String? _error;
  ProfitAndLossBreakdown _data = ProfitAndLossBreakdown.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await DatabaseHelper.instance.getProfitAndLossBreakdown(
        season: widget.season,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load P&L audit.\n$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DialogLoading();
    if (_error != null) return _DialogError(message: _error!);

    final margin = _data.profitMargin;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryHeader(
          label: _data.season.isEmpty
              ? 'Final Net Profit'
              : 'Final Net Profit · ${_data.season}',
          amount: _data.netProfit,
          accent: AppColors.mediumGreen,
          background: AppColors.tagGreenBg,
        ),
        const SizedBox(height: 8),
        Text(
          'Profit margin: ${margin.toStringAsFixed(1)}% of revenue',
          style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
        ),
        const SizedBox(height: 10),
        const _FormulaCard(
          text:
              'Net Profit = (Gross Revenue + Seasonal Increments) − '
              '(COGS / Purchase Cost + Total Discounts Given + General Expenses)',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              _CashLine(
                sign: '+',
                label: 'Gross Sales Revenue',
                amount: _data.grossSalesRevenue,
              ),
              _CashLine(
                sign: '+',
                label: 'Total Seasonal Increments Collected',
                amount: _data.seasonalIncrements,
              ),
              _CashLine(
                sign: '−',
                label: 'Cost of Goods Sold (COGS)',
                amount: _data.cogs,
                negative: true,
              ),
              _CashLine(
                sign: '−',
                label: 'Item & Cart Discounts Granted',
                amount: _data.totalDiscounts,
                negative: true,
              ),
              _CashLine(
                sign: '−',
                label: 'Total Shop Expenses',
                amount: _data.shopExpenses,
                negative: true,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: AppColors.border,
                ),
              ),
              _CashLine(
                sign: '=',
                label: 'Final Net Profit',
                amount: _data.netProfit,
                emphasize: true,
                emphasizeColor: AppColors.mediumGreen,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Top profitable products',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const _TableHeader(columns: [
          (flex: 40, label: 'PRODUCT'),
          (flex: 20, label: 'REVENUE'),
          (flex: 20, label: 'COGS'),
          (flex: 20, label: 'MARGIN'),
        ]),
        const Divider(height: 1, thickness: 0.5, color: AppColors.border),
        if (_data.topProducts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: _EmptyList(text: 'No product margin data this season'),
          )
        else
          for (var i = 0; i < _data.topProducts.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 0.5,
                color: Color(0xFFF0F4EE),
              ),
            _ProductProfitRowView(row: _data.topProducts[i]),
          ],
      ],
    );
  }
}

class _ProductProfitRowView extends StatelessWidget {
  const _ProductProfitRowView({required this.row});

  final ProductProfitRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 40,
            child: Text(
              row.productName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 20,
            child: Text(
              _KpiFmt.rs(row.revenue),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            flex: 20,
            child: Text(
              _KpiFmt.rs(row.cogs),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            flex: 20,
            child: Text(
              _KpiFmt.rs(row.margin),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.mediumGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Reports — Revenue & Sales Type
// =============================================================================

Future<void> showRevenueBreakdownDialog({
  required BuildContext context,
  String? season,
  VoidCallback? onViewSalesLedger,
}) {
  return AppDialog.show<void>(
    context: context,
    title: 'Revenue & Sales Type Breakdown',
    subtitle: 'Cash vs Credit (Udhaar) split',
    maxWidth: 640,
    content: _RevenueBreakdownBody(
      season: season,
      onViewSalesLedger: onViewSalesLedger,
    ),
  );
}

class _RevenueBreakdownBody extends StatefulWidget {
  const _RevenueBreakdownBody({
    this.season,
    this.onViewSalesLedger,
  });

  final String? season;
  final VoidCallback? onViewSalesLedger;

  @override
  State<_RevenueBreakdownBody> createState() => _RevenueBreakdownBodyState();
}

class _RevenueBreakdownBodyState extends State<_RevenueBreakdownBody> {
  bool _loading = true;
  String? _error;
  ProfitAndLossBreakdown _data = ProfitAndLossBreakdown.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await DatabaseHelper.instance.getProfitAndLossBreakdown(
        season: widget.season,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load revenue breakdown.\n$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DialogLoading();
    if (_error != null) return _DialogError(message: _error!);

    final cashPct = _data.totalRevenue > 0
        ? (_data.cashSales / _data.totalRevenue) * 100.0
        : 0.0;
    final creditPct = _data.totalRevenue > 0
        ? (_data.creditSales / _data.totalRevenue) * 100.0
        : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryHeader(
          label: _data.season.isEmpty
              ? 'Total Revenue / Sales'
              : 'Total Revenue · ${_data.season}',
          amount: _data.totalRevenue,
          accent: AppColors.mediumGreen,
          background: AppColors.tagGreenBg,
        ),
        const SizedBox(height: 10),
        const _FormulaCard(
          text:
              'Total Revenue = Cash Sales + Credit (Udhaar) Sales '
              '(product invoices only; advances excluded)',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              _CashLine(
                sign: '•',
                label: 'Cash Sales (${cashPct.toStringAsFixed(0)}%)',
                amount: _data.cashSales,
              ),
              _CashLine(
                sign: '•',
                label: 'Credit / Udhaar Sales (${creditPct.toStringAsFixed(0)}%)',
                amount: _data.creditSales,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: AppColors.border,
                ),
              ),
              _CashLine(
                sign: '=',
                label: 'Total Revenue',
                amount: _data.totalRevenue,
                emphasize: true,
                emphasizeColor: AppColors.mediumGreen,
              ),
              const SizedBox(height: 6),
              _CashLine(
                sign: '+',
                label: '  of which Seasonal Increments',
                amount: _data.seasonalIncrements,
              ),
              _CashLine(
                sign: '−',
                label: '  Discounts Granted',
                amount: _data.totalDiscounts,
                negative: true,
              ),
            ],
          ),
        ),
        if (widget.onViewSalesLedger != null) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton.primary(
              label: 'View All Sales Transactions',
              icon: Icons.receipt_long_outlined,
              onPressed: () {
                Navigator.of(context).pop();
                widget.onViewSalesLedger!();
              },
            ),
          ),
        ],
      ],
    );
  }
}

// =============================================================================
// Reports — Inventory Purchases
// =============================================================================

Future<void> showPurchasesBreakdownDialog({
  required BuildContext context,
  String? season,
}) {
  return AppDialog.show<void>(
    context: context,
    title: 'Inventory Purchases Summary',
    subtitle: 'Cash vs Credit + stock by category',
    maxWidth: 640,
    content: _PurchasesBreakdownBody(season: season),
  );
}

class _PurchasesBreakdownBody extends StatefulWidget {
  const _PurchasesBreakdownBody({this.season});

  final String? season;

  @override
  State<_PurchasesBreakdownBody> createState() =>
      _PurchasesBreakdownBodyState();
}

class _PurchasesBreakdownBodyState extends State<_PurchasesBreakdownBody> {
  bool _loading = true;
  String? _error;
  PurchasesBreakdown _data = PurchasesBreakdown.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await DatabaseHelper.instance.getPurchasesBreakdown(
        season: widget.season,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load purchases summary.\n$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _DialogLoading();
    if (_error != null) return _DialogError(message: _error!);

    final cashPct = _data.totalPurchases > 0
        ? (_data.cashPurchases / _data.totalPurchases) * 100.0
        : 0.0;
    final creditPct = _data.totalPurchases > 0
        ? (_data.creditPurchases / _data.totalPurchases) * 100.0
        : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryHeader(
          label: _data.season.isEmpty
              ? 'Total Purchases'
              : 'Total Purchases · ${_data.season}',
          amount: _data.totalPurchases,
          accent: const Color(0xFFA32D2D),
          background: AppColors.tagRedBg,
        ),
        const SizedBox(height: 10),
        const _FormulaCard(
          text:
              'Purchase invoices this season — cash settlements vs wholesaler '
              'credit, plus stock additions by product category',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            children: [
              _CashLine(
                sign: '•',
                label: 'Cash Purchases (${cashPct.toStringAsFixed(0)}%)',
                amount: _data.cashPurchases,
              ),
              _CashLine(
                sign: '•',
                label: 'Credit Purchases (${creditPct.toStringAsFixed(0)}%)',
                amount: _data.creditPurchases,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Divider(
                  height: 1,
                  thickness: 0.5,
                  color: AppColors.border,
                ),
              ),
              _CashLine(
                sign: '=',
                label: 'Total Purchases',
                amount: _data.totalPurchases,
                emphasize: true,
                emphasizeColor: const Color(0xFFA32D2D),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Stock additions by category',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const _TableHeader(columns: [
          (flex: 60, label: 'CATEGORY'),
          (flex: 40, label: 'AMOUNT (₨)'),
        ]),
        const Divider(height: 1, thickness: 0.5, color: AppColors.border),
        if (_data.byCategory.every((c) => c.amount <= 0.005))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: _EmptyList(text: 'No purchase line items this season'),
          )
        else
          for (var i = 0; i < _data.byCategory.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 0.5,
                color: Color(0xFFF0F4EE),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    flex: 60,
                    child: Text(
                      _data.byCategory[i].category,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 40,
                    child: Text(
                      _KpiFmt.rs(_data.byCategory[i].amount),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
      ],
    );
  }
}

