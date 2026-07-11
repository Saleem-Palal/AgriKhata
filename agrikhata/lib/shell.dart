import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/screens/add_zamindar_screen.dart';
import 'package:agrikhata/screens/main_ledger_screen.dart';
import 'package:agrikhata/screens/new_sale_screen.dart';
import 'package:agrikhata/screens/products_screen.dart';
import 'package:agrikhata/screens/settings_screen.dart';
import 'package:agrikhata/screens/zamindar_directory.dart';
import 'package:agrikhata/screens/zamindar_profile_screen.dart';
import 'package:agrikhata/services/update_service.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:flutter/material.dart';

enum ZamindarView { directory, add, profile }

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _selectedIndex = 2;
  ZamindarView _zamindarView = ZamindarView.directory;
  Zamindar? _selectedZamindar;
  int _directoryRefreshToken = 0;
  int? _preSelectedZamindarIdForSale;
  int? _preSelectedKisaanIdForSale;
  String? _editInvoiceNumber; // For edit mode
  int _ledgerRefreshToken = 0; // For forcing ledger refresh
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      UpdateService().checkForUpdates(context);
    });
  }

  Future<void> _loadAppVersion() async {
    final label = await AppVersion.displayLabel();
    if (!mounted) return;
    setState(() => _appVersion = label);
  }

  void _refreshDirectory() {
    setState(() => _directoryRefreshToken++);
  }

  void _navigateToSaleWithZamindar(int zamindarId, {int? kisaanId}) {
    setState(() {
      _preSelectedZamindarIdForSale = zamindarId;
      _preSelectedKisaanIdForSale = kisaanId;
      _editInvoiceNumber =
          null; // Clear edit mode when navigating from zamindar
      _selectedIndex = 2; // Navigate to New Sale screen
    });
  }

  void _navigateToEditInvoice(String invoiceNumber) {
    setState(() {
      _editInvoiceNumber = invoiceNumber;
      _preSelectedZamindarIdForSale = null; // Clear pre-selection
      _preSelectedKisaanIdForSale = null;
      _selectedIndex = 2; // Navigate to New Sale screen in edit mode
      _ledgerRefreshToken++; // Increment to trigger refresh when coming back
    });
  }

  void _clearEditState() {
    print('🧹 Shell: Clearing edit state (was: $_editInvoiceNumber)');
    setState(() {
      _editInvoiceNumber = null;
      _preSelectedZamindarIdForSale = null;
      _preSelectedKisaanIdForSale = null;
    });
    print('🧹 Shell: Edit state cleared (now: $_editInvoiceNumber)');
  }

  Widget _buildZamindarsScreen() {
    switch (_zamindarView) {
      case ZamindarView.add:
        return AddZamindarScreen(
          zamindar: _selectedZamindar,
          onCancel: () => setState(() {
            _zamindarView = _selectedZamindar == null
                ? ZamindarView.directory
                : ZamindarView.profile;
          }),
          onSaved: () => setState(() {
            _zamindarView = ZamindarView.directory;
            _refreshDirectory();
          }),
          onSaveZamindar: (updated) => setState(() {
            _selectedZamindar = updated;
            _zamindarView = ZamindarView.profile;
            _refreshDirectory();
          }),
        );
      case ZamindarView.profile:
        final selected = _selectedZamindar;
        if (selected == null) {
          return ZamindarDirectoryScreen(
            key: ValueKey(_directoryRefreshToken),
            onAddZamindar: () =>
                setState(() => _zamindarView = ZamindarView.add),
            onZamindarTap: (zamindar) => setState(() {
              _selectedZamindar = zamindar;
              _zamindarView = ZamindarView.profile;
            }),
          );
        }
        return ZamindarProfileScreen(
          zamindar: selected,
          onBack: () => setState(() {
            _zamindarView = ZamindarView.directory;
            _refreshDirectory();
          }),
          onEdit: () => setState(() => _zamindarView = ZamindarView.add),
          onDelete: () => setState(() {
            _selectedZamindar = null;
            _zamindarView = ZamindarView.directory;
            _refreshDirectory();
          }),
          onNavigateToSaleWithZamindar: selected.id != null
              ? () => _navigateToSaleWithZamindar(selected.id!)
              : null,
          onNavigateToSaleWithKisaan: selected.id != null
              ? (kisaanId) => _navigateToSaleWithZamindar(
                  selected.id!,
                  kisaanId: kisaanId,
                )
              : null,
        );
      case ZamindarView.directory:
        return ZamindarDirectoryScreen(
          key: ValueKey(_directoryRefreshToken),
          onAddZamindar: () => setState(() {
            _selectedZamindar = null;
            _zamindarView = ZamindarView.add;
          }),
          onZamindarTap: (zamindar) => setState(() {
            _selectedZamindar = zamindar;
            _zamindarView = ZamindarView.profile;
          }),
        );
    }
  }

  void _handleApplicationDataReset() {
    setState(() {
      _selectedZamindar = null;
      _zamindarView = ZamindarView.directory;
      _editInvoiceNumber = null;
      _preSelectedZamindarIdForSale = null;
      _preSelectedKisaanIdForSale = null;
      _directoryRefreshToken++;
      _ledgerRefreshToken++;
    });
  }

  List<Widget> get _screens => [
    const Center(child: Text("Dashboard")),
    _buildZamindarsScreen(),
    NewSaleScreen(
      key: ValueKey(
        '$_preSelectedZamindarIdForSale-$_preSelectedKisaanIdForSale-$_editInvoiceNumber',
      ),
      preSelectedZamindarId: _preSelectedZamindarIdForSale,
      preSelectedKisaanId: _preSelectedKisaanIdForSale,
      editInvoiceNumber: _editInvoiceNumber,
      onCancelEdit: _clearEditState,
    ),
    const ProductsScreen(),
    const Center(child: Text("Purchase")),
    MainLedgerScreen(
      key: ValueKey(
        'ledger-$_ledgerRefreshToken',
      ), // Refresh when token changes
      onEditInvoice: _navigateToEditInvoice,
    ),
    const Center(child: Text("Reports")),
    SettingsScreen(onDataReset: _handleApplicationDataReset),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 220,
            color: AppColors.sidebarBg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      _sectionTitle("MAIN"),
                      _navItem(0, Icons.grid_view_rounded, "Dashboard"),
                      _navItem(1, Icons.person_outline_rounded, "Zamindars"),
                      _navItem(2, Icons.add_shopping_cart_rounded, "New Sale"),
                      const SizedBox(height: 20),
                      _sectionTitle("INVENTORY"),
                      _navItem(3, Icons.inventory_2_outlined, "Products"),
                      _navItem(4, Icons.shopping_bag_outlined, "Purchase"),
                      const SizedBox(height: 20),
                      _sectionTitle("FINANCE"),
                      _navItem(
                        5,
                        Icons.account_balance_wallet_outlined,
                        "Ledger",
                      ),
                      _navItem(6, Icons.analytics_outlined, "Reports"),
                      const SizedBox(height: 20),
                      _sectionTitle("SYSTEM"),
                      _navItem(7, Icons.settings_outlined, "Settings"),
                    ],
                  ),
                ),
                _buildFooter(),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(index: _selectedIndex, children: _screens),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Text(
            "AgriKhata",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          Text(
            "Atta Muhammad & Sons",
            style: TextStyle(color: AppColors.sidebarText, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 8, top: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.sidebarSection,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => setState(() {
          _selectedIndex = index;
          if (index == 1) _zamindarView = ZamindarView.directory;
          // Clear edit mode when manually navigating to New Sale screen
          if (index == 2) {
            _editInvoiceNumber = null;
            _preSelectedZamindarIdForSale = null;
            _preSelectedKisaanIdForSale = null;
          }
        }),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.sidebarActive : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? Colors.white : AppColors.sidebarText,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : AppColors.sidebarText,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.sidebarActive,
                radius: 16,
                child: const Text(
                  "AM",
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Atta Muhammad",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    "Owner",
                    style: TextStyle(
                      color: AppColors.sidebarText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (_appVersion.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              _appVersion,
              style: TextStyle(
                color: AppColors.sidebarText.withValues(alpha: 0.75),
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
