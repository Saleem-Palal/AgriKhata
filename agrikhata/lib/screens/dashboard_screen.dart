import 'dart:math' as math;

import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/services/whatsapp_urdu_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:agrikhata/utils/season_utils.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Shop-counter home screen — layout aligned to `Extra/dashboard (1).html`.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.onNavigateToNewSale,
    this.onNavigateToAddZamindar,
    this.onNavigateToWholesalers,
  });

  final VoidCallback? onNavigateToNewSale;
  final VoidCallback? onNavigateToAddZamindar;
  final VoidCallback? onNavigateToWholesalers;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static final NumberFormat _currency = NumberFormat('#,##,##0');
  static final DateFormat _headerClock = DateFormat('EEEE, d MMMM yyyy');
  static final DateFormat _headerTime = DateFormat('h:mm a');
  static final DateFormat _expiryFormat = DateFormat('d MMM yyyy');

  static const List<String> _recoveryFilters = <String>[
    'Weekly',
    'Monthly',
    '90 Days',
    'After Harvest',
  ];

  DashboardMetrics _metrics = DashboardMetrics.empty();
  List<DashboardRecoveryRow> _recoveries = const <DashboardRecoveryRow>[];
  String _selectedRecoveryFilter = 'Weekly';
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isLoadingRecoveries = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
    _loadMetrics();
  }

  @override
  void dispose() {
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() {
    if (!mounted) return;
    _loadMetrics(showFullLoading: false);
  }

  Future<void> _loadMetrics({bool showFullLoading = true}) async {
    if (showFullLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    } else {
      setState(() {
        _isRefreshing = true;
        _error = null;
      });
    }

    try {
      final metrics = await DatabaseHelper.instance.getDashboardMetrics();
      final recoveries = await DatabaseHelper.instance.getTopPendingRecoveries(
        paymentTerm: _selectedRecoveryFilter,
        limit: 5,
      );
      if (!mounted) return;
      setState(() {
        _metrics = metrics;
        _recoveries = recoveries;
        _isLoading = false;
        _isRefreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _error = 'Could not load dashboard metrics.\n$e';
      });
    }
  }

  Future<void> _onRecoveryFilterChanged(String filter) async {
    if (_selectedRecoveryFilter == filter) return;
    setState(() {
      _selectedRecoveryFilter = filter;
      _isLoadingRecoveries = true;
    });
    try {
      final recoveries = await DatabaseHelper.instance.getTopPendingRecoveries(
        paymentTerm: filter,
        limit: 5,
      );
      if (!mounted) return;
      setState(() {
        _recoveries = recoveries;
        _isLoadingRecoveries = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingRecoveries = false);
    }
  }

  String _formatRs(double amount) {
    final rounded = amount.round();
    final sign = rounded < 0 ? '-' : '';
    return '₨ $sign${_currency.format(rounded.abs())}';
  }

  Future<void> _openWhatsAppReminder(DashboardRecoveryRow row) async {
    final phone = row.whatsappNumber?.trim() ?? '';
    if (WhatsAppUrduService.normalizePhone(phone) == null) {
      if (!mounted) return;
      AppToast.showError(context, 'No WhatsApp number on file for ${row.name}.');
      return;
    }

    try {
      final shopName = await ShopSettings.getShopName();
      final launched = await WhatsAppUrduService.sendUrduReminder(
        phone: phone,
        zamindarName: row.name,
        shopName: shopName,
        amount: row.outstandingBalance,
      );
      if (!launched && mounted) {
        AppToast.showError(context, 'Could not open WhatsApp.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.showError(context, 'Could not open WhatsApp: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final clockLabel =
        '${_headerClock.format(now)}  ·  ${_headerTime.format(now)}';

    return ColoredBox(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AgriHeader(
            breadcrumbs: const ['Main', 'Dashboard'],
            actions: [
              Text(
                clockLabel,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textHint,
                ),
              ),
              Tooltip(
                message: 'Refresh metrics',
                child: IconButton(
                  onPressed: _isLoading || _isRefreshing
                      ? null
                      : () => _loadMetrics(showFullLoading: false),
                  icon: _isRefreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.darkGreen,
                          ),
                        )
                      : const Icon(
                          Icons.sync_rounded,
                          size: 18,
                          color: AppColors.darkGreen,
                        ),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
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
            SizedBox(height: 10),
            Text(
              'Loading dashboard…',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.dangerText,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => _loadMetrics(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.darkGreen,
      onRefresh: () => _loadMetrics(showFullLoading: false),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildKpiRow(),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final maxW = constraints.maxWidth;
                if (!maxW.isFinite || maxW < 900) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildLeftColumn(),
                      const SizedBox(height: 12),
                      _buildRightColumn(),
                    ],
                  );
                }
                final half = (maxW - 12) / 2;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: half, child: _buildLeftColumn()),
                    const SizedBox(width: 12),
                    SizedBox(width: half, child: _buildRightColumn()),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // KPI row
  // ---------------------------------------------------------------------------

  Widget _buildKpiRow() {
    final cards = [
      _KpiCard(
        emoji: '🟢',
        title: 'You Will Get',
        titleColor: AppColors.mediumGreen,
        value: _formatRs(_metrics.totalReceivables),
        valueColor: AppColors.textPrimary,
        subtext: 'Lene Hain (Zamindar Udhaar)',
        subtextColor: const Color(0xFF4C8067),
        backgroundColor: AppColors.tagGreenBg,
        borderColor: const Color(0xFFBEE3CC),
      ),
      _KpiCard(
        emoji: '🔴',
        title: 'You Will Give',
        titleColor: const Color(0xFFA32D2D),
        value: _formatRs(_metrics.totalPayables),
        valueColor: AppColors.tagRedText,
        subtext: 'Dene Hain (Wholesalers)',
        subtextColor: const Color(0xFFA85B5B),
        backgroundColor: AppColors.tagRedBg,
        borderColor: const Color(0xFFF3C6C6),
      ),
      _KpiCard(
        emoji: '💵',
        title: 'Cash in Hand',
        titleColor: AppColors.tagBlueText,
        value: _formatRs(_metrics.cashInHand),
        valueColor: AppColors.tagBlueText,
        subtext: "Today's Drawer Cash",
        subtextColor: const Color(0xFF5B84AA),
        backgroundColor: AppColors.tagBlueBg,
        borderColor: const Color(0xFFC3D9F0),
      ),
      _KpiCard(
        emoji: '👥',
        title: 'Active Accounts',
        titleColor: const Color(0xFF4B5A50),
        value: _currency.format(_metrics.activeAccounts),
        valueColor: AppColors.textPrimary,
        subtext:
            'Zamindars: ${_metrics.activeZamindars} | Wholesalers: ${_metrics.activeWholesalers}',
        subtextColor: AppColors.textMuted,
        backgroundColor: Color.lerp(
          AppColors.cardSurface,
          AppColors.textMuted,
          0.10,
        )!,
        borderColor: const Color(0xFFDCE2DE),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        if (!maxW.isFinite || maxW < 700) {
          final cardW = maxW.isFinite
              ? ((maxW - 12) / 2).clamp(140.0, maxW)
              : 200.0;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final card in cards)
                SizedBox(
                  width: cardW,
                  child: card,
                ),
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: cards[i]),
            ],
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Left column
  // ---------------------------------------------------------------------------

  Widget _buildLeftColumn() {
    return Column(
      children: [
        _SowingSeasonMonitorCard(),
        const SizedBox(height: 12),
        _DashboardCard(
          title: '📦 Low Stock Alerts',
          child: _metrics.lowStockAlerts.isEmpty
              ? const _EmptyHint(text: 'All stock levels healthy')
              : Column(
                  children: [
                    for (var i = 0; i < _metrics.lowStockAlerts.length; i++) ...[
                      if (i > 0) const _Hairline(),
                      _StockRow(alert: _metrics.lowStockAlerts[i]),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _DashboardCard(
          title: '⏳ Product Expiry Warnings',
          child: _metrics.expiryAlerts.isEmpty
              ? const _EmptyHint(text: 'No products expiring in 60 days')
              : Column(
                  children: [
                    for (var i = 0; i < _metrics.expiryAlerts.length; i++) ...[
                      if (i > 0) const _Hairline(),
                      _ExpiryRow(
                        alert: _metrics.expiryAlerts[i],
                        dateLabel: _expiryFormat.format(
                          _metrics.expiryAlerts[i].expiryDate,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Right column
  // ---------------------------------------------------------------------------

  Widget _buildRightColumn() {
    final cash = _metrics.todayCashSalesVolume;
    final credit = _metrics.todayCreditSalesVolume;
    final total = cash + credit;
    final cashPct = total <= 0 ? 0.0 : (cash / total) * 100.0;
    final creditPct = total <= 0 ? 0.0 : 100.0 - cashPct;

    return Column(
      children: [
        _DashboardCard(
          title: '👤 Top Pending Recoveries',
          trailing: null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RecoveryFilterBar(
                filters: _recoveryFilters,
                selected: _selectedRecoveryFilter,
                onSelected: _onRecoveryFilterChanged,
              ),
              const SizedBox(height: 8),
              if (_isLoadingRecoveries)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.darkGreen,
                      ),
                    ),
                  ),
                )
              else if (_recoveries.isEmpty)
                const _EmptyHint(text: 'No pending recoveries for this filter')
              else
                _RecoveriesTable(
                  rows: _recoveries,
                  formatRs: _formatRs,
                  onWhatsApp: _openWhatsAppReminder,
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _DashboardCard(
          title: '🧾 Counter Ledger Snapshot',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _SnapshotTile(
                      label: "Today's Cash Sales",
                      value: _formatRs(cash),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SnapshotTile(
                      label: "Today's Credit Sales",
                      value: _formatRs(credit),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: SizedBox(
                        height: 6,
                        child: Stack(
                          children: [
                            const ColoredBox(
                              color: AppColors.border,
                              child: SizedBox.expand(),
                            ),
                            FractionallySizedBox(
                              widthFactor: total <= 0
                                  ? 0
                                  : (cashPct / 100).clamp(0.0, 1.0),
                              child: const ColoredBox(
                                color: AppColors.accentGreen,
                                child: SizedBox.expand(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '${cashPct.round()}% Cash / ${creditPct.round()}% Credit',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: AppColors.textHint,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _DashboardCard(
          title: '⚡ Quick Actions',
          child: Row(
            children: [
              Expanded(
                child: _QuickActionButton(
                  emoji: '➕',
                  label: 'New Invoice\n(Sale Screen)',
                  onTap: widget.onNavigateToNewSale,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickActionButton(
                  emoji: '🚜',
                  label: 'Add Zamindar\nProfile',
                  onTap: widget.onNavigateToAddZamindar,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickActionButton(
                  emoji: '💰',
                  label: 'Record Wholesaler\nPayment',
                  onTap: widget.onNavigateToWholesalers,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Shared chrome
// =============================================================================

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      thickness: 0.5,
      color: Color(0xFFF0F4EE),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.emoji,
    required this.title,
    required this.titleColor,
    required this.value,
    required this.valueColor,
    required this.subtext,
    required this.subtextColor,
    required this.backgroundColor,
    required this.borderColor,
  });

  final String emoji;
  final String title;
  final Color titleColor;
  final String value;
  final Color valueColor;
  final String subtext;
  final Color subtextColor;
  final Color backgroundColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$emoji $title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: valueColor,
              height: 1.15,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            subtext,
            style: TextStyle(fontSize: 10, color: subtextColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Sowing season monitor
// =============================================================================

class _SowingSeasonMonitorCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final season = SeasonUtils.getCurrentSeason();
    final isKharif = season.name == 'Kharif';
    final crops = isKharif
        ? 'Rice, Cotton, Sugarcane, Maize'
        : 'Wheat, Mustard, Gram, Barley';
    final monthName = DateFormat('MMMM').format(DateTime.now());
    // Approved HTML prototype: 50% arc with May–Oct center label.
    const double progress = 0.50;
    const String seasonBounds = 'May–Oct';

    return _DashboardCard(
      title: '🗓️ Sowing Season Monitor',
      child: Row(
        children: [
          SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(88, 88),
                  painter: _SeasonRingPainter(progress: progress),
                ),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      seasonBounds,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      '50%',
                      style: TextStyle(
                        fontSize: 9,
                        color: AppColors.textHint,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current Season: ${season.name}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  crops,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Mid-season execution point — $monthName',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textHint,
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

class _SeasonRingPainter extends CustomPainter {
  const _SeasonRingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width / 2) - stroke / 2;
    final track = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final arc = Paint()
      ..color = AppColors.accentGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, track);
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _SeasonRingPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

// =============================================================================
// Stock / expiry rows
// =============================================================================

class _StockRow extends StatelessWidget {
  const _StockRow({required this.alert});

  final DashboardLowStockAlert alert;

  @override
  Widget build(BuildContext context) {
    final critical = alert.isCritical;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              alert.displayName,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _StatusBadge(
            label: '${alert.availableStock} left',
            critical: critical,
          ),
        ],
      ),
    );
  }
}

class _ExpiryRow extends StatelessWidget {
  const _ExpiryRow({required this.alert, required this.dateLabel});

  final DashboardExpiryAlert alert;
  final String dateLabel;

  @override
  Widget build(BuildContext context) {
    final days = alert.daysRemaining;
    final daysLabel = days <= 0
        ? 'Expiring today'
        : 'Expiring in $days Day${days == 1 ? '' : 's'}';

    // Strip any accidental "Batch …" suffixes from product names.
    final cleanName = alert.productName
        .replaceAll(RegExp(r'\s*[·\-|]?\s*Batch\b.*$', caseSensitive: false), '')
        .trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cleanName.isEmpty ? alert.productName : cleanName,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'Expiry: $dateLabel',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textHint,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StatusBadge(label: daysLabel, critical: alert.isCritical),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.critical});

  final String label;
  final bool critical;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: critical ? AppColors.tagRedBg : AppColors.tagAmberBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w500,
          color: critical ? AppColors.tagRedText : AppColors.tagAmberText,
        ),
      ),
    );
  }
}

// =============================================================================
// Recoveries
// =============================================================================

class _RecoveryFilterBar extends StatelessWidget {
  const _RecoveryFilterBar({
    required this.filters,
    required this.selected,
    required this.onSelected,
  });

  final List<String> filters;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final filter in filters)
          _FilterChip(
            label: filter,
            selected: selected == filter,
            onTap: () => onSelected(filter),
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.tagGreenBg : AppColors.background,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? AppColors.recBorder : AppColors.inputBorder,
              width: 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: selected ? AppColors.mediumGreen : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _RecoveriesTable extends StatelessWidget {
  const _RecoveriesTable({
    required this.rows,
    required this.formatRs,
    required this.onWhatsApp,
  });

  final List<DashboardRecoveryRow> rows;
  final String Function(double) formatRs;
  final ValueChanged<DashboardRecoveryRow> onWhatsApp;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Row(
            children: [
              Expanded(
                flex: 40,
                child: Text(
                  'ZAMINDAR',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Expanded(
                flex: 26,
                child: Text(
                  'OWED (₨)',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Expanded(flex: 34, child: SizedBox.shrink()),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 0.5, color: AppColors.border),
        for (var i = 0; i < rows.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  flex: 40,
                  child: Text(
                    rows[i].name,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  flex: 26,
                  child: Text(
                    formatRs(rows[i].outstandingBalance),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFA32D2D),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  flex: 34,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _WhatsAppLink(
                      onTap: () => onWhatsApp(rows[i]),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (i < rows.length - 1)
            const Divider(
              height: 1,
              thickness: 0.5,
              color: Color(0xFFF0F4EE),
            ),
        ],
      ],
    );
  }
}

class _WhatsAppLink extends StatelessWidget {
  const _WhatsAppLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppWhatsAppIconButton(onPressed: onTap);
  }
}

// =============================================================================
// Snapshot + quick actions
// =============================================================================

class _SnapshotTile extends StatelessWidget {
  const _SnapshotTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _QuickActionButton extends StatefulWidget {
  const _QuickActionButton({
    required this.emoji,
    required this.label,
    this.onTap,
  });

  final String emoji;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_QuickActionButton> createState() => _QuickActionButtonState();
}

class _QuickActionButtonState extends State<_QuickActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          transform: Matrix4.translationValues(0, _hovered ? -1 : 0, 0),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFFF0F7EB) : AppColors.cardSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hovered ? AppColors.recBorder : AppColors.border,
              width: 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.emoji, style: const TextStyle(fontSize: 17)),
              const SizedBox(height: 6),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
