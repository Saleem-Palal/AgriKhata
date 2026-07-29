import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/services/payment_service.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Opens the protected Edit Payment dialog for a customer payment receipt.
///
/// Returns `true` when the payment was saved successfully.
Future<bool> showEditPaymentDialog({
  required BuildContext context,
  required String paymentId,
}) async {
  final payment = await PaymentService.instance.getPayment(paymentId);
  if (payment == null) {
    if (context.mounted) {
      AppToast.showError(context, 'Payment not found');
    }
    return false;
  }

  final editability = await PaymentService.instance.evaluatePaymentRow(payment);
  if (!editability.isEditable) {
    if (context.mounted) {
      AppToast.showError(
        context,
        editability.reason ??
            '🔒 This payment belongs to a closed/settled season and cannot be modified.',
      );
    }
    return false;
  }

  if (!context.mounted) return false;

  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _EditPaymentDialog(
      payment: payment,
      editability: editability,
    ),
  );
  return saved == true;
}

class _EditPaymentDialog extends StatefulWidget {
  final Map<String, dynamic> payment;
  final PaymentEditability editability;

  const _EditPaymentDialog({
    required this.payment,
    required this.editability,
  });

  @override
  State<_EditPaymentDialog> createState() => _EditPaymentDialogState();
}

class _EditPaymentDialogState extends State<_EditPaymentDialog> {
  late final TextEditingController _amountController;
  late final TextEditingController _notesController;
  late final TextEditingController _adminPinController;
  late final TextEditingController _masterPinController;

  late DateTime _paymentDate;
  late String _paymentMethod;
  var _masterAuthorized = false;
  var _isSaving = false;
  String? _error;

  String get _paymentId =>
      widget.payment[PaymentsTable.paymentId] as String? ?? '';

  @override
  void initState() {
    super.initState();
    final amount =
        (widget.payment[PaymentsTable.amountPaid] as num?)?.round() ?? 0;
    _amountController = TextEditingController(text: '$amount');
    _notesController = TextEditingController(
      text: widget.payment[PaymentsTable.notes] as String? ?? '',
    );
    _adminPinController = TextEditingController();
    _masterPinController = TextEditingController();

    _paymentDate = DateTime.tryParse(
          widget.payment[PaymentsTable.dateTime] as String? ?? '',
        ) ??
        DateTime.now();

    var method =
        widget.payment[PaymentsTable.paymentMethod] as String? ?? 'Cash';
    if (method != 'Cash' && method != 'Bank Transfer') {
      method = method.toLowerCase().contains('bank') ? 'Bank Transfer' : 'Cash';
    }
    _paymentMethod = method;
    _masterAuthorized = !widget.editability.requiresMasterAdmin;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    _adminPinController.dispose();
    _masterPinController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _paymentDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      _paymentDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _paymentDate.hour,
        _paymentDate.minute,
      );
    });
  }

  Future<void> _authorizeMasterAdmin() async {
    setState(() => _error = null);
    try {
      await PaymentService.instance.verifyMasterAdminPasscode(
        _masterPinController.text,
      );
      // Owner PIN satisfies both Master Admin gate and Admin save gate.
      _adminPinController.text = _masterPinController.text.trim();
      setState(() => _masterAuthorized = true);
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '');
      });
    }
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid payment amount');
      return;
    }
    if (widget.editability.requiresMasterAdmin && !_masterAuthorized) {
      setState(() => _error = 'Authorize with Master Admin passcode first');
      return;
    }
    if (_adminPinController.text.trim().length != 4) {
      setState(() => _error = 'Enter Admin PIN to save changes');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await PaymentService.instance.updatePayment(
        paymentId: _paymentId,
        dateTime: _paymentDate,
        amountPaid: amount,
        paymentMethod: _paymentMethod,
        notes: _notesController.text.trim(),
        adminPin: _adminPinController.text.trim(),
        masterAdminAuthorized: _masterAuthorized,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = e.toString().replaceFirst(RegExp(r'^[^:]+:\s*'), '');
      });
    }
  }

  InputDecoration _fieldDecoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFD4E8D8)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFFD4E8D8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF2D6A4F)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zamindar =
        widget.payment[PaymentsTable.zamindarName] as String? ?? 'Zamindar';
    final invoice =
        (widget.payment[PaymentsTable.invoiceNumber] as String?)?.trim();

    return AlertDialog(
      title: const Text(
        '✏️ Edit Payment',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1B4332),
        ),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: const Text(
                  '⚠️ Editing this payment will adjust the Zamindar\'s '
                  'outstanding balance and cash drawer history.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF633806),
                    height: 1.35,
                  ),
                ),
              ),
              if (widget.editability.requiresMasterAdmin) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFCEBEB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFF5C6C6)),
                  ),
                  child: Text(
                    widget.editability.reason ??
                        'Master Admin passcode required (outside ${PaymentService.editWindowDays}-day window).',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF791F1F),
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                'Receipt: $_paymentId'
                '${invoice != null && invoice.isNotEmpty ? '  ·  Invoice: $invoice' : '  ·  Advance'}'
                '\nZamindar: $zamindar',
                style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
              ),
              const SizedBox(height: 14),
              const Text(
                'Amount (₨)',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D6A4F),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _amountController,
                enabled: !_isSaving && _masterAuthorized,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: _fieldDecoration(hint: '0'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Payment Date',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D6A4F),
                ),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: (!_isSaving && _masterAuthorized) ? _pickDate : null,
                child: InputDecorator(
                  decoration: _fieldDecoration(),
                  child: Text(
                    DateFormat('dd MMM yyyy').format(_paymentDate),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF1B4332),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Payment Mode',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D6A4F),
                ),
              ),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: _paymentMethod,
                decoration: _fieldDecoration(),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  DropdownMenuItem(
                    value: 'Bank Transfer',
                    child: Text('Bank Transfer'),
                  ),
                ],
                onChanged: (!_isSaving && _masterAuthorized)
                    ? (v) {
                        if (v == null) return;
                        setState(() => _paymentMethod = v);
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              const Text(
                'Notes / Remarks',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D6A4F),
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _notesController,
                enabled: !_isSaving && _masterAuthorized,
                maxLines: 2,
                decoration: _fieldDecoration(hint: 'Optional remarks'),
              ),
              if (widget.editability.requiresMasterAdmin &&
                  !_masterAuthorized) ...[
                const SizedBox(height: 14),
                const Text(
                  'Master Admin Passcode',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF791F1F),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _masterPinController,
                        obscureText: true,
                        maxLength: 4,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: _fieldDecoration(hint: '••••')
                            .copyWith(counterText: ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _isSaving ? null : _authorizeMasterAdmin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF791F1F),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Authorize'),
                    ),
                  ],
                ),
              ],
              if (_masterAuthorized) ...[
                const SizedBox(height: 14),
                const Text(
                  'Admin PIN (required to save)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D6A4F),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _adminPinController,
                  enabled: !_isSaving,
                  obscureText: true,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _fieldDecoration(hint: '••••')
                      .copyWith(counterText: ''),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFDC3545),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: (_isSaving || !_masterAuthorized) ? null : _save,
          icon: _isSaving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.save_outlined, size: 16),
          label: Text(_isSaving ? 'Saving…' : 'Save Changes'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1B4332),
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }
}
