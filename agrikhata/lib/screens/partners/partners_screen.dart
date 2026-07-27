import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/partner_model.dart';
import 'package:agrikhata/services/partner_service.dart';
import 'package:agrikhata/services/user_account_store.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class PartnersScreen extends StatefulWidget {
  const PartnersScreen({super.key});

  @override
  State<PartnersScreen> createState() => _PartnersScreenState();
}

class _PartnersScreenState extends State<PartnersScreen> {
  static final NumberFormat _currency = NumberFormat('#,##,##0');

  final PartnerService _service = PartnerService.instance;

  /// 0 = overhead split, 1 = cash drawings. Manual index avoids TabBarView
  /// semantics churn that can spam Windows AXTree bridge errors.
  int _lowerTabIndex = 0;
  bool _loading = true;
  String? _error;

  List<PartnerModel> _partners = [];
  List<PartnerDrawingModel> _drawings = [];
  List<OverheadSplitRow> _overheadRows = [];
  Map<String, String> _zamindarNames = {};

  static const _pageHeaderBg = Color(0xFFEEF3EC);
  static const _pageHeaderBorder = Color(0xFFDCE6D9);
  static const _debtRed = Color(0xFFA32D2D);
  static const _equityColors = [
    Color(0xFF2D6A4F),
    Color(0xFF0C447C),
    Color(0xFF9C6644),
    Color(0xFF6B2D5C),
  ];

