import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/partner_model.dart';
import 'package:agrikhata/screens/partners/dialogs/seasonal_settlement_dialog.dart';
import 'package:agrikhata/services/partner_accounting_service.dart';
import 'package:agrikhata/services/user_account_store.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Partner Equity & Profit Management dashboard.
class PartnerManagementScreen extends StatefulWidget {
  const PartnerManagementScreen({super.key});

  @override
  State<PartnerManagementScreen> createState() =>
      _PartnerManagementScreenState();
}

class _PartnerManagementScreenState extends State<PartnerManagementScreen> {
  static final NumberFormat _currency = NumberFormat('#,##,##0');
  final PartnerAccountingService _svc = PartnerAccountingService.instance;

  int _tab = 0;
  bool _loading = true;
  String? _error;

  List<PartnerModel> _partners = [];
  List<InvoiceMarginSplitRow> _invoiceSplits = [];
  List<PartnerTransactionModel> _reinvestTx = [];
  List<PartnerTransactionModel> _injectionTx = [];
  List<OverheadSplitRow> _overheadRows = [];
  List<PartnerDrawingModel> _drawings = [];
  Map<String, String> _zamindarNames = {};
  double _seasonAdjustmentsYield = 0;
  double _discountsAbsorbed = 0;

  static const _headerBg = Color(0xFFEEF3EC);
  static const _headerBorder = Color(0xFFDCE6D9);
  static const _debtRed = Color(0xFFA32D2D);
  static const _btnGreen = Color(0xFF2D6A4F);
  static const _btnBlue = Color(0xFF1D3557);
  static const _btnAmber = Color(0xFFE07A5F);
  static const _equityColors = [
    Color(0xFF2D6A4F),
    Color(0xFF0C447C),
    Color(0xFF9C6644),
    Color(0xFF6B2D5C),
  ];

