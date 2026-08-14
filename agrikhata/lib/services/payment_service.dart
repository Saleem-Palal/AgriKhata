import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/models/user_model.dart';
import 'package:agrikhata/services/session_context.dart';

/// Editability + protected update API for customer (`payments`) entries.
///
/// Maps to the product concept of "payment_logs" / "customer_ledger":
/// physical tables are [PaymentsTable] and [LedgerTransactionTable].
class PaymentService {
  PaymentService._();
  static final PaymentService instance = PaymentService._();

  /// Shopkeeper edit window for past payments (calendar days).
  static const int editWindowDays = 30;

  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Evaluates whether a payment may be edited under ledger-lock rules.
  Future<PaymentEditability> evaluateEditability({
    required DateTime paymentDate,
    required String season,
    String? paymentMethod,
  }) async {
    final seasonLabel = season.trim();
    if (seasonLabel.isNotEmpty) {
      final past = await _db.isPastSeasonRecord(seasonLabel: seasonLabel);
      if (past) {
        final isOwner = SessionContext.currentUser?.isOwner == true;
        if (!isOwner) {
          return const PaymentEditability(
            isEditable: false,
            requiresMasterAdmin: false,
            reason:
                '🔒 This payment belongs to a past season and is read-only. '
                'Only the Owner / Master Admin can modify it.',
          );
        }
        return PaymentEditability(
          isEditable: true,
          requiresMasterAdmin: true,
          reason:
              'This payment belongs to a past season. '
              'Master Owner PIN is required to authorize the edit.',
        );
      }
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final paymentDay = DateTime(
      paymentDate.year,
      paymentDate.month,
      paymentDate.day,
    );
    final ageDays = today.difference(paymentDay).inDays;
    final outsideWindow = ageDays > editWindowDays;

    if (outsideWindow) {
      return PaymentEditability(
        isEditable: true,
        requiresMasterAdmin: true,
        reason:
            'This payment is older than $editWindowDays days. '
            'Master Admin passcode is required to authorize the edit.',
        ageDays: ageDays,
      );
    }

    return PaymentEditability(
      isEditable: true,
      requiresMasterAdmin: false,
      reason: null,
      ageDays: ageDays,
    );
  }

  Future<PaymentEditability> evaluatePaymentRow(
    Map<String, dynamic> row,
  ) async {
    final dateRaw = row[PaymentsTable.dateTime] as String? ?? '';
    final date = DateTime.tryParse(dateRaw) ?? DateTime.now();
    return evaluateEditability(
      paymentDate: date,
      season: row[PaymentsTable.season] as String? ?? '',
      paymentMethod: row[PaymentsTable.paymentMethod] as String?,
    );
  }

  Future<Map<String, dynamic>?> getPayment(String paymentId) =>
      _db.getPaymentById(paymentId);

  /// Verifies a PIN against the Master Admin (Owner) account.
  Future<UserModel> verifyMasterAdminPasscode(String pinCode) async {
    final pin = pinCode.trim();
    if (pin.length != 4 || int.tryParse(pin) == null) {
      throw StateError('Enter a valid 4-digit Master Admin PIN');
    }
    final owner = await _db.getOwnerUser();
    if (owner == null) {
      throw StateError('No Master Admin (Owner) account is configured');
    }
    if (owner.pinCode != pin) {
      throw StateError('Incorrect Master Admin passcode');
    }
    return owner;
  }

  /// Verifies Admin PIN — accepts Owner PIN, or the signed-in admin user's PIN
  /// when they are Owner / Partner / Manager.
  Future<UserModel> verifyAdminPin(String pinCode) async {
    final pin = pinCode.trim();
    if (pin.length != 4 || int.tryParse(pin) == null) {
      throw StateError('Enter a valid 4-digit Admin PIN');
    }

    final owner = await _db.getOwnerUser();
    if (owner != null && owner.pinCode == pin) {
      return owner;
    }

    final current = SessionContext.currentUser;
    if (current != null &&
        current.isActive &&
        (current.isOwner || current.isPartner || current.isManager) &&
        current.pinCode == pin) {
      return current;
    }

    throw StateError('Incorrect Admin PIN');
  }

  /// Saves an edited payment after PIN verification and lock checks.
  ///
  /// Ledger CREDIT rows and Cash-in-Hand KPI update automatically via
  /// `after_payment_update` + live Cash payment aggregation.
  Future<void> updatePayment({
    required String paymentId,
    required DateTime dateTime,
    required double amountPaid,
    required String paymentMethod,
    String notes = '',
    required String adminPin,
    bool masterAdminAuthorized = false,
  }) async {
    final existing = await _db.getPaymentById(paymentId);
    if (existing == null) {
      throw StateError('Payment $paymentId not found');
    }

    final editability = await evaluatePaymentRow(existing);
    if (!editability.isEditable) {
      throw StateError(
        editability.reason ??
            'This payment cannot be modified.',
      );
    }
    if (editability.requiresMasterAdmin && !masterAdminAuthorized) {
      throw StateError(
        editability.reason ??
            'Master Admin passcode is required to edit this payment.',
      );
    }

    final admin = await verifyAdminPin(adminPin);
    final editedBy = admin.footprintLabel;

    await _db.updatePaymentEntry(
      paymentId: paymentId,
      dateTime: dateTime,
      amountPaid: amountPaid,
      paymentMethod: paymentMethod,
      notes: notes,
      editedBy: editedBy,
    );
  }

  /// Deletes a cash settlement or wallet deduction and reverts balances.
  Future<void> deletePayment({required String paymentId}) async {
    final existing = await _db.getPaymentById(paymentId);
    if (existing == null) {
      throw StateError('Payment $paymentId not found');
    }

    final editability = await evaluatePaymentRow(existing);
    if (!editability.isEditable) {
      throw StateError(
        editability.reason ?? 'This payment cannot be modified.',
      );
    }

    await _db.deletePaymentEntry(paymentId: paymentId);
  }
}

/// Result of date-window / season-lock evaluation for a payment.
class PaymentEditability {
  final bool isEditable;
  final bool requiresMasterAdmin;
  final String? reason;
  final int? ageDays;

  const PaymentEditability({
    required this.isEditable,
    required this.requiresMasterAdmin,
    this.reason,
    this.ageDays,
  });
}
