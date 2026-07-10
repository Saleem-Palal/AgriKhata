import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../models/ledger_models.dart';
import '../utils/season_utils.dart';
import '../utils/pdf_generator.dart';
import '../utils/pdf_share.dart';
import '../Widgets/ledger_widgets.dart';
import '../Database/database_helper.dart' as db;

class MainLedgerScreen extends StatefulWidget {
  final Function(String)? onEditInvoice;

  const MainLedgerScreen({super.key, this.onEditInvoice});

  @override
  State<MainLedgerScreen> createState() => _MainLedgerScreenState();
}

class _MainLedgerScreenState extends State<MainLedgerScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // Keep state alive

  late TabController _tabController;
  late Season _selectedSeason;
  late List<Season> _availableSeasons;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  List<LedgerEntry> _salesEntries = [];
  List<LedgerEntry> _purchasesEntries = [];
  List<PaymentLedgerEntry> _paymentsEntries = [];
  bool _isLoading = true;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _selectedSeason = SeasonUtils.getCurrentSeason();
    _availableSeasons = SeasonUtils.getAvailableSeasons(yearsBack: 3);
    _loadSeasonOptions();
    _loadLedgerData();

    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
    
    // Listen for database changes and auto-refresh
    db.DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  void _onDatabaseChanged() {
    _loadSeasonOptions();
    _loadLedgerData(showLoading: false);
  }

  Future<void> _loadSeasonOptions() async {
    try {
      final seasonNames =
          await db.DatabaseHelper.instance.getDistinctLedgerSeasons();
      var parsed = SeasonUtils.seasonsFromDisplayNames(seasonNames);

      if (parsed.isEmpty) {
        parsed = [SeasonUtils.getCurrentSeason()];
      }

      if (!parsed.contains(_selectedSeason)) {
        _selectedSeason = parsed.first;
      }

      if (mounted) {
        setState(() => _availableSeasons = parsed);
      }
    } catch (e) {
      debugPrint('Failed to load season options: $e');
    }
  }

  @override
  void didUpdateWidget(MainLedgerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-refresh when widget updates (e.g., after returning from edit)
    _loadLedgerData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    // Remove database listener to prevent memory leaks
    db.DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  Future<void> _loadLedgerData({bool showLoading = true}) async {
    if (showLoading) setState(() => _isLoading = true);

    try {
      // Fetch data from new three-table schema
      final salesWithDetails = await db.DatabaseHelper.instance
          .getAllSalesWithDetails(season: _selectedSeason.displayName);
      
      final paymentsData = await db.DatabaseHelper.instance
          .getAllPayments(season: _selectedSeason.displayName);

      final registeredZamindars = await db.DatabaseHelper.instance
          .getAllZamindars();
      final registeredZamindarNames = registeredZamindars
          .map((zamindar) => zamindar.name)
          .toSet();

      debugPrint(
        'LEDGER DEBUG: Fetched ${salesWithDetails.length} sales with details',
      );
      debugPrint(
        'LEDGER DEBUG: Fetched ${paymentsData.length} payments',
      );

      final salesEntries = <LedgerEntry>[];

      for (final saleData in salesWithDetails) {
        final sale = saleData['sale'] as Map<String, dynamic>;
        final itemsList = saleData['items'] as List<Map<String, dynamic>>;
        final totalCollected = saleData['totalCollected'] as double;
        
        final invoiceNumber = sale[db.SalesTable.invoiceNumber] as String;
        final dateTimeStr = sale[db.SalesTable.dateTime] as String;
        final zamindarName = sale[db.SalesTable.zamindarName] as String;
        final kisaanName = sale[db.SalesTable.kisaanName] as String?;
        final totalPayable = (sale[db.SalesTable.totalPayable] as num).toDouble();

        // Convert sale_items to LineItem objects
        final items = itemsList.map((item) {
          return LineItem(
            productName: item[db.SaleItemsTable.productName] as String,
            quantity: (item[db.SaleItemsTable.quantity] as num).toDouble(),
            unit: '',
            unitPrice: (item[db.SaleItemsTable.unitPrice] as num).toDouble(),
            seasonalIncrement: (item[db.SaleItemsTable.seasonalIncrement] as num?)?.toDouble() ?? 0,
            discount: (item[db.SaleItemsTable.itemDiscount] as num?)?.toDouble() ?? 0,
          );
        }).toList();

        // Calculate payment status
        PaymentStatus status;
        if (totalCollected >= totalPayable) {
          status = PaymentStatus.paid;
        } else if (totalCollected > 0) {
          status = PaymentStatus.partial;
        } else {
          status = PaymentStatus.unpaid;
        }

        // Use invoiceNumber as the ID (no need for fake counter)
        final ledgerEntry = LedgerEntry(
          id: 0, // Deprecated field, kept for backward compatibility
          invoiceNumber: invoiceNumber,
          date: DateTime.parse(dateTimeStr),
          stakeholderName: zamindarName,
          kisaanName: kisaanName,
          items: items,
          total: totalPayable,
          paid: totalCollected,
          status: status,
          season: _selectedSeason.displayName,
          isWalkInCustomer: !registeredZamindarNames.contains(zamindarName),
        );

        salesEntries.add(ledgerEntry);
      }

      salesEntries.sort((a, b) => b.date.compareTo(a.date));

      debugPrint('LEDGER DEBUG: Final sales entries = ${salesEntries.length}');
      debugPrint('LEDGER DEBUG: Final payments entries = ${paymentsData.length}');

      setState(() {
        _salesEntries = salesEntries;
        _paymentsEntries = paymentsData
            .map(PaymentLedgerEntry.fromMap)
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading ledger data: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load ledger data: $e'),
            backgroundColor: const Color(0xFFDC3545),
          ),
        );
      }
    }
  }

  List<LedgerEntry> get _filteredSalesEntries {
    if (_searchQuery.isEmpty) return _salesEntries;
    return _salesEntries.where((entry) {
      return entry.invoiceNumber.toLowerCase().contains(_searchQuery) ||
          entry.stakeholderName.toLowerCase().contains(_searchQuery) ||
          (entry.kisaanName?.toLowerCase().contains(_searchQuery) ?? false) ||
          entry.itemsSummary.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  List<LedgerEntry> get _filteredPurchasesEntries {
    if (_searchQuery.isEmpty) return _purchasesEntries;
    return _purchasesEntries.where((entry) {
      return entry.invoiceNumber.toLowerCase().contains(_searchQuery) ||
          entry.stakeholderName.toLowerCase().contains(_searchQuery) ||
          (entry.kisaanName?.toLowerCase().contains(_searchQuery) ?? false) ||
          entry.itemsSummary.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  List<PaymentLedgerEntry> get _filteredPaymentsEntries {
    if (_searchQuery.isEmpty) return _paymentsEntries;
    return _paymentsEntries.where((entry) {
      return entry.paymentId.toLowerCase().contains(_searchQuery) ||
          (entry.invoiceNumber?.toLowerCase().contains(_searchQuery) ??
              false) ||
          entry.zamindarName.toLowerCase().contains(_searchQuery) ||
          (entry.kisaanName?.toLowerCase().contains(_searchQuery) ?? false);
    }).toList();
  }

  Future<void> _handleExportStatement() async {
    setState(() => _isExporting = true);

    try {
      await PdfGenerator.saveConsolidatedLedgerToDocuments(
        salesEntries: _filteredSalesEntries,
        purchasesEntries: _filteredPurchasesEntries,
        paymentEntries: _filteredPaymentsEntries,
        season: _selectedSeason,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF Saved Successfully to Local Storage'),
            backgroundColor: Color(0xFF28A745),
          ),
        );
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export: $e'),
            backgroundColor: const Color(0xFFDC3545),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _handleShareViaWhatsApp() async {
    setState(() => _isExporting = true);

    try {
      final file = await PdfGenerator.saveConsolidatedLedgerToDocuments(
        salesEntries: _filteredSalesEntries,
        purchasesEntries: _filteredPurchasesEntries,
        paymentEntries: _filteredPaymentsEntries,
        season: _selectedSeason,
      );

      await PdfShare.sharePdfFile(
        file: file,
        fileName: p.basename(file.path),
        text: 'AgriKhata Consolidated Ledger — ${_selectedSeason.displayName}',
        subject: 'AgriKhata Consolidated Ledger',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to share via WhatsApp: $e'),
            backgroundColor: const Color(0xFFDC3545),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9F4),
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _buildTabsCard(),
                  const SizedBox(height: 14),
                  _buildFilterRow(),
                  const SizedBox(height: 14),
                  _buildKpiRow(),
                  const SizedBox(height: 14),
                  Expanded(child: _buildLedgerCard()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE2EBE0), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'Finance',
            style: TextStyle(fontSize: 12, color: Color(0xFF95B89A)),
          ),
          const Text(
            '  ›  ',
            style: TextStyle(fontSize: 12, color: Color(0xFF95B89A)),
          ),
          const Text(
            'Ledger',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFF1B4332),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                _tabController.animateTo(0);
                setState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _tabController.index == 0
                      ? const Color(0xFFF7F9F4)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: _tabController.index == 0
                          ? const Color(0xFF1B4332)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
                child: Text(
                  'Sales Ledger',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _tabController.index == 0
                        ? const Color(0xFF1B4332)
                        : const Color(0xFF95B89A),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                _tabController.animateTo(1);
                setState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _tabController.index == 1
                      ? const Color(0xFFF7F9F4)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: _tabController.index == 1
                          ? const Color(0xFF1B4332)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  'Purchases Ledger',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _tabController.index == 1
                        ? const Color(0xFF1B4332)
                        : const Color(0xFF95B89A),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                _tabController.animateTo(2);
                setState(() {});
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _tabController.index == 2
                      ? const Color(0xFFF7F9F4)
                      : Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: _tabController.index == 2
                          ? const Color(0xFF1B4332)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                ),
                child: Text(
                  'Payments Ledger',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: _tabController.index == 2
                        ? const Color(0xFF1B4332)
                        : const Color(0xFF95B89A),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFC6DEC9), width: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 15, color: Color(0xFF95B89A)),
                const SizedBox(width: 7),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'Search Invoice #, Zamindar or Kisaan name...',
                      hintStyle: TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFF95B89A),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF1B4332),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        SeasonDropdown(
          selectedSeason: _selectedSeason,
          availableSeasons: _availableSeasons,
          onChanged: (season) {
            if (season != null && season != _selectedSeason) {
              setState(() {
                _selectedSeason = season;
              });
              _loadLedgerData();
            }
          },
        ),
        const SizedBox(width: 10),
        InkWell(
          onTap: _isExporting ? null : _handleExportStatement,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFC6DEC9), width: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isExporting)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF1B4332),
                      ),
                    ),
                  )
                else
                  const Icon(
                    Icons.file_download_outlined,
                    size: 14,
                    color: Color(0xFF1B4332),
                  ),
                const SizedBox(width: 6),
                const Text(
                  'Export Statement',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1B4332),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        InkWell(
          onTap: _isExporting ? null : _handleShareViaWhatsApp,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(
              color: const Color(0xFF25D366),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.chat_outlined,
                  size: 14,
                  color: Colors.white,
                ),
                SizedBox(width: 6),
                Text(
                  'Share via WhatsApp',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiRow() {
    if (_isLoading) {
      return const SizedBox.shrink();
    }

    if (_tabController.index == 2) {
      final summary = PaymentSummary.fromEntries(_filteredPaymentsEntries);
      return Row(
        children: [
          Expanded(
            child: _buildKpiCard(
              'Total Payments Received',
              summary.totalPaymentsReceived,
              const Color(0xFF1B4332),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              'Total Advance Collected',
              summary.totalAdvanceCollected,
              const Color(0xFF2D6A4F),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildKpiCard(
              'Total Wallet Deductions',
              summary.totalWalletDeductions,
              const Color(0xFF1565C0),
            ),
          ),
        ],
      );
    }

    final entries = _tabController.index == 0
        ? _filteredSalesEntries
        : _filteredPurchasesEntries;
    final summary = LedgerSummary.fromEntries(entries);

    return Row(
      children: [
        Expanded(
          child: _buildKpiCard(
            'Total Volume Sold',
            summary.totalVolume,
            const Color(0xFF1B4332),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildKpiCard(
            'Total Cash Received',
            summary.totalCashReceived,
            const Color(0xFF2D6A4F),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildKpiCard(
            'Outstanding Credit',
            summary.outstandingCredit,
            const Color(0xFFA32D2D),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiCard(String label, double value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2EBE0), width: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: Color(0xFF95B89A),
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '₨ ${NumberFormat('#,##,##0').format(value)}',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerCard() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1B4332)),
        ),
      );
    }

    if (_tabController.index == 0) {
      return LedgerTable(
        entries: _filteredSalesEntries,
        onRefresh: _loadLedgerData,
        onEdit: _handleEditInvoice,
        onDelete: _handleDeleteInvoice,
      );
    } else if (_tabController.index == 1) {
      return LedgerTable(
        entries: _filteredPurchasesEntries,
        onRefresh: _loadLedgerData,
        onEdit: _handleEditInvoice,
        onDelete: _handleDeleteInvoice,
      );
    } else {
      return PaymentsLedgerTable(entries: _filteredPaymentsEntries);
    }
  }

  Future<void> _handleEditInvoice(LedgerEntry entry) async {
    // Use the callback from Shell instead of Navigator.push
    // Pass the actual invoice_number string instead of the fake runtime counter
    if (widget.onEditInvoice != null) {
      widget.onEditInvoice!(entry.invoiceNumber);
    }
  }

  Future<void> _handleDeleteInvoice(LedgerEntry entry) async {
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
      await db.DatabaseHelper.instance.deleteInvoiceEntirely(entry.invoiceNumber);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invoice ${entry.invoiceNumber} deleted'),
            backgroundColor: const Color(0xFF28A745),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete invoice: $e'),
            backgroundColor: const Color(0xFFDC3545),
          ),
        );
      }
    }
  }
}
