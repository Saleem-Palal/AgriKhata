import '../models/user_model.dart';

/// Shell / feature destinations used for RBAC checks.
enum AppDestination {
  dashboard,
  zamindars,
  newSale,
  products,
  purchase,
  wholesalers,
  ledger,
  expenses,
  reports,
  userAccounts,
  partnerManagement,
  settings,
}

/// Central role → permission matrix for AgriKhata desktop.
class RolePermissions {
  RolePermissions._();

  /// Sidebar index for each destination (must match [Shell] IndexedStack).
  static const Map<AppDestination, int> destinationIndex = {
    AppDestination.dashboard: 0,
    AppDestination.zamindars: 1,
    AppDestination.newSale: 2,
    AppDestination.products: 3,
    AppDestination.purchase: 4,
    AppDestination.wholesalers: 5,
    AppDestination.ledger: 6,
    AppDestination.expenses: 7,
    AppDestination.reports: 8,
    AppDestination.userAccounts: 9,
    AppDestination.partnerManagement: 10,
    AppDestination.settings: 11,
  };

  static AppDestination? destinationForIndex(int index) {
    for (final entry in destinationIndex.entries) {
      if (entry.value == index) return entry.key;
    }
    return null;
  }

  static const Set<AppDestination> _owner = {
    AppDestination.dashboard,
    AppDestination.zamindars,
    AppDestination.newSale,
    AppDestination.products,
    AppDestination.purchase,
    AppDestination.wholesalers,
    AppDestination.ledger,
    AppDestination.expenses,
    AppDestination.reports,
    AppDestination.userAccounts,
    AppDestination.partnerManagement,
    AppDestination.settings,
  };

  /// Partner: Dashboard, POS, Zamindars, Inventory, Expenses, Partner Mgmt.
  static const Set<AppDestination> _partner = {
    AppDestination.dashboard,
    AppDestination.zamindars,
    AppDestination.newSale,
    AppDestination.products,
    AppDestination.purchase,
    AppDestination.wholesalers,
    AppDestination.ledger,
    AppDestination.expenses,
    AppDestination.partnerManagement,
    AppDestination.settings,
  };

  /// Manager: Dashboard, POS, Zamindars, Inventory, Expenses, Reports.
  static const Set<AppDestination> _manager = {
    AppDestination.dashboard,
    AppDestination.zamindars,
    AppDestination.newSale,
    AppDestination.products,
    AppDestination.purchase,
    AppDestination.wholesalers,
    AppDestination.ledger,
    AppDestination.expenses,
    AppDestination.reports,
    AppDestination.settings,
  };

  /// Cashier: POS + Zamindar lookup only.
  static const Set<AppDestination> _cashier = {
    AppDestination.zamindars,
    AppDestination.newSale,
  };

  static Set<AppDestination> allowedFor(String? role) {
    switch ((role ?? '').toUpperCase()) {
      case UserRole.owner:
        return _owner;
      case UserRole.partner:
        return _partner;
      case UserRole.manager:
        return _manager;
      case UserRole.cashier:
        return _cashier;
      default:
        return const {AppDestination.newSale};
    }
  }

  static bool canAccess(String? role, AppDestination destination) {
    return allowedFor(role).contains(destination);
  }

  static bool canAccessIndex(String? role, int index) {
    final dest = destinationForIndex(index);
    if (dest == null) return false;
    return canAccess(role, dest);
  }

  /// Safe landing index when current selection is blocked.
  static int fallbackIndex(String? role) {
    final allowed = allowedFor(role);
    if (allowed.contains(AppDestination.newSale)) {
      return destinationIndex[AppDestination.newSale]!;
    }
    if (allowed.contains(AppDestination.dashboard)) {
      return destinationIndex[AppDestination.dashboard]!;
    }
    return allowed.isEmpty
        ? destinationIndex[AppDestination.newSale]!
        : destinationIndex[allowed.first]!;
  }

  static bool canManageUsers(String? role) =>
      (role ?? '').toUpperCase() == UserRole.owner;

  static bool canViewAuditLogs(String? role) =>
      (role ?? '').toUpperCase() == UserRole.owner ||
      (role ?? '').toUpperCase() == UserRole.partner ||
      (role ?? '').toUpperCase() == UserRole.manager;
}
