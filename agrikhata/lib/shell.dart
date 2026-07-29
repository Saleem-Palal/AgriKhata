import 'package:agrikhata/Core/Themes/app_colors.dart';
import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/screens/add_zamindar_screen.dart';
import 'package:agrikhata/screens/dashboard_screen.dart';
import 'package:agrikhata/screens/expense_screen.dart';
import 'package:agrikhata/screens/main_ledger_screen.dart';
import 'package:agrikhata/screens/new_sale_screen.dart';
import 'package:agrikhata/screens/products_screen.dart';
import 'package:agrikhata/screens/purchase_screen.dart';
import 'package:agrikhata/screens/reports_screen.dart';
import 'package:agrikhata/screens/settings_screen.dart';
import 'package:agrikhata/screens/partners/partner_management_screen.dart';
import 'package:agrikhata/screens/partners/partners_screen.dart';
import 'package:agrikhata/screens/users/users_screen.dart';
import 'package:agrikhata/screens/wholesalers_screen.dart';
import 'package:agrikhata/screens/zamindar_directory.dart';
import 'package:agrikhata/screens/zamindar_profile_screen.dart';
import 'package:agrikhata/services/auth_service.dart';
import 'package:agrikhata/services/update_service.dart';
import 'package:agrikhata/services/user_account_store.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:agrikhata/utils/role_permissions.dart';
import 'package:agrikhata/utils/shop_settings.dart';
import 'package:flutter/material.dart';