  @override
  void initState() {
    super.initState();
    UserAccountStore.instance.refresh();
    _load();
    DatabaseHelper.instance.addListener(_onDb);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDb);
    super.dispose();
  }

  void _onDb() {
    if (mounted) _load(silent: true);
  }

  String _pkr(num n) => '₨ ${_currency.format(n.round())}';

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final partners = await _svc.getActivePartners();
      final splits = await _svc.getInvoiceMarginSplits();
      final reinvest = await _svc.getTransactions(
        type: PartnerTransactionType.profitReinvestment,
      );
      final inject = await _svc.getTransactions(
        type: PartnerTransactionType.capitalInjection,
      );
      final overhead = await _svc.getOverheadSplitRows();
      final drawings = await _svc.getDrawings();
      final zamindars = await DatabaseHelper.instance.getAllZamindars();
      final adjustments =
          await DatabaseHelper.instance.getProductSaleAdjustmentTotals();
      if (!mounted) return;
      setState(() {
        _partners = partners;
        _invoiceSplits = splits;
        _reinvestTx = reinvest;
        _injectionTx = inject;
        _overheadRows = overhead;
        _drawings = drawings;
        _zamindarNames = {
          for (final z in zamindars)
            if (z.id != null) z.id.toString(): z.name,
        };
        _seasonAdjustmentsYield = adjustments['seasonalIncrements'] ?? 0;
        _discountsAbsorbed = adjustments['totalDiscounts'] ?? 0;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Color _eqColor(int i) => _equityColors[i % _equityColors.length];

  Future<void> _needPartners(Future<bool?> Function() open) async {
    if (_partners.isEmpty) {
      AppToast.showWarning(context, 'Add an active partner first');
      return;
    }
    final ok = await open();
    if (ok == true && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: const TextStyle(color: AppColors.error),
                        ),
                      )
                    : _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: _headerBg,
        border: Border(bottom: BorderSide(color: _headerBorder, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Partner Equity & Profit Management',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Track capital, reinvestment, drawings, and profit share across partners',
            style: TextStyle(fontSize: 11.5, color: Color(0xFF5C8468)),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              _hdrBtn(
                'Add Partner',
                Icons.person_add_alt_1,
                AppColors.primary,
                outline: true,
                onTap: () async {
                  final ok = await _showAddPartnerDialog();
                  if (ok == true && mounted) {
                    await _load();
                    if (mounted) {
                      AppToast.showSuccess(context, 'Partner capital added');
                    }
                  }
                },
              ),
              _hdrBtn(
                'Out-of-Pocket Investment',
                Icons.add,
                _btnGreen,
                onTap: () => _needPartners(() async {
                  final ok = await _showInjectDialog();
                  if (ok == true && mounted) {
                    AppToast.showSuccess(context, 'Capital injected');
                  }
                  return ok;
                }),
              ),
              _hdrBtn(
                'Reinvest Retained Profit',
                Icons.sync,
                _btnBlue,
                onTap: () => _needPartners(() async {
                  final ok = await _showReinvestDialog();
                  if (ok == true && mounted) {
                    AppToast.showSuccess(context, 'Profit reinvested');
                  }
                  return ok;
                }),
              ),
              _hdrBtn(
                'Record Cash Drawing',
                Icons.payments_outlined,
                _btnAmber,
                onTap: () => _needPartners(() async {
                  final ok = await _showDrawingDialog();
                  if (ok == true && mounted) {
                    AppToast.showSuccess(context, 'Cash drawing recorded');
                  }
                  return ok;
                }),
              ),
              _hdrBtn(
                'Seasonal Settlement',
                Icons.balance,
                AppColors.primary,
                onTap: () => _needPartners(() async {
                  final ok = await _showSettlementDialog();
                  if (ok == true && mounted) {
                    AppToast.showSuccess(context, 'Seasonal settlement applied');
                  }
                  return ok;
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hdrBtn(
    String label,
    IconData icon,
    Color color, {
    required VoidCallback onTap,
    bool outline = false,
  }) {
    return Material(
      color: outline ? Colors.white : color,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: outline
                ? Border.all(color: const Color(0xFFC6DEC9), width: 0.5)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: outline ? color : Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: outline ? color : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final totalEq = _svc.totalBusinessEquity(_partners);
    final drawings = _svc.totalActiveDrawings(_partners);
    final unsettled = _partners.fold<double>(0, (s, p) => s + p.unsettledProfit);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _kpiGrid(totalEq, drawings, unsettled),
          const SizedBox(height: 18),
          const Text(
            'Active Partner Balances & Profit Distribution',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          _partnersTable(totalEq),
          const SizedBox(height: 20),
          _lowerTabs(),
        ],
      ),
    );
  }

  Widget _kpiGrid(double totalEq, double drawings, double unsettled) {
    final cards = <Widget>[
      _kpi('Total Business Equity', _pkr(totalEq),
          'Across ${_partners.length} partners'),
      for (var i = 0; i < _partners.length; i++)
        _kpi(
          '${_partners[i].name} Equity',
          _pkr(_partners[i].totalEquity),
          '${_svc.partnerEquitySharePct(_partners[i], _partners).toStringAsFixed(0)}% Net Equity Share',
          subColor: _eqColor(i),
          boldSub: true,
        ),
      _kpi('Active Cash Drawings Debt', _pkr(drawings), 'Pending settlement',
          valueColor: _debtRed),
      _kpi('Unsettled Profit Pool', _pkr(unsettled), 'Available to reinvest',
          subColor: _btnBlue),
      _kpi(
        'Total Season Adjustments Yield',
        _pkr(_seasonAdjustmentsYield),
        'Seasonal increments collected on sales',
        subColor: const Color(0xFF0C447C),
      ),
      _kpi(
        'Total Discounts Absorbed',
        _pkr(_discountsAbsorbed),
        'Item + overall discounts conceded',
        valueColor: const Color(0xFF28A745),
      ),
      _kpi(
        'Net Partner Distributable Equity',
        _pkr(unsettled),
        'After seasonal yield & discounts in net profit',
        subColor: _btnGreen,
        boldSub: true,
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 1100 ? 4 : (c.maxWidth >= 700 ? 2 : 1);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: cols == 1 ? 3.2 : 2.35,
          children: cards,
        );
      },
    );
  }

  Widget _kpi(
    String label,
    String value,
    String sub, {
    Color? valueColor,
    Color? subColor,
    bool boldSub = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B8F71),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: valueColor ?? AppColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: boldSub ? FontWeight.w600 : FontWeight.w400,
              color: subColor ?? AppColors.textHint,
            ),
          ),
        ],
      ),
    );
  }

  Widget _partnersTable(double totalEq) {
    if (_partners.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: const Center(
          child: Text(
            'No active partners yet. Use “Add Partner” to get started.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    return AppDataTable(
      minWidth: 1100,
      columns: const [
        AppDataColumn(title: 'Partner Name', flex: 14),
        AppDataColumn(title: 'Linked Accounts', flex: 14),
        AppDataColumn(title: 'Initial Capital', flex: 10),
        AppDataColumn(title: 'Out-of-Pocket', flex: 10),
        AppDataColumn(title: 'Reinvested Profit', flex: 10),
        AppDataColumn(title: 'Cash Drawings', flex: 10),
        AppDataColumn(title: 'Unsettled Profit', flex: 10),
        AppDataColumn(title: 'Net Equity Share %', flex: 12),
        AppDataColumn(title: 'Actions', flex: 10),
      ],
      rows: [
        for (var i = 0; i < _partners.length; i++)
          _partnerRow(_partners[i], i, totalEq),
      ],
    );
  }

  AppDataRow _partnerRow(PartnerModel p, int i, double totalEq) {
    final pct = p.equityPercentage(totalEq);
    final user = UserAccountStore.instance.findById(p.userAccountId);
    final zName = p.zamindarId == null ? null : _zamindarNames[p.zamindarId!];
    final color = _eqColor(i);

    return AppDataRow(
      cells: [
        AppTableCellText(
          p.name,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
            color: AppColors.primary,
          ),
        ),
        _linkedBadges(user?.name, zName),
        AppTableCellText(_pkr(p.initialCapital)),
        AppTableCellText(_pkr(p.outOfPocketInjections)),
        AppTableCellText(_pkr(p.reinvestedProfit)),
        AppTableCellText(
          _pkr(p.totalDrawings),
          style: TextStyle(
            fontSize: 12.5,
            color: p.totalDrawings > 0 ? _debtRed : AppColors.textPrimary,
          ),
        ),
        AppTableCellText(_pkr(p.unsettledProfit)),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: (pct / 100).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: const Color(0xFFE2EBE0),
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${pct.toStringAsFixed(0)}%',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
        _outlineBtn('Edit Equity', Icons.edit_outlined, () async {
          final ok = await _showEditDialog(p);
          if (ok == true && mounted) {
            await _load();
            if (mounted) {
              AppToast.showSuccess(context, 'Partner equity updated');
            }
          }
        }),
      ],
    );
  }

  Widget _linkedBadges(String? user, String? zamindar) {
    if (user == null && zamindar == null) {
      return const Text('—', style: TextStyle(color: AppColors.textHint));
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (user != null)
          _chip(user, AppColors.tagBlueBg, AppColors.tagBlueText,
              Icons.manage_accounts_outlined),
        if (zamindar != null)
          _chip(zamindar, AppColors.tagGreenBg, AppColors.tagGreenText,
              Icons.agriculture_outlined),
      ],
    );
  }

  Widget _chip(String label, Color bg, Color fg, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }

  Widget _outlineBtn(String label, IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: const Color(0xFFC6DEC9), width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: AppColors.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lowerTabs() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _tabBtn(0, 'Invoice Profit Margin Splits'),
                _tabBtn(1, 'Overhead Expenses Split (50-50 Ledger)'),
                _tabBtn(2, 'Counter Cash Drawing Ledger'),
                _tabBtn(3, 'History of Reinvested Profit'),
                _tabBtn(4, 'Out-of-Pocket Investments'),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          ExcludeSemantics(
            child: switch (_tab) {
              0 => _invoiceTab(),
              1 => _overheadTab(),
              2 => _drawingsTab(),
              3 => _reinvestTab(),
              _ => _injectionTab(),
            },
          ),
        ],
      ),
    );
  }

  Widget _tabBtn(int i, String label) {
    final sel = _tab == i;
    return InkWell(
      onTap: () => setState(() => _tab = i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: sel ? AppColors.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: sel ? AppColors.primary : AppColors.textHint,
          ),
        ),
      ),
    );
  }

  Widget _invoiceTab() {
    if (_invoiceSplits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No sales invoices yet for margin split.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }
    return AppDataTable(
      showCardChrome: false,
      margin: EdgeInsets.zero,
      minWidth: 980,
      columns: [
        const AppDataColumn(title: 'Invoice # & Date', flex: 16),
        const AppDataColumn(title: 'Customer / Zamindar', flex: 14),
        const AppDataColumn(title: 'Invoice Amount', flex: 11),
        const AppDataColumn(title: 'Total COGS', flex: 10),
        const AppDataColumn(title: 'Net Sale Margin', flex: 11),
        for (final p in _partners)
          AppDataColumn(title: '${p.name} Share', flex: 11),
        const AppDataColumn(title: 'Action', flex: 12),
      ],
      rows: [
        for (final r in _invoiceSplits)
          AppDataRow(
            cells: [
              AppTableCellText(
                '${r.invoiceNumber} | ${DateFormat('dd-MMM-yyyy').format(r.date)}',
              ),
              AppTableCellText(r.customerName),
              AppTableCellText(_pkr(r.invoiceAmount)),
              AppTableCellText(_pkr(r.cogs)),
              AppTableCellText(
                _pkr(r.netMargin),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: r.netMargin >= 0
                      ? AppColors.mediumGreen
                      : _debtRed,
                ),
              ),
              for (final p in _partners)
                AppTableCellText(_pkr(r.shareByPartnerId[p.id] ?? 0)),
              _outlineBtn('View Split', Icons.visibility_outlined, () {
                _showSplitBreakdown(r);
              }),
            ],
          ),
      ],
    );
  }

  Future<void> _showSplitBreakdown(InvoiceMarginSplitRow row) async {
    await AppDialog.show(
      context: context,
      title: 'Split Breakdown — ${row.invoiceNumber}',
      maxWidth: 560,
      content: SizedBox(
        height: 340,
        width: double.infinity,
        child: ListView(
          children: [
            Text(
              '${row.customerName} · ${_pkr(row.invoiceAmount)} invoice · '
              'COGS ${_pkr(row.cogs)} · Margin ${_pkr(row.netMargin)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            const Text(
              'Partner shares (by Net Equity %)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
            ),
            const SizedBox(height: 6),
            for (final p in _partners)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p.name),
                subtitle: Text(
                  '${(row.equityPctByPartnerId[p.id] ?? 0).toStringAsFixed(1)}% equity',
                ),
                trailing: Text(
                  _pkr(row.shareByPartnerId[p.id] ?? 0),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            const Divider(),
            const Text(
              'Line items',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
            ),
            for (final item in row.items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item[SaleItemsTable.productName]?.toString() ?? 'Item',
                  style: const TextStyle(fontSize: 12.5),
                ),
                subtitle: Text(
                  'Qty ${item[SaleItemsTable.quantity]} × '
                  '${_pkr((item[SaleItemsTable.unitPrice] as num?) ?? 0)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textHint),
                ),
                trailing: Text(
                  _pkr((item[SaleItemsTable.subtotal] as num?) ?? 0),
                ),
              ),
          ],
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'Close',
          icon: Icons.close,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _overheadTab() {
    if (_overheadRows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No overhead expenses this month (Shop Rent, Electricity, Salaries).',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppDataTable(
          showCardChrome: false,
          margin: EdgeInsets.zero,
          minWidth: 720,
          columns: [
            const AppDataColumn(title: 'Expense Category', flex: 22),
            const AppDataColumn(title: 'Total Amount', flex: 14),
            for (final p in _partners)
              AppDataColumn(title: '${p.name} Share', flex: 16),
            const AppDataColumn(title: 'Date', flex: 14),
          ],
          rows: [
            for (final row in _overheadRows)
              AppDataRow(
                cells: [
                  AppTableCellText(
                    row.expense.category,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12.5,
                    ),
                  ),
                  AppTableCellText(_pkr(row.expense.amount)),
                  for (final p in _partners)
                    AppTableCellText(
                      _pkr(row.shareByPartnerId[p.id] ?? 0),
                    ),
                  AppTableCellText(
                    DateFormat('dd-MMM-yyyy').format(row.expense.expenseDate),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textHint,
                    ),
                  ),
                ],
              ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            'Overheads are split automatically equally between active partners regardless of equity ratio, per store policy.',
            style: TextStyle(fontSize: 11, color: AppColors.textHint),
          ),
        ),
      ],
    );
  }

  Widget _drawingsTab() {
    if (_drawings.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No cash drawings recorded yet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }

    final nameById = {for (final p in _partners) p.id: p.name};

    return AppDataTable(
      showCardChrome: false,
      margin: EdgeInsets.zero,
      minWidth: 800,
      columns: const [
        AppDataColumn(title: 'Date', flex: 14),
        AppDataColumn(title: 'Partner Name', flex: 18),
        AppDataColumn(title: 'Amount', flex: 12),
        AppDataColumn(title: 'Type', flex: 12),
        AppDataColumn(title: 'Status', flex: 12),
        AppDataColumn(title: 'Recorded By', flex: 14),
        AppDataColumn(title: 'Action', flex: 16),
      ],
      rows: [
        for (final d in _drawings)
          AppDataRow(
            cells: [
              AppTableCellText(
                DateFormat('dd-MMM-yyyy').format(d.date),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textHint,
                ),
              ),
              AppTableCellText(
                nameById[d.partnerId] ?? 'Partner #${d.partnerId}',
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 12.5,
                ),
              ),
              AppTableCellText(
                _pkr(d.amount),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  color: d.isTaken ? _debtRed : AppColors.mediumGreen,
                ),
              ),
              AppTableCellText(d.type),
              _statusChip(d.isSettled),
              AppTableCellText(
                d.createdByUserName.trim().isEmpty
                    ? '—'
                    : d.createdByUserName.trim(),
              ),
              d.isSettled
                  ? const Text(
                      '✓ Settled',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textHint,
                      ),
                    )
                  : Material(
                      color: AppColors.tagGreenBg,
                      borderRadius: BorderRadius.circular(7),
                      child: InkWell(
                        onTap: () async {
                          await _svc.settleDrawing(d.id);
                          await _load(silent: true);
                          if (!mounted) return;
                          AppToast.showSuccess(
                            context,
                            'Drawing marked as settled',
                          );
                        },
                        borderRadius: BorderRadius.circular(7),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5,
                          ),
                          child: Text(
                            'Mark as Settled',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.tagGreenText,
                            ),
                          ),
                        ),
                      ),
                    ),
            ],
          ),
      ],
    );
  }

  Widget _statusChip(bool settled) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: settled ? AppColors.tagGreenBg : AppColors.tagAmberBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        settled ? 'Settled' : 'Pending',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: settled ? AppColors.tagGreenText : AppColors.tagAmberText,
        ),
      ),
    );
  }

  Widget _reinvestTab() {
    if (_reinvestTx.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No reinvestment history yet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }
    final names = {for (final p in _partners) p.id: p.name};
    return AppDataTable(
      showCardChrome: false,
      margin: EdgeInsets.zero,
      minWidth: 900,
      columns: const [
        AppDataColumn(title: 'Date & Time', flex: 16),
        AppDataColumn(title: 'Partner Name', flex: 14),
        AppDataColumn(title: 'Reinvested Amount', flex: 12),
        AppDataColumn(title: 'Equity % Change', flex: 16),
        AppDataColumn(title: 'Settlement Cycle', flex: 14),
        AppDataColumn(title: 'Notes', flex: 14),
      ],
      rows: [
        for (final t in _reinvestTx)
          AppDataRow(
            cells: [
              AppTableCellText(
                DateFormat('dd-MMM-yyyy · hh:mm a').format(t.date),
                style: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
              ),
              AppTableCellText(names[t.partnerId] ?? 'Partner #${t.partnerId}'),
              AppTableCellText(_pkr(t.amount)),
              AppTableCellText(
                '${(t.equityPctBefore ?? 0).toStringAsFixed(1)}% → '
                '${(t.equityPctAfter ?? 0).toStringAsFixed(1)}%',
              ),
              AppTableCellText(t.seasonLabel ?? t.reference ?? '—'),
              AppTableCellText(t.notes?.isNotEmpty == true ? t.notes! : '—'),
            ],
          ),
      ],
    );
  }

  Widget _injectionTab() {
    if (_injectionTx.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No out-of-pocket investments recorded yet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }
    final names = {for (final p in _partners) p.id: p.name};
    return AppDataTable(
      showCardChrome: false,
      margin: EdgeInsets.zero,
      minWidth: 980,
      columns: const [
        AppDataColumn(title: 'Date & Time', flex: 14),
        AppDataColumn(title: 'Partner Name', flex: 12),
        AppDataColumn(title: 'Capital Injected', flex: 11),
        AppDataColumn(title: 'Payment Channel', flex: 16),
        AppDataColumn(title: 'Updated Equity %', flex: 11),
        AppDataColumn(title: 'Reference / Receipt #', flex: 12),
        AppDataColumn(title: 'Recorded By', flex: 12),
      ],
      rows: [
        for (final t in _injectionTx)
          AppDataRow(
            cells: [
              AppTableCellText(
                DateFormat('dd-MMM-yyyy · hh:mm a').format(t.date),
                style: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
              ),
              AppTableCellText(names[t.partnerId] ?? 'Partner #${t.partnerId}'),
              AppTableCellText(_pkr(t.amount)),
              AppTableCellText(t.paymentChannel ?? '—'),
              AppTableCellText(
                '${(t.equityPctAfter ?? 0).toStringAsFixed(1)}%',
              ),
              AppTableCellText(t.reference ?? '—'),
              AppTableCellText(
                t.createdByUserName.trim().isEmpty
                    ? '—'
                    : t.createdByUserName.trim(),
              ),
            ],
          ),
      ],
    );
  }

  // ── Dialogs ────────────────────────────────────────────────────────────

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.inputBorder, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.inputBorder, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: AppColors.accentGreen, width: 1.2),
        ),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Text(
          t,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6B8F71),
          ),
        ),
      );

  String? _safeDd(String? v, List<DropdownMenuItem<String?>> items) {
    if (v == null) return null;
    return items.where((i) => i.value == v).length == 1 ? v : null;
  }

  Future<DateTime?> _pickDt(DateTime current) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: current.isAfter(now) ? now : current,
      firstDate: DateTime(2020),
      lastDate: now,
      builder: (c, child) => Theme(
        data: Theme.of(c).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            onSurface: AppColors.textPrimary,
          ),
        ),
        child: child!,
      ),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      builder: (c, child) => Theme(
        data: Theme.of(c).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            onSurface: AppColors.textPrimary,
          ),
        ),
        child: child!,
      ),
    );
    if (t == null || !mounted) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Widget _dtField(DateTime value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: _dec('Select date & time').copyWith(
          suffixIcon: const Icon(Icons.calendar_month_outlined, size: 18),
        ),
        child: Text(
          DateFormat('dd-MMM-yyyy · hh:mm a').format(value),
          style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
        ),
      ),
    );
  }

  Future<bool?> _showInjectDialog() {
    final formKey = GlobalKey<FormState>();
    final amountCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var partnerId = _partners.first.id;
    var source = PartnerCapitalPaymentSource.shopCounterCashDeposit;
    var dt = DateTime.now();
    var saving = false;

    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AppDialog(
          title: 'Inject Out-of-Pocket Capital',
          onClose: () => Navigator.pop(ctx, false),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label('Date / Time'),
                _dtField(dt, () async {
                  final p = await _pickDt(dt);
                  if (p != null) setLocal(() => dt = p);
                }),
                const SizedBox(height: 12),
                _label('Partner'),
                DropdownButtonFormField<String>(
                  initialValue: partnerId,
                  decoration: _dec('Partner'),
                  items: _partners
                      .map((p) =>
                          DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setLocal(() => partnerId = v);
                  },
                ),
                const SizedBox(height: 12),
                _label('Amount (PKR)'),
                TextFormField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _dec('e.g. 100000'),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    if (n == null || n <= 0) return 'Enter a valid amount';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _label('Payment Source'),
                DropdownButtonFormField<String>(
                  initialValue: source,
                  decoration: _dec('Source'),
                  items: PartnerCapitalPaymentSource.all
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setLocal(() => source = v);
                  },
                ),
                const SizedBox(height: 12),
                _label('Reference / Receipt # (Required)'),
                TextFormField(
                  controller: refCtrl,
                  decoration: _dec('e.g. RCP-2041 / Supplier Bill #88'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                _label('Notes'),
                TextFormField(
                  controller: notesCtrl,
                  decoration: _dec('Optional remarks'),
                ),
              ],
            ),
          ),
          actions: [
            AppButton.secondary(
              label: 'Cancel',
              icon: Icons.close,
              onPressed: saving ? null : () => Navigator.pop(ctx, false),
            ),
            AppButton.primary(
              label: 'Inject Capital',
              icon: Icons.check,
              loading: saving,
              onPressed: saving
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      setLocal(() => saving = true);
                      try {
                        await _svc.injectOutOfPocketCapital(
                          partnerId: partnerId,
                          amount: double.parse(amountCtrl.text),
                          paymentSource: source,
                          reference: refCtrl.text,
                          notes: notesCtrl.text,
                          date: dt,
                        );
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        if (ctx.mounted) {
                          AppToast.showError(ctx, '$e');
                          setLocal(() => saving = false);
                        }
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showReinvestDialog() {
    final formKey = GlobalKey<FormState>();
    final amountCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var partnerId = _partners.first.id;
    var dt = DateTime.now();
    var saving = false;

    PartnerModel selected() =>
        _partners.firstWhere((p) => p.id == partnerId, orElse: () => _partners.first);

    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final avail = selected().unsettledProfit;
          return AppDialog(
            title: 'Reinvest Retained Profit',
            onClose: () => Navigator.pop(ctx, false),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('Date / Time'),
                  _dtField(dt, () async {
                    final p = await _pickDt(dt);
                    if (p != null) setLocal(() => dt = p);
                  }),
                  const SizedBox(height: 12),
                  _label('Partner'),
                  DropdownButtonFormField<String>(
                    initialValue: partnerId,
                    decoration: _dec('Partner'),
                    items: _partners
                        .map((p) =>
                            DropdownMenuItem(value: p.id, child: Text(p.name)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setLocal(() => partnerId = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6F1FB),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Unsettled Profit available: ${_pkr(avail)}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _btnBlue,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _label('Amount to convert into Equity Capital'),
                  TextFormField(
                    controller: amountCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec('e.g. 50000'),
                    validator: (v) {
                      final n = double.tryParse(v ?? '');
                      if (n == null || n <= 0) return 'Enter a valid amount';
                      if (n > avail + 0.009) {
                        return 'Exceeds unsettled profit';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  _label('Notes'),
                  TextFormField(
                    controller: notesCtrl,
                    decoration: _dec('Optional'),
                  ),
                ],
              ),
            ),
            actions: [
              AppButton.secondary(
                label: 'Cancel',
                icon: Icons.close,
                onPressed: saving ? null : () => Navigator.pop(ctx, false),
              ),
              AppButton.primary(
                label: 'Reinvest Profit',
                icon: Icons.check,
                loading: saving,
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setLocal(() => saving = true);
                        try {
                          await _svc.reinvestRetainedProfit(
                            partnerId: partnerId,
                            amount: double.parse(amountCtrl.text),
                            notes: notesCtrl.text,
                            date: dt,
                          );
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          if (ctx.mounted) {
                            AppToast.showError(ctx, '$e');
                            setLocal(() => saving = false);
                          }
                        }
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool?> _showDrawingDialog() {
    final formKey = GlobalKey<FormState>();
    final amountCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    var partnerId = _partners.first.id;
    var type = PartnerDrawingType.taken;
    var dt = DateTime.now();
    var saving = false;

    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AppDialog(
          title: 'Record Cash Drawing',
          onClose: () => Navigator.pop(ctx, false),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label('Date / Time'),
                _dtField(dt, () async {
                  final p = await _pickDt(dt);
                  if (p != null) setLocal(() => dt = p);
                }),
                const SizedBox(height: 12),
                _label('Partner'),
                DropdownButtonFormField<String>(
                  initialValue: partnerId,
                  decoration: _dec('Partner'),
                  items: _partners
                      .map((p) =>
                          DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setLocal(() => partnerId = v);
                  },
                ),
                const SizedBox(height: 12),
                _label('Drawing Type'),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: _dec('Type'),
                  items: const [
                    DropdownMenuItem(
                      value: PartnerDrawingType.taken,
                      child: Text('TAKEN — Cash withdrawn'),
                    ),
                    DropdownMenuItem(
                      value: PartnerDrawingType.returned,
                      child: Text('RETURNED — Cash returned'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => type = v);
                  },
                ),
                const SizedBox(height: 12),
                _label('Amount (PKR)'),
                TextFormField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _dec('e.g. 15000'),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    if (n == null || n <= 0) return 'Enter a valid amount';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _label('Notes'),
                TextFormField(
                  controller: notesCtrl,
                  decoration: _dec('Purpose / remarks'),
                ),
              ],
            ),
          ),
          actions: [
            AppButton.secondary(
              label: 'Cancel',
              icon: Icons.close,
              onPressed: saving ? null : () => Navigator.pop(ctx, false),
            ),
            AppButton.primary(
              label: 'Record Drawing',
              icon: Icons.check,
              loading: saving,
              onPressed: saving
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      setLocal(() => saving = true);
                      try {
                        await _svc.recordDrawing(
                          partnerId: partnerId,
                          amount: double.parse(amountCtrl.text),
                          type: type,
                          notes: notesCtrl.text,
                          date: dt,
                        );
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        if (ctx.mounted) {
                          AppToast.showError(ctx, '$e');
                          setLocal(() => saving = false);
                        }
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showSettlementDialog() =>
      SeasonalSettlementDialog.show(context);

  Future<bool?> _showAddPartnerDialog() async {
    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final capitalCtrl = TextEditingController();
    String? userId;
    String? zamindarId;
    var dt = DateTime.now();
    var saving = false;
    var loadingZ = true;
    var zamindars = <Zamindar>[];

    DatabaseHelper.instance.getAllZamindars().then((list) {
      zamindars = list;
      loadingZ = false;
    });

    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          if (loadingZ) {
            DatabaseHelper.instance.getAllZamindars().then((list) {
              if (ctx.mounted) {
                setLocal(() {
                  zamindars = list;
                  loadingZ = false;
                });
              }
            });
          }
          final users = UserAccountStore.instance.users;
          final userItems = <DropdownMenuItem<String?>>[
            const DropdownMenuItem(value: null, child: Text('— None —')),
            ...users.map(
              (u) => DropdownMenuItem(
                value: u.id,
                child: Text('${u.name} (${u.role})'),
              ),
            ),
          ];
          final zItems = <DropdownMenuItem<String?>>[
            const DropdownMenuItem(value: null, child: Text('— None —')),
            ...zamindars.where((z) => z.id != null).map(
                  (z) => DropdownMenuItem(
                    value: z.id.toString(),
                    child: Text(z.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
          ];

          return AppDialog(
            title: 'Add Partner Capital',
            onClose: () => Navigator.pop(ctx, false),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('Date / Time'),
                  _dtField(dt, () async {
                    final p = await _pickDt(dt);
                    if (p != null) setLocal(() => dt = p);
                  }),
                  const SizedBox(height: 12),
                  _label('Partner Name'),
                  TextFormField(
                    controller: nameCtrl,
                    decoration: _dec('e.g. Atta Muhammad'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  _label('Phone'),
                  TextFormField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec('0300…'),
                  ),
                  const SizedBox(height: 12),
                  _label('Initial Capital (PKR)'),
                  TextFormField(
                    controller: capitalCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec('e.g. 600000'),
                    validator: (v) {
                      final n = double.tryParse(v ?? '');
                      if (n == null || n <= 0) return 'Enter valid capital';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  _label('Link User Account (Optional)'),
                  DropdownButtonFormField<String?>(
                    initialValue: _safeDd(userId, userItems),
                    decoration: _dec('User account'),
                    items: userItems,
                    onChanged: (v) => setLocal(() => userId = v),
                  ),
                  const SizedBox(height: 12),
                  _label('Link Zamindar Profile (Optional)'),
                  if (loadingZ)
                    const LinearProgressIndicator(minHeight: 2)
                  else
                    DropdownButtonFormField<String?>(
                      initialValue: _safeDd(zamindarId, zItems),
                      decoration: _dec('Zamindar'),
                      isExpanded: true,
                      items: zItems,
                      onChanged: (v) => setLocal(() => zamindarId = v),
                    ),
                ],
              ),
            ),
            actions: [
              AppButton.secondary(
                label: 'Cancel',
                icon: Icons.close,
                onPressed: saving ? null : () => Navigator.pop(ctx, false),
              ),
              AppButton.primary(
                label: 'Add Partner',
                icon: Icons.check,
                loading: saving,
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setLocal(() => saving = true);
                        try {
                          await _svc.addPartner(
                            name: nameCtrl.text,
                            phone: phoneCtrl.text,
                            initialCapital: double.parse(capitalCtrl.text),
                            userAccountId: userId,
                            zamindarId: zamindarId,
                            createdAt: dt,
                          );
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          if (ctx.mounted) {
                            AppToast.showError(ctx, '$e');
                            setLocal(() => saving = false);
                          }
                        }
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool?> _showEditDialog(PartnerModel partner) async {
    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController(text: partner.name);
    final phoneCtrl = TextEditingController(text: partner.phone);
    final capitalCtrl = TextEditingController(
      text: partner.initialCapital.round().toString(),
    );
    String? userId = partner.userAccountId;
    String? zamindarId = partner.zamindarId;
    var saving = false;
    var loadingZ = true;
    var zamindars = <Zamindar>[];

    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          if (loadingZ) {
            DatabaseHelper.instance.getAllZamindars().then((list) {
              if (ctx.mounted) {
                setLocal(() {
                  zamindars = list;
                  loadingZ = false;
                });
              }
            });
          }
          final users = UserAccountStore.instance.users;
          final userItems = <DropdownMenuItem<String?>>[
            const DropdownMenuItem(value: null, child: Text('— None —')),
            ...users.map(
              (u) => DropdownMenuItem(
                value: u.id,
                child: Text('${u.name} (${u.role})'),
              ),
            ),
          ];
          final zItems = <DropdownMenuItem<String?>>[
            const DropdownMenuItem(value: null, child: Text('— None —')),
            ...zamindars.where((z) => z.id != null).map(
                  (z) => DropdownMenuItem(
                    value: z.id.toString(),
                    child: Text(z.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
          ];

          return AppDialog(
            title: 'Edit Partner Equity',
            onClose: () => Navigator.pop(ctx, false),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('Partner Name'),
                  TextFormField(
                    controller: nameCtrl,
                    decoration: _dec('Name'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  _label('Phone'),
                  TextFormField(
                    controller: phoneCtrl,
                    decoration: _dec('Phone'),
                  ),
                  const SizedBox(height: 12),
                  _label('Initial Capital (PKR)'),
                  TextFormField(
                    controller: capitalCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec('Capital'),
                  ),
                  const SizedBox(height: 12),
                  _label('Link User Account'),
                  DropdownButtonFormField<String?>(
                    initialValue: _safeDd(userId, userItems),
                    decoration: _dec('User'),
                    items: userItems,
                    onChanged: (v) => setLocal(() => userId = v),
                  ),
                  const SizedBox(height: 12),
                  _label('Link Zamindar Profile'),
                  if (loadingZ)
                    const LinearProgressIndicator(minHeight: 2)
                  else
                    DropdownButtonFormField<String?>(
                      initialValue: _safeDd(zamindarId, zItems),
                      decoration: _dec('Zamindar'),
                      isExpanded: true,
                      items: zItems,
                      onChanged: (v) => setLocal(() => zamindarId = v),
                    ),
                ],
              ),
            ),
            actions: [
              AppButton.secondary(
                label: 'Cancel',
                icon: Icons.close,
                onPressed: saving ? null : () => Navigator.pop(ctx, false),
              ),
              AppButton.primary(
                label: 'Save Changes',
                icon: Icons.check,
                loading: saving,
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setLocal(() => saving = true);
                        try {
                          await _svc.updatePartner(
                            partner.copyWith(
                              name: nameCtrl.text.trim(),
                              phone: phoneCtrl.text.trim(),
                              initialCapital:
                                  double.tryParse(capitalCtrl.text) ?? 0,
                              userAccountId: userId,
                              clearUserAccountId: userId == null,
                              zamindarId: zamindarId,
                              clearZamindarId: zamindarId == null,
                            ),
                          );
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          if (ctx.mounted) {
                            AppToast.showError(ctx, '$e');
                            setLocal(() => saving = false);
                          }
                        }
                      },
              ),
            ],
          );
        },
      ),
    );
  }
}
