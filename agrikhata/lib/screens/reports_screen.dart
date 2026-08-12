import 'dart:async';

import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/dashboard/kpi_breakdown_dialogs.dart';
import 'package:agrikhata/services/whatsapp_urdu_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// Domain helpers
// ---------------------------------------------------------------------------

enum PaymentTermsTone { healthy, warn, critical }

class OutstandingCreditRow {
  const OutstandingCreditRow({
    required this.name,
    required this.village,
    required this.balance,
    required this.balanceLabel,
    required this.termsLabel,
    required this.lastActive,
    this.zamindarId,
    this.whatsappNumber,
    this.balanceIsCritical = false,
  });

  final int? zamindarId;
  final String name;
  final String village;
  final double balance;
  final String balanceLabel;
  final String termsLabel;
  final String lastActive;
  final String? whatsappNumber;
  final bool balanceIsCritical;

  PaymentTermsTone get tone {
    final lower = termsLabel.toLowerCase();
    if (lower.contains('overdue') || lower.contains('past season')) {
      return PaymentTermsTone.critical;
    }
    if (lower.contains('harvest')) return PaymentTermsTone.healthy;
    return PaymentTermsTone.warn;
  }
}

class CapitalCategory {
  const CapitalCategory({
    required this.name,
    required this.amount,
    required this.amountLabel,
    required this.ratio,
    required this.color,
  });

  final String name;
  final double amount;
  final String amountLabel;
  final double ratio;
  final Color color;
}

class AgingSegment {
  const AgingSegment({
    required this.label,
    required this.percent,
    required this.amount,
    required this.color,
  });

  final String label;
  final double percent;
  final double amount;
  final Color color;
}

class SeasonalMetrics {
  const SeasonalMetrics({
    required this.season,
    required this.totalPurchases,
    required this.totalRevenue,
    required this.cashSales,
    required this.creditSales,
    required this.netProfit,
    required this.totalMarketDebt,
    required this.highRiskDues,
    required this.todaysRecovery,
    required this.dailyTarget,
    required this.collectionEfficiency,
    this.cashPurchases = 0,
    this.creditPurchases = 0,
    this.grossSalesBase = 0,
    this.seasonalIncrements = 0,
    this.totalDiscounts = 0,
  });

  final String season;
  final double totalPurchases;
  final double cashPurchases;
  final double creditPurchases;
  final double totalRevenue;
  final double cashSales;
  final double creditSales;
  final double netProfit;
  final double totalMarketDebt;
  final double highRiskDues;
  final double todaysRecovery;
  final double dailyTarget;
  final double collectionEfficiency;
  final double grossSalesBase;
  final double seasonalIncrements;
  final double totalDiscounts;

  double get profitMargin =>
      totalRevenue > 0 ? (netProfit / totalRevenue) * 100.0 : 0.0;

  double get recoveryProgress =>
      dailyTarget > 0 ? (todaysRecovery / dailyTarget).clamp(0.0, 1.0) : 0.0;

  double get cashSalesPct =>
      totalRevenue > 0 ? (cashSales / totalRevenue) * 100.0 : 0.0;

  double get creditSalesPct =>
      totalRevenue > 0 ? (creditSales / totalRevenue) * 100.0 : 0.0;

  factory SeasonalMetrics.empty() => const SeasonalMetrics(
    season: '',
    totalPurchases: 0,
    totalRevenue: 0,
    cashSales: 0,
    creditSales: 0,
    netProfit: 0,
    totalMarketDebt: 0,
    highRiskDues: 0,
    todaysRecovery: 0,
    dailyTarget: 100000,
    collectionEfficiency: 0,
  );

