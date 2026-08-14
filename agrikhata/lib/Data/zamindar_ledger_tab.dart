import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/edit_cash_advance_dialog.dart';
import 'package:agrikhata/Widgets/edit_payment_dialog.dart';
import 'package:agrikhata/Widgets/ledger_widgets.dart';
import 'package:agrikhata/Widgets/past_season_guard.dart';
import 'package:agrikhata/Widgets/settlement_split_fields.dart';
import 'package:agrikhata/models/season.dart';
import 'package:agrikhata/screens/new_sale_screen.dart';
import 'package:agrikhata/services/payment_service.dart';
import 'package:agrikhata/services/season_service.dart';
import 'package:agrikhata/services/whatsapp_urdu_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';

class ZamindarLedgerTab extends StatefulWidget {
  final int zamindarId;
  final void Function(String invoiceNumber)? onEditInvoice;

  const ZamindarLedgerTab({
    super.key,
    required this.zamindarId,
    this.onEditInvoice,
  });

  @override
  State<ZamindarLedgerTab> createState() => _ZamindarLedgerTabState();
}

class _ZamindarLedgerTabState extends State<ZamindarLedgerTab> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _tableHScrollController = ScrollController();
  String _selectedSeason = SeasonFilterOption.current;
  int _ledgerSubTab = 0; // 0 = Purchases, 1 = Payment History
  List<Map<String, dynamic>> _allTransactions = [];
  Map<String, String> _invoiceItemSummaries = {};
  Map<String, Map<String, double>> _invoiceCollections = {};
  Map<String, Map<String, double>> _invoiceSaleDiscounts = {};
  Map<String, String> _invoiceSaleRemarks = {};
  String _outstandingBalanceDisplay = "Rs. 0";
  double _outstandingBalanceAmount = 0;
  bool _isLoading = true;
  bool _isExporting = false;
  String? _loadError;
  String _zamindarName = 'Zamindar';
  String _zamindarWhatsapp = '';

  List<String> _seasons = [
    SeasonFilterOption.current,
    SeasonFilterOption.allTime,
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadLedgerData();
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
    SeasonService.instance.activeSeasonNotifier.addListener(_onSeasonChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tableHScrollController.dispose();
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    SeasonService.instance.activeSeasonNotifier.removeListener(
      _onSeasonChanged,
    );
    super.dispose();
  }

  void _onDatabaseChanged() => _loadLedgerData(showLoading: false);

  void _onSeasonChanged() {
    if (_selectedSeason == SeasonFilterOption.current) {
      _loadLedgerData(showLoading: false);
    } else {
      setState(() {});
    }
  }

  Future<void> _loadLedgerData({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final transactions = await DatabaseHelper.instance.getLedgerTransactions(
        widget.zamindarId,
      );
      final outstandingBalance = await DatabaseHelper.instance
          .getOutstandingBalanceString(widget.zamindarId);
      final distinctSeasons = await DatabaseHelper.instance
          .getDistinctSeasonsForZamindar(widget.zamindarId);
      final filterLabels = await SeasonService.instance.zamindarFilterLabels();
      // Keep named prior seasons from ledger that aren't the previous slot.
      final previous = await SeasonService.instance.getPreviousSeason();
      final extras = distinctSeasons.where((s) {
        if (previous != null && s == previous.name) return false;
        final active = SeasonService.instance.activeSeasonName;
        if (active != null && s == active) return false;
        return true;
      });
      final seasons = <String>[
        ...filterLabels,
        ...extras.where((s) => !filterLabels.contains(s)),
      ];
      final zamindar = await DatabaseHelper.instance.getZamindar(
        widget.zamindarId,
      );
      final balances = await DatabaseHelper.instance.getZamindarBalancesSafe(
        widget.zamindarId,
      );

      final invoiceNumbers = transactions
          .map((row) => row[LedgerTransactionTable.invoiceNumber] as String?)
          .whereType<String>()
          .toList();

      final itemSummaries = await DatabaseHelper.instance
          .getSaleItemsSummariesForInvoices(invoiceNumbers);
      final collections = await DatabaseHelper.instance
          .getInvoiceCollectionSummaries(invoiceNumbers);
      final saleDiscounts = await DatabaseHelper.instance
          .getSaleDiscountSummariesForInvoices(invoiceNumbers);
      final saleRemarks = await DatabaseHelper.instance
          .getSaleRemarksForInvoices(invoiceNumbers);

      if (!mounted) return;
      setState(() {
        _allTransactions = transactions;
        _invoiceItemSummaries = itemSummaries;
        _invoiceCollections = collections;
        _invoiceSaleDiscounts = saleDiscounts;
        _invoiceSaleRemarks = saleRemarks;
        _outstandingBalanceDisplay = outstandingBalance;
        _outstandingBalanceAmount =
            (balances?['outstandingBalance'] as num?)?.toDouble() ?? 0;
        _seasons = seasons;
        if (!_seasons.contains(_selectedSeason)) {
          _selectedSeason = SeasonFilterOption.current;
        }
        _zamindarName = zamindar?.name ?? 'Zamindar';
        _zamindarWhatsapp = zamindar?.whatsappNumber ?? '';
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Failed to load ledger: $e';
      });
    }
  }

  List<Map<String, dynamic>> get _filteredTransactions {
    final query = _searchController.text.trim().toLowerCase();

    return _allTransactions.where((row) {
      final season = row[LedgerTransactionTable.season] as String? ?? '';
      final activeName = SeasonService.instance.activeSeasonName;
      if (_selectedSeason == SeasonFilterOption.current) {
        if (activeName != null &&
            activeName.isNotEmpty &&
            season != activeName) {
          return false;
        }
      } else if (_selectedSeason != SeasonFilterOption.allTime) {
        if (season != _selectedSeason) return false;
      }

      if (query.isEmpty) return true;

      final invoiceNumber =
          row[LedgerTransactionTable.invoiceNumber] as String? ?? '';
      final invoiceRemarks = (_invoiceSaleRemarks[invoiceNumber] ?? '')
          .toLowerCase();
      final kisaan = (row['kisaan_name'] as String? ?? '').toLowerCase();
      final description =
          (row[LedgerTransactionTable.description] as String? ?? '')
              .toLowerCase();
      final category = (row[LedgerTransactionTable.category] as String? ?? '')
          .toLowerCase();
      final items = (_invoiceItemSummaries[invoiceNumber] ?? '').toLowerCase();

      return invoiceNumber.toLowerCase().contains(query) ||
          kisaan.contains(query) ||
          description.contains(query) ||
          invoiceRemarks.contains(query) ||
          category.contains(query) ||
          items.contains(query);
    }).toList();
  }

  int get _filteredTotalDebit => _filteredTransactions
      .where(
        (row) =>
            (row[LedgerTransactionTable.type] as String?) ==
            LedgerTransactionType.debit,
      )
      .fold<int>(
        0,
        (sum, row) =>
            sum + ((row[LedgerTransactionTable.amount] as num?)?.round() ?? 0),
      );

  int get _filteredTotalCredit => _filteredTransactions
      .where(
        (row) =>
            (row[LedgerTransactionTable.type] as String?) ==
            LedgerTransactionType.credit,
      )
      .fold<int>(
        0,
        (sum, row) =>
            sum + ((row[LedgerTransactionTable.amount] as num?)?.round() ?? 0),
      );

  /// Pricing adjustments for SALE debit rows in the current filter window.
  Map<String, double> get _filteredSaleAdjustments {
    var gross = 0.0;
    var seasonal = 0.0;
    var discounts = 0.0;
    final seen = <String>{};
    for (final row in _filteredTransactions) {
      final type = row[LedgerTransactionTable.type] as String?;
      final category = (row[LedgerTransactionTable.category] as String? ?? '')
          .toUpperCase();
      if (type != LedgerTransactionType.debit || category != 'SALE') continue;
      final invoice = (row[LedgerTransactionTable.invoiceNumber] as String?)
          ?.trim();
      if (invoice == null || invoice.isEmpty || !seen.add(invoice)) continue;

      final joinedGross = (row[SaleJoinColumns.subtotal] as num?)?.toDouble();
      final joinedSeasonal =
          (row[SaleJoinColumns.seasonalIncrementTotal] as num?)?.toDouble();
      final joinedItemDisc = (row[SaleJoinColumns.itemDiscountsTotal] as num?)
          ?.toDouble();
      final joinedOverall = (row[SaleJoinColumns.overallDiscount] as num?)
          ?.toDouble();
      final batch = _invoiceSaleDiscounts[invoice];

      gross += joinedGross ?? batch?['subtotal'] ?? 0;
      seasonal += joinedSeasonal ?? batch?['seasonal_increment_total'] ?? 0;
      discounts +=
          (joinedItemDisc ?? batch?['item_discounts_total'] ?? 0) +
          (joinedOverall ?? batch?['overall_discount'] ?? 0);
    }
    return {
      'grossSales': gross,
      'seasonalIncrements': seasonal,
      'totalDiscounts': discounts,
    };
  }

  Future<void> _handleExportPdf() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final rows = _visibleTransactions;
      final file = await PdfGenerator.saveZamindarTransactionLedgerToDocuments(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        transactions: rows,
        outstandingBalance: _outstandingBalanceDisplay,
        totalPaymentsReceived: _filteredTotalCredit,
        totalDebit: _filteredTotalDebit,
        itemSummaries: _invoiceItemSummaries,
        saleRemarks: _invoiceSaleRemarks,
      );
      if (!mounted) return;
      AppToast.showSuccess(context, 'PDF saved to ${file.path}');
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to export PDF: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleShareWhatsAppPdf() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final rows = _visibleTransactions;
      final file = await PdfGenerator.saveZamindarTransactionLedgerToDocuments(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        transactions: rows,
        outstandingBalance: _outstandingBalanceDisplay,
        totalPaymentsReceived: _filteredTotalCredit,
        totalDebit: _filteredTotalDebit,
        itemSummaries: _invoiceItemSummaries,
        saleRemarks: _invoiceSaleRemarks,
      );

      final shopName = await ShopSettings.getShopName();
      await WhatsAppUrduService.sharePdfWithUrduCaption(
        phone: _zamindarWhatsapp,
        zamindarName: _zamindarName,
        shopName: shopName,
        amount: _outstandingBalanceAmount,
        pdfPath: file.path,
        subject: 'AgriKhata Ledger — $_zamindarName',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to share via WhatsApp: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handlePrint() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      final rows = _visibleTransactions;
      final pdf = await PdfGenerator.generateZamindarTransactionLedgerPdf(
        zamindarName: _zamindarName,
        seasonLabel: _selectedSeason,
        transactions: rows,
        outstandingBalance: _outstandingBalanceDisplay,
        totalPaymentsReceived: _filteredTotalCredit,
        totalDebit: _filteredTotalDebit,
        itemSummaries: _invoiceItemSummaries,
        saleRemarks: _invoiceSaleRemarks,
      );
      await PdfGenerator.printDocument(pdf);
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to print: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadError!,
              style: const TextStyle(color: AppColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _loadLedgerData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatsBar(),
            const SizedBox(height: 8),
            _buildFilterBar(),
            const SizedBox(height: 8),
            Expanded(child: _buildLedgerList()),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsBar() {
    final adj = _filteredSaleAdjustments;
    final stats = [
      _LedgerStat(
        label: 'Gross Base',
        value: 'Rs ${_fmt(adj['grossSales'] ?? 0)}',
        color: const Color(0xFF1B4332),
      ),
      _LedgerStat(
        label: 'Seasonal Inc',
        value: 'Rs ${_fmt(adj['seasonalIncrements'] ?? 0)}',
        color: const Color(0xFF0C447C),
      ),
      _LedgerStat(
        label: 'Discounts',
        value: 'Rs ${_fmt(adj['totalDiscounts'] ?? 0)}',
        color: const Color(0xFF28A745),
      ),
      _LedgerStat(
        label: 'Net Debit',
        value: 'Rs ${_fmt(_filteredTotalDebit.toDouble())}',
        color: const Color(0xFFA32D2D),
      ),
      _LedgerStat(
        label: 'Payments',
        value: 'Rs ${_fmt(_filteredTotalCredit.toDouble())}',
        color: const Color(0xFF0C447C),
      ),
      _LedgerStat(
        label: 'Outstanding',
        value: _outstandingBalanceDisplay,
        color: const Color(0xFF27500A),
        emphasize: true,
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < stats.length; i++) ...[
              if (i > 0)
                Container(
                  width: 1,
                  height: 18,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: AppColors.border,
                ),
              _statCell(stats[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statCell(_LedgerStat stat) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${stat.label}: ',
          style: TextStyle(
            fontSize: 11,
            fontWeight: stat.emphasize ? FontWeight.w600 : FontWeight.w500,
            color: AppColors.textMuted,
          ),
        ),
        Text(
          stat.value,
          style: TextStyle(
            fontSize: stat.emphasize ? 13 : 12,
            fontWeight: FontWeight.w700,
            color: stat.color,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterBar() {
    return AppSearchBar(
      controller: _searchController,
      hintText: 'Search Invoice #, Kisaan or items...',
      breakpoint: 1100,
      filters: [
        AppFilterDropdown(
          options: _seasons,
          value: _selectedSeason,
          onChanged: (val) {
            if (val != null) setState(() => _selectedSeason = val);
          },
        ),
        Text(
          "${_visibleLedgerRows.length} txns",
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        AppButton.secondary(
          label: 'Print',
          icon: Icons.print_outlined,
          compact: true,
          loading: _isExporting,
          onPressed: _isExporting ? null : _handlePrint,
        ),
        AppButton.whatsapp(
          label: 'WhatsApp PDF',
          compact: true,
          loading: _isExporting,
          onPressed: _isExporting ? null : _handleShareWhatsAppPdf,
        ),
        AppButton.pdf(
          label: 'Export PDF',
          compact: true,
          loading: _isExporting,
          onPressed: _isExporting ? null : _handleExportPdf,
        ),
      ],
    );
  }

  List<ZamindarLedgerRow> get _filteredLedgerRows {
    return ZamindarLedgerRow.fromTransactions(
      transactions: _filteredTransactions,
      itemSummaries: _invoiceItemSummaries,
      collections: _invoiceCollections,
      saleDiscounts: _invoiceSaleDiscounts,
      saleRemarks: _invoiceSaleRemarks,
    );
  }

  List<ZamindarLedgerRow> get _visibleLedgerRows {
    final rows = _filteredLedgerRows;
    if (_ledgerSubTab == 1) {
      return rows.where((row) => row.isPaymentHistoryRow).toList();
    }
    return rows.where((row) => row.isPurchaseRow).toList();
  }

  List<Map<String, dynamic>> get _visibleTransactions =>
      _visibleLedgerRows.map((row) => row.source).toList();

  Widget _buildLedgerSubTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          height: 30,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F4EE),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ledgerSubTabButton(
                index: 0,
                label: 'Purchases',
                icon: Icons.shopping_bag_outlined,
              ),
              _ledgerSubTabButton(
                index: 1,
                label: 'Payment History',
                icon: Icons.payments_outlined,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ledgerSubTabButton({
    required int index,
    required String label,
    required IconData icon,
  }) {
    final isActive = _ledgerSubTab == index;
    return InkWell(
      onTap: () => setState(() => _ledgerSubTab = index),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? const Color(0xFFC6DEC9) : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isActive ? AppColors.darkGreen : AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive ? AppColors.darkGreen : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLedgerList() {
    final rows = _visibleLedgerRows;

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
          _buildLedgerSubTabs(),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      _ledgerSubTab == 1
                          ? 'No payment records yet'
                          : 'No purchase invoices yet',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final minWidth = 1120.0;
                      final width = constraints.maxWidth < minWidth
                          ? minWidth
                          : constraints.maxWidth;
                      return Scrollbar(
                        controller: _tableHScrollController,
                        thumbVisibility: constraints.maxWidth < minWidth,
                        child: SingleChildScrollView(
                          controller: _tableHScrollController,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: width,
                            height: constraints.maxHeight,
                            child: ZamindarLedgerTable(
                              rows: rows,
                              embedded: true,
                              actionsWidth: _ledgerSubTab == 1 ? 80 : 120,
                              actionsBuilder: (context, row) =>
                                  _buildRowActions(row),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRowActions(ZamindarLedgerRow row) {
    final source = row.source;
    final category = row.category;
    final isDebit = row.isDebit;
    final invoiceNumber =
        source[LedgerTransactionTable.invoiceNumber] as String?;
    final hasInvoice = invoiceNumber != null && invoiceNumber.isNotEmpty;
    final isSale = category == 'SALE' && isDebit && hasInvoice;
    final isAdvance =
        isDebit &&
        hasInvoice &&
        (category == 'ADVANCE_LOAN_RECORD' ||
            category == 'CASH_ADVANCE' ||
            category == 'DIESEL_ADVANCE' ||
            category == 'PETROL_ADVANCE');
    final isPayment = row.isEditablePayment;

    if (!isSale && !isAdvance && !isPayment) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (isPayment) ...[
          _actionIconButton(
            icon: Icons.edit,
            iconColor: const Color(0xFF1B4332),
            borderColor: const Color(0xFFC6DEC9),
            tooltip: row.isWalletDeduction
                ? 'Edit Wallet Deduction'
                : 'Edit Payment',
            onTap: () => _handleEditPayment(
              row.paymentId!,
              seasonLabel: source[LedgerTransactionTable.season] as String?,
              seasonId: source[LedgerTransactionTable.seasonId] as int?,
            ),
          ),
          const SizedBox(width: 6),
          _actionIconButton(
            icon: Icons.delete,
            iconColor: const Color(0xFFDC3545),
            borderColor: const Color(0xFFF5C6C6),
            tooltip: 'Delete',
            onTap: () => _handleDeletePayment(
              row.paymentId!,
              seasonLabel: source[LedgerTransactionTable.season] as String?,
              seasonId: source[LedgerTransactionTable.seasonId] as int?,
            ),
          ),
        ],
        if (isSale || isAdvance) ...[
          _actionIconButton(
            icon: Icons.edit,
            iconColor: const Color(0xFF1B4332),
            borderColor: const Color(0xFFC6DEC9),
            tooltip: 'Edit',
            onTap: () => isAdvance
                ? _handleEditAdvance(
                    invoiceNumber,
                    seasonLabel:
                        source[LedgerTransactionTable.season] as String?,
                    seasonId: source[LedgerTransactionTable.seasonId] as int?,
                  )
                : _handleEditInvoice(
                    invoiceNumber,
                    seasonLabel:
                        source[LedgerTransactionTable.season] as String?,
                    seasonId: source[LedgerTransactionTable.seasonId] as int?,
                  ),
          ),
          const SizedBox(width: 6),
          _actionIconButton(
            icon: Icons.delete,
            iconColor: const Color(0xFFDC3545),
            borderColor: const Color(0xFFF5C6C6),
            tooltip: 'Delete',
            onTap: () => _handleDeleteInvoice(
              invoiceNumber,
              seasonLabel: source[LedgerTransactionTable.season] as String?,
              seasonId: source[LedgerTransactionTable.seasonId] as int?,
            ),
          ),
          const SizedBox(width: 6),
          _actionIconButton(
            icon: Icons.payments_outlined,
            iconColor: const Color(0xFF1B4332),
            borderColor: const Color(0xFFC6DEC9),
            tooltip: 'Bill Settlement',
            onTap: () => _showBillSettlementDialog(source),
          ),
        ],
      ],
    );
  }

  Future<void> _handleEditPayment(
    String paymentId, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    final updated = await showEditPaymentDialog(
      context: context,
      paymentId: paymentId,
    );
    if (updated && mounted) {
      AppToast.showSuccess(context, 'Payment updated');
      await _loadLedgerData(showLoading: false);
    }
  }

  Future<void> _handleDeletePayment(
    String paymentId, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    final confirmed = await AppDialog.confirm(
      context: context,
      title: 'Delete Payment?',
      message:
          'Are you sure you want to delete this payment record? This will revert the balance changes.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (confirmed != true) return;

    try {
      await PaymentService.instance.deletePayment(paymentId: paymentId);
      if (mounted) {
        AppToast.showSuccess(context, 'Payment deleted');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to delete payment: $e');
      }
    }
  }

  Future<void> _handleEditAdvance(
    String invoiceNumber, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    final updated = await showEditCashAdvanceDialog(
      context: context,
      invoiceNumber: invoiceNumber,
    );
    if (updated && mounted) {
      await _loadLedgerData(showLoading: false);
    }
  }

  Future<void> _handleEditInvoice(
    String invoiceNumber, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    if (widget.onEditInvoice != null) {
      widget.onEditInvoice!(invoiceNumber);
      return;
    }

    // Fallback when opened outside Shell (e.g. pushed profile).
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => NewSaleScreen(
          editInvoiceNumber: invoiceNumber,
          onCancelEdit: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  Future<void> _handleDeleteInvoice(
    String invoiceNumber, {
    String? seasonLabel,
    int? seasonId,
  }) async {
    final allowed = await ensurePastSeasonWriteAccess(
      context,
      seasonId: seasonId,
      seasonLabel: seasonLabel,
    );
    if (!allowed || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Transaction?'),
        content: const Text(
          'Are you sure you want to delete this transaction and all associated payments?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFDC3545),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await DatabaseHelper.instance.deleteInvoiceEntirely(invoiceNumber);
      if (mounted) {
        AppToast.showSuccess(context, 'Invoice $invoiceNumber deleted');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to delete invoice: $e');
      }
    }
  }

  Widget _actionIconButton({
    required IconData icon,
    required Color iconColor,
    required Color borderColor,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Icon(icon, size: 14, color: iconColor),
      ),
    );
    if (tooltip == null || tooltip.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Future<void> _showBillSettlementDialog(Map<String, dynamic> row) async {
    final transaction = LedgerTransaction.fromMap(row);
    final invoiceNumber = transaction.invoiceNumber;

    if (invoiceNumber == null || invoiceNumber.isEmpty) {
      if (mounted) {
        AppToast.showError(context, 'This sale is not linked to an invoice.');
      }
      return;
    }

    double remainingBalance;
    try {
      remainingBalance = await DatabaseHelper.instance
          .getInvoiceRemainingBalance(invoiceNumber);
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Could not load invoice balance: $e');
      }
      return;
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => _InvoiceBillSettlementDialog(
        row: row,
        transaction: transaction,
        invoiceNumber: invoiceNumber,
        totalAmount: transaction.amount.toDouble(),
        remainingBalance: remainingBalance,
        zamindarWhatsapp: _zamindarWhatsapp,
        onSettlementComplete: _loadLedgerData,
      ),
    );
  }

  String _fmt(double value) {
    final formatted = value.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);
      final pos = i + 1;
      if (pos == 3 || (pos > 3 && (pos - 3) % 2 == 0)) {
        if (i != chars.length - 1) buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }
}

class _LedgerStat {
  final String label;
  final String value;
  final Color color;
  final bool emphasize;

  const _LedgerStat({
    required this.label,
    required this.value,
    required this.color,
    this.emphasize = false,
  });
}

class _InvoiceBillSettlementDialog extends StatefulWidget {
  final Map<String, dynamic> row;
  final LedgerTransaction transaction;
  final String invoiceNumber;
  final double totalAmount;
  final double remainingBalance;
  final String zamindarWhatsapp;
  final Future<void> Function() onSettlementComplete;

  const _InvoiceBillSettlementDialog({
    required this.row,
    required this.transaction,
    required this.invoiceNumber,
    required this.totalAmount,
    required this.remainingBalance,
    required this.zamindarWhatsapp,
    required this.onSettlementComplete,
  });

  @override
  State<_InvoiceBillSettlementDialog> createState() =>
      _InvoiceBillSettlementDialogState();
}

class _InvoiceBillSettlementDialogState
    extends State<_InvoiceBillSettlementDialog> {
  late final TextEditingController _amountController;
  final _walletAmountController = TextEditingController();
  final _remarksController = TextEditingController();
  bool _showReceiptActions = false;
  bool _isSubmitting = false;
  bool _deductFromWallet = false;
  double _availableAdvance = 0;
  BillSettlementResult? _settlementResult;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: widget.remainingBalance > 0
          ? widget.remainingBalance.toStringAsFixed(0)
          : '',
    );
    _amountController.addListener(() => setState(() {}));
    _walletAmountController.addListener(() => setState(() {}));
    _loadAdvanceBalance();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _walletAmountController.dispose();
    _remarksController.dispose();
    super.dispose();
  }

  Future<void> _loadAdvanceBalance() async {
    try {
      final balance = await DatabaseHelper.instance.getAdvanceBalance(
        widget.transaction.zamindarId,
      );
      if (!mounted) return;
      setState(() => _availableAdvance = balance.toDouble());
    } catch (_) {
      if (!mounted) return;
      setState(() => _availableAdvance = 0);
    }
  }

  double? get _enteredAmount => double.tryParse(_amountController.text.trim());

  bool get _canSubmit {
    if (_isSubmitting) return false;
    final amt = _enteredAmount;
    if (amt == null || amt <= 0) return false;
    if (amt > widget.remainingBalance) return false;
    if (widget.remainingBalance <= 0) return false;
    return SettlementSplitFields.isWalletDeductionValid(
      deductFromWallet: _deductFromWallet,
      rawText: _walletAmountController.text,
      availableAdvance: _availableAdvance,
      outstandingDues: widget.remainingBalance,
      settlementAmount: amt,
    );
  }

  String _fmt(double value) {
    final formatted = value.toStringAsFixed(0);
    final chars = formatted.split('').reversed.toList();
    final buffer = StringBuffer();
    for (int i = 0; i < chars.length; i++) {
      buffer.write(chars[i]);
      final pos = i + 1;
      if (pos == 3 || (pos > 3 && (pos - 3) % 2 == 0)) {
        if (i != chars.length - 1) buffer.write(',');
      }
    }
    return buffer.toString().split('').reversed.join('');
  }

  Widget _buildDialogRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: valueColor ?? AppColors.darkGreen,
          ),
        ),
      ],
    );
  }

  Future<void> _submitPayment() async {
    final amount = _enteredAmount!;
    final walletDeduction = SettlementSplitFields.walletDeductionAmount(
      deductFromWallet: _deductFromWallet,
      rawText: _walletAmountController.text,
    );
    final remarks = _remarksController.text.trim();
    setState(() => _isSubmitting = true);

    try {
      final zamindar = await DatabaseHelper.instance.getZamindar(
        widget.transaction.zamindarId,
      );

      String? kisaanName = widget.row['kisaan_name'] as String?;
      if (kisaanName == null && widget.transaction.kisaanId != null) {
        final kisaan = await DatabaseHelper.instance.getKisaan(
          widget.transaction.kisaanId!,
        );
        kisaanName = kisaan?.name;
      }

      final now = DateTime.now();
      final paymentId = await DatabaseHelper.instance.insertPayment(
        invoiceNumber: widget.invoiceNumber,
        zamindarId: widget.transaction.zamindarId,
        dateTime: now,
        zamindarName: zamindar?.name ?? 'Unknown',
        kisaanName: kisaanName,
        kisaanId: widget.transaction.kisaanId,
        amountPaid: amount,
        paymentMethod: 'Cash',
        season: widget.transaction.season,
        walletDeductionAmount: walletDeduction,
        remarks: remarks.isEmpty ? null : remarks,
      );

      final invoiceSummary = await DatabaseHelper.instance
          .getInvoiceSettlementSnapshot(
            widget.invoiceNumber,
            cashPaidNow: amount,
          );

      await widget.onSettlementComplete();

      if (!mounted) return;
      setState(() {
        _settlementResult = BillSettlementResult(
          zamindarId: widget.transaction.zamindarId,
          zamindarName: zamindar?.name ?? 'Unknown',
          kisaanId: widget.transaction.kisaanId,
          kisaanName: kisaanName ?? 'Self',
          amountPaid: amount,
          walletDeductionAmount: walletDeduction,
          cashReceivedAmount: amount - walletDeduction,
          remarks: remarks.isEmpty ? null : remarks,
          invoiceNumbers: [widget.invoiceNumber],
          paymentId: paymentId,
          dateTime: now,
          description: DatabaseHelper.formatBillPaymentDescription(
            widget.invoiceNumber,
          ),
          paymentMethod: walletDeduction > 0 && amount - walletDeduction > 0
              ? 'Cash + Advance Wallet'
              : walletDeduction > 0
              ? 'Advance Wallet Deduction'
              : 'Cash',
          invoiceSummaries: [invoiceSummary],
        );
        _showReceiptActions = true;
        _isSubmitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      AppToast.showError(context, 'Failed to record payment: $e');
    }
  }

  Future<void> _printReceipt() async {
    final result = _settlementResult;
    if (result == null) return;
    try {
      await PdfGenerator.printBillSettlementReceipt(
        zamindarName: result.zamindarName,
        kisaanName: result.kisaanName,
        amount: result.amountPaid.round(),
        invoiceNumbers: result.invoiceNumbers,
        invoiceSummaries: result.invoiceSummaries,
        date: result.dateTime,
        paymentMethod: result.paymentMethod,
      );
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to print receipt: $e');
      }
    }
  }

  Future<void> _shareWhatsAppPdf() async {
    final result = _settlementResult;
    if (result == null) return;
    try {
      final shopName = await ShopSettings.getShopName();
      final file = await PdfGenerator.saveBillSettlementReceiptToDocuments(
        zamindarName: result.zamindarName,
        kisaanName: result.kisaanName,
        amount: result.amountPaid.round(),
        invoiceNumbers: result.invoiceNumbers,
        invoiceSummaries: result.invoiceSummaries,
        date: result.dateTime,
        paymentMethod: result.paymentMethod,
      );
      await WhatsAppUrduService.sharePdfWithUrduCaption(
        phone: widget.zamindarWhatsapp,
        zamindarName: result.zamindarName,
        shopName: shopName,
        amount: result.amountPaid,
        pdfPath: file.path,
        detailLines: ['کسان: ${result.kisaanName}', result.description],
        subject: 'Bill Settlement — ${result.zamindarName}',
      );
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Failed to share via WhatsApp: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      content: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.darkGreen,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Bill Settlement',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFFA7C4A0),
                        size: 18,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              if (!_showReceiptActions) ...[
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.7,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildDialogRow('Invoice:', widget.invoiceNumber),
                        const SizedBox(height: 8),
                        _buildDialogRow(
                          'Invoice Total:',
                          'Rs ${_fmt(widget.totalAmount)}',
                        ),
                        const SizedBox(height: 8),
                        _buildDialogRow(
                          'Remaining Balance:',
                          'Rs ${_fmt(widget.remainingBalance)}',
                          valueColor: const Color(0xFFA32D2D),
                        ),
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 16),
                        const Text(
                          'Total Settlement Amount',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _amountController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.darkGreen,
                          ),
                          onChanged: (value) {
                            final amt = double.tryParse(value.trim());
                            if (amt != null && amt > widget.remainingBalance) {
                              _amountController.text = widget.remainingBalance
                                  .toStringAsFixed(0);
                              _amountController.selection =
                                  TextSelection.fromPosition(
                                    TextPosition(
                                      offset: _amountController.text.length,
                                    ),
                                  );
                            }
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            prefixText: 'Rs ',
                            prefixStyle: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: AppColors.darkGreen,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            hintText: '0',
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: const BorderSide(
                                color: AppColors.sidebarBg,
                                width: 0.5,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: const BorderSide(
                                color: AppColors.darkGreen,
                                width: 1,
                              ),
                            ),
                            errorText:
                                _amountController.text.trim().isNotEmpty &&
                                    (_enteredAmount ?? 0) >
                                        widget.remainingBalance
                                ? 'Cannot exceed remaining balance (Rs ${_fmt(widget.remainingBalance)})'
                                : _amountController.text.trim().isNotEmpty &&
                                      (_enteredAmount ?? 0) <= 0
                                ? 'Enter a valid amount'
                                : null,
                            errorStyle: const TextStyle(fontSize: 9),
                          ),
                        ),
                        if (widget.remainingBalance <= 0) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'This invoice is already fully settled.',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFA32D2D),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        SettlementSplitFields(
                          availableAdvance: _availableAdvance,
                          outstandingDues: widget.remainingBalance,
                          settlementAmount: _enteredAmount ?? 0,
                          deductFromWallet: _deductFromWallet,
                          onDeductFromWalletChanged: (value) {
                            setState(() {
                              _deductFromWallet = value;
                              if (!value) _walletAmountController.clear();
                            });
                          },
                          walletAmountController: _walletAmountController,
                          remarksController: _remarksController,
                          formatAmount: _fmt,
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFAFAFA),
                    border: Border(
                      top: BorderSide(color: AppColors.border, width: 0.5),
                    ),
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _canSubmit ? _submitPayment : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B4332),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFB0B0B0),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Confirm Settlement',
                                style: TextStyle(fontSize: 12),
                              ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 20,
                        backgroundColor: Color(0xFFEAF3DE),
                        child: Icon(
                          Icons.check_circle_outline,
                          color: Color(0xFF27500A),
                          size: 24,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Ledger Updated Successfully',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkGreen,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Payment recorded for ${widget.invoiceNumber}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppColors.border,
                            width: 0.5,
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Amount Settled:',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  'Rs ${_fmt(_settlementResult?.amountPaid ?? 0)}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF27500A),
                                  ),
                                ),
                              ],
                            ),
                            if ((_settlementResult?.walletDeductionAmount ??
                                    0) >
                                0) ...[
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Wallet Deducted:',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    'Rs ${_fmt(_settlementResult!.walletDeductionAmount)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF0C447C),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Cash Received:',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    'Rs ${_fmt(_settlementResult!.cashReceivedAmount)}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.darkGreen,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _printReceipt,
                              icon: const Icon(Icons.print, size: 14),
                              label: const Text(
                                'Print Receipt',
                                style: TextStyle(fontSize: 11),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _shareWhatsAppPdf,
                              icon: const Icon(Icons.send, size: 14),
                              label: const Text(
                                'WhatsApp PDF',
                                style: TextStyle(fontSize: 11),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF25D366),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          'Done & Close Window',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
