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
import 'package:agrikhata/screens/users/users_screen.dart';
import 'package:agrikhata/Widgets/sales/pos_confirm_dialog.dart';
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
  int _ledgerRefreshToken = 0; // For forcing main ledger refresh
  int? _ledgerInitialTabIndex;
  int _wholesalerNavToken = 0;
  int? _pendingWholesalerId;
  int _zamindarLedgerRefreshToken =
      0; // For forcing zamindar profile ledger refresh
  int _pendingZamindarLedgerNav =
      0; // Invalidates stale async dashboard navigations
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

  void _onShopNameChanged(String name) => setState(() => _shopName = name);

  void _invalidatePendingZamindarLedgerNav() => _pendingZamindarLedgerNav++;

  void _repairZamindarState() {
    if (_zamindarView == ZamindarView.profile && _selectedZamindar == null) {
      _zamindarView = ZamindarView.directory;
      _profileInitialTabIndex = null;
    }
  }

  ZamindarView get _effectiveZamindarView {
    if (_zamindarView == ZamindarView.profile && _selectedZamindar == null) {
      return ZamindarView.directory;
    }
    return _zamindarView;
  }

  void _clearSaleNavState() {
    _editInvoiceNumber = null;
    _editReturnIndex = null;
    _preSelectedZamindarIdForSale = null;
    _preSelectedKisaanIdForSale = null;
  }

  Future<bool> _confirmAbandonEdit() {
    return PosConfirmDialog.ask(
      context: context,
      title: 'Discard invoice edit?',
      message:
          'Leave edit mode and lose unsaved changes to this invoice?\n\n'
          'Press Enter for Yes, Esc for No.',
      yesLabel: 'Yes — Discard (Enter)',
      noLabel: 'No — Keep Editing (Esc)',
      danger: true,
    );
  }

  Future<void> _selectNavIndex(int index) async {
    if (!RolePermissions.canAccessIndex(_role, index)) {
      _invalidatePendingZamindarLedgerNav();
      setState(() {
        _selectedIndex = RolePermissions.fallbackIndex(_role);
      });
      return;
    }

    final reTappingNewSaleWhileEditing =
        _editInvoiceNumber != null && index == 2 && _selectedIndex == 2;
    final leavingEditSession =
        _editInvoiceNumber != null && index != _selectedIndex;

    if (reTappingNewSaleWhileEditing || leavingEditSession) {
      final confirmed = await _confirmAbandonEdit();
      if (!confirmed || !mounted) return;
    }

    _invalidatePendingZamindarLedgerNav();
    final previousIndex = _selectedIndex;
    setState(() {
      if (reTappingNewSaleWhileEditing || leavingEditSession) {
        _clearSaleNavState();
      } else {
        if (previousIndex == 2 && index != 2) {
          _preSelectedZamindarIdForSale = null;
          _preSelectedKisaanIdForSale = null;
        }
        if (index == 2 && _editInvoiceNumber == null) {
          _preSelectedZamindarIdForSale = null;
          _preSelectedKisaanIdForSale = null;
        }
      }

      _selectedIndex = index;
      if (index == 1 && previousIndex != 1) {
        _zamindarView = ZamindarView.directory;
        _profileInitialTabIndex = null;
      }
      if (index != 5) {
        _pendingWholesalerId = null;
      }
      if (index != 6) {
        _ledgerInitialTabIndex = null;
      }
      _repairZamindarState();
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
    _invalidatePendingZamindarLedgerNav();
    setState(() {
      _preSelectedZamindarIdForSale = zamindarId;
      _preSelectedKisaanIdForSale = kisaanId;
      _editInvoiceNumber = null;
      _editReturnIndex = null;
      _selectedIndex = 2;
    });
  }

  void _navigateToEditInvoice(String invoiceNumber) {
    _invalidatePendingZamindarLedgerNav();
    setState(() {
      _editReturnIndex = _selectedIndex;
      _editInvoiceNumber = invoiceNumber;
      _preSelectedZamindarIdForSale = null;
      _preSelectedKisaanIdForSale = null;
      _selectedIndex = 2;
    });
  }

  void _clearEditState() {
    setState(() {
      final returnIndex = _editReturnIndex;
      _editInvoiceNumber = null;
      _preSelectedZamindarIdForSale = null;
      _preSelectedKisaanIdForSale = null;
      _editReturnIndex = null;
      if (returnIndex != null) {
        _selectedIndex = returnIndex;
        if (returnIndex == 1) {
          _zamindarLedgerRefreshToken++;
        } else if (returnIndex == 6) {
          _ledgerRefreshToken++;
        }
      }
      _repairZamindarState();
    });
  }

  Widget _buildZamindarsScreen() {
    switch (_effectiveZamindarView) {
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
        final selected = _selectedZamindar!;
        return ZamindarProfileScreen(
          key: ValueKey(
            'profile-${selected.id}-tab-${_profileInitialTabIndex ?? 0}-zledger-$_zamindarLedgerRefreshToken',
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
      _profileInitialTabIndex = null;
      _clearSaleNavState();
      _directoryRefreshToken++;
      _ledgerRefreshToken++;
      _zamindarLedgerRefreshToken++;
      _guardSelectedIndex();
    });
  }

  void _navigateToNewSaleFromDashboard() {
    if (!RolePermissions.canAccessIndex(_role, 2)) {
      setState(() => _selectedIndex = RolePermissions.fallbackIndex(_role));
      return;
    }
    _invalidatePendingZamindarLedgerNav();
    setState(() {
      _selectedIndex = 2;
      _clearSaleNavState();
    });
  }

  void _navigateToAddZamindarFromDashboard() {
    if (!RolePermissions.canAccessIndex(_role, 1)) {
      setState(() => _selectedIndex = RolePermissions.fallbackIndex(_role));
      return;
    }
    _invalidatePendingZamindarLedgerNav();
    setState(() {
      _selectedIndex = 1;
      _selectedZamindar = null;
      _zamindarView = ZamindarView.add;
      _profileInitialTabIndex = null;
    });
  }

  void _navigateToWholesalersFromDashboard() {
    _selectNavIndex(5);
  }

  Future<void> _navigateToWholesalerProfileFromDashboard(
    int wholesalerId,
  ) async {
    if (!RolePermissions.canAccessIndex(_role, 5)) {
      await _selectNavIndex(5);
      return;
    }
    setState(() {
      _selectedIndex = 5;
      _pendingWholesalerId = wholesalerId;
      _wholesalerNavToken++;
    });
  }

  Future<void> _navigateToCashLedgerFromDashboard() async {
    if (!RolePermissions.canAccessIndex(_role, 6)) {
      await _selectNavIndex(6);
      return;
    }
    setState(() {
      _selectedIndex = 6;
      // Payments tab is the closest cash-account ledger surface.
      _ledgerInitialTabIndex = 2;
      _ledgerRefreshToken++;
    });
  }

  Future<void> _navigateToSalesLedgerFromReports() async {
    if (!RolePermissions.canAccessIndex(_role, 6)) {
      await _selectNavIndex(6);
      return;
    }
    setState(() {
      _selectedIndex = 6;
      _ledgerInitialTabIndex = 0;
      _ledgerRefreshToken++;
    });
  }

  Future<void> _navigateToZamindarLedgerFromDashboard(int zamindarId) async {
    final navId = ++_pendingZamindarLedgerNav;
    try {
      final zamindar = await DatabaseHelper.instance.getZamindar(zamindarId);
      if (!mounted || navId != _pendingZamindarLedgerNav) return;
      if (zamindar == null || !RolePermissions.canAccessIndex(_role, 1)) {
        await _selectNavIndex(1);
        return;
      }
      setState(() {
        _selectedIndex = 1;
        _selectedZamindar = zamindar;
        _profileInitialTabIndex = 2;
        _zamindarView = ZamindarView.profile;
      });
    } catch (_) {
      if (!mounted || navId != _pendingZamindarLedgerNav) return;
      await _selectNavIndex(1);
    }
  }

  List<Widget> get _screens => [
    DashboardScreen(
      onNavigateToNewSale: _navigateToNewSaleFromDashboard,
      onNavigateToAddZamindar: _navigateToAddZamindarFromDashboard,
      onNavigateToWholesalers: _navigateToWholesalersFromDashboard,
      onNavigateToZamindarLedger: _navigateToZamindarLedgerFromDashboard,
      onNavigateToWholesalerProfile: _navigateToWholesalerProfileFromDashboard,
      onNavigateToCashLedger: _navigateToCashLedgerFromDashboard,
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
    WholesalersScreen(
      key: ValueKey('wholesaler-$_wholesalerNavToken-$_pendingWholesalerId'),
      initialWholesalerId: _pendingWholesalerId,
    ),
    MainLedgerScreen(
      key: ValueKey('ledger-$_ledgerRefreshToken'),
      onEditInvoice: _navigateToEditInvoice,
      initialTabIndex: _ledgerInitialTabIndex,
    ),
    const ExpenseScreen(),
    ReportsScreen(
      onNavigateToSalesLedger: _navigateToSalesLedgerFromReports,
    ),
    const UsersScreen(),
    const PartnerManagementScreen(),
    SettingsScreen(
      onDataReset: _handleApplicationDataReset,
      onShopNameChanged: _onShopNameChanged,
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
                          children: [..._buildNavSections()],
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
        key: ValueKey(index),
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
    super.key,
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
  void didUpdateWidget(covariant _SidebarNavItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Hover offset/scale must not linger into the selected state.
    if (widget.isSelected && _hovered) {
      _hovered = false;
    }
  }

  void _handleTap() {
    if (_hovered) setState(() => _hovered = false);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final showHover = _hovered && !isSelected;
    // Snap into selected styling; animate only for idle ↔ hover transitions.
    final animDuration = isSelected
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final scaleDuration = isSelected
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return MouseRegion(
      onEnter: (_) {
        if (!isSelected) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _handleTap,
        child: AnimatedContainer(
          duration: animDuration,
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
                    duration: scaleDuration,
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