  factory SeasonalMetrics.fromMap(Map<String, dynamic> map) {
    return SeasonalMetrics(
      season: map['season'] as String? ?? '',
      totalPurchases: (map['totalPurchases'] as num?)?.toDouble() ?? 0,
      cashPurchases: (map['cashPurchases'] as num?)?.toDouble() ?? 0,
      creditPurchases: (map['creditPurchases'] as num?)?.toDouble() ?? 0,
      totalRevenue: (map['totalRevenue'] as num?)?.toDouble() ?? 0,
      cashSales: (map['cashSales'] as num?)?.toDouble() ?? 0,
      creditSales: (map['creditSales'] as num?)?.toDouble() ?? 0,
      grossSalesBase: (map['grossSalesBase'] as num?)?.toDouble() ?? 0,
      seasonalIncrements: (map['seasonalIncrements'] as num?)?.toDouble() ?? 0,
      totalDiscounts: (map['totalDiscounts'] as num?)?.toDouble() ?? 0,
      netProfit: (map['netProfit'] as num?)?.toDouble() ?? 0,
      totalMarketDebt: (map['totalMarketDebt'] as num?)?.toDouble() ?? 0,
      highRiskDues: (map['highRiskDues'] as num?)?.toDouble() ?? 0,
      todaysRecovery: (map['todaysRecovery'] as num?)?.toDouble() ?? 0,
      dailyTarget: (map['dailyTarget'] as num?)?.toDouble() ?? 100000,
      collectionEfficiency:
          (map['collectionEfficiency'] as num?)?.toDouble() ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// ReportsScreen
// ---------------------------------------------------------------------------

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    this.onNavigateToSalesLedger,
  });

  /// Opens Finance → Ledger (Sales tab) from revenue drill-down.
  final VoidCallback? onNavigateToSalesLedger;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _whatsAppGreen = Color(0xFF25D366);
  static const _whatsAppGreenHover = Color(0xFF1FBD5A);
  static const _agingCurrent = Color(0xFF52B788);
  static const _agingOverdue = Color(0xFFEF9F27);
  static const _agingCritical = Color(0xFFB23A48);
  static const _highRisk = Color(0xFFA32D2D);
  static const _rankMid = Color(0xFF40916C);
  static const _rankLight = Color(0xFF97C459);

  static final _currency = NumberFormat('#,##,##0');

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  String _searchQuery = '';
  String _selectedVillage = '';
  String _selectedTerm = 'All Terms';

  bool _isLoading = true;
  bool _isDirectoryLoading = false;
  String? _error;

