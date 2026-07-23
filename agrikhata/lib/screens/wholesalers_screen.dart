import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/app_auto_suggest_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// View state
// ---------------------------------------------------------------------------

enum WholesalerView { directory, profile }

enum _ProfileTab { ledger, purchases, payments }

// ---------------------------------------------------------------------------
// Mock domain models (mirrors HTML WHOLESALERS graph)
// ---------------------------------------------------------------------------

class LedgerEntry {
  LedgerEntry({
    required this.date,
    required this.type,
    required this.ref,
    required this.debit,
    required this.credit,
    required this.balance,
  });

  String date;
  String type;
  String ref;
  double debit;
  double credit;
  double balance;
}

class PurchaseInvoice {
  PurchaseInvoice({
    required this.date,
    required this.ref,
    required this.transport,
    required this.total,
  });

  String date;
  String ref;
  double transport;
  double total;
}

class PaymentReceipt {
  PaymentReceipt({
    required this.date,
    required this.receipt,
    required this.amount,
    required this.method,
    this.description = '',
  });

  String date;
  String receipt;
  double amount;
  String method;
  String description;
}

class Wholesaler {
  Wholesaler({
    required this.id,
    required this.name,
    required this.city,
    required this.phone,
    required this.balance,
    required this.ledger,
    required this.purchases,
    required this.payments,
  });

  final String id;
  String name;
  String city;
  String phone;
  double balance;
  List<LedgerEntry> ledger;
  List<PurchaseInvoice> purchases;
  List<PaymentReceipt> payments;
}

// ---------------------------------------------------------------------------
// Currency formatter — Pakistani / Indian grouping: ₨ #,##,###
// ---------------------------------------------------------------------------