  @override
  void initState() {
    super.initState();
    _load();
    UserAccountStore.instance.refresh();
    DatabaseHelper.instance.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged() {
    if (mounted) _load(silent: true);
  }

  String _formatPkr(num amount) => '₨ ${_currency.format(amount.round())}';

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final partners = await _service.getActivePartners();
      final drawings = await _service.getDrawings();
      final overhead = await _service.getOverheadSplitRows();
      final zamindars = await DatabaseHelper.instance.getAllZamindars();
      final nameMap = <String, String>{
        for (final z in zamindars)
          if (z.id != null) z.id.toString(): z.name,
      };
      if (!mounted) return;
      setState(() {
        _partners = partners;
        _drawings = drawings;
        _overheadRows = overhead;
        _zamindarNames = nameMap;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load partners: $e';
      });
    }
  }

  Color _equityColor(int index) =>
      _equityColors[index % _equityColors.length];

  Future<void> _openAddPartnerDialog() async {
    final saved = await showAddPartnerDialog(context);
    if (saved == true && mounted) {
      await _load();
      if (!mounted) return;
      AppToast.showSuccess(context, 'Partner capital added');
    }
  }

  Future<void> _openDrawingDialog() async {
    if (_partners.isEmpty) {
      AppToast.showWarning(context, 'Add an active partner first');
      return;
    }
    final saved = await showRecordDrawingDialog(context, partners: _partners);
    if (saved == true && mounted) {
      await _load();
      if (!mounted) return;
      AppToast.showSuccess(context, 'Cash drawing recorded');
    }
  }

  Future<void> _openSettlementDialog() async {
    if (_partners.isEmpty) {
      AppToast.showWarning(context, 'Add an active partner first');
      return;
    }
    final saved = await showSeasonalSettlementDialog(
      context,
      partners: _partners,
    );
    if (saved == true && mounted) {
      await _load();
      if (!mounted) return;
      AppToast.showSuccess(context, 'Seasonal settlement applied');
    }
  }

  Future<void> _openEditEquityDialog(PartnerModel partner) async {
    final saved = await showEditEquityDialog(context, partner: partner);
    if (saved == true && mounted) {
      await _load();
      if (!mounted) return;
      AppToast.showSuccess(context, 'Partner equity updated');
    }
  }

  Future<void> _openPartnerLedger(PartnerModel partner) async {
    final drawings =
        await _service.getDrawings(partnerId: partner.id);
    if (!mounted) return;
    await AppDialog.show(
      context: context,
      title: '${partner.name} — Drawing Ledger',
      maxWidth: 520,
      content: SizedBox(
        height: 320,
        width: double.infinity,
        child: drawings.isEmpty
            ? const Center(
                child: Text(
                  'No drawings recorded yet.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
              )
            : ListView.separated(
                itemCount: drawings.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFFEEF3EC)),
                itemBuilder: (context, i) {
                  final d = drawings[i];
                  final isTaken = d.isTaken;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _formatPkr(d.amount),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: isTaken ? _debtRed : AppColors.mediumGreen,
                      ),
                    ),
                    subtitle: Text(
                      '${DateFormat('dd-MMM-yyyy').format(d.date)}'
                      ' · ${d.type}'
                      '${d.notes != null && d.notes!.isNotEmpty ? ' · ${d.notes}' : ''}'
                      '${d.createdByUserName.trim().isNotEmpty ? ' · Recorded By: ${d.createdByUserName.trim()}' : ''}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textHint,
                      ),
                    ),
                    trailing: Text(
                      d.isSettled ? 'Settled' : 'Pending',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: d.isSettled
                            ? AppColors.tagGreenText
                            : AppColors.tagAmberText,
                      ),
                    ),
                  );
                },
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

  Future<void> _markDrawingSettled(PartnerDrawingModel drawing) async {
    await _service.settleDrawing(drawing.id);
    await _load(silent: true);
    if (!mounted) return;
    AppToast.showSuccess(context, 'Drawing marked as settled');
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: const BoxDecoration(
        color: _pageHeaderBg,
        border: Border(
          bottom: BorderSide(color: _pageHeaderBorder, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Partner Equity & Profit Management',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Track capital, reinvestment, drawings, and profit share across partners',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF5C8468)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppButton.primary(
            label: 'Add Partner Capital',
            icon: Icons.add,
            onPressed: _openAddPartnerDialog,
          ),
          const SizedBox(width: 8),
          AppButton.secondary(
            label: 'Record Cash Drawing',
            icon: Icons.payments_outlined,
            onPressed: _openDrawingDialog,
          ),
          const SizedBox(width: 8),
          AppButton.secondary(
            label: 'Seasonal Settlement',
            icon: Icons.event_available_outlined,
            onPressed: _openSettlementDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final totalCapital = _service.totalBusinessCapital(_partners);
    final totalDrawings = _service.totalActiveDrawings(_partners);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSummaryCards(totalCapital, totalDrawings),
          const SizedBox(height: 20),
          const Text(
            'Active Partner Balances & Profit Distribution',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 8),
          _buildPartnersTable(),
          const SizedBox(height: 20),
          _buildLowerTabs(),
        ],
      ),
    );
  }

  Widget _buildSummaryCards(double totalCapital, double totalDrawings) {
    final cards = <Widget>[
      _kpiCard(
        label: 'Total Business Capital',
        value: _formatPkr(totalCapital),
        subtitle:
            'Across ${_partners.length} partner${_partners.length == 1 ? '' : 's'}',
        icon: Icons.account_balance_outlined,
      ),
      for (var i = 0; i < _partners.length; i++)
        _kpiCard(
          label: '${_partners[i].name} Equity',
          value: _formatPkr(_service.partnerEquity(_partners[i])),
          subtitle:
              '${_service.partnerEquitySharePct(_partners[i], _partners).toStringAsFixed(0)}% Net Equity Share',
          subtitleColor: _equityColor(i),
          subtitleBold: true,
        ),
      _kpiCard(
        label: 'Active Cash Drawings Debt',
        value: _formatPkr(totalDrawings),
        valueColor: _debtRed,
        subtitle: 'Pending settlement',
        icon: Icons.warning_amber_rounded,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 1100
            ? 4
            : constraints.maxWidth >= 700
                ? 2
                : 1;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: cols == 1 ? 3.2 : 2.4,
          children: cards,
        );
      },
    );
  }

  Widget _kpiCard({
    required String label,
    required String value,
    required String subtitle,
    Color? valueColor,
    Color? subtitleColor,
    bool subtitleBold = false,
    IconData? icon,
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
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: valueColor ?? AppColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: subtitleColor ?? AppColors.textHint),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight:
                        subtitleBold ? FontWeight.w600 : FontWeight.w400,
                    color: subtitleColor ?? AppColors.textHint,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPartnersTable() {
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
            'No active partners yet. Use “Add Partner Capital” to get started.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    return AppDataTable(
      minWidth: 980,
      columns: const [
        AppDataColumn(title: 'Partner Name', flex: 18),
        AppDataColumn(title: 'Linked Accounts', flex: 16),
        AppDataColumn(title: 'Initial Capital', flex: 12),
        AppDataColumn(title: 'Reinvested Profit', flex: 12),
        AppDataColumn(title: 'Cash Drawings', flex: 11),
        AppDataColumn(title: 'Net Equity Share %', flex: 14),
        AppDataColumn(title: 'Actions', flex: 17),
      ],
      rows: [
        for (var i = 0; i < _partners.length; i++)
          _partnerRow(_partners[i], i),
      ],
    );
  }

  AppDataRow _partnerRow(PartnerModel partner, int index) {
    final pct = _service.partnerEquitySharePct(partner, _partners);
    final user =
        UserAccountStore.instance.findById(partner.userAccountId);
    final zamindarName = partner.zamindarId == null
        ? null
        : _zamindarNames[partner.zamindarId!];
    final color = _equityColor(index);

    return AppDataRow(
      cells: [
        AppTableCellText(
          partner.name,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
            color: AppColors.primary,
          ),
        ),
        _linkedBadges(user?.name, zamindarName),
        AppTableCellText(_formatPkr(partner.initialCapital)),
        AppTableCellText(_formatPkr(partner.reinvestedProfit)),
        AppTableCellText(
          _formatPkr(partner.activeDrawings),
          style: TextStyle(
            fontSize: 12.5,
            color: partner.activeDrawings > 0
                ? _debtRed
                : AppColors.textPrimary,
          ),
        ),
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
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _outlineAction(
              label: 'View Ledger',
              icon: Icons.menu_book_outlined,
              onTap: () => _openPartnerLedger(partner),
            ),
            _outlineAction(
              label: 'Edit Equity',
              icon: Icons.edit_outlined,
              onTap: () => _openEditEquityDialog(partner),
            ),
          ],
        ),
      ],
    );
  }

  Widget _linkedBadges(String? userName, String? zamindarName) {
    if (userName == null && zamindarName == null) {
      return const Text(
        '—',
        style: TextStyle(fontSize: 12, color: AppColors.textHint),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (userName != null)
          _badge(
            label: userName,
            bg: AppColors.tagBlueBg,
            fg: AppColors.tagBlueText,
            icon: Icons.manage_accounts_outlined,
          ),
        if (zamindarName != null)
          _badge(
            label: zamindarName,
            bg: AppColors.tagGreenBg,
            fg: AppColors.tagGreenText,
            icon: Icons.agriculture_outlined,
          ),
      ],
    );
  }

  Widget _badge({
    required String label,
    required Color bg,
    required Color fg,
    required IconData icon,
  }) {
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _outlineAction({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
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

  Widget _buildLowerTabs() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _lowerTabButton(
                index: 0,
                label: 'Overhead Expenses Split (50-50 Ledger)',
              ),
              _lowerTabButton(
                index: 1,
                label: 'Counter Cash Drawing Ledger',
              ),
            ],
          ),
          const Divider(height: 1, thickness: 1, color: AppColors.border),
          SizedBox(
            height: 340,
            child: ExcludeSemantics(
              child: _lowerTabIndex == 0
                  ? _buildOverheadTab()
                  : _buildDrawingsTab(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lowerTabButton({required int index, required String label}) {
    final selected = _lowerTabIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _lowerTabIndex = index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? AppColors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.primary : AppColors.textHint,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverheadTab() {
    if (_overheadRows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No overhead expenses this month (Shop Rent, Electricity, Salaries).',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }

    final partnerCols = _partners;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: AppDataTable(
            showCardChrome: false,
            margin: EdgeInsets.zero,
            minWidth: 720,
            columns: [
              const AppDataColumn(title: 'Expense Category', flex: 22),
              const AppDataColumn(title: 'Total Amount', flex: 14),
              for (final p in partnerCols)
                AppDataColumn(
                  title: '${p.name} Share',
                  flex: 16,
                ),
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
                    AppTableCellText(_formatPkr(row.expense.amount)),
                    for (final p in partnerCols)
                      AppTableCellText(
                        _formatPkr(row.shareByPartnerId[p.id] ?? 0),
                      ),
                    AppTableCellText(
                      DateFormat('dd-MMM-yyyy')
                          .format(row.expense.expenseDate),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'Overheads are split automatically equally between active partners regardless of equity ratio, per store policy.',
            style: TextStyle(fontSize: 11, color: AppColors.textHint),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawingsTab() {
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
      minWidth: 900,
      columns: const [
        AppDataColumn(title: 'Date', flex: 14),
        AppDataColumn(title: 'Partner Name', flex: 18),
        AppDataColumn(title: 'Amount', flex: 12),
        AppDataColumn(title: 'Type', flex: 10),
        AppDataColumn(title: 'Recorded By', flex: 18),
        AppDataColumn(title: 'Status', flex: 12),
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
                _formatPkr(d.amount),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  color: d.isTaken ? _debtRed : AppColors.mediumGreen,
                ),
              ),
              AppTableCellText(d.type),
              AppTableCellText(
                d.createdByUserName.trim().isEmpty
                    ? '—'
                    : d.createdByUserName.trim(),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textHint,
                ),
              ),
              _statusChip(d.isSettled),
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
                        onTap: () => _markDrawingSettled(d),
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
}

// ── Dialogs ──────────────────────────────────────────────────────────────────

Future<bool?> showAddPartnerDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (_) => const _AddPartnerDialog(),
  );
}

Future<bool?> showRecordDrawingDialog(
  BuildContext context, {
  required List<PartnerModel> partners,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _RecordDrawingDialog(partners: partners),
  );
}

Future<bool?> showSeasonalSettlementDialog(
  BuildContext context, {
  required List<PartnerModel> partners,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _SeasonalSettlementDialog(partners: partners),
  );
}

Future<bool?> showEditEquityDialog(
  BuildContext context, {
  required PartnerModel partner,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _EditEquityDialog(partner: partner),
  );
}

InputDecoration _fieldDecoration(String hint) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppColors.inputBorder, width: 0.5),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppColors.inputBorder, width: 0.5),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: AppColors.accentGreen, width: 1.2),
    ),
  );
}