  SeasonalMetrics _metrics = SeasonalMetrics.empty();
  List<AgingSegment> _agingSegments = const [];
  List<CapitalCategory> _capitalCategories = const [];
  List<OutstandingCreditRow> _directoryRows = const [];
  List<String> _villages = const [];

  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  static const _paymentTermOptions = <String>[
    'All Terms',
    'Harvest Settlement',
    '90-Day Cycle',
    'After a Week',
    'After a Month',
    'Overdue / Past Season',
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
    _loadAll();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _toastTimer?.cancel();
    _removeToast();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() {
    _loadAll(showFullLoading: false);
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      final next = _searchController.text;
      if (next == _searchQuery) return;
      setState(() => _searchQuery = next);
      _loadDirectory();
    });
  }

  Future<void> _loadAll({bool showFullLoading = true}) async {
    if (showFullLoading && mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final results = await Future.wait([
        DatabaseHelper.instance.getSeasonalMetrics(),
        DatabaseHelper.instance.getAnalyticalInsights(),
        DatabaseHelper.instance.getDistinctVillages(),
        DatabaseHelper.instance.getOutstandingCreditDirectory(
          search: _searchQuery,
          village: _selectedVillage.isEmpty ? null : _selectedVillage,
          paymentTerm: _selectedTerm,
        ),
      ]);

      if (!mounted) return;

      final metrics = SeasonalMetrics.fromMap(
        results[0] as Map<String, dynamic>,
      );
      final insights = results[1] as Map<String, dynamic>;
      final villages = results[2] as List<String>;
      final directory = results[3] as List<Map<String, dynamic>>;

      setState(() {
        _metrics = metrics;
        _agingSegments = _mapAging(insights);
        _capitalCategories = _mapCapital(insights);
        _villages = villages;
        _directoryRows = _mapDirectory(directory);
        _isLoading = false;
        _isDirectoryLoading = false;
        _error = null;
      });
    } catch (e, st) {
      debugPrint('Reports load failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isDirectoryLoading = false;
        _error = 'Failed to load reports: $e';
      });
    }
  }

  Future<void> _loadDirectory() async {
    if (!mounted) return;
    setState(() => _isDirectoryLoading = true);

    try {
      final directory = await DatabaseHelper.instance
          .getOutstandingCreditDirectory(
            search: _searchQuery,
            village: _selectedVillage.isEmpty ? null : _selectedVillage,
            paymentTerm: _selectedTerm,
          );
      if (!mounted) return;
      setState(() {
        _directoryRows = _mapDirectory(directory);
        _isDirectoryLoading = false;
      });
    } catch (e) {
      debugPrint('Directory reload failed: $e');
      if (!mounted) return;
      setState(() => _isDirectoryLoading = false);
    }
  }

  List<AgingSegment> _mapAging(Map<String, dynamic> insights) {
    final aging =
        (insights['creditAging'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final currentPct = (aging['currentPercent'] as num?)?.toDouble() ?? 0;
    final overduePct = (aging['overduePercent'] as num?)?.toDouble() ?? 0;
    final criticalPct = (aging['criticalPercent'] as num?)?.toDouble() ?? 0;
    // Avoid a blank bar when there is no outstanding credit.
    final hasData = currentPct + overduePct + criticalPct > 0;
    return [
      AgingSegment(
        label: 'Current (<90 Days)',
        percent: hasData ? currentPct : 0,
        amount: (aging['currentAmount'] as num?)?.toDouble() ?? 0,
        color: _agingCurrent,
      ),
      AgingSegment(
        label: 'Overdue (90–180 Days)',
        percent: hasData ? overduePct : 0,
        amount: (aging['overdueAmount'] as num?)?.toDouble() ?? 0,
        color: _agingOverdue,
      ),
      AgingSegment(
        label: 'Critical (>180 Days)',
        percent: hasData ? criticalPct : 0,
        amount: (aging['criticalAmount'] as num?)?.toDouble() ?? 0,
        color: _agingCritical,
      ),
    ];
  }

  List<CapitalCategory> _mapCapital(Map<String, dynamic> insights) {
    final list = (insights['capitalTrapped'] as List?) ?? const [];
    final colors = <String, Color>{
      'Fertilizers': AppColors.mediumGreen,
      'Seeds': _rankMid,
      'Pesticides': _rankLight,
    };

    if (list.isEmpty) {
      return [
        for (final entry in colors.entries)
          CapitalCategory(
            name: entry.key,
            amount: 0,
            amountLabel: _formatCurrency(0),
            ratio: 0,
            color: entry.value,
          ),
      ];
    }

    return list.map((raw) {
      final map = (raw as Map).cast<String, dynamic>();
      final name = map['category'] as String? ?? 'Other';
      final amount = (map['amount'] as num?)?.toDouble() ?? 0;
      final ratio = (map['ratio'] as num?)?.toDouble() ?? 0;
      return CapitalCategory(
        name: name,
        amount: amount,
        amountLabel: _formatCurrency(amount),
        ratio: ratio.clamp(0.0, 1.0),
        color: colors[name] ?? AppColors.accentGreen,
      );
    }).toList();
  }

  List<OutstandingCreditRow> _mapDirectory(List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      final balance = (row['outstandingBalance'] as num?)?.toDouble() ?? 0;
      return OutstandingCreditRow(
        zamindarId: row['zamindarId'] as int?,
        name: row['name'] as String? ?? '—',
        village: row['village'] as String? ?? '—',
        balance: balance,
        balanceLabel: _formatCurrency(balance),
        termsLabel: row['paymentTerm'] as String? ?? '90-Day Cycle',
        lastActive: row['lastActiveLabel'] as String? ?? '—',
        whatsappNumber: row['whatsappNumber'] as String?,
        balanceIsCritical: row['isCritical'] as bool? ?? false,
      );
    }).toList();
  }

  static String _formatCurrency(num value) {
    return '₨ ${_currency.format(value.round())}';
  }

  void _removeToast() {
    _toastEntry?.remove();
    _toastEntry = null;
  }

  Future<void> _sendReminder(OutstandingCreditRow row) async {
    final phone = row.whatsappNumber?.trim() ?? '';
    if (WhatsAppUrduService.normalizePhone(phone) == null) {
      if (!mounted) return;
      AppToast.showError(
        context,
        'No WhatsApp number on file for ${row.name}.',
      );
      return;
    }

    try {
      final shopName = await ShopSettings.getShopName();
      final message = WhatsAppUrduService.buildUrduReminderText(
        zamindarName: row.name,
        shopName: shopName,
        amount: row.balance,
      );

      final launched = await WhatsAppUrduService.sendUrduReminder(
        phone: phone,
        zamindarName: row.name,
        shopName: shopName,
        amount: row.balance,
      );

      if (!mounted) return;

      if (!launched) {
        AppToast.showError(context, 'Could not open WhatsApp.');
        return;
      }

      _toastTimer?.cancel();
      _removeToast();

      final overlay = Overlay.of(context);
      _toastEntry = OverlayEntry(
        builder: (context) => _WhatsAppReminderToast(
          name: row.name,
          message: message,
          onDismiss: () {
            _toastTimer?.cancel();
            _removeToast();
          },
        ),
      );
      overlay.insert(_toastEntry!);
      _toastTimer = Timer(const Duration(milliseconds: 4500), _removeToast);
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Could not send WhatsApp reminder: $e');
      }
    }
  }

  void _onPrintStatement(OutstandingCreditRow row) {
    AppToast.showSuccess(context, 'Printing statement for ${row.name}…');
  }

  void _onViewLedger(OutstandingCreditRow row) {
    AppToast.showSuccess(context, 'Opening ledger for ${row.name}…');
  }

  void _onPrintSeasonalSummary() {
    AppToast.showSuccess(
      context,
      _metrics.season.isEmpty
          ? 'Preparing seasonal summary for print…'
          : 'Preparing ${_metrics.season} summary for print…',
    );
  }

  void _onExportCreditLedger() {
    AppToast.showSuccess(context, 'Exporting complete credit ledger (PDF)…');
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AgriHeader(
            breadcrumbs: const ['Finance', 'Reports'],
            actions: [
              if (_metrics.season.isNotEmpty)
                Text(
                  _metrics.season,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.darkGreen),
            SizedBox(height: 12),
            Text(
              'Loading reports…',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: _highRisk, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: () => _loadAll(), child: const Text('Retry')),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Season Performance (Sales, Revenue & Profit)'),
          const SizedBox(height: 8),
          _SeasonPerformanceRow(
            metrics: _metrics,
            onOpenRevenue: () => showRevenueBreakdownDialog(
              context: context,
              season: _metrics.season.isEmpty ? null : _metrics.season,
              onViewSalesLedger: widget.onNavigateToSalesLedger,
            ),
            onOpenPurchases: () => showPurchasesBreakdownDialog(
              context: context,
              season: _metrics.season.isEmpty ? null : _metrics.season,
            ),
            onOpenNetProfit: () => showNetProfitAuditDialog(
              context: context,
              season: _metrics.season.isEmpty ? null : _metrics.season,
            ),
          ),
          const SizedBox(height: 16),
          const _SectionLabel('Outstanding Credit & Recovery Overview'),
          const SizedBox(height: 8),
          _OutstandingOverviewRow(metrics: _metrics),
          const SizedBox(height: 16),
          _InsightsSection(
            agingSegments: _agingSegments,
            capitalCategories: _capitalCategories,
          ),
          const SizedBox(height: 16),
          _CreditDirectoryCard(
            searchController: _searchController,
            villages: _villages,
            selectedVillage: _selectedVillage,
            selectedTerms: _selectedTerm,
            termOptions: _paymentTermOptions,
            rows: _directoryRows,
            isLoading: _isDirectoryLoading,
            onVillageChanged: (v) {
              setState(() => _selectedVillage = v);
              _loadDirectory();
            },
            onTermsChanged: (t) {
              setState(() => _selectedTerm = t);
              _loadDirectory();
            },
            onSendReminder: _sendReminder,
            onPrintStatement: _onPrintStatement,
            onViewLedger: _onViewLedger,
            whatsAppGreen: _whatsAppGreen,
            whatsAppGreenHover: _whatsAppGreenHover,
            highRisk: _highRisk,
          ),
          const SizedBox(height: 16),
          _ActionFooter(
            onPrintSummary: _onPrintSeasonalSummary,
            onExportPdf: _onExportCreditLedger,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared chrome
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Color(0xFF6B9E7A),
        letterSpacing: 0.5,
      ),
    );
  }
}

