import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Data/agri_header.dart';
import 'package:agrikhata/Database/database_helper.dart';
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

  final List<String> _balanceFilters = ["All balances", "Over limit", "Clear"];

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
          _selectedVillage == "All villages" || z.villageDisplay == _selectedVillage;

      final matchesBalance =
          _selectedBalanceFilter == "All balances" ||
          (_selectedBalanceFilter == "Over limit" && z.isOverLimit) ||
          (_selectedBalanceFilter == "Clear" && !z.isOverLimit);

      return matchesSearch && matchesVillage && matchesBalance;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadZamindars();
  }

  Future<void> _loadZamindars() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add Zamindar action not available')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredZamindars;
    final overLimitCount = _zamindars.where((z) => z.isOverLimit).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AgriHeader(
          breadcrumbs: const ["Zamindars", "Zamindar Directory"],
          actions: [
            ElevatedButton.icon(
              onPressed: _handleAddZamindar,
              icon: const Icon(Icons.check, size: 16),
              label: const Text("Add Zamindar"),
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
                          "Showing ${filtered.length} of ${_zamindars.length} zamindars  ·  $overLimitCount over credit limit",
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
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.sidebarBg, width: 0.5),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 16, color: AppColors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: "Search by name or village...",
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: AppColors.sidebarText,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        _buildFilterDropdown(_villageOptions, _selectedVillage, (val) {
          setState(() => _selectedVillage = val!);
        }),
        const SizedBox(width: 10),
        _buildFilterDropdown(_balanceFilters, _selectedBalanceFilter, (val) {
          setState(() => _selectedBalanceFilter = val!);
        }),
      ],
    );
  }

  Widget _buildFilterDropdown(
    List<String> options,
    String value,
    ValueChanged<String?> onChanged,
  ) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.sidebarBg, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 16,
            color: AppColors.textMuted,
          ),
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
          items: options
              .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildTable(List<Zamindar> zamindars) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              _buildTableHeaderRow(),
              for (int i = 0; i < zamindars.length; i++)
                _buildTableDataRow(
                  zamindars[i],
                  isLast: i == zamindars.length - 1,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeaderRow() {
    TextStyle style = const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      color: AppColors.textMuted,
      letterSpacing: 0.3,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F9F4),
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(flex: 24, child: Text("NAME", style: style)),
          Expanded(flex: 18, child: Text("VILLAGE", style: style)),
          Expanded(flex: 12, child: Text("TOTAL LAND", style: style)),
          Expanded(flex: 18, child: Text("UDHAAR BALANCE", style: style)),
          Expanded(flex: 14, child: Text("ACTIVE KISAANS", style: style)),
          Expanded(flex: 10, child: Text("STATUS", style: style)),
          const SizedBox(width: 24),
        ],
      ),
    );
  }

  Widget _buildTableDataRow(Zamindar z, {required bool isLast}) {
    return InkWell(
      onTap: () => _handleRowTap(z),
      hoverColor: const Color(0xFFF0F7EB),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : const Border(
                  bottom: BorderSide(color: AppColors.border, width: 0.5),
                ),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 24,
              child: Text(
                z.name,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.darkGreen,
                ),
              ),
            ),
            Expanded(
              flex: 18,
              child: Text(
                z.villageDisplay,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            Expanded(
              flex: 12,
              child: Text(
                "${z.totalLandAcres.toStringAsFixed(0)} ${z.landUnit}",
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Expanded(
              flex: 18,
              child: Text(
                "Rs ${_formatNumber(z.udhaarBalance)}",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: z.isOverLimit
                      ? const Color(0xFFA32D2D)
                      : const Color(0xFF27500A),
                ),
              ),
            ),
            Expanded(flex: 14, child: _buildKisaanBadge(z.activeKisaans)),
            Expanded(flex: 10, child: _buildStatusBadge(z.isOverLimit)),
            const SizedBox(
              width: 24,
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: AppColors.sidebarBg,
              ),
            ),
          ],
        ),
      ),
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(bool isOverLimit) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isOverLimit
              ? const Color(0xFFFCEBEB)
              : const Color(0xFFEAF3DE),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          isOverLimit ? "Over limit" : "Clear",
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: isOverLimit
                ? const Color(0xFF791F1F)
                : const Color(0xFF27500A),
          ),
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
