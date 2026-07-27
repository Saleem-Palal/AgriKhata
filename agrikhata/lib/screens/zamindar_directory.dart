import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:agrikhata/screens/zamindar_profile_screen.dart';

class ZamindarDirectoryScreen extends StatefulWidget {
  final void Function(Zamindar zamindar)? onZamindarTap;
  final VoidCallback? onAddZamindar;

  const ZamindarDirectoryScreen({
    super.key,
    this.onZamindarTap,
    this.onAddZamindar,
  });

  @override
  State<ZamindarDirectoryScreen> createState() =>
      _ZamindarDirectoryScreenState();
}

class _ZamindarDirectoryScreenState extends State<ZamindarDirectoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedVillage = "All villages";
  String _selectedBalanceFilter = "All balances";

  final List<String> _balanceFilters = [
    "All balances",
    "Outstanding",
    "Clear",
  ];

  List<Zamindar> _zamindars = [];
  bool _isLoading = true;
  String? _loadError;

  List<String> get _villageOptions {
    final villages = _zamindars
        .map((z) => z.villageDisplay)
        .where((v) => v != 'Unknown location')
        .toSet()
        .toList()
      ..sort();
    return ["All villages", ...villages];
  }

  List<Zamindar> get _filteredZamindars {
    return _zamindars.where((z) {
      final query = _searchController.text.toLowerCase();
      final matchesSearch =
          query.isEmpty ||
          z.name.toLowerCase().contains(query) ||
          (z.village?.toLowerCase().contains(query) ?? false);

      final matchesVillage =
          _selectedVillage == "All villages" ||
          z.villageDisplay == _selectedVillage;

      final matchesBalance =
          _selectedBalanceFilter == "All balances" ||
          (_selectedBalanceFilter == "Outstanding" && z.udhaarBalance > 0) ||
          (_selectedBalanceFilter == "Clear" && z.udhaarBalance == 0);

      return matchesSearch && matchesVillage && matchesBalance;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    DatabaseHelper.instance.addListener(_onDatabaseChanged);
    _loadZamindars();
  }

  void _onDatabaseChanged() => _loadZamindars(showLoading: false);

  Future<void> _loadZamindars({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final rows = await DatabaseHelper.instance.getAllZamindarsEnriched();
      if (!mounted) return;
      setState(() {
        _zamindars = rows;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Failed to load zamindars: $e';
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    DatabaseHelper.instance.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _handleRowTap(Zamindar z) async {
    if (widget.onZamindarTap != null) {
      widget.onZamindarTap!.call(z);
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ZamindarProfileScreen(zamindar: z),
        ),
      );
      _loadZamindars();
    }
  }

  void _handleAddZamindar() async {
    if (widget.onAddZamindar != null) {
      widget.onAddZamindar!.call();
    } else {
      AppToast.showError(context, 'Add Zamindar action not available');
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredZamindars;
    final outstandingCount =
        _zamindars.where((z) => z.udhaarBalance > 0).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AgriHeader(
          breadcrumbs: const ["Zamindars", "Zamindar Directory"],
          actions: [
            AppButton.primary(
              label: 'Add Zamindar',
              icon: Icons.add,
              onPressed: _handleAddZamindar,
            ),
          ],
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
              ? Center(
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
                        onPressed: _loadZamindars,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSearchRow(),
                      const SizedBox(height: 14),
                      _buildTable(filtered),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          "Showing ${filtered.length} of ${_zamindars.length} zamindars  ·  $outstandingCount with outstanding udhaar",
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSearchRow() {
    return AppSearchBar(
      controller: _searchController,
      hintText: 'Search by name or village...',
      filters: [
        AppFilterDropdown(
          options: _villageOptions,
          value: _selectedVillage,
          onChanged: (val) {
            if (val != null) setState(() => _selectedVillage = val);
          },
        ),
        AppFilterDropdown(
          options: _balanceFilters,
          value: _selectedBalanceFilter,
          onChanged: (val) {
            if (val != null) setState(() => _selectedBalanceFilter = val);
          },
        ),
      ],
    );
  }

  Widget _buildTable(List<Zamindar> zamindars) {
    return AppDataTable(
      minWidth: 900,
      trailingWidth: 24,
      columns: const [
        AppDataColumn(title: 'Name', flex: 20),
        AppDataColumn(title: 'Village', flex: 14),
        AppDataColumn(title: 'Total Land', flex: 10),
        AppDataColumn(title: 'Udhaar Balance', flex: 14),
        AppDataColumn(title: 'Wallet', flex: 12),
        AppDataColumn(title: 'Active Kisaans', flex: 12),
        AppDataColumn(title: 'Status', flex: 10),
      ],
      rows: [
        for (int i = 0; i < zamindars.length; i++)
          AppDataRow(
            onTap: () => _handleRowTap(zamindars[i]),
            trailing: const SizedBox(
              width: 24,
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: AppColors.sidebarBg,
              ),
            ),
            cells: [
              AppTableCellText(
                zamindars[i].name,
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w500,
                  color: AppColors.darkGreen,
                ),
              ),
              AppTableCellText(
                zamindars[i].villageDisplay,
                style: AppTextStyles.bodySmall.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              '${zamindars[i].totalLandAcres.toStringAsFixed(0)} ${zamindars[i].landUnit}',
              AppTableCellText(
                'Rs ${_formatNumber(zamindars[i].udhaarBalance)}',
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w500,
                  color: zamindars[i].isOverLimit
                      ? const Color(0xFFA32D2D)
                      : const Color(0xFF27500A),
                ),
              ),
              AppTableCellText(
                'Rs ${_formatNumber(zamindars[i].advanceBalance.toDouble())}',
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: FontWeight.w500,
                  color: AppColors.tagBlueText,
                ),
              ),
              _buildKisaanBadge(zamindars[i].activeKisaans),
              _buildStatusBadge(zamindars[i].udhaarBalance),
            ],
          ),
      ],
    );
  }

  Widget _buildKisaanBadge(int count) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF3DE),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person, size: 10, color: Color(0xFF27500A)),
            const SizedBox(width: 4),
            Text(
              "$count Kisaans",
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: Color(0xFF27500A),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(double outstandingBalance) {
    final isClear = outstandingBalance <= 0;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isClear
              ? const Color(0xFFEAF3DE)
              : const Color(0xFFFAEEDA),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          isClear ? "Clear" : "Outstanding",
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: isClear
                ? const Color(0xFF27500A)
                : const Color(0xFF633806),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
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

// class _DummyZamindarProfileScreen extends StatelessWidget {
//   final Zamindar zamindar;

//   const _DummyZamindarProfileScreen({required this.zamindar});

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       backgroundColor: const Color(0xFFF7F9F4),
//       appBar: AppBar(
//         backgroundColor: AppColors.cardSurface,
//         elevation: 0,
//         foregroundColor: AppColors.darkGreen,
//         title: Text(zamindar.name),
//       ),
//       body: Center(
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           children: [
//             CircleAvatar(
//               radius: 32,
//               backgroundColor: AppColors.sidebarActive,
//               child: Text(
//                 zamindar.name
//                     .split(' ')
//                     .where((e) => e.isNotEmpty)
//                     .map((e) => e[0].toUpperCase())
//                     .take(2)
//                     .join(),
//                 style: const TextStyle(color: Colors.white, fontSize: 22),
//               ),
//             ),
//             const SizedBox(height: 16),
//             Text(
//               zamindar.name,
//               style: const TextStyle(
//                 fontSize: 20,
//                 fontWeight: FontWeight.w600,
//                 color: AppColors.darkGreen,
//               ),
//             ),
//             const SizedBox(height: 4),
//             Text(
//               "${zamindar.village} · ${zamindar.totalLandAcres.toStringAsFixed(0)} Acres",
//               style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
//             ),
//             const SizedBox(height: 24),
//             const Text(
//               "Zamindar Profile Hub — coming soon",
//               style: TextStyle(fontSize: 13, color: AppColors.textMuted),
//             ),
//             const SizedBox(height: 20),
//             OutlinedButton(
//               onPressed: () => Navigator.pop(context),
//               child: const Text("Back to Directory"),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