class _ReportCard extends StatefulWidget {
  const _ReportCard({
    required this.child,
    this.onTap,
    this.showDetailCue = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool showDetailCue;

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final clickable = widget.onTap != null;
    final borderColor = _hovered && clickable
        ? AppColors.recBorder
        : AppColors.border;

    return MouseRegion(
      onEnter: clickable ? (_) => setState(() => _hovered = true) : null,
      onExit: clickable ? (_) => setState(() => _hovered = false) : null,
      cursor: clickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        transform:
            Matrix4.translationValues(0, _hovered && clickable ? -1 : 0, 0),
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: borderColor,
            width: _hovered && clickable ? 1.0 : 0.5,
          ),
          boxShadow: _hovered && clickable
              ? const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ]
              : const [],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: widget.child,
                ),
                if (clickable || widget.showDetailCue)
                  const Positioned(
                    top: 10,
                    right: 10,
                    child: Tooltip(
                      message: 'Click for details',
                      child: Icon(
                        Icons.info_outline,
                        size: 14,
                        color: AppColors.textHint,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KpiLabel extends StatelessWidget {
  const _KpiLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: AppColors.textHint,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _KpiValue extends StatelessWidget {
  const _KpiValue(this.text, {this.bold = false});

  final String text;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 22,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          color: AppColors.textPrimary,
          height: 1.2,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.tone});

  final String label;
  final PaymentTermsTone tone;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    switch (tone) {
      case PaymentTermsTone.healthy:
        bg = AppColors.tagGreenBg;
        fg = AppColors.tagGreenText;
      case PaymentTermsTone.warn:
        bg = AppColors.tagAmberBg;
        fg = AppColors.tagAmberText;
      case PaymentTermsTone.critical:
        bg = AppColors.tagRedBg;
        fg = AppColors.tagRedText;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.value,
    this.color = AppColors.mediumGreen,
    this.height = 7,
    this.trackColor = AppColors.border,
  });

  final double value;
  final Color color;
  final double height;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: trackColor),
            FractionallySizedBox(
              widthFactor: clamped,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmt(num value) => '₨ ${NumberFormat('#,##,##0').format(value.round())}';

// ---------------------------------------------------------------------------
// Zone 1 — KPI rows
// ---------------------------------------------------------------------------

class _SeasonPerformanceRow extends StatelessWidget {
  const _SeasonPerformanceRow({
    required this.metrics,
    this.onOpenRevenue,
    this.onOpenPurchases,
    this.onOpenNetProfit,
  });

  final SeasonalMetrics metrics;
  final VoidCallback? onOpenRevenue;
  final VoidCallback? onOpenPurchases;
  final VoidCallback? onOpenNetProfit;

  @override
  Widget build(BuildContext context) {
    final margin = metrics.profitMargin;
    final marginHit = margin >= 15;

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = 12.0;
        final cardWidth = (constraints.maxWidth - gap * 3) / 4;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(
              width: cardWidth.clamp(180, double.infinity),
              child: _ReportCard(
                onTap: onOpenRevenue,
                showDetailCue: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('TOTAL REVENUE / SALES'),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.totalRevenue)),
                    const SizedBox(height: 12),
                    Text(
                      'Base: ${_fmt(metrics.grossSalesBase)}  |  '
                      'Seasonal: +${_fmt(metrics.seasonalIncrements)}  |  '
                      'Disc: -${_fmt(metrics.totalDiscounts)}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Cash: ${_fmt(metrics.cashSales)} (${metrics.cashSalesPct.toStringAsFixed(0)}%)  |  '
                      'Credit: ${_fmt(metrics.creditSales)} (${metrics.creditSalesPct.toStringAsFixed(0)}%)',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(180, double.infinity),
              child: _ReportCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('SEASONAL INCREMENTS'),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.seasonalIncrements)),
                    const SizedBox(height: 12),
                    const Text(
                      'Surcharge revenue this season',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(180, double.infinity),
              child: _ReportCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('DISCOUNTS GIVEN'),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.totalDiscounts)),
                    const SizedBox(height: 12),
                    const Text(
                      'Item + overall discounts absorbed',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(180, double.infinity),
              child: _ReportCard(
                onTap: onOpenPurchases,
                showDetailCue: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('TOTAL PURCHASES'),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.totalPurchases)),
                    const SizedBox(height: 12),
                    Text(
                      'Cash: ${_fmt(metrics.cashPurchases)}  |  Credit: ${_fmt(metrics.creditPurchases)}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(180, double.infinity),
              child: _ReportCard(
                onTap: onOpenNetProfit,
                showDetailCue: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('NET PROFIT'),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.netProfit), bold: true),
                    const SizedBox(height: 12),
                    const Text(
                      'This season',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(180, double.infinity),
              child: _ReportCard(
                onTap: onOpenNetProfit,
                showDetailCue: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('PROFIT MARGIN'),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _KpiValue('${margin.toStringAsFixed(1)}%'),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: _StatusBadge(
                            label: 'Target: >15.0%',
                            tone: marginHit
                                ? PaymentTermsTone.healthy
                                : PaymentTermsTone.warn,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _ProgressBar(value: (margin / 100).clamp(0.0, 1.0)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _OutstandingOverviewRow extends StatelessWidget {
  const _OutstandingOverviewRow({required this.metrics});

  final SeasonalMetrics metrics;

  static const _highRisk = Color(0xFFA32D2D);
  static const _amberBar = Color(0xFFEF9F27);

  @override
  Widget build(BuildContext context) {
    final efficiency = metrics.collectionEfficiency;
    final efficiencyHit = efficiency >= 85;

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = 12.0;
        final cardWidth = (constraints.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            SizedBox(
              width: cardWidth.clamp(220, double.infinity),
              child: _ReportCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('TOTAL MARKET DEBT'),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.totalMarketDebt)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 14,
                          color: _highRisk,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'High Risk Dues: ${_fmt(metrics.highRiskDues)}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: _highRisk,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(220, double.infinity),
              child: _ReportCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel("TODAY'S RECOVERY"),
                    const SizedBox(height: 6),
                    _KpiValue(_fmt(metrics.todaysRecovery)),
                    const SizedBox(height: 12),
                    _ProgressBar(value: metrics.recoveryProgress),
                    const SizedBox(height: 6),
                    Text(
                      '${(metrics.recoveryProgress * 100).round()}% of ${_fmt(metrics.dailyTarget)} daily target',
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: cardWidth.clamp(220, double.infinity),
              child: _ReportCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _KpiLabel('COLLECTION EFFICIENCY RATE'),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _KpiValue('${efficiency.round()}%'),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: _StatusBadge(
                            label: 'Target: >85%',
                            tone: efficiencyHit
                                ? PaymentTermsTone.healthy
                                : PaymentTermsTone.warn,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _ProgressBar(
                      value: (efficiency / 100).clamp(0.0, 1.0),
                      color: efficiencyHit ? AppColors.mediumGreen : _amberBar,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Zone 2 — Insights
// ---------------------------------------------------------------------------

class _InsightsSection extends StatelessWidget {
  const _InsightsSection({
    required this.agingSegments,
    required this.capitalCategories,
  });

  final List<AgingSegment> agingSegments;
  final List<CapitalCategory> capitalCategories;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _CreditAgingCard(segments: agingSegments)),
              const SizedBox(width: 12),
              Expanded(
                child: _CapitalTrappedCard(categories: capitalCategories),
              ),
            ],
          );
        }
        return Column(
          children: [
            _CreditAgingCard(segments: agingSegments),
            const SizedBox(height: 12),
            _CapitalTrappedCard(categories: capitalCategories),
          ],
        );
      },
    );
  }
}

class _CreditAgingCard extends StatelessWidget {
  const _CreditAgingCard({required this.segments});

  final List<AgingSegment> segments;

  @override
  Widget build(BuildContext context) {
    final hasData = segments.any((s) => s.percent > 0);

    return _ReportCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Credit Aging Breakdown',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 12,
              child: hasData
                  ? Row(
                      children: [
                        for (final s in segments)
                          if (s.percent > 0)
                            Expanded(
                              flex: (s.percent * 10).round().clamp(1, 1000),
                              child: ColoredBox(color: s.color),
                            ),
                      ],
                    )
                  : const ColoredBox(color: AppColors.border),
            ),
          ),
          const SizedBox(height: 12),
          for (final s in segments)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: s.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      s.label,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    '${s.percent.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CapitalTrappedCard extends StatelessWidget {
  const _CapitalTrappedCard({required this.categories});

  final List<CapitalCategory> categories;

  @override
  Widget build(BuildContext context) {
    return _ReportCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Capital Trapped by Category',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    categories[i].name,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  categories[i].amountLabel,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _ProgressBar(
              value: categories[i].ratio,
              color: categories[i].color,
              height: 6,
              trackColor: const Color(0xFFF0F4EE),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Zone 3 — Master Outstanding Credit Directory
// ---------------------------------------------------------------------------

class _CreditDirectoryCard extends StatelessWidget {
  const _CreditDirectoryCard({
    required this.searchController,
    required this.villages,
    required this.selectedVillage,
    required this.selectedTerms,
    required this.termOptions,
    required this.rows,
    required this.isLoading,
    required this.onVillageChanged,
    required this.onTermsChanged,
    required this.onSendReminder,
    required this.onPrintStatement,
    required this.onViewLedger,
    required this.whatsAppGreen,
    required this.whatsAppGreenHover,
    required this.highRisk,
  });

  final TextEditingController searchController;
  final List<String> villages;
  final String selectedVillage;
  final String selectedTerms;
  final List<String> termOptions;
  final List<OutstandingCreditRow> rows;
  final bool isLoading;
  final ValueChanged<String> onVillageChanged;
  final ValueChanged<String> onTermsChanged;
  final ValueChanged<OutstandingCreditRow> onSendReminder;
  final ValueChanged<OutstandingCreditRow> onPrintStatement;
  final ValueChanged<OutstandingCreditRow> onViewLedger;
  final Color whatsAppGreen;
  final Color whatsAppGreenHover;
  final Color highRisk;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Text(
              'Master Outstanding Credit Directory',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.all(16),
            child: _FilterBar(
              searchController: searchController,
              villages: villages,
              selectedVillage: selectedVillage,
              selectedTerms: selectedTerms,
              termOptions: termOptions,
              onVillageChanged: onVillageChanged,
              onTermsChanged: onTermsChanged,
            ),
          ),
          const Divider(height: 0.5, thickness: 0.5, color: AppColors.border),
          if (isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: AppColors.darkGreen,
                  ),
                ),
              ),
            )
          else
            AppDataTable(
              showCardChrome: false,
              minWidth: 920,
              empty: const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    'No matching zamindars found.',
                    style: TextStyle(fontSize: 12, color: AppColors.textHint),
                  ),
                ),
              ),
              columns: const [
                AppDataColumn(title: 'Zamindar Name', flex: 20),
                AppDataColumn(title: 'Village', flex: 14),
                AppDataColumn(title: 'Outstanding Balance', flex: 16),
                AppDataColumn(title: 'Payment Terms', flex: 16),
                AppDataColumn(title: 'Last Active', flex: 12),
                AppDataColumn(title: 'Recovery Actions', flex: 22),
              ],
              rows: [
                for (final row in rows)
                  AppDataRow(
                    cells: [
                      AppTableCellText(
                        row.name,
                        style: AppTextStyles.bodySmall.copyWith(
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      AppTableCellText(
                        row.village,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                      AppTableCellText(
                        row.balanceLabel,
                        style: AppTextStyles.bodySmall.copyWith(
                          fontWeight: FontWeight.w500,
                          color: row.balanceIsCritical
                              ? highRisk
                              : AppColors.textPrimary,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _StatusBadge(
                          label: row.termsLabel,
                          tone: row.tone,
                        ),
                      ),
                      AppTableCellText(
                        row.lastActive,
                        style: AppTextStyles.bodySmall.copyWith(
                          fontSize: 11,
                          color: AppColors.textHint,
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _WhatsAppReminderButton(
                            color: whatsAppGreen,
                            hoverColor: whatsAppGreenHover,
                            onTap: () => onSendReminder(row),
                          ),
                          _IconActionButton(
                            icon: Icons.print_outlined,
                            tooltip: 'Print Statement',
                            onTap: () => onPrintStatement(row),
                          ),
                          _IconActionButton(
                            icon: Icons.menu_book_outlined,
                            tooltip: 'View Ledger',
                            onTap: () => onViewLedger(row),
                          ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.searchController,
    required this.villages,
    required this.selectedVillage,
    required this.selectedTerms,
    required this.termOptions,
    required this.onVillageChanged,
    required this.onTermsChanged,
  });

  final TextEditingController searchController;
  final List<String> villages;
  final String selectedVillage;
  final String selectedTerms;
  final List<String> termOptions;
  final ValueChanged<String> onVillageChanged;
  final ValueChanged<String> onTermsChanged;

  InputDecoration _searchDecoration() {
    return InputDecoration(
      hintText: 'Search Zamindar or Village...',
      hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 12.5),
      prefixIcon: const Padding(
        padding: EdgeInsets.only(left: 10, right: 4),
        child: Icon(Icons.search, size: 16, color: AppColors.textHint),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      filled: true,
      fillColor: Colors.white,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.inputBorder, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.accentGreen, width: 1),
      ),
    );
  }

  Widget _styledDropdown({
    required String value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    required double width,
  }) {
    return SizedBox(
      width: width,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.inputBorder, width: 0.5),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            isDense: true,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textPrimary,
            ),
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: AppColors.textMuted,
              size: 20,
            ),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 200, maxWidth: 480),
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: searchController,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textPrimary,
              ),
              decoration: _searchDecoration(),
            ),
          ),
        ),
        _styledDropdown(
          value: selectedVillage,
          width: 170,
          items: [
            const DropdownMenuItem(value: '', child: Text('All Villages')),
            for (final v in villages)
              DropdownMenuItem(value: v, child: Text(v)),
          ],
          onChanged: (v) {
            if (v != null) onVillageChanged(v);
          },
        ),
        _styledDropdown(
          value: selectedTerms,
          width: 200,
          items: [
            for (final t in termOptions)
              DropdownMenuItem(value: t, child: Text(t)),
          ],
          onChanged: (v) {
            if (v != null) onTermsChanged(v);
          },
        ),
      ],
    );
  }
}