Widget _fieldLabel(String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Color(0xFF6B8F71),
      ),
    ),
  );
}

final DateFormat _dialogDateTimeFormat = DateFormat('dd-MMM-yyyy · hh:mm a');

Future<DateTime?> _pickPartnerDateTime(
  BuildContext context,
  DateTime current,
) async {
  final now = DateTime.now();
  final pickedDate = await showDatePicker(
    context: context,
    initialDate: current.isAfter(now) ? now : current,
    firstDate: DateTime(2020),
    lastDate: now,
    builder: (context, child) {
      return Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            onSurface: AppColors.textPrimary,
          ),
        ),
        child: child!,
      );
    },
  );
  if (pickedDate == null || !context.mounted) return null;

  final pickedTime = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(current),
    builder: (context, child) {
      return Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            onSurface: AppColors.textPrimary,
          ),
        ),
        child: child!,
      );
    },
  );
  if (pickedTime == null || !context.mounted) return null;

  return DateTime(
    pickedDate.year,
    pickedDate.month,
    pickedDate.day,
    pickedTime.hour,
    pickedTime.minute,
  );
}

Widget _dateTimeField({
  required DateTime value,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: InputDecorator(
      decoration: _fieldDecoration('Select date & time').copyWith(
        suffixIcon: const Icon(
          Icons.calendar_month_outlined,
          size: 18,
          color: AppColors.textMuted,
        ),
      ),
      child: Text(
        _dialogDateTimeFormat.format(value),
        style: const TextStyle(fontSize: 12.5, color: AppColors.textPrimary),
      ),
    ),
  );
}