String formatPKR(num amount) {
  final isNeg = amount < 0;
  var digits = amount.abs().round().toString();
  if (digits.length <= 3) {
    return '₨ ${isNeg ? '-' : ''}$digits';
  }
  final last3 = digits.substring(digits.length - 3);
  var rest = digits.substring(0, digits.length - 3);
  final buffer = StringBuffer();
  for (var i = 0; i < rest.length; i++) {
    if (i > 0 && (rest.length - i) % 2 == 0) buffer.write(',');
    buffer.write(rest[i]);
  }
  return '₨ ${isNeg ? '-' : ''}${buffer.toString()},$last3';
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class WholesalersScreen extends StatefulWidget {
  const WholesalersScreen({super.key});

  @override
  State<WholesalersScreen> createState() => _WholesalersScreenState();
}

class _WholesalersScreenState extends State<WholesalersScreen> {
  static const _primary = Color(0xFF1B4332);
  static const _secondary = Color(0xFF2D6A4F);
  static const _border = Color(0xFFE2EBE0);
  static const _bg = Color(0xFFF7F9F4);
  static const _inputBorder = Color(0xFFC6DEC9);

  final TextEditingController _searchController = TextEditingController();
  WholesalerView _view = WholesalerView.directory;
  Wholesaler? _active;
  _ProfileTab _profileTab = _ProfileTab.ledger;

  late List<Wholesaler> _wholesalers;
  bool _loading = true;
  List<Map<String, dynamic>> _activeLedger = [];
  List<Map<String, dynamic>> _activePurchases = [];
  List<Map<String, dynamic>> _activePayments = [];
  Map<String, List<Map<String, dynamic>>> _purchaseItemsByInvoice = {};
  final Set<String> _expandedPurchaseInvoices = {};
  final Set<String> _expandedLedgerRefs = {};
  bool _ledgerLoading = false;
  bool _purchasesLoading = false;
  bool _paymentsLoading = false;

  @override
  void initState() {
    super.initState();
    _wholesalers = [];
    _searchController.addListener(() => setState(() {}));
    _loadWholesalers();
    DatabaseHelper.instance.addListener(_onDbChanged);
  }

  void _onDbChanged() {
    _loadWholesalers(silent: true);
    final active = _active;
    if (active != null) {
      final id = int.tryParse(active.id);
      if (id != null) _loadProfileData(id);
    }
  }

  Future<void> _loadWholesalers({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final rows = await DatabaseHelper.instance.getAllWholesalers();
      if (!mounted) return;
      setState(() {
        _wholesalers = rows
            .map(
              (w) => Wholesaler(
                id: '${w.id}',
                name: w.name,
                city: w.city,
                phone: w.phone,
                balance: w.balance,
                ledger: const [],
                purchases: [],
                payments: [],
              ),
            )
            .toList();
        _loading = false;
        if (_active != null) {
          final match =
              _wholesalers.where((w) => w.id == _active!.id).toList();
          _active = match.isEmpty ? null : match.first;
          if (_active == null) {
            _view = WholesalerView.directory;
            _activeLedger = [];
            _activePurchases = [];
            _activePayments = [];
            _purchaseItemsByInvoice = {};
            _expandedPurchaseInvoices.clear();
            _expandedLedgerRefs.clear();
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _loadLedger(int wholesalerId) async {
    setState(() => _ledgerLoading = true);
    try {
      final rows =
          await DatabaseHelper.instance.fetchWholesalerLedger(wholesalerId);
      if (!mounted) return;
      setState(() {
        _activeLedger = rows;
        _ledgerLoading = false;
      });
    } catch (e, st) {
      debugPrint('Failed to load wholesaler ledger ($wholesalerId): $e\n$st');
      if (!mounted) return;
      setState(() {
        _activeLedger = [];
        _ledgerLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load khata ledger: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _loadPurchases(int wholesalerId) async {
    setState(() => _purchasesLoading = true);
    try {
      final rows =
          await DatabaseHelper.instance.fetchWholesalerPurchases(wholesalerId);
      final items = await DatabaseHelper.instance
          .fetchWholesalerPurchaseItemsGrouped(wholesalerId);
      if (!mounted) return;
      setState(() {
        _activePurchases = rows;
        _purchaseItemsByInvoice = items;
        _purchasesLoading = false;
      });
    } catch (e, st) {
      debugPrint('Failed to load purchases ($wholesalerId): $e\n$st');
      if (!mounted) return;
      setState(() {
        _activePurchases = [];
        _purchaseItemsByInvoice = {};
        _purchasesLoading = false;
      });
    }
  }

  Future<void> _loadPayments(int wholesalerId) async {
    setState(() => _paymentsLoading = true);
    try {
      final rows =
          await DatabaseHelper.instance.fetchWholesalerPayments(wholesalerId);
      if (!mounted) return;
      setState(() {
        _activePayments = rows;
        _paymentsLoading = false;
      });
    } catch (e, st) {
      debugPrint('Failed to load payments ($wholesalerId): $e\n$st');
      if (!mounted) return;
      setState(() {
        _activePayments = [];
        _paymentsLoading = false;
      });
    }
  }

  Future<void> _loadProfileData(int wholesalerId) async {
    await Future.wait([
      _loadLedger(wholesalerId),
      _loadPurchases(wholesalerId),
      _loadPayments(wholesalerId),
    ]);
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDbChanged);
    _searchController.dispose();
    super.dispose();
  }

  List<Wholesaler> get _filtered {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _wholesalers;
    return _wholesalers.where((w) {
      return w.name.toLowerCase().contains(q) ||
          w.city.toLowerCase().contains(q);
    }).toList();
  }

  void _openProfile(Wholesaler w) {
    setState(() {
      _active = w;
      _view = WholesalerView.profile;
      _profileTab = _ProfileTab.ledger;
      _activeLedger = [];
      _activePurchases = [];
      _activePayments = [];
      _purchaseItemsByInvoice = {};
      _expandedPurchaseInvoices.clear();
      _expandedLedgerRefs.clear();
      _ledgerLoading = true;
      _purchasesLoading = true;
      _paymentsLoading = true;
    });
    final id = int.tryParse(w.id);
    if (id != null) {
      _loadProfileData(id);
    } else {
      setState(() {
        _ledgerLoading = false;
        _purchasesLoading = false;
        _paymentsLoading = false;
      });
    }
  }

  void _backToDirectory() {
    setState(() {
      _view = WholesalerView.directory;
      _active = null;
      _profileTab = _ProfileTab.ledger;
      _activeLedger = [];
      _activePurchases = [];
      _activePayments = [];
      _purchaseItemsByInvoice = {};
      _expandedPurchaseInvoices.clear();
      _expandedLedgerRefs.clear();
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDirectory = _view == WholesalerView.directory;
    final active = _active;

    return ColoredBox(
      color: _bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AgriHeader(
            breadcrumbs: isDirectory
                ? const ['Inventory', 'Wholesalers']
                : [
                    'Inventory',
                    'Wholesalers',
                    if (active != null) active.name,
                  ],
            onBreadcrumbTap: isDirectory
                ? null
                : (index) {
                    if (index <= 1) _backToDirectory();
                  },
            actions: isDirectory
                ? [
                    ElevatedButton.icon(
                      onPressed: _showAddWholesalerDialog,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add New Wholesaler'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ]
                : const [],
          ),
          Expanded(
            child: isDirectory
                ? (_loading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildDirectoryView())
                : _buildProfileView(active!),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // VIEW A — Directory
  // ===========================================================================

  Widget _buildDirectoryView() {
    final rows = _filtered;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border, width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Search row
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: _border, width: 0.5),
                ),
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 12.5, color: _primary),
                decoration: InputDecoration(
                  hintText: 'Search Wholesaler or City...',
                  hintStyle: const TextStyle(
                    color: AppColors.textHint,
                    fontSize: 12.5,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 16,
                    color: AppColors.textHint,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 0,
                  ),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: _inputBorder,
                      width: 0.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: _inputBorder,
                      width: 0.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: AppColors.accentGreen,
                      width: 1,
                    ),
                  ),
                  isDense: true,
                ),
              ),
            ),

            // Table header
            _tableHeaderRow(const [
              _ColSpec('Wholesaler / Shop Name', flex: 26),
              _ColSpec('Mobile Phone', flex: 16),
              _ColSpec('City', flex: 18),
              _ColSpec('Current Owed Balance', flex: 20),
              _ColSpec('Actions', flex: 20),
            ]),

            // Rows
            Expanded(
              child: rows.isEmpty
                  ? const Center(
                      child: Text(
                        'No matching wholesalers found.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textHint,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final w = rows[index];
                        return _DirectoryRow(
                          wholesaler: w,
                          onOpenKhata: () => _openProfile(w),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // VIEW B — Profile
  // ===========================================================================

  Widget _buildProfileView(Wholesaler w) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Back link
          InkWell(
            onTap: _backToDirectory,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_back, size: 14, color: AppColors.textMuted),
                  SizedBox(width: 6),
                  Text(
                    'Back to Wholesaler Directory',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Summary header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border, width: 0.5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.name,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: _primary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on_outlined,
                            size: 13,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            w.city,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(width: 14),
                          const Icon(
                            Icons.phone_outlined,
                            size: 13,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            w.phone,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _showRecordPaymentDialog(w),
                            icon: const Icon(
                              Icons.payments_outlined,
                              size: 15,
                            ),
                            label: const Text('Record Payment'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Print Statement would open here.',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            },
                            icon: const Icon(Icons.print_outlined, size: 15),
                            label: const Text('Print Statement'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _primary,
                              side: const BorderSide(
                                color: _inputBorder,
                                width: 0.5,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Outstanding balance card
                Container(
                  constraints: const BoxConstraints(minWidth: 230),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: _primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TOTAL OUTSTANDING UDHAAR',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.6,
                          color: AppColors.sidebarText,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        formatPKR(w.balance),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Tabbed panels
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border, width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Tab bar
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: _border, width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      _profileTabChip(
                        '📋  Khata Statement',
                        _ProfileTab.ledger,
                      ),
                      _profileTabChip(
                        '📦  Bulk Purchase Invoices',
                        _ProfileTab.purchases,
                      ),
                      _profileTabChip(
                        '💸  Payment Logs',
                        _ProfileTab.payments,
                      ),
                    ],
                  ),
                ),
                // Tab body
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: switch (_profileTab) {
                    _ProfileTab.ledger => KeyedSubtree(
                      key: const ValueKey('ledger'),
                      child: _buildLedgerTable(w),
                    ),
                    _ProfileTab.purchases => KeyedSubtree(
                      key: const ValueKey('purchases'),
                      child: _buildPurchasesTable(w),
                    ),
                    _ProfileTab.payments => KeyedSubtree(
                      key: const ValueKey('payments'),
                      child: _buildPaymentsTable(w),
                    ),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileTabChip(String label, _ProfileTab tab) {
    final active = _profileTab == tab;
    return InkWell(
      onTap: () => setState(() => _profileTab = tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? _primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: active ? _primary : AppColors.textHint,
          ),
        ),
      ),
    );
  }

  // ---- Tab 1: Ledger (DB-driven) ----

  String _formatLedgerDate(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}';
  }

  Widget _buildLedgerTable(Wholesaler w) {
    if (_ledgerLoading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_activeLedger.isEmpty) {
      return _emptyTableMessage('No ledger entries yet.');
    }
    return Column(
      children: [
        _tableHeaderRow(const [
          _ColSpec('Date', flex: 14),
          _ColSpec('Type', flex: 18),
          _ColSpec('Invoice Reference', flex: 18),
          _ColSpec('Debit', flex: 14),
          _ColSpec('Credit', flex: 14),
          _ColSpec('Balance', flex: 18),
        ]),
        ..._activeLedger.expand((row) {
          final debit =
              (row[WholesalerLedgerTable.debit] as num?)?.toDouble() ?? 0;
          final credit =
              (row[WholesalerLedgerTable.credit] as num?)?.toDouble() ?? 0;
          final balance =
              (row[WholesalerLedgerTable.runningBalance] as num?)
                      ?.toDouble() ??
                  0;
          final type =
              row[WholesalerLedgerTable.transactionType] as String? ?? '—';
          final ref =
              row[WholesalerLedgerTable.referenceId] as String? ?? '—';
          final dateRaw = row[WholesalerLedgerTable.date] as String?;
          final isPurchase = type == WholesalerLedgerTxnType.purchase;
          final items = isPurchase
              ? (_purchaseItemsByInvoice[ref] ?? const [])
              : const <Map<String, dynamic>>[];
          final expanded = _expandedLedgerRefs.contains(ref);

          return [
            InkWell(
              onTap: items.isEmpty
                  ? null
                  : () => setState(() {
                      if (expanded) {
                        _expandedLedgerRefs.remove(ref);
                      } else {
                        _expandedLedgerRefs.add(ref);
                      }
                    }),
              child: _dataRow([
                _cell(
                  _formatLedgerDate(dateRaw),
                  flex: 14,
                  muted: true,
                  small: true,
                ),
                Expanded(
                  flex: 18,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            type,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: _primary,
                            ),
                          ),
                        ),
                        if (items.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Icon(
                            expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 16,
                            color: AppColors.textMuted,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                _cell(ref.isEmpty ? '—' : ref, flex: 18, muted: true),
                Expanded(
                  flex: 14,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: debit > 0
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: _badge(formatPKR(debit), debit: false),
                          )
                        : const Text(
                            '—',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textHint,
                            ),
                          ),
                  ),
                ),
                Expanded(
                  flex: 14,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: credit > 0
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: _badge(formatPKR(credit), debit: true),
                          )
                        : const Text(
                            '—',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textHint,
                            ),
                          ),
                  ),
                ),
                _cell(
                  formatPKR(balance),
                  flex: 18,
                  medium: true,
                  bold: true,
                ),
              ]),
            ),
            if (expanded && items.isNotEmpty)
              _buildProductDetailsPanel(items),
          ];
        }),
      ],
    );
  }

  Widget _buildProductDetailsPanel(List<Map<String, dynamic>> items) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF5F9F2),
        border: Border(bottom: BorderSide(color: _border, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Products in this purchase',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          ...items.map((item) {
            final name =
                item[PurchaseItemsTable.productName] as String? ?? '—';
            final qty =
                (item[PurchaseItemsTable.quantity] as num?)?.toInt() ?? 0;
            final rate =
                (item[PurchaseItemsTable.purchaseRate] as num?)?.toDouble() ??
                0;
            final lineTotal =
                (item[PurchaseItemsTable.lineTotal] as num?)?.toDouble() ??
                (qty * rate);
            final expiryRaw = item[PurchaseItemsTable.expiryDate] as String?;
            final expiry = expiryRaw == null || expiryRaw.isEmpty
                ? null
                : _formatLedgerDate(expiryRaw);

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 34,
                    child: Text(
                      name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _primary,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 12,
                    child: Text(
                      'Qty $qty',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 18,
                    child: Text(
                      '@ ${formatPKR(rate)}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 18,
                    child: Text(
                      formatPKR(lineTotal),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _primary,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 18,
                    child: Text(
                      expiry == null ? '—' : 'Exp $expiry',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textHint,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ---- Tab 2: Purchases (DB-driven) ----

  Color _paymentTypeBadgeBg(String type) {
    switch (type) {
      case PurchasePaymentType.cash:
        return const Color(0xFFD8F3DC);
      case PurchasePaymentType.partial:
        return const Color(0xFFE6F1FB);
      default:
        return const Color(0xFFFAEEDA);
    }
  }

  Color _paymentTypeBadgeFg(String type) {
    switch (type) {
      case PurchasePaymentType.cash:
        return const Color(0xFF2D6A4F);
      case PurchasePaymentType.partial:
        return const Color(0xFF0C447C);
      default:
        return const Color(0xFF633806);
    }
  }

  Widget _typedBadge(String label, {required Color bg, required Color fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildPurchasesTable(Wholesaler w) {
    if (_purchasesLoading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_activePurchases.isEmpty) {
      return _emptyTableMessage('No bulk purchase invoices yet.');
    }
    return Column(
      children: [
        _tableHeaderRow(const [
          _ColSpec('', flex: 4),
          _ColSpec('Date', flex: 14),
          _ColSpec('Invoice No.', flex: 16),
          _ColSpec('Transport', flex: 14),
          _ColSpec('Total Bill', flex: 16),
          _ColSpec('Payment Type', flex: 14),
          _ColSpec('Items', flex: 12),
        ]),
        ..._activePurchases.expand((row) {
          final dateRaw = row[PurchaseInvoicesTable.dateTime] as String?;
          final invoice =
              row[PurchaseInvoicesTable.invoiceNumber] as String? ?? '—';
          final transport =
              (row[PurchaseInvoicesTable.transportCharges] as num?)
                      ?.toDouble() ??
                  0;
          final total =
              (row[PurchaseInvoicesTable.grandTotal] as num?)?.toDouble() ?? 0;
          final payType =
              row[PurchaseInvoicesTable.paymentType] as String? ?? '—';
          final items = _purchaseItemsByInvoice[invoice] ?? const [];
          final expanded = _expandedPurchaseInvoices.contains(invoice);

          return [
            InkWell(
              onTap: items.isEmpty
                  ? null
                  : () => setState(() {
                      if (expanded) {
                        _expandedPurchaseInvoices.remove(invoice);
                      } else {
                        _expandedPurchaseInvoices.add(invoice);
                      }
                    }),
              child: _dataRow([
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      items.isEmpty
                          ? Icons.remove
                          : (expanded
                              ? Icons.expand_less
                              : Icons.expand_more),
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
                _cell(
                  _formatLedgerDate(dateRaw),
                  flex: 14,
                  muted: true,
                  small: true,
                ),
                _cell(invoice, flex: 16, medium: true),
                _cell(formatPKR(transport), flex: 14, muted: true),
                _cell(formatPKR(total), flex: 16, medium: true, bold: true),
                Expanded(
                  flex: 14,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _typedBadge(
                        payType,
                        bg: _paymentTypeBadgeBg(payType),
                        fg: _paymentTypeBadgeFg(payType),
                      ),
                    ),
                  ),
                ),
                _cell(
                  '${items.length}',
                  flex: 12,
                  muted: true,
                ),
              ]),
            ),
            if (expanded && items.isNotEmpty)
              _buildProductDetailsPanel(items),
          ];
        }),
      ],
    );
  }

  // ---- Tab 3: Payments (DB-driven) ----

  Widget _buildPaymentsTable(Wholesaler w) {
    if (_paymentsLoading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_activePayments.isEmpty) {
      return _emptyTableMessage('No payments recorded yet.');
    }
    return Column(
      children: [
        _tableHeaderRow(const [
          _ColSpec('Date', flex: 12),
          _ColSpec('Reference / Invoice No.', flex: 14),
          _ColSpec('Amount Paid', flex: 12),
          _ColSpec('Method', flex: 10),
          _ColSpec('Items Summary', flex: 20),
          _ColSpec('Description', flex: 18),
        ]),
        ..._activePayments.map((row) {
          final dateRaw = row[WholesalerPaymentsTable.date] as String?;
          final ref =
              row[WholesalerPaymentsTable.referenceNo] as String? ?? '—';
          final amount =
              (row[WholesalerPaymentsTable.amount] as num?)?.toDouble() ?? 0;
          final method =
              row[WholesalerPaymentsTable.paymentMethod] as String? ?? '—';
          final description =
              row[WholesalerPaymentsTable.notes] as String? ?? '';
          final itemsSummary =
              row[WholesalerPaymentsTable.itemsSummary] as String? ?? '';
          final itemsText = itemsSummary.trim().isEmpty
              ? '—'
              : itemsSummary.trim();
          final isClearance = itemsText == 'N/A (Account Clearance)';

          return _dataRow([
            _cell(
              _formatLedgerDate(dateRaw),
              flex: 12,
              muted: true,
              small: true,
            ),
            _cell(ref.isEmpty ? '—' : ref, flex: 14, medium: true),
            Expanded(
              flex: 12,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  formatPKR(amount),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _secondary,
                  ),
                ),
              ),
            ),
            _cell(method, flex: 10, muted: true),
            Expanded(
              flex: 20,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  itemsText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: isClearance ? FontStyle.italic : FontStyle.normal,
                    color: isClearance ? AppColors.textMuted : _primary,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 18,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  description.trim().isEmpty ? '—' : description.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: description.trim().isEmpty
                        ? AppColors.textMuted
                        : _primary,
                  ),
                ),
              ),
            ),
          ]);
        }),
      ],
    );
  }

  // ===========================================================================
  // Add New Wholesaler modal
  // ===========================================================================

  Future<void> _showAddWholesalerDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final cityController = TextEditingController();
    final balanceController = TextEditingController();
    String? errorText;

    final saved = await showDialog<bool>(
      context: context,
      barrierColor: _primary.withValues(alpha: 0.4),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: const BoxDecoration(
                        color: _primary,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Add New Wholesaler',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => Navigator.of(ctx).pop(false),
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: AppColors.sidebarText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppAutoSuggestField(
                            controller: nameController,
                            labelText: 'Wholesaler / Shop Name',
                            hintText: 'e.g. Khan Traders',
                            isRequired: true,
                            autofocus: true,
                            textInputAction: TextInputAction.next,
                            fetchSuggestions: (text) =>
                                DatabaseHelper.instance.fetchNameSuggestions(
                                  WholesalerTable.name,
                                  text,
                                ),
                          ),
                          const SizedBox(height: 12),
                          _modalLabel('Mobile Phone Number *'),
                          TextField(
                            controller: phoneController,
                            keyboardType: TextInputType.phone,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9+\-\s]'),
                              ),
                            ],
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            decoration: _modalFieldDecoration(
                              hint: 'e.g. 0301-2345678',
                            ),
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 12),
                          _modalLabel('City *'),
                          TextField(
                            controller: cityController,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            decoration: _modalFieldDecoration(
                              hint: 'e.g. Sukkur',
                            ),
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 12),
                          _modalLabel('Opening Balance Udhaar (optional)'),
                          TextField(
                            controller: balanceController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            decoration: _modalFieldDecoration(
                              hint: 'Defaults to 0 if left blank',
                            ),
                          ),
                          if (errorText != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              errorText!,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF791F1F),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: _border, width: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _primary,
                              side: const BorderSide(
                                color: _inputBorder,
                                width: 0.5,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              final name = nameController.text.trim();
                              final phone = phoneController.text.trim();
                              final city = cityController.text.trim();
                              final balanceRaw =
                                  balanceController.text.trim();

                              if (name.isEmpty ||
                                  phone.isEmpty ||
                                  city.isEmpty) {
                                setModalState(() {
                                  errorText =
                                      'Please fill in Name, Phone, and City.';
                                });
                                return;
                              }

                              if (balanceRaw.isNotEmpty &&
                                  double.tryParse(balanceRaw) == null) {
                                setModalState(() {
                                  errorText =
                                      'Opening balance must be a valid number.';
                                });
                                return;
                              }

                              Navigator.of(ctx).pop(true);
                            },
                            icon: const Icon(Icons.check, size: 15),
                            label: const Text('Save Wholesaler'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (saved != true || !mounted) {
      nameController.dispose();
      phoneController.dispose();
      cityController.dispose();
      balanceController.dispose();
      return;
    }

    final name = nameController.text.trim();
    final phone = phoneController.text.trim();
    final city = cityController.text.trim();
    final openingBalance =
        double.tryParse(balanceController.text.trim()) ?? 0;

    nameController.dispose();
    phoneController.dispose();
    cityController.dispose();
    balanceController.dispose();

    final balance = openingBalance < 0 ? 0.0 : openingBalance;

    try {
      final dbId = await DatabaseHelper.instance.insertWholesaler(
        DbWholesaler(
          name: name,
          city: city,
          phone: phone,
          balance: balance,
        ),
      );

      final created = Wholesaler(
        id: '$dbId',
        name: name,
        city: city,
        phone: phone,
        balance: balance,
        ledger: const [],
        purchases: [],
        payments: [],
      );

      setState(() {
        _wholesalers.insert(0, created);
        if (_searchController.text.isNotEmpty) {
          _searchController.clear();
        }
      });

      if (!mounted) return;
      _showSuccessToast(
        title: 'Wholesaler Added',
        message: '$name added to wholesaler directory',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save wholesaler: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ===========================================================================
  // Record Payment modal
  // ===========================================================================

  double _outstandingOwedAmount(Wholesaler w) {
    return w.balance > 0 ? w.balance : 0;
  }

  Future<void> _showRecordPaymentDialog(Wholesaler w) async {
    final amountController = TextEditingController();
    final descriptionController = TextEditingController();
    final outstandingOwed = _outstandingOwedAmount(w);
    String method = 'Cash';

    final saved = await showDialog<bool>(
      context: context,
      barrierColor: _primary.withValues(alpha: 0.4),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: const BoxDecoration(
                        color: _primary,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Record Payment',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => Navigator.of(ctx).pop(false),
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: AppColors.sidebarText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Body
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _modalLabel('Wholesaler'),
                          TextField(
                            enabled: false,
                            controller: TextEditingController(text: w.name),
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            decoration: _modalFieldDecoration(
                              fill: _bg,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _modalLabel('Amount Paid (₨)'),
                          TextField(
                            controller: amountController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            decoration: _modalFieldDecoration(
                              hint: 'e.g. 50000',
                            ),
                          ),
                          const SizedBox(height: 12),
                          _modalLabel('Payment Method'),
                          DropdownButtonFormField<String>(
                            initialValue: method,
                            decoration: _modalFieldDecoration(),
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'Cash',
                                child: Text('Cash'),
                              ),
                              DropdownMenuItem(
                                value: 'Bank Transfer',
                                child: Text('Bank Transfer'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setModalState(() => method = v);
                            },
                          ),
                          const SizedBox(height: 12),
                          _modalLabel('Description (optional)'),
                          TextField(
                            controller: descriptionController,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: _primary,
                            ),
                            decoration: _modalFieldDecoration(
                              hint: 'e.g. Partial settlement for June stock',
                            ),
                          ),
                          if (outstandingOwed > 0) ...[
                            const SizedBox(height: 10),
                            Text(
                              'Outstanding owed: ${formatPKR(outstandingOwed)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Footer
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: _border, width: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _primary,
                              side: const BorderSide(
                                color: _inputBorder,
                                width: 0.5,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              final amount = double.tryParse(
                                amountController.text.trim(),
                              );
                              if (amount == null || amount <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Please enter a valid payment amount.',
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                                return;
                              }
                              if (outstandingOwed <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'This wholesaler has no outstanding '
                                      'balance to settle.',
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                                return;
                              }
                              if (amount > outstandingOwed + 0.01) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Payment amount cannot exceed the '
                                      'outstanding owed balance of '
                                      '${formatPKR(outstandingOwed)}.',
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                                return;
                              }
                              Navigator.of(ctx).pop(true);
                            },
                            icon: const Icon(Icons.check, size: 15),
                            label: const Text('Save Payment'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (saved != true || !mounted) {
      amountController.dispose();
      descriptionController.dispose();
      return;
    }

    final amount = double.tryParse(amountController.text.trim()) ?? 0;
    final description = descriptionController.text.trim();
    amountController.dispose();
    descriptionController.dispose();

    if (amount <= 0) return;

    final owedNow = _outstandingOwedAmount(w);
    if (owedNow <= 0 || amount > owedNow + 0.01) return;

    final dbId = int.tryParse(w.id);
    if (dbId == null) return;

    try {
      await DatabaseHelper.instance.recordWholesalerPayment(
        wholesalerId: dbId,
        amount: amount,
        method: method,
        remarks: description,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to record payment: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!mounted) return;
    _showSuccessToast(
      title: 'Payment Recorded',
      message: '${formatPKR(amount)} via $method for ${w.name}',
    );
  }

  void _showSuccessToast({required String title, required String message}) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Positioned(
          right: 24,
          bottom: 24,
          child: Material(
            color: Colors.transparent,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 250),
              builder: (ctx, t, child) {
                return Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, 20 * (1 - t)),
                    child: child,
                  ),
                );
              },
              child: Container(
                width: 300,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border, width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: _primary.withValues(alpha: 0.18),
                      blurRadius: 40,
                      offset: const Offset(0, 16),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(
                        color: AppColors.tagGreenBg,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        size: 14,
                        color: _secondary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: _primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            message,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 4), () {
      entry.remove();
    });
  }

  // ===========================================================================
  // Shared table helpers
  // ===========================================================================

  Widget _tableHeaderRow(List<_ColSpec> cols) {
    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(bottom: BorderSide(color: _border, width: 0.5)),
      ),
      child: Row(
        children: cols
            .map(
              (c) => Expanded(
                flex: c.flex,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Text(
                    c.label.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _dataRow(List<Widget> cells) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border, width: 0.5)),
      ),
      child: Row(children: cells),
    );
  }

  Widget _cell(
    String text, {
    required int flex,
    bool muted = false,
    bool medium = false,
    bool bold = false,
    bool small = false,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: small ? 11 : 12,
            fontWeight: bold
                ? FontWeight.w600
                : medium
                    ? FontWeight.w500
                    : FontWeight.w400,
            color: muted ? AppColors.textMuted : _primary,
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, {required bool debit}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: debit ? AppColors.tagGreenBg : AppColors.tagRedBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: debit ? AppColors.tagGreenText : AppColors.tagRedText,
        ),
      ),
    );
  }

  Widget _emptyTableMessage(String msg) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          msg,
          style: const TextStyle(fontSize: 12, color: AppColors.textHint),
        ),
      ),
    );
  }

  Widget _modalLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  InputDecoration _modalFieldDecoration({String? hint, Color? fill}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 12.5, color: AppColors.textHint),
      filled: true,
      fillColor: fill ?? Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder, width: 0.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.accentGreen, width: 1),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Directory row widget
// ---------------------------------------------------------------------------

class _ColSpec {
  const _ColSpec(this.label, {required this.flex});
  final String label;
  final int flex;
}

class _DirectoryRow extends StatefulWidget {
  const _DirectoryRow({
    required this.wholesaler,
    required this.onOpenKhata,
  });

  final Wholesaler wholesaler;
  final VoidCallback onOpenKhata;

  @override
  State<_DirectoryRow> createState() => _DirectoryRowState();
}

class _DirectoryRowState extends State<_DirectoryRow> {
  bool _hovered = false;

  static const _border = Color(0xFFE2EBE0);
  static const _primary = Color(0xFF1B4332);
  static const _balanceRed = Color(0xFFA32D2D);
  static const _secondary = Color(0xFF2D6A4F);
  static const _inputBorder = Color(0xFFC6DEC9);
  static const _hoverBg = Color(0xFFF5F9F2);

  @override
  Widget build(BuildContext context) {
    final w = widget.wholesaler;
    final owed = w.balance > 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hovered ? _hoverBg : Colors.white,
          border: const Border(
            bottom: BorderSide(color: _border, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 26,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  w.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _primary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Expanded(
              flex: 16,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  w.phone,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Expanded(
              flex: 18,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  w.city,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Expanded(
              flex: 20,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Text(
                  formatPKR(w.balance),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: owed ? _balanceRed : _secondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Expanded(
              flex: 20,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: widget.onOpenKhata,
                    icon: const Icon(Icons.menu_book_outlined, size: 13),
                    label: const Text('Open Khata'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _primary,
                      side: const BorderSide(color: _inputBorder, width: 0.5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
