import 'package:flutter/foundation.dart';

import '../Database/database_helper.dart';
import '../models/user_model.dart';

/// Lightweight view of a shop login account for Partner linking dropdowns.
class AppUserAccount {
  final String id;
  final String name;
  final String role;
  final String pin;
  final String subtitle;
  final bool isOwner;

  const AppUserAccount({
    required this.id,
    required this.name,
    required this.role,
    required this.pin,
    required this.subtitle,
    this.isOwner = false,
  });

  factory AppUserAccount.fromUser(UserModel user) {
    return AppUserAccount(
      id: user.id,
      name: user.name,
      role: user.roleLabel,
      pin: user.pinCode,
      subtitle: user.email?.isNotEmpty == true
          ? user.email!
          : (user.phone.isNotEmpty ? user.phone : user.roleLabel),
      isOwner: user.isOwner,
    );
  }

  AppUserAccount copyWith({
    String? id,
    String? name,
    String? role,
    String? pin,
    String? subtitle,
    bool? isOwner,
  }) {
    return AppUserAccount(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      pin: pin ?? this.pin,
      subtitle: subtitle ?? this.subtitle,
      isOwner: isOwner ?? this.isOwner,
    );
  }
}

/// DB-backed registry of shop staff accounts (replaces in-memory seed data).
class UserAccountStore extends ChangeNotifier {
  UserAccountStore._();
  static final UserAccountStore instance = UserAccountStore._();

  List<AppUserAccount> _users = const [];
  bool _loading = false;

  List<AppUserAccount> get users => List.unmodifiable(_users);
  bool get isLoading => _loading;

  AppUserAccount? findById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final u in _users) {
      if (u.id == id) return u;
    }
    return null;
  }

  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      final rows = await DatabaseHelper.instance.getUsers();
      _users = rows.map(AppUserAccount.fromUser).toList();
    } catch (e, st) {
      debugPrint('UserAccountStore.refresh failed: $e\n$st');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void setUsers(List<AppUserAccount> users) {
    _users = List.of(users);
    notifyListeners();
  }

  void addUser(AppUserAccount user) {
    _users = [..._users, user];
    notifyListeners();
  }

  void updateUser(AppUserAccount user) {
    _users = _users.map((u) => u.id == user.id ? user : u).toList();
    notifyListeners();
  }

  void removeUser(String id) {
    _users = _users.where((u) => u.id != id).toList();
    notifyListeners();
  }
}
