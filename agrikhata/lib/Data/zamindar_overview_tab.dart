import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/edit_payment_dialog.dart';
import 'package:agrikhata/Widgets/ledger_widgets.dart';
import 'package:agrikhata/services/session_context.dart';
import 'package:agrikhata/services/whatsapp_urdu_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/season_utils.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ZamindarOverviewTab extends StatefulWidget {
  final Zamindar zamindar;
  final VoidCallback onNavigateToAddKisaan;
  final VoidCallback? onNavigateToLedger;
  final VoidCallback? onRefresh;
  final VoidCallback? onNavigateToSaleWithZamindar;

  const ZamindarOverviewTab({
    super.key,
    required this.zamindar,
    required this.onNavigateToAddKisaan,
    this.onNavigateToLedger,
    this.onRefresh,
    this.onNavigateToSaleWithZamindar,
  });

  @override
  State<ZamindarOverviewTab> createState() => _ZamindarOverviewTabState();
}

class _ZamindarOverviewTabState extends State<ZamindarOverviewTab> {
  static final _productLedgerDateFormat = DateFormat('dd MMM yyyy');
  static final _productLedgerTimeFormat = DateFormat('hh:mm a');

  String _outstandingBalanceDisplay = "Rs. 0";
  bool _isLoading = true;
  int _advanceBalance = 0;
  List<ZamindarProductLedgerEntry> _productLedgerEntries = const [];
  Set<String> _selectedProducts = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    // Listen for database changes and auto-refresh
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  @override
  void dispose() {
    // Remove database listener to prevent memory leaks
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(ZamindarOverviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload data whenever widget updates (e.g., when tab becomes visible)
    _loadData();
  }

  void _onDatabaseChanged() => _loadData(showLoading: false);

  Future<void> _loadData({bool showLoading = true}) async {
    if (widget.zamindar.id == null) {
      if (showLoading) setState(() => _isLoading = false);
      return;
    }

    if (showLoading) setState(() => _isLoading = true);

    try {
      // Use centralized method for outstanding balance
      final outstandingBalance = await DatabaseHelper.instance
          .getOutstandingBalanceString(widget.zamindar.id!);
      final advBalance = await DatabaseHelper.instance.getAdvanceBalance(
        widget.zamindar.id!,
      );
      final productLedger = await DatabaseHelper.instance
          .getZamindarProductWiseLedgerEntries(widget.zamindar.id!);

      if (!mounted) return;
      setState(() {
        _outstandingBalanceDisplay = outstandingBalance;
        _advanceBalance = advBalance;
        _productLedgerEntries = productLedger;
        // Drop selections for products that no longer appear in the ledger.
        final available = productLedger.map((e) => e.productName).toSet();
        _selectedProducts = _selectedProducts.where(available.contains).toSet();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final mainColumn = Column(
      children: [
        _buildLandCreditCard(),
        const SizedBox(height: 14),
        _buildProductWiseLedgerCard(),
        const SizedBox(height: 14),
        _buildRecentTransactionsCard(),
      ],
    );

    final sidebarColumn = Column(
      children: [
        _buildQuickActionsCard(context),
        const SizedBox(height: 14),
        _buildCropsCard(),
        const SizedBox(height: 14),
        _buildPaymentTermsCard(),
        const SizedBox(height: 14),
        _buildAdvancePaymentCard(),
      ],
    );

    return Material(
      color: Colors.transparent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const pad = 20.0;
          final maxW = constraints.maxWidth - (pad * 2);
          final stack = maxW < 720;
          final content = stack
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    mainColumn,
                    const SizedBox(height: 14),
                    sidebarColumn,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: (maxW - 234).clamp(200.0, double.infinity),
                      child: mainColumn,
                    ),
                    const SizedBox(width: 14),
                    SizedBox(width: 220, child: sidebarColumn),
                  ],
                );

          return SingleChildScrollView(
            padding: const EdgeInsets.all(pad),
            child: content,
          );
        },
      ),
    );
  }

  Widget _card({
    required String title,
    required Widget child,
    Widget? trailing,
    bool padChild = true,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.darkGreen,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  trailing,
                ],
              ],
            ),
          ),
          if (padChild)
            Padding(padding: const EdgeInsets.all(14), child: child)
          else
            child,
        ],
      ),
    );
  }

  Widget _buildLandCreditCard() {
    // Extract numeric value from display string for limit checking
    final outstandingValue =
        int.tryParse(
          _outstandingBalanceDisplay.replaceAll(RegExp(r'[^0-9]'), ''),
        ) ??
        0;

    final creditLimit = widget.zamindar.creditLimit.toDouble();
    final isOverLimit = outstandingValue > creditLimit;
    final usedColor = isOverLimit
        ? const Color(0xFFA32D2D)
        : const Color(0xFF27500A);

    return _card(
      title: "Land & credit details",
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: _infoItem(
              "Total land",
              "${widget.zamindar.totalLandAcres.toStringAsFixed(0)} ${widget.zamindar.landUnit}",
              "",
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 1,
            child: _infoItem(
              "Credit limit",
              "Rs ${_fmt(creditLimit)}",
              "Set by owner",
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 1,
            child: _infoItem(
              "Total outstanding balance",
              _outstandingBalanceDisplay,
              isOverLimit
                  ? "Rs ${_fmt((outstandingValue - creditLimit).clamp(0.0, double.infinity))} over"
                  : "Within limit",
              valueColor: usedColor,
              subColor: usedColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 1,
            child: _infoItem(
              "Advance paid",
              "Rs ${_fmt(_advanceBalance.toDouble())}",
              "Pre-payment",
              valueColor: Colors.blue[700],
              subColor: Colors.blue[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoItem(
    String label,
    String value,
    String sub, {
    Color? valueColor,
    Color? subColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9F4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: valueColor ?? AppColors.darkGreen,
              letterSpacing: -0.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              sub,
              style: TextStyle(
                fontSize: 11,
                color: subColor ?? AppColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCropsCard() {
    final seasons = widget.zamindar.activeSeasons;
    final crops = widget.zamindar.activeCrops;

    return _card(
      title: "Seasons & crops",
      child: seasons.isEmpty && crops.isEmpty
          ? const Text(
              'None configured',
              style: TextStyle(fontSize: 11, color: AppColors.textMuted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (seasons.isNotEmpty) ...[
                  const Text(
                    'Seasons',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: seasons
                        .map(
                          (s) => _chip(
                            s,
                            const Color(0xFFFAEEDA),
                            const Color(0xFF633806),
                          ),
                        )
                        .toList(),
                  ),
                ],
                if (seasons.isNotEmpty && crops.isNotEmpty)
                  const SizedBox(height: 10),
                if (crops.isNotEmpty) ...[
                  const Text(
                    'Crops',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: crops
                        .map(
                          (c) => _chip(
                            c,
                            const Color(0xFFEAF3DE),
                            const Color(0xFF27500A),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _chip(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }

  List<String> get _distinctProducts {
    final names = _productLedgerEntries
        .map((e) => e.productName)
        .where((n) => n.trim().isNotEmpty)
        .toSet()
        .toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  List<ZamindarProductLedgerEntry> get _filteredProductLedger {
    if (_selectedProducts.isEmpty) return _productLedgerEntries;
    return _productLedgerEntries
        .where((e) => _selectedProducts.contains(e.productName))
        .toList();
  }

  int get _filteredProductTotalQty =>
      _filteredProductLedger.fold<int>(0, (sum, item) => sum + item.quantity);

  int get _filteredProductTotalValue =>
      _filteredProductLedger.fold<int>(0, (sum, item) => sum + item.lineTotal);

  String get _filteredProductTotalUom {
    final uoms = _filteredProductLedger.map((e) => e.uom).toSet();
    if (uoms.length == 1) return uoms.first;
    return 'units';
  }

  Future<void> _generateProductWiseLedgerPdf() async {
    final filtered = _filteredProductLedger;
    if (filtered.isEmpty) {
      if (!mounted) return;
      AppToast.showWarning(context, 'No product ledger rows to export');
      return;
    }

    try {
      final filterLabel = _selectedProducts.isEmpty
          ? 'All products'
          : _selectedProducts.join(', ');
      final rows = filtered
          .map(
            (e) => <String, dynamic>{
              'invoice_number': e.invoiceNumber,
              'date_time': e.dateTime,
              'kisaan_name': e.kisaanName,
              'product_name': e.productName,
              'quantity': e.quantity,
              'uom': e.uom,
              'unit_price': e.unitPrice,
              'line_total': e.lineTotal,
            },
          )
          .toList();

      final file = await PdfGenerator.saveProductWiseLedgerToDocuments(
        zamindarName: widget.zamindar.name,
        rows: rows,
        filterLabel: filterLabel,
        totalQuantity: _filteredProductTotalQty,
        totalUom: _filteredProductTotalUom,
        totalValue: _filteredProductTotalValue,
      );

      if (!mounted) return;
      AppToast.showSuccess(context, 'PDF saved to ${file.path}');
    } catch (e) {
      if (!mounted) return;
      AppToast.showError(context, 'Failed to generate PDF: $e');
    }
  }

  Widget _buildProductWiseLedgerCard() {
    final products = _distinctProducts;
    final filtered = _filteredProductLedger;
    final totalQty = _filteredProductTotalQty;
    final totalUom = _filteredProductTotalUom;
    final totalValue = _filteredProductTotalValue;
    final hasSelection = _selectedProducts.isNotEmpty;

    return _card(
      title: "Product-wise ledger",
      padChild: false,
      trailing: AppButton.pdf(
        compact: true,
        onPressed: _generateProductWiseLedgerPdf,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (products.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: products.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final name = products[index];
                    final selected = _selectedProducts.contains(name);
                    return FilterChip(
                      label: Text(name),
                      selected: selected,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                      onSelected: (isSelected) {
                        setState(() {
                          if (isSelected) {
                            _selectedProducts = {..._selectedProducts, name};
                          } else {
                            _selectedProducts = {..._selectedProducts}
                              ..remove(name);
                          }
                        });
                      },
                      labelStyle: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? AppColors.tagGreenText
                            : AppColors.textMuted,
                      ),
                      selectedColor: AppColors.tagGreenBg,
                      backgroundColor: const Color(0xFFEEF3EC),
                      side: BorderSide(
                        color: selected
                            ? AppColors.accentGreen
                            : AppColors.border,
                        width: 0.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF3EC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.6),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.border, width: 0.5),
                      ),
                      child: const Icon(
                        Icons.inventory_2_outlined,
                        size: 18,
                        color: AppColors.darkGreen,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasSelection
                                ? 'Selected product quantity'
                                : 'Total quantity issued',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textMuted,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$totalQty $totalUom',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppColors.darkGreen,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(width: 1, height: 36, color: AppColors.border),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasSelection
                                ? 'Selected product value'
                                : 'Total value issued',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textMuted,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Rs ${_fmt(totalValue.toDouble())}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: AppColors.darkGreen,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (hasSelection)
                      TextButton(
                        onPressed: () => setState(() => _selectedProducts = {}),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.accentGreen,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Clear',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (_productLedgerEntries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No product purchases yet',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            )
          else if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No rows match the selected products',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth < 920
                    ? 920.0
                    : constraints.maxWidth;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: width,
                    child: Column(
                      children: [
                        _buildProductLedgerHeader(),
                        ...List.generate(filtered.length, (index) {
                          return _buildProductLedgerRow(
                            filtered[index],
                            index.isOdd,
                          );
                        }),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildProductLedgerHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFFEEF3EC),
        border: Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
          bottom: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              'INVOICE NO',
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              'DATE / TIME',
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'KISAAN NAME',
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'PRODUCT NAME',
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              'QUANTITY',
              textAlign: TextAlign.right,
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              'PRODUCT PRICE',
              textAlign: TextAlign.right,
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              'TOTAL PRICE',
              textAlign: TextAlign.right,
              style: _productLedgerHeaderStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductLedgerRow(
    ZamindarProductLedgerEntry entry,
    bool highlight,
  ) {
    final dateLabel =
        '${_productLedgerDateFormat.format(entry.dateTime)} · '
        '${_productLedgerTimeFormat.format(entry.dateTime)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: highlight
            ? const Color(0xFFEEF3EC).withValues(alpha: 0.45)
            : Colors.white,
        border: const Border(
          bottom: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              entry.invoiceNumber.isEmpty ? '—' : entry.invoiceNumber,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              dateLabel,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              entry.kisaanName,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              entry.productName,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              '${entry.quantity} ${entry.uom}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              'Rs ${_fmt(entry.unitPrice.toDouble())}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              'Rs ${_fmt(entry.lineTotal.toDouble())}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.darkGreen,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static const _productLedgerHeaderStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    color: AppColors.textMuted,
    letterSpacing: 0.4,
  );

  Widget _buildRecentTransactionsCard() {
    return _card(
      title: "Recent transactions",
      padChild: false,
      trailing: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onNavigateToLedger,
          child: const Text(
            "View full ledger",
            style: TextStyle(fontSize: 11, color: AppColors.accentGreen),
          ),
        ),
      ),
      child: FutureBuilder<List<ZamindarLedgerRow>>(
        future: _loadRecentLedgerRows(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(14),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }

          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Failed to load transactions',
                style: TextStyle(fontSize: 11, color: Colors.red[700]),
              ),
            );
          }

          final rows = snapshot.data ?? [];
          if (rows.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No transactions yet',
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth < 720
                  ? 720.0
                  : constraints.maxWidth;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  child: ZamindarLedgerTable(
                    rows: rows,
                    shrinkWrap: true,
                    embedded: true,
                    actionsWidth: 44,
                    actionsBuilder: (context, row) {
                      if (!row.isEditablePayment) {
                        return const SizedBox.shrink();
                      }
                      return Align(
                        alignment: Alignment.centerRight,
                        child: Tooltip(
                          message: 'Edit Payment',
                          child: InkWell(
                            onTap: () => _handleEditPayment(row.paymentId!),
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
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _handleEditPayment(String paymentId) async {
    final updated = await showEditPaymentDialog(
      context: context,
      paymentId: paymentId,
    );
    if (updated && mounted) {
      AppToast.showSuccess(context, 'Payment updated');
      setState(() {});
      widget.onRefresh?.call();
    }
  }

  Future<List<ZamindarLedgerRow>> _loadRecentLedgerRows() async {
    if (widget.zamindar.id == null) return const [];

    final transactions = await DatabaseHelper.instance.getLedgerTransactions(
      widget.zamindar.id!,
      limit: 4,
    );
    if (transactions.isEmpty) return const [];

    final invoiceNumbers = transactions
        .map((row) => row[LedgerTransactionTable.invoiceNumber] as String?)
        .whereType<String>()
        .toList();

    final itemSummaries = await DatabaseHelper.instance
        .getSaleItemsSummariesForInvoices(invoiceNumbers);
    final collections = await DatabaseHelper.instance
        .getInvoiceCollectionSummaries(invoiceNumbers);

    return ZamindarLedgerRow.fromTransactions(
      transactions: transactions,
      itemSummaries: itemSummaries,
      collections: collections,
    );
  }

  Widget _buildQuickActionsCard(BuildContext context) {
    return _card(
      title: "Quick actions",
      child: Column(
        children: [
          AppButton.primary(
            label: 'New sale for this Zamindar',
            icon: Icons.receipt_long_outlined,
            expanded: true,
            onPressed: widget.onNavigateToSaleWithZamindar,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            label: 'Add Kisaan',
            icon: Icons.person_add_outlined,
            expanded: true,
            onPressed: widget.onNavigateToAddKisaan,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.whatsapp(
            label: 'Send via WhatsApp',
            expanded: true,
            onPressed: _sendWhatsAppReminder,
          ),
        ],
      ),
    );
  }

  Future<void> _sendWhatsAppReminder() async {
    final phone = widget.zamindar.whatsappNumber.trim();
    if (WhatsAppUrduService.normalizePhone(phone) == null) {
      if (!mounted) return;
      AppToast.showError(
        context,
        'No WhatsApp number on file for ${widget.zamindar.name}.',
      );
      return;
    }

    try {
      double zamindarDebt = 0;
      final advancePayment = _advanceBalance.toDouble();
      final kisaanDebtLines = <String>[];
      var kisaanCount = 0;

      if (widget.zamindar.id != null) {
        final balances = await DatabaseHelper.instance.getZamindarBalancesSafe(
          widget.zamindar.id!,
        );
        zamindarDebt =
            (balances?['outstandingBalance'] as num?)?.toDouble() ?? 0;

        final kisaans = await DatabaseHelper.instance.getKisaansForZamindar(
          widget.zamindar.id!,
        );
        kisaanCount = kisaans.length;
        for (final kisaan in kisaans) {
          final due = kisaan.id != null
              ? await DatabaseHelper.instance.getKisaanBalanceDue(kisaan.id!)
              : 0.0;
          kisaanDebtLines.add(
            '${kisaan.name} — ${WhatsAppUrduService.formatAmount(due)}',
          );
        }
      }

      final ledgerSource = _selectedProducts.isEmpty
          ? _productLedgerEntries
          : _productLedgerEntries
                .where((e) => _selectedProducts.contains(e.productName))
                .toList();

      final ledgerLines = ledgerSource.map((e) {
        final date = _productLedgerDateFormat.format(e.dateTime);
        return '${e.productName} (${e.quantity} ${e.uom}) — '
            '${WhatsAppUrduService.formatAmount(e.lineTotal.toDouble())}'
            ' · ${e.kisaanName} · $date';
      }).toList();

      final ledgerTotalQty = ledgerSource.fold<int>(
        0,
        (sum, e) => sum + e.quantity,
      );
      final ledgerTotalValue = ledgerSource.fold<double>(
        0,
        (sum, e) => sum + e.lineTotal,
      );

      final shopName = await ShopSettings.getShopName();
      final launched = await WhatsAppUrduService.sendZamindarProfileSummary(
        phone: phone,
        zamindarName: widget.zamindar.name,
        fatherName: widget.zamindar.fathersName,
        shopName: shopName,
        zamindarDebt: zamindarDebt,
        advancePayment: advancePayment,
        kisaanCount: kisaanCount,
        kisaanDebtLines: kisaanDebtLines,
        ledgerLines: ledgerLines,
        ledgerTotalQty: ledgerTotalQty,
        ledgerTotalValue: ledgerTotalValue,
      );

      if (!mounted) return;
      if (launched) {
        AppToast.showSuccess(context, 'WhatsApp profile summary opened.');
      } else {
        AppToast.showError(context, 'Could not open WhatsApp.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Could not send WhatsApp summary: $e');
      }
    }
  }

  Widget _buildPaymentTermsCard() {
    return _card(
      title: "Payment terms",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.zamindar.paymentTerms.isEmpty)
            const Text(
              '—',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.darkGreen,
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.zamindar.paymentTerms
                  .map(
                    (term) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.tagGreenBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        term,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.tagGreenText,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 4),
          Text(
            widget.zamindar.paymentTerms.contains('After Harvest')
                ? "Payment expected after harvest — ${widget.zamindar.activeSeasons.join(' / ')}"
                : "Agreed payment schedule for credit sales",
            style: const TextStyle(fontSize: 10, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancePaymentCard() {
    return _card(
      title: "Advance payment",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 32,
                color: Colors.blue[700],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Current balance",
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Rs ${_fmt(_advanceBalance.toDouble())}",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue[700],
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _showReceiveAdvancePaymentDialog,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: const Icon(Icons.add_circle_outline, size: 15),
              label: const Text("Receive advance payment"),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "Pre-payments that will be adjusted against future sales",
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  void _showReceiveAdvancePaymentDialog() {
    final amountController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.payment, color: Colors.blue[700], size: 20),
              const SizedBox(width: 8),
              const Text(
                'Receive Advance Payment',
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Zamindar: ${widget.zamindar.name}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.darkGreen,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Amount',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Enter amount (e.g., 50000)',
                  prefixText: 'Rs ',
                  prefixStyle: const TextStyle(
                    fontSize: 14,
                    color: AppColors.darkGreen,
                    fontWeight: FontWeight.w600,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide(color: Colors.blue[700]!, width: 2),
                  ),
                ),
              ),
            ],
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final amount = int.tryParse(
                  amountController.text.replaceAll(RegExp(r'[^0-9]'), ''),
                );

                if (amount == null || amount <= 0) {
                  AppToast.showError(context, 'Please enter a valid amount');
                  return;
                }

                try {
                  await DatabaseHelper.instance.receiveAdvancePayment(
                    zamindarId: widget.zamindar.id!,
                    amount: amount,
                    dateTime: DateTime.now(),
                    season: SeasonUtils.getSeasonString(DateTime.now()),
                  );

                  // Reload data
                  await _loadData();

                  // Call parent refresh
                  widget.onRefresh?.call();

                  if (!mounted) return;
                  Navigator.pop(ctx);

                  AppToast.showSuccess(
                    context,
                    'Advance payment of Rs ${_fmt(amount.toDouble())} received successfully',
                  );

                  // Trigger receipt printing
                  try {
                    await PdfGenerator.printAdvancePaymentReceipt(
                      zamindarName: widget.zamindar.name,
                      amount: amount,
                      date: DateTime.now(),
                      servedBy: SessionContext.footprintLabel,
                    );
                  } catch (e) {
                    debugPrint('Error printing receipt: $e');
                    if (!mounted) return;
                    AppToast.showWarning(
                      context,
                      'Payment saved but receipt print failed: $e',
                    );
                  }
                } catch (e) {
                  if (!mounted) return;
                  AppToast.showError(context, 'Error: $e');
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.print, size: 15),
              label: const Text('Save & Print Receipt'),
            ),
          ],
        );
      },
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
