import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Data/zamindar_kisaans_tab.dart';
import 'package:agrikhata/Data/zamindar_ledger_tab.dart';
import 'package:agrikhata/Data/zamindar_overview_tab.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/screens/add_zamindar_screen.dart';
import 'package:flutter/material.dart';

class ZamindarProfileScreen extends StatefulWidget {
  final Zamindar zamindar;
  final VoidCallback? onBack;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final int? initialTabIndex;

  const ZamindarProfileScreen({
    super.key,
    required this.zamindar,
    this.onBack,
    this.onEdit,
    this.onDelete,
    this.initialTabIndex,
  });

  @override
  State<ZamindarProfileScreen> createState() => _ZamindarProfileScreenState();
}

class _ZamindarProfileScreenState extends State<ZamindarProfileScreen> {
  int _selectedTab = 0;
  bool _openKisaanDrawerOnLoad = false;
  Map<String, Object>? _balanceData;
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
  }

  Future<void> _loadLiveStats() async {
    if (widget.zamindar.id == null) {
      setState(() => _isLoadingStats = false);
      return;
    }

    try {
      final balances = await DatabaseHelper.instance.getZamindarBalancesSafe(
        widget.zamindar.id!,
      );
      final count = await DatabaseHelper.instance.countKisaansForZamindar(
        widget.zamindar.id!,
      );

      if (!mounted) return;
      setState(() {
        _balanceData = balances;
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
      child: Row(
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                z.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                z.villageDisplay,
                style: TextStyle(color: AppColors.sidebarText, fontSize: 12),
              ),
            ],
          ),
          if (z.isOverLimit) ...[
            const SizedBox(width: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          const Spacer(),
          if (_isLoadingStats)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFB7E4C7)),
              ),
            )
          else ...[
            _bannerStat(
              "Rs ${_formatNumber((_balanceData?['outstandingBalance'] as int? ?? 0).toDouble())}",
              "Total outstanding",
            ),
            const SizedBox(width: 24),
            _bannerStat(
              "${z.landArea.toStringAsFixed(0)} ${z.landUnit}",
              "Total land",
            ),
            const SizedBox(width: 24),
            _bannerStat("$_kisaanCount", "Kisaans"),
          ],
        ],
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
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(color: AppColors.sidebarSection, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: List.generate(_tabs.length, (i) {
          final isActive = _selectedTab == i;
          return InkWell(
            onTap: () => setState(() => _selectedTab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              margin: const EdgeInsets.only(right: 24),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isActive ? AppColors.darkGreen : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                _tabs[i],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isActive ? AppColors.darkGreen : AppColors.textMuted,
                ),
              ),
            ),
          );
        }),
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
        );
      case 2:
        return ZamindarLedgerTab(zamindarId: z.id!);
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
        );
    }
  }

  // ---------- Export PDF dialog & action stubs ----------
  void _showExportPdfDialog(Zamindar z) {
    showDialog(
      context: context,
      builder: (ctx) {
        // temporary local selection state inside dialog
        final Map<String, bool> seasonSelection = {
          'Rabi': true,
          'Kharif': true,
        };
        final Map<String, bool> cropSelection = {
          'Rice': true,
          'Wheat': true,
          'Cotton': true,
        };

        return StatefulBuilder(
          builder: (c, setState) {
            return AlertDialog(
              title: const Text('Export PDF — Select data to include'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Seasons'),
                    ...seasonSelection.keys.map((s) {
                      return CheckboxListTile(
                        value: seasonSelection[s],
                        title: Text(s),
                        onChanged: (v) =>
                            setState(() => seasonSelection[s] = v!),
                      );
                    }).toList(),
                    const SizedBox(height: 8),
                    const Text('Crops'),
                    ...cropSelection.keys.map((cname) {
                      return CheckboxListTile(
                        value: cropSelection[cname],
                        title: Text(cname),
                        onChanged: (v) =>
                            setState(() => cropSelection[cname] = v!),
                      );
                    }).toList(),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _generateAndSavePdf(z, seasonSelection, cropSelection);
                  },
                  child: const Text('Save PDF'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _sharePdfViaWhatsApp(z, seasonSelection, cropSelection);
                  },
                  child: const Text('WhatsApp'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _printPdf(z, seasonSelection, cropSelection);
                  },
                  child: const Text('Print'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _generateAndSavePdf(
    Zamindar z,
    Map<String, bool> seasons,
    Map<String, bool> crops,
  ) {
    // TODO: Implement PDF generation using selected seasons/crops.
    // For now, show a SnackBar as a placeholder.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generating PDF (placeholder)')),
    );
  }

  void _sharePdfViaWhatsApp(
    Zamindar z,
    Map<String, bool> seasons,
    Map<String, bool> crops,
  ) {
    // TODO: Implement sharing via WhatsApp intent.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sharing via WhatsApp (placeholder)')),
    );
  }

  void _printPdf(
    Zamindar z,
    Map<String, bool> seasons,
    Map<String, bool> crops,
  ) {
    // TODO: Implement printing via platform channels or printing package.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Printing (placeholder)')));
  }

  // ---------- Delete confirmation & stub ----------
  void _confirmDelete(Zamindar z) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${z.name}?'),
        content: Text(
          'Are you sure you want to permanently delete ${z.name}? This action cannot be undone.',
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting zamindar: $e')),
        );
      }
    }
  }

  String _formatNumber(double value) {
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
