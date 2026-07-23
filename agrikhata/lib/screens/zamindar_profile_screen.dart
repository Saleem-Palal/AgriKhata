import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Data/zamindar_kisaans_tab.dart';
import 'package:agrikhata/Data/zamindar_ledger_tab.dart';
import 'package:agrikhata/Data/zamindar_overview_tab.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/screens/add_zamindar_screen.dart';
import 'package:agrikhata/utils/pdf_generator.dart';
import 'package:agrikhata/utils/pdf_share.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class ZamindarProfileScreen extends StatefulWidget {
  final Zamindar zamindar;
  final VoidCallback? onBack;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final int? initialTabIndex;
  final VoidCallback? onNavigateToSaleWithZamindar;
  final void Function(int kisaanId)? onNavigateToSaleWithKisaan;
  final void Function(String invoiceNumber)? onEditInvoice;

  const ZamindarProfileScreen({
    super.key,
    required this.zamindar,
    this.onBack,
    this.onEdit,
    this.onDelete,
    this.initialTabIndex,
    this.onNavigateToSaleWithZamindar,
    this.onNavigateToSaleWithKisaan,
    this.onEditInvoice,
  });

  @override
  State<ZamindarProfileScreen> createState() => _ZamindarProfileScreenState();
}

class _ZamindarProfileScreenState extends State<ZamindarProfileScreen> {
  int _selectedTab = 0;
  bool _openKisaanDrawerOnLoad = false;
  String _outstandingBalanceDisplay = "Rs. 0";
  int _kisaanCount = 0;
  bool _isLoadingStats = true;

  final List<String> _tabs = ["Overview", "Kisaans", "Ledger"];

  @override
  void initState() {
    super.initState();
    if (widget.initialTabIndex != null) {
      _selectedTab = widget.initialTabIndex!;
    }
    _loadLiveStats();
    // Listen for database changes and auto-refresh
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
  }

