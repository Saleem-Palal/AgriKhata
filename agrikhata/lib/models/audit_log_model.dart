/// Activity footprint row stored in the local `audit_logs` table.
class AuditLogModel {
  final String id;
  final String userId;
  final String userName;
  final String actionType;
  final String referenceId;
  final String description;
  final DateTime timestamp;

  const AuditLogModel({
    required this.id,
    required this.userId,
    required this.userName,
    required this.actionType,
    required this.referenceId,
    required this.description,
    required this.timestamp,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'user_id': userId,
        'user_name': userName,
        'action_type': actionType,
        'reference_id': referenceId,
        'description': description,
        'timestamp': timestamp.toIso8601String(),
      };

  factory AuditLogModel.fromMap(Map<String, Object?> map) {
    final rawTs = map['timestamp'] as String? ?? '';
    return AuditLogModel(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      userName: map['user_name'] as String? ?? '',
      actionType: map['action_type'] as String? ?? '',
      referenceId: map['reference_id']?.toString() ?? '',
      description: map['description'] as String? ?? '',
      timestamp: DateTime.tryParse(rawTs) ?? DateTime.now(),
    );
  }
}

/// Canonical audit action types.
class AuditActionType {
  static const String newSale = 'NEW_SALE';
  static const String purchaseEntry = 'PURCHASE_ENTRY';
  static const String addProduct = 'ADD_PRODUCT';
  static const String recordExpense = 'RECORD_EXPENSE';
  static const String drawingEntry = 'DRAWING_ENTRY';
  static const String editPayment = 'EDIT_PAYMENT';
  static const String seasonRollover = 'SEASON_ROLLOVER';

  static String label(String type) {
    switch (type) {
      case newSale:
        return 'New Sale';
      case purchaseEntry:
        return 'Purchase Entry';
      case addProduct:
        return 'Add Product';
      case recordExpense:
        return 'Record Expense';
      case drawingEntry:
        return 'Drawing Entry';
      case editPayment:
        return 'Edit Payment';
      case seasonRollover:
        return 'Season Rollover';
      default:
        return type;
    }
  }
}
