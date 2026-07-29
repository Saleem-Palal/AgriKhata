/// Shop login account persisted in the local `users` table.
class UserModel {
  final String id;
  final String name;
  final String phone;
  final String? email;
  final String role;
  final String pinCode;
  final String? partnerId;
  final bool isActive;
  final DateTime createdAt;

  const UserModel({
    required this.id,
    required this.name,
    this.phone = '',
    this.email,
    required this.role,
    required this.pinCode,
    this.partnerId,
    this.isActive = true,
    required this.createdAt,
  });

  bool get isOwner => role == UserRole.owner;
  bool get isPartner => role == UserRole.partner;
  bool get isManager => role == UserRole.manager;
  bool get isCashier => role == UserRole.cashier;

  String get roleLabel => UserRole.label(role);

  /// Immutable display label for activity footprints, e.g. `Ali Raza (Manager)`.
  String get footprintLabel => '$name ($roleLabel)';

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final word = parts.first;
      return word.substring(0, word.length >= 2 ? 2 : 1).toUpperCase();
    }
    return ('${parts.first[0]}${parts.last[0]}').toUpperCase();
  }

  UserModel copyWith({
    String? id,
    String? name,
    String? phone,
    String? email,
    bool clearEmail = false,
    String? role,
    String? pinCode,
    String? partnerId,
    bool clearPartnerId = false,
    bool? isActive,
    DateTime? createdAt,
  }) {
    return UserModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: clearEmail ? null : (email ?? this.email),
      role: role ?? this.role,
      pinCode: pinCode ?? this.pinCode,
      partnerId: clearPartnerId ? null : (partnerId ?? this.partnerId),
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'phone': phone,
        'email': email,
        'role': role,
        'pin_code': pinCode,
        'partner_id': partnerId,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory UserModel.fromMap(Map<String, Object?> map) {
    final rawCreated = map['created_at'] as String? ?? '';
    return UserModel(
      id: map['id']?.toString() ?? '',
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      email: map['email'] as String?,
      role: (map['role'] as String? ?? UserRole.cashier).toUpperCase(),
      pinCode: map['pin_code'] as String? ?? '',
      partnerId: map['partner_id']?.toString(),
      isActive: (map['is_active'] as int?) != 0,
      createdAt: DateTime.tryParse(rawCreated) ?? DateTime.now(),
    );
  }
}

/// Canonical role string constants stored in SQLite.
class UserRole {
  static const String owner = 'OWNER';
  static const String partner = 'PARTNER';
  static const String manager = 'MANAGER';
  static const String cashier = 'CASHIER';

  static const List<String> staffRoles = [partner, manager, cashier];

  static String label(String role) {
    switch (role.toUpperCase()) {
      case owner:
        return 'Owner';
      case partner:
        return 'Partner';
      case manager:
        return 'Manager';
      case cashier:
        return 'Cashier';
      default:
        return role;
    }
  }

  static String normalize(String role) {
    final upper = role.trim().toUpperCase();
    switch (upper) {
      case owner:
      case partner:
      case manager:
      case cashier:
        return upper;
      default:
        // Legacy UI labels
        final lower = role.trim().toLowerCase();
        if (lower == 'owner') return owner;
        if (lower == 'partner') return partner;
        if (lower == 'manager') return manager;
        if (lower == 'cashier') return cashier;
        return upper;
    }
  }
}