class _WhatsAppReminderButton extends StatefulWidget {
  const _WhatsAppReminderButton({
    required this.color,
    required this.hoverColor,
    required this.onTap,
  });

  final Color color;
  final Color hoverColor;
  final VoidCallback onTap;

  @override
  State<_WhatsAppReminderButton> createState() =>
      _WhatsAppReminderButtonState();
}

class _WhatsAppReminderButtonState extends State<_WhatsAppReminderButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Share via WhatsApp',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _hovered ? widget.hoverColor : widget.color,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline, size: 13, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  'Send Reminder',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconActionButton extends StatefulWidget {
  const _IconActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_IconActionButton> createState() => _IconActionButtonState();
}

class _IconActionButtonState extends State<_IconActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered ? const Color(0xFFF0F7EB) : Colors.white,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: _hovered ? AppColors.recBorder : AppColors.inputBorder,
                width: 0.5,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hovered ? AppColors.mediumGreen : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Zone 4 — Footer actions
// ---------------------------------------------------------------------------

class _ActionFooter extends StatelessWidget {
  const _ActionFooter({
    required this.onPrintSummary,
    required this.onExportPdf,
  });

  final VoidCallback onPrintSummary;
  final VoidCallback onExportPdf;

  @override
  Widget build(BuildContext context) {
    return _ReportCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttons = [
            _FooterButton(
              label: 'Print Seasonal Summary',
              icon: Icons.print_outlined,
              filled: false,
              onTap: onPrintSummary,
            ),
            _FooterButton(
              label: 'Export Complete Credit Ledger (PDF)',
              icon: Icons.picture_as_pdf_outlined,
              filled: true,
              onTap: onExportPdf,
            ),
          ];

          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight, child: buttons[i]),
                ],
              ],
            );
          }

          return Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: buttons,
          );
        },
      ),
    );
  }
}