enum ZamindarView { directory, add, profile }

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  /// Landing route: Dashboard (index 0) instead of New Sale.
  int _selectedIndex = 0;
  ZamindarView _zamindarView = ZamindarView.directory;
  Zamindar? _selectedZamindar;
  int? _profileInitialTabIndex;
  int _directoryRefreshToken = 0;
  int? _preSelectedZamindarIdForSale;
  int? _preSelectedKisaanIdForSale;
  String? _editInvoiceNumber; // For edit mode
  /// Sidebar index to restore after edit save/cancel (e.g. Zamindar Ledger / Main Ledger).
  int? _editReturnIndex;
  int _ledgerRefreshToken = 0; // For forcing ledger refresh
  String _appVersion = '';
  String _shopName = ShopSettings.defaultShopName;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _loadShopName();
    _guardSelectedIndex();
    AuthService.instance.addListener(_onAuthChanged);
    UserAccountStore.instance.refresh();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      UpdateService().checkForUpdates(context);
    });
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    _guardSelectedIndex();
    setState(() {});
  }

  String? get _role => AuthService.instance.role;

  void _guardSelectedIndex() {
    if (!RolePermissions.canAccessIndex(_role, _selectedIndex)) {
      _selectedIndex = RolePermissions.fallbackIndex(_role);
    }
  }

  void _selectNavIndex(int index) {
    if (!RolePermissions.canAccessIndex(_role, index)) {
      setState(() {
        _selectedIndex = RolePermissions.fallbackIndex(_role);
      });
      return;
    }
    setState(() {
      _selectedIndex = index;
      if (index == 1) {
        _zamindarView = ZamindarView.directory;
        _profileInitialTabIndex = null;
      }
      // Clear edit mode when manually navigating away from an edit session
      if (index == 2 || _editInvoiceNumber != null) {
        _editInvoiceNumber = null;
        _editReturnIndex = null;
        _preSelectedZamindarIdForSale = null;
        _preSelectedKisaanIdForSale = null;
      }
    });
  }

  Future<void> _loadAppVersion() async {
    final label = await AppVersion.displayLabel();
    if (!mounted) return;
    setState(() => _appVersion = label);
  }

  Future<void> _loadShopName() async {
    final name = await ShopSettings.getShopName();
    if (!mounted) return;
    setState(() => _shopName = name);
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
      _editReturnIndex = null;
      _selectedIndex = 2; // Navigate to New Sale screen
    });
  }

  void _navigateToEditInvoice(String invoiceNumber) {
    setState(() {
      _editReturnIndex = _selectedIndex;
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
      final returnIndex = _editReturnIndex;
      _editInvoiceNumber = null;
      _preSelectedZamindarIdForSale = null;
      _preSelectedKisaanIdForSale = null;
      _editReturnIndex = null;
      // Return to the screen where Edit was clicked (after save or discard).
      if (returnIndex != null) {
        _selectedIndex = returnIndex;
        // Avoid resetting Zamindar profile → directory when returning to Zamindars.
        if (returnIndex == 1) {
          _ledgerRefreshToken++;
        }
      }
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
          key: ValueKey(
            'profile-${selected.id}-tab-${_profileInitialTabIndex ?? 0}',
          ),
          zamindar: selected,
          initialTabIndex: _profileInitialTabIndex,
          onBack: () => setState(() {
            _zamindarView = ZamindarView.directory;
            _profileInitialTabIndex = null;
            _refreshDirectory();
          }),
          onEdit: () => setState(() => _zamindarView = ZamindarView.add),
          onDelete: () => setState(() {
            _selectedZamindar = null;
            _profileInitialTabIndex = null;
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
          onEditInvoice: _navigateToEditInvoice,
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
      _editReturnIndex = null;
      _preSelectedZamindarIdForSale = null;
      _preSelectedKisaanIdForSale = null;
      _directoryRefreshToken++;
      _ledgerRefreshToken++;
    });
  }

  void _navigateToNewSaleFromDashboard() {
    _selectNavIndex(2);
    if (_selectedIndex == 2) {
      setState(() {
        _editInvoiceNumber = null;
        _editReturnIndex = null;
        _preSelectedZamindarIdForSale = null;
        _preSelectedKisaanIdForSale = null;
      });
    }
  }

  void _navigateToAddZamindarFromDashboard() {
    _selectNavIndex(1);
    if (_selectedIndex == 1) {
      setState(() {
        _selectedZamindar = null;
        _zamindarView = ZamindarView.add;
      });
    }
  }

  void _navigateToWholesalersFromDashboard() {
    _selectNavIndex(5);
  }

  Future<void> _navigateToZamindarLedgerFromDashboard(int zamindarId) async {
    try {
      final zamindar = await DatabaseHelper.instance.getZamindar(zamindarId);
      if (!mounted) return;
      if (zamindar == null ||
          !RolePermissions.canAccessIndex(_role, 1)) {
        _selectNavIndex(1);
        return;
      }
      setState(() {
        _selectedIndex = 1;
        _selectedZamindar = zamindar;
        _profileInitialTabIndex = 2; // Ledger tab
        _zamindarView = ZamindarView.profile;
      });
    } catch (_) {
      if (!mounted) return;
      _selectNavIndex(1);
    }
  }

  List<Widget> get _screens => [
    DashboardScreen(
      onNavigateToNewSale: _navigateToNewSaleFromDashboard,
      onNavigateToAddZamindar: _navigateToAddZamindarFromDashboard,
      onNavigateToWholesalers: _navigateToWholesalersFromDashboard,
      onNavigateToZamindarLedger: _navigateToZamindarLedgerFromDashboard,
    ),
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
    const PurchaseScreen(),
    const WholesalersScreen(),
    MainLedgerScreen(
      key: ValueKey(
        'ledger-$_ledgerRefreshToken',
      ), // Refresh when token changes
      onEditInvoice: _navigateToEditInvoice,
    ),
    const ExpenseScreen(),
    const ReportsScreen(),
    const UsersScreen(),
    const PartnerManagementScreen(),
    SettingsScreen(
      onDataReset: _handleApplicationDataReset,
      onShopNameChanged: (name) => setState(() => _shopName = name),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 220,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.sidebarBg, AppColors.sidebarBgEnd],
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0x14000000),
                  offset: Offset(2, 0),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Stack(
              children: [
                // Soft ambient radial glow (top-left), matching HTML ::before
                Positioned(
                  top: -60,
                  left: -60,
                  child: IgnorePointer(
                    child: Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            AppColors.sidebarGlow.withValues(alpha: 0.25),
                            AppColors.sidebarGlow.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // App logo pinned at top
                    _buildHeader(),
                    // Middle nav scrolls when window height shrinks
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ..._buildNavSections(),
                          ],
                        ),
                      ),
                    ),
                    // User profile pinned at bottom
                    _buildFooter(),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: RolePermissions.canAccessIndex(_role, _selectedIndex)
                  ? _selectedIndex
                  : RolePermissions.fallbackIndex(_role),
              children: _screens,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildNavSections() {
    final items = <Widget>[];

    void addSection(String title, List<(int, IconData, String)> entries) {
      final visible = entries
          .where((e) => RolePermissions.canAccessIndex(_role, e.$1))
          .toList();
      if (visible.isEmpty) return;
      if (items.isNotEmpty) items.add(const SizedBox(height: 6));
      items.add(_sectionTitle(title));
      for (final e in visible) {
        items.add(_navItem(e.$1, e.$2, e.$3));
      }
    }

    addSection('MAIN', [
      (0, Icons.grid_view_rounded, 'Dashboard'),
      (1, Icons.person_outline_rounded, 'Zamindars'),
      (2, Icons.add_shopping_cart_rounded, 'New Sale'),
    ]);
    addSection('INVENTORY', [
      (3, Icons.inventory_2_outlined, 'Products'),
      (4, Icons.shopping_bag_outlined, 'Purchase'),
      (5, Icons.handshake_outlined, 'Wholesalers'),
    ]);
    addSection('FINANCE', [
      (6, Icons.menu_book_outlined, 'Ledger'),
      (7, Icons.payments_outlined, 'Expenses'),
      (8, Icons.analytics_outlined, 'Reports'),
    ]);
    addSection('SYSTEM', [
      (9, Icons.manage_accounts_outlined, 'User Accounts'),
      (10, Icons.groups_outlined, 'Partner Management'),
      (11, Icons.settings_outlined, 'Settings'),
    ]);
    return items;
  }

  Widget _buildHeader() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.eco_rounded,
                size: 16,
                color: AppColors.sidebarAccentBar,
              ),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'AgriKhata',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            _shopName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.sidebarText,
              fontSize: 15,
              height: 1.8,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 4, top: 2),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.sidebarSection,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.3,
        ),
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final isSelected = _selectedIndex == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: _SidebarNavItem(
        icon: icon,
        label: label,
        isSelected: isSelected,
        onTap: () => _selectNavIndex(index),
      ),
    );
  }

  Widget _buildFooter() {
    final user = AuthService.instance.currentUser;
    final displayName = user?.name ?? 'Staff';
    final roleLabel = user?.roleLabel ?? 'User';
    final initials = user?.initials ?? '?';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.sidebarActive,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.accentGreen,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: Color(0xFFD8F3DC),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: const Color(0xFF52D68C),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.sidebarBgEnd,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      roleLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8FBA9A),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Switch user / Logout',
                onPressed: () async {
                  await AuthService.instance.logout();
                },
                icon: const Icon(
                  Icons.logout_rounded,
                  size: 16,
                  color: Color(0xFF8FBA9A),
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
          if (_appVersion.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _appVersion,
              style: const TextStyle(
                color: AppColors.sidebarVersion,
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Desktop nav row with hover translate + icon scale matching the HTML mock.
class _SidebarNavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarNavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final showHover = _hovered && !isSelected;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(showHover ? 3.0 : 0.0, 0, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.sidebarActive
                : showHover
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: AppColors.sidebarActive.withValues(alpha: 0.45),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (isSelected)
                Positioned(
                  left: -12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.sidebarAccentBar,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(3),
                          bottomRight: Radius.circular(3),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.sidebarAccentBar.withValues(
                              alpha: 0.8,
                            ),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  AnimatedScale(
                    scale: showHover ? 1.15 : 1.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutBack,
                    child: Icon(
                      widget.icon,
                      size: 16,
                      color: isSelected || showHover
                          ? (showHover && !isSelected
                                ? AppColors.sidebarAccentBar
                                : Colors.white)
                          : AppColors.sidebarNavIdle,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected || showHover
                            ? Colors.white
                            : AppColors.sidebarNavIdle,
                        fontSize: 13,
                        fontWeight: isSelected
                            ? FontWeight.w500
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