/// DropdownButton asserts if [value] is set but missing from [items].
String? _safeNullableDropdownValue(
  String? value,
  List<DropdownMenuItem<String?>> items,
) {
  if (value == null) return null;
  final matches = items.where((item) => item.value == value);
  return matches.length == 1 ? value : null;
}

class _AddPartnerDialog extends StatefulWidget {
  const _AddPartnerDialog();

  @override
  State<_AddPartnerDialog> createState() => _AddPartnerDialogState();
}

class _AddPartnerDialogState extends State<_AddPartnerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _capitalCtrl = TextEditingController();
  String? _userAccountId;
  String? _zamindarId;
  List<Zamindar> _zamindars = [];
  bool _saving = false;
  bool _loadingZ = true;
  DateTime _dateTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadZamindars();
  }

  Future<void> _loadZamindars() async {
    final list = await DatabaseHelper.instance.getAllZamindars();
    if (!mounted) return;
    setState(() {
      _zamindars = list;
      _loadingZ = false;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _capitalCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final capital =
        double.tryParse(_capitalCtrl.text.replaceAll(',', '').trim()) ?? 0;
    setState(() => _saving = true);
    try {
      await PartnerService.instance.addPartner(
        name: _nameCtrl.text,
        phone: _phoneCtrl.text,
        initialCapital: capital,
        userAccountId: _userAccountId,
        zamindarId: _zamindarId,
        createdAt: _dateTime,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Could not save partner: $e');
      setState(() => _saving = false);
    }
  }

  Future<void> _pickDateTime() async {
    final picked = await _pickPartnerDateTime(context, _dateTime);
    if (picked == null || !mounted) return;
    setState(() => _dateTime = picked);
  }

  @override
  Widget build(BuildContext context) {
    final users = UserAccountStore.instance.users;
    return AppDialog(
      title: 'Add Partner Capital',
      onClose: () => Navigator.of(context).pop(false),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _fieldLabel('Date / Time'),
            _dateTimeField(value: _dateTime, onTap: _pickDateTime),
            const SizedBox(height: 12),
            _fieldLabel('Partner Name'),
            TextFormField(
              controller: _nameCtrl,
              decoration: _fieldDecoration('e.g. Atta Muhammad'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 12),
            _fieldLabel('Phone Number'),
            TextFormField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _fieldDecoration('e.g. 03001234567'),
            ),
            const SizedBox(height: 12),
            _fieldLabel('Initial Capital (PKR)'),
            TextFormField(
              controller: _capitalCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _fieldDecoration('e.g. 600000'),
              validator: (v) {
                final n = double.tryParse(v?.replaceAll(',', '') ?? '');
                if (n == null || n <= 0) return 'Enter a valid capital amount';
                return null;
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Link User Account (Optional)'),
            Builder(
              builder: (context) {
                final items = <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('— None —'),
                  ),
                  ...users.map(
                    (u) => DropdownMenuItem<String?>(
                      value: u.id,
                      child: Text('${u.name} (${u.role})'),
                    ),
                  ),
                ];
                return DropdownButtonFormField<String?>(
                  initialValue: _safeNullableDropdownValue(_userAccountId, items),
                  decoration: _fieldDecoration('Select shop staff account'),
                  items: items,
                  onChanged: (v) => setState(() => _userAccountId = v),
                );
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Link Zamindar Profile (Optional)'),
            if (_loadingZ)
              const LinearProgressIndicator(minHeight: 2)
            else
              Builder(
                builder: (context) {
                  final items = <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('— None —'),
                    ),
                    ..._zamindars
                        .where((z) => z.id != null)
                        .map(
                          (z) => DropdownMenuItem<String?>(
                            value: z.id.toString(),
                            child: Text(
                              z.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                  ];
                  return DropdownButtonFormField<String?>(
                    initialValue: _safeNullableDropdownValue(_zamindarId, items),
                    decoration:
                        _fieldDecoration('Select for personal crop credit'),
                    isExpanded: true,
                    items: items,
                    onChanged: (v) => setState(() => _zamindarId = v),
                  );
                },
              ),
          ],
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton.primary(
          label: 'Add Partner',
          icon: Icons.check,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _RecordDrawingDialog extends StatefulWidget {
  final List<PartnerModel> partners;
  const _RecordDrawingDialog({required this.partners});

  @override
  State<_RecordDrawingDialog> createState() => _RecordDrawingDialogState();
}

class _RecordDrawingDialogState extends State<_RecordDrawingDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  late String _partnerId;
  String _type = PartnerDrawingType.taken;
  bool _saving = false;
  DateTime _dateTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _partnerId = widget.partners.first.id;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final picked = await _pickPartnerDateTime(context, _dateTime);
    if (picked == null || !mounted) return;
    setState(() => _dateTime = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '').trim()) ?? 0;
    setState(() => _saving = true);
    try {
      await PartnerService.instance.recordDrawing(
        partnerId: _partnerId,
        amount: amount,
        type: _type,
        notes: _notesCtrl.text.trim(),
        date: _dateTime,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Could not record drawing: $e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Record Cash Drawing',
      onClose: () => Navigator.of(context).pop(false),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _fieldLabel('Date / Time'),
            _dateTimeField(value: _dateTime, onTap: _pickDateTime),
            const SizedBox(height: 12),
            _fieldLabel('Partner'),
            DropdownButtonFormField<String>(
              initialValue: _partnerId,
              decoration: _fieldDecoration('Select partner'),
              items: widget.partners
                  .map(
                    (p) => DropdownMenuItem(
                      value: p.id,
                      child: Text(p.name),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _partnerId = v);
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Drawing Type'),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: _fieldDecoration('Type'),
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
                if (v != null) setState(() => _type = v);
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Amount (PKR)'),
            TextFormField(
              controller: _amountCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _fieldDecoration('e.g. 15000'),
              validator: (v) {
                final n = double.tryParse(v?.replaceAll(',', '') ?? '');
                if (n == null || n <= 0) return 'Enter a valid amount';
                return null;
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Notes'),
            TextFormField(
              controller: _notesCtrl,
              decoration:
                  _fieldDecoration('e.g. Personal household expense'),
            ),
          ],
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton.primary(
          label: 'Record Drawing',
          icon: Icons.check,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _SeasonalSettlementDialog extends StatefulWidget {
  final List<PartnerModel> partners;
  const _SeasonalSettlementDialog({required this.partners});

  @override
  State<_SeasonalSettlementDialog> createState() =>
      _SeasonalSettlementDialogState();
}

class _SeasonalSettlementDialogState extends State<_SeasonalSettlementDialog> {
  final _formKey = GlobalKey<FormState>();
  final _profitCtrl = TextEditingController();
  late String _season;
  bool _saving = false;
  DateTime _dateTime = DateTime.now();

  static final _currency = NumberFormat('#,##,##0');

  @override
  void initState() {
    super.initState();
    final year = DateTime.now().year;
    _season = 'Kharif $year';
  }

  @override
  void dispose() {
    _profitCtrl.dispose();
    super.dispose();
  }

  String _previewText() {
    final svc = PartnerService.instance;
    final parts = widget.partners.map((p) {
      final pct = svc.partnerEquitySharePct(p, widget.partners);
      return '${p.name} ${pct.toStringAsFixed(0)}%';
    }).join(' / ');
    return 'Profit will be split per current equity ratio — $parts — '
        'credited to reinvested capital after offsetting linked Zamindar crop debt.';
  }

  Future<void> _pickDateTime() async {
    final picked = await _pickPartnerDateTime(context, _dateTime);
    if (picked == null || !mounted) return;
    setState(() => _dateTime = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final profit =
        double.tryParse(_profitCtrl.text.replaceAll(',', '').trim()) ?? 0;
    setState(() => _saving = true);
    try {
      await PartnerService.instance.runSeasonalSettlement(
        netProfit: profit,
        seasonLabel: _season,
        settledAt: _dateTime,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Settlement failed: $e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final year = DateTime.now().year;
    return AppDialog(
      title: 'Seasonal Profit Reinvestment',
      onClose: () => Navigator.of(context).pop(false),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _fieldLabel('Date / Time'),
            _dateTimeField(value: _dateTime, onTap: _pickDateTime),
            const SizedBox(height: 12),
            _fieldLabel('Season'),
            DropdownButtonFormField<String>(
              initialValue: _season,
              decoration: _fieldDecoration('Season'),
              items: [
                'Kharif $year',
                'Rabi $year',
                'Kharif ${year - 1}',
                'Rabi ${year - 1}',
              ]
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _season = v);
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Net Profit to Distribute (PKR)'),
            TextFormField(
              controller: _profitCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _fieldDecoration('e.g. 500000'),
              validator: (v) {
                final n = double.tryParse(v?.replaceAll(',', '') ?? '');
                if (n == null || n <= 0) return 'Enter a valid profit amount';
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF3DE),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _previewText(),
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF2D6A4F),
                  height: 1.35,
                ),
              ),
            ),
            if (_profitCtrl.text.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...widget.partners.map((p) {
                final pct = PartnerService.instance
                    .partnerEquitySharePct(p, widget.partners);
                final profit = double.tryParse(
                      _profitCtrl.text.replaceAll(',', ''),
                    ) ??
                    0;
                final share = profit * (pct / 100);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${p.name}: ₨ ${_currency.format(share.round())}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton.primary(
          label: 'Confirm Settlement',
          icon: Icons.check,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _EditEquityDialog extends StatefulWidget {
  final PartnerModel partner;
  const _EditEquityDialog({required this.partner});

  @override
  State<_EditEquityDialog> createState() => _EditEquityDialogState();
}

class _EditEquityDialogState extends State<_EditEquityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _capitalCtrl;
  late final TextEditingController _reinvestCtrl;
  String? _userAccountId;
  String? _zamindarId;
  List<Zamindar> _zamindars = [];
  bool _saving = false;
  bool _loadingZ = true;

  @override
  void initState() {
    super.initState();
    final p = widget.partner;
    _nameCtrl = TextEditingController(text: p.name);
    _phoneCtrl = TextEditingController(text: p.phone);
    _capitalCtrl =
        TextEditingController(text: p.initialCapital.round().toString());
    _reinvestCtrl =
        TextEditingController(text: p.reinvestedProfit.round().toString());
    _userAccountId = p.userAccountId;
    _zamindarId = p.zamindarId;
    _loadZamindars();
  }

  Future<void> _loadZamindars() async {
    final list = await DatabaseHelper.instance.getAllZamindars();
    if (!mounted) return;
    setState(() {
      _zamindars = list;
      _loadingZ = false;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _capitalCtrl.dispose();
    _reinvestCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final updated = widget.partner.copyWith(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        initialCapital:
            double.tryParse(_capitalCtrl.text.replaceAll(',', '')) ?? 0,
        reinvestedProfit:
            double.tryParse(_reinvestCtrl.text.replaceAll(',', '')) ?? 0,
        userAccountId: _userAccountId,
        clearUserAccountId: _userAccountId == null,
        zamindarId: _zamindarId,
        clearZamindarId: _zamindarId == null,
      );
      await PartnerService.instance.updatePartner(updated);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Could not update: $e');
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = UserAccountStore.instance.users;
    return AppDialog(
      title: 'Edit Partner Equity',
      onClose: () => Navigator.of(context).pop(false),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _fieldLabel('Partner Name'),
            TextFormField(
              controller: _nameCtrl,
              decoration: _fieldDecoration('Partner name'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            _fieldLabel('Phone'),
            TextFormField(
              controller: _phoneCtrl,
              decoration: _fieldDecoration('Phone'),
            ),
            const SizedBox(height: 12),
            _fieldLabel('Initial Capital (PKR)'),
            TextFormField(
              controller: _capitalCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _fieldDecoration('Capital'),
            ),
            const SizedBox(height: 12),
            _fieldLabel('Reinvested Profit (PKR)'),
            TextFormField(
              controller: _reinvestCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _fieldDecoration('Reinvested'),
            ),
            const SizedBox(height: 12),
            _fieldLabel('Link User Account'),
            Builder(
              builder: (context) {
                final items = <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('— None —'),
                  ),
                  ...users.map(
                    (u) => DropdownMenuItem<String?>(
                      value: u.id,
                      child: Text('${u.name} (${u.role})'),
                    ),
                  ),
                ];
                return DropdownButtonFormField<String?>(
                  initialValue: _safeNullableDropdownValue(_userAccountId, items),
                  decoration: _fieldDecoration('User account'),
                  items: items,
                  onChanged: (v) => setState(() => _userAccountId = v),
                );
              },
            ),
            const SizedBox(height: 12),
            _fieldLabel('Link Zamindar Profile'),
            if (_loadingZ)
              const LinearProgressIndicator(minHeight: 2)
            else
              Builder(
                builder: (context) {
                  final items = <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('— None —'),
                    ),
                    ..._zamindars
                        .where((z) => z.id != null)
                        .map(
                          (z) => DropdownMenuItem<String?>(
                            value: z.id.toString(),
                            child: Text(
                              z.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                  ];
                  return DropdownButtonFormField<String?>(
                    initialValue: _safeNullableDropdownValue(_zamindarId, items),
                    decoration: _fieldDecoration('Zamindar'),
                    isExpanded: true,
                    items: items,
                    onChanged: (v) => setState(() => _zamindarId = v),
                  );
                },
              ),
          ],
        ),
      ),
      actions: [
        AppButton.secondary(
          label: 'Cancel',
          icon: Icons.close,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        AppButton.primary(
          label: 'Save Changes',
          icon: Icons.check,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