  @override
  void dispose() {
    // Remove database listener to prevent memory leaks
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() => _loadLiveStats(showLoading: false);

  Future<void> _loadLiveStats({bool showLoading = true}) async {
    if (widget.zamindar.id == null) {
      if (showLoading) setState(() => _isLoadingStats = false);
      return;
    }

    if (showLoading) setState(() => _isLoadingStats = true);

    try {
      // Use centralized method for outstanding balance
      final outstandingBalance = await DatabaseHelper.instance
          .getOutstandingBalanceString(widget.zamindar.id!);
      final count = await DatabaseHelper.instance.countKisaansForZamindar(
        widget.zamindar.id!,
      );

      if (!mounted) return;
      setState(() {
        _outstandingBalanceDisplay = outstandingBalance;
        _kisaanCount = count;
        _isLoadingStats = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStats = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = widget.zamindar;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AgriHeader(
            breadcrumbs: ["Zamindars", z.name],
            onBreadcrumbTap: (i) {
              if (i == 0) {
                if (widget.onBack != null) {
                  widget.onBack!.call();
                } else {
                  Navigator.of(context).pop();
                }
              }
            },
            actions: [
              OutlinedButton.icon(
                onPressed: () {
                  // If parent provided an edit handler (Shell inline flow), use it.
                  if (widget.onEdit != null) {
                    widget.onEdit!.call();
                    return;
                  }
                  // Otherwise push the AddZamindarScreen route for standalone flow.
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (ctx) => AddZamindarScreen(
                        zamindar: z as Zamindar?,
                        onCancel: () => Navigator.of(ctx).pop(),
                        onSaved: () => Navigator.of(ctx).pop(),
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: const Text("Edit"),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _showExportPdfDialog(z),
                icon: const Icon(Icons.file_download_outlined, size: 15),
                label: const Text("Export PDF"),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _confirmDelete(z),
                icon: const Icon(
                  Icons.delete_outline,
                  size: 15,
                  color: Color(0xFFA32D2D),
                ),
                label: const Text(
                  "Delete",
                  style: TextStyle(color: Color(0xFFA32D2D)),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFF09595)),
                ),
              ),
            ],
          ),
          _buildProfileBanner(z),
          _buildTabBar(),
          Expanded(child: _buildTabContent(z)),
        ],
      ),
    );
  }

  Widget _buildProfileBanner(Zamindar z) {
    final initials = z.name
        .split(' ')
        .where((e) => e.isNotEmpty)
        .map((e) => e[0].toUpperCase())
        .take(2)
        .join();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      color: AppColors.darkGreen,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 720;

          final identitySection = Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: AppColors.sidebarActive,
                child: Text(
                  initials,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      z.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      z.villageDisplay,
                      style: TextStyle(
                        color: AppColors.sidebarText,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (z.isOverLimit && !isNarrow) ...[
                const SizedBox(width: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFCEBEB),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    "Over credit limit",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF791F1F),
                    ),
                  ),
                ),
              ],
            ],
          );

          final statsSection = _isLoadingStats
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFFB7E4C7),
                    ),
                  ),
                )
              : Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  alignment: isNarrow
                      ? WrapAlignment.start
                      : WrapAlignment.end,
                  children: [
                    _bannerStat(
                      _outstandingBalanceDisplay,
                      "Total outstanding balance",
                    ),
                    _bannerStat(
                      "${z.landArea.toStringAsFixed(0)} ${z.landUnit}",
                      "Total land",
                    ),
                    _bannerStat("$_kisaanCount", "Kisaans"),
                  ],
                );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identitySection,
                if (z.isOverLimit) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFCEBEB),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        "Over credit limit",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF791F1F),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                statsSection,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: identitySection),
              statsSection,
            ],
          );
        },
      ),
    );
  }

  Widget _bannerStat(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFFB7E4C7),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: AppColors.sidebarSection, fontSize: 10),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    final tabIcons = [
      Icons.dashboard_outlined,
      Icons.people_outline,
      Icons.receipt_long_outlined,
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(_tabs.length, (i) {
            final isActive = _selectedTab == i;
            return InkWell(
              onTap: () {
                setState(() => _selectedTab = i);
                _loadLiveStats();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                margin: const EdgeInsets.only(right: 32),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isActive ? AppColors.darkGreen : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tabIcons[i],
                      size: 16,
                      color: isActive
                          ? AppColors.darkGreen
                          : AppColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _tabs[i],
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                        color: isActive
                            ? AppColors.darkGreen
                            : AppColors.textMuted,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildTabContent(Zamindar z) {
    if (z.id == null) {
      return const Center(
        child: Text(
          'Invalid Zamindar profile',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      );
    }

    switch (_selectedTab) {
      case 1:
        final shouldOpen = _openKisaanDrawerOnLoad;
        _openKisaanDrawerOnLoad = false;
        return ZamindarKisaansTab(
          zamindarId: z.id!,
          zamindarName: z.name,
          autoOpenAdd: shouldOpen,
          onNavigateToSale: widget.onNavigateToSaleWithKisaan,
        );
      case 2:
        return ZamindarLedgerTab(
          zamindarId: z.id!,
          onEditInvoice: widget.onEditInvoice,
        );
      default:
        return ZamindarOverviewTab(
          zamindar: z,
          onNavigateToAddKisaan: () {
            setState(() {
              _selectedTab = 1;
              _openKisaanDrawerOnLoad = true;
            });
          },
          onNavigateToLedger: () {
            setState(() {
              _selectedTab = 2;
            });
          },
          onRefresh: _loadLiveStats,
          onNavigateToSaleWithZamindar: widget.onNavigateToSaleWithZamindar,
        );
    }
  }

  // ---------- Export PDF dialog ----------
  void _showExportPdfDialog(Zamindar z) {
    if (z.id == null) return;

    showDialog(
      context: context,
      barrierColor: AppColors.darkGreen.withValues(alpha: 0.35),
      builder: (ctx) => _ZamindarExportPdfSheet(
        zamindar: z,
        onSave: (seasons, crops) =>
            _runExportAction(z, seasons, crops, ExportPdfAction.save),
        onWhatsApp: (seasons, crops) =>
            _runExportAction(z, seasons, crops, ExportPdfAction.whatsapp),
        onPrint: (seasons, crops) =>
            _runExportAction(z, seasons, crops, ExportPdfAction.print),
      ),
    );
  }

  Future<void> _runExportAction(
    Zamindar z,
    Set<String> selectedSeasons,
    Set<String> selectedCrops,
    ExportPdfAction action,
  ) async {
    try {
      final allRows = await DatabaseHelper.instance.getZamindarLedgerPdfRows(
        zamindarId: z.id!,
        seasons: selectedSeasons,
      );
      final kisaans = await DatabaseHelper.instance.getKisaansForZamindar(
        z.id!,
      );
      final kisaanCropById = <int, String>{
        for (final k in kisaans)
          if (k.id != null) k.id!: k.currentCrop,
      };

      const knownCrops = {
        'wheat',
        'mustard',
        'potato',
        'onion',
        'chili',
        'rice',
        'cotton',
        'sugarcane',
        'maize',
        'sunflower',
        'tomato',
        'mango',
      };

      bool matchesCrops(Map<String, dynamic> row) {
        if (selectedCrops.isEmpty) return true;

        final kisaanIdRaw = row['kisaan_id'];
        final kisaanId = kisaanIdRaw is int
            ? kisaanIdRaw
            : (kisaanIdRaw is num ? kisaanIdRaw.toInt() : null);
        if (kisaanId == null) return true;

        final cropBlob = (kisaanCropById[kisaanId] ?? '').trim();
        if (cropBlob.isEmpty) return true;

        final kisaanCrops = cropBlob
            .split(',')
            .map((c) => c.trim().toLowerCase())
            .where((c) => c.isNotEmpty)
            .toSet();

        final hasCatalogCrop = kisaanCrops.any(knownCrops.contains);
        if (!hasCatalogCrop) return true;

        final selected = selectedCrops.map((c) => c.toLowerCase()).toSet();
        return kisaanCrops.any(selected.contains);
      }

      var filtered = allRows.where(matchesCrops).toList();
      if (filtered.isEmpty && allRows.isNotEmpty) {
        filtered = List<Map<String, dynamic>>.from(allRows);
      }

      final seasonLabel = selectedSeasons.isEmpty
          ? 'All seasons'
          : selectedSeasons.join(', ');
      final cropNote = selectedCrops.isEmpty
          ? ''
          : ' - Crops: ${selectedCrops.join(', ')}';

      final outstanding = await DatabaseHelper.instance
          .getOutstandingBalanceString(z.id!);
      final cumulativeRemaining = filtered.fold<double>(
        0,
        (sum, row) => sum + ((row['remaining'] as num?)?.toDouble() ?? 0),
      );

      if (action == ExportPdfAction.print) {
        final pdf = await PdfGenerator.generateZamindarLedgerPdf(
          zamindarName: '${z.name}$cropNote',
          seasonLabel: seasonLabel,
          rows: filtered,
          outstandingBalance: outstanding,
          cumulativeRemaining: cumulativeRemaining,
        );
        await PdfGenerator.printDocument(pdf);
        return;
      }

      final file = await PdfGenerator.saveZamindarLedgerToDocuments(
        zamindarName: z.name,
        seasonLabel: seasonLabel,
        rows: filtered,
        outstandingBalance: outstanding,
        cumulativeRemaining: cumulativeRemaining,
      );

      if (action == ExportPdfAction.whatsapp) {
        await PdfShare.sharePdfFile(
          file: file,
          fileName: p.basename(file.path),
          text: 'AgriKhata Ledger - ${z.name} ($seasonLabel$cropNote)',
          subject: 'AgriKhata Zamindar Ledger',
        );
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              filtered.isEmpty
                  ? 'PDF saved (no sales rows found) to ${file.path}'
                  : 'PDF saved (${filtered.length} invoices) to ${file.path}',
            ),
            backgroundColor: AppColors.darkGreen,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ---------- Delete confirmation & stub ----------
  void _confirmDelete(Zamindar z) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${z.name}?'),
        content: Text(
          'Are you sure you want to permanently delete ${z.name}? All linked kisaans, sales, payments, and ledger records will also be removed. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await _deleteZamindarFromDatabase(z.id);
      // After deletion, go back to directory (either via callback or pop)
      if (widget.onBack != null) {
        widget.onBack!.call();
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  // Delete zamindar from local database
  Future<void> _deleteZamindarFromDatabase(int? id) async {
    if (id == null) return;
    try {
      await DatabaseHelper.instance.deleteZamindar(id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting zamindar: $e')));
      }
    }
  }
}

enum ExportPdfAction { save, whatsapp, print }

class _ZamindarExportPdfSheet extends StatefulWidget {
  final Zamindar zamindar;
  final void Function(Set<String> seasons, Set<String> crops) onSave;
  final void Function(Set<String> seasons, Set<String> crops) onWhatsApp;
  final void Function(Set<String> seasons, Set<String> crops) onPrint;

  const _ZamindarExportPdfSheet({
    required this.zamindar,
    required this.onSave,
    required this.onWhatsApp,
    required this.onPrint,
  });

  @override
  State<_ZamindarExportPdfSheet> createState() =>
      _ZamindarExportPdfSheetState();
}

class _ZamindarExportPdfSheetState extends State<_ZamindarExportPdfSheet> {
  static const Map<String, List<String>> _seasonCropMap = {
    'Rabi': ['Wheat', 'Mustard', 'Potato', 'Onion', 'Chili'],
    'Kharif': [
      'Rice',
      'Cotton',
      'Sugarcane',
      'Maize',
      'Sunflower',
      'Tomato',
      'Mango',
    ],
  };

  bool _loading = true;
  String? _error;
  List<String> _availableSeasons = [];
  final Set<String> _selectedSeasons = {};
  final Set<String> _selectedCrops = {};

  @override
  void initState() {
    super.initState();
    _loadFilters();
  }

  String _seasonFamily(String seasonLabel) {
    final lower = seasonLabel.toLowerCase();
    if (lower.contains('rabi')) return 'Rabi';
    if (lower.contains('kharif')) return 'Kharif';
    return seasonLabel;
  }

  List<String> get _visibleCrops {
    if (_selectedSeasons.isEmpty) return const [];
    final allowed = <String>{};
    for (final season in _selectedSeasons) {
      final family = _seasonFamily(season);
      allowed.addAll(_seasonCropMap[family] ?? const []);
    }
    final profileCrops = widget.zamindar.activeCrops;
    if (profileCrops.isEmpty) {
      return allowed.toList()..sort();
    }
    return profileCrops.where(allowed.contains).toList();
  }

  Future<void> _loadFilters() async {
    try {
      final seasons = await DatabaseHelper.instance
          .getDistinctSeasonsForZamindar(widget.zamindar.id!);
      if (!mounted) return;
      setState(() {
        _availableSeasons = seasons;
        _selectedSeasons
          ..clear()
          ..addAll(seasons);
        _selectedCrops
          ..clear()
          ..addAll(_visibleCrops);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load filters: $e';
      });
    }
  }

  void _toggleSeason(String season) {
    setState(() {
      if (_selectedSeasons.contains(season)) {
        _selectedSeasons.remove(season);
      } else {
        _selectedSeasons.add(season);
      }
      final visible = _visibleCrops.toSet();
      _selectedCrops.removeWhere((c) => !visible.contains(c));
      for (final crop in visible) {
        // Newly revealed crops start selected for convenience.
        if (!_selectedCrops.contains(crop) &&
            widget.zamindar.activeCrops.contains(crop)) {
          _selectedCrops.add(crop);
        }
      }
      // If profile has no crops configured, auto-select newly visible ones.
      if (widget.zamindar.activeCrops.isEmpty) {
        _selectedCrops.addAll(visible);
      }
    });
  }

  void _toggleCrop(String crop) {
    setState(() {
      if (_selectedCrops.contains(crop)) {
        _selectedCrops.remove(crop);
      } else {
        _selectedCrops.add(crop);
      }
    });
  }

  Widget _buildPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required Color selectedBg,
    required Color selectedFg,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? selectedBg : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? selectedFg.withValues(alpha: 0.45)
                : AppColors.sidebarBg,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected)
              Icon(Icons.check, size: 14, color: selectedFg),
            if (selected) const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? selectedFg : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleCrops = _visibleCrops;

    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
              decoration: const BoxDecoration(
                color: AppColors.darkGreen,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Export PDF',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Select seasons & crops to include',
                          style: TextStyle(
                            color: Color(0xFFA7C4A0),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _error != null
                    ? Text(
                        _error!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Seasons',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.darkGreen.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Only seasons with ledger activity',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_availableSeasons.isEmpty)
                            const Text(
                              'No season records found for this Zamindar.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _availableSeasons
                                  .map(
                                    (season) => _buildPill(
                                      label: season,
                                      selected: _selectedSeasons.contains(
                                        season,
                                      ),
                                      onTap: () => _toggleSeason(season),
                                      selectedBg: const Color(0xFFFAEEDA),
                                      selectedFg: const Color(0xFF633806),
                                    ),
                                  )
                                  .toList(),
                            ),
                          const SizedBox(height: 20),
                          Text(
                            'Crops',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.darkGreen.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Filtered by selected seasons & profile crops',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_selectedSeasons.isEmpty)
                            const Text(
                              'Select at least one season to see crops.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            )
                          else if (visibleCrops.isEmpty)
                            const Text(
                              'No matching crops for the selected seasons.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: visibleCrops
                                  .map(
                                    (crop) => _buildPill(
                                      label: crop,
                                      selected: _selectedCrops.contains(crop),
                                      onTap: () => _toggleCrop(crop),
                                      selectedBg: const Color(0xFFEAF3DE),
                                      selectedFg: const Color(0xFF27500A),
                                    ),
                                  )
                                  .toList(),
                            ),
                        ],
                      ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: const BoxDecoration(
                color: Color(0xFFF4F7F1),
                border: Border(
                  top: BorderSide(color: AppColors.border, width: 0.5),
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  OutlinedButton(
                    onPressed: _loading || _selectedSeasons.isEmpty
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.onSave(
                              Set<String>.from(_selectedSeasons),
                              Set<String>.from(_selectedCrops),
                            );
                          },
                    child: const Text('Save PDF'),
                  ),
                  OutlinedButton(
                    onPressed: _loading || _selectedSeasons.isEmpty
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.onWhatsApp(
                              Set<String>.from(_selectedSeasons),
                              Set<String>.from(_selectedCrops),
                            );
                          },
                    child: const Text('WhatsApp'),
                  ),
                  ElevatedButton(
                    onPressed: _loading || _selectedSeasons.isEmpty
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.onPrint(
                              Set<String>.from(_selectedSeasons),
                              Set<String>.from(_selectedCrops),
                            );
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.darkGreen,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Print'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