class _FooterButton extends StatefulWidget {
  const _FooterButton({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;

  @override
  State<_FooterButton> createState() => _FooterButtonState();
}

class _FooterButtonState extends State<_FooterButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final filled = widget.filled;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: filled
                ? (_hovered ? AppColors.mediumGreen : AppColors.darkGreen)
                : (_hovered ? const Color(0xFFF0F7EB) : Colors.white),
            borderRadius: BorderRadius.circular(9),
            border: filled
                ? null
                : Border.all(color: AppColors.inputBorder, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: filled ? Colors.white : AppColors.textPrimary,
              ),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: filled ? Colors.white : AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WhatsApp reminder toast overlay
// ---------------------------------------------------------------------------

class _WhatsAppReminderToast extends StatelessWidget {
  const _WhatsAppReminderToast({
    required this.name,
    required this.message,
    required this.onDismiss,
  });

  final String name;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 24,
      bottom: 24,
      child: Material(
        color: Colors.transparent,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          builder: (context, t, child) {
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, 20 * (1 - t)),
                child: child,
              ),
            );
          },
          child: Container(
            width: 340,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border, width: 0.5),
              boxShadow: [
                BoxShadow(
                  color: AppColors.darkGreen.withValues(alpha: 0.18),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: const Color(0xFF25D366),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.chat_bubble,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'WhatsApp Reminder Sent',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: onDismiss,
                        child: const Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                          children: [
                            const TextSpan(text: 'Message preview to '),
                            TextSpan(
                              text: name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          message,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textPrimary,
                            height: 1.5,
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
      ),
    );
  }
}
