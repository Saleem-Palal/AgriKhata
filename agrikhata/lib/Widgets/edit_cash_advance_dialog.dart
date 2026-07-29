import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Edit dialog for kisaan cash / fuel advance invoices.
Future<bool> showEditCashAdvanceDialog({
  required BuildContext context,
  required String invoiceNumber,
}) async {
  final invoiceData = await DatabaseHelper.instance
      .getInvoiceDataByInvoiceNumber(invoiceNumber);

  if (invoiceData == null) {
    if (context.mounted) {
      AppToast.showError(context, 'Advance invoice not found');
    }
    return false;
  }

  final transactionType =
      invoiceData['transactionType'] as String? ??
      SaleTransactionType.cashAdvance;
  if (!SaleTransactionType.isAdvance(transactionType)) {
    if (context.mounted) {
      AppToast.showError(context, 'This invoice is not a cash/fuel advance');
    }
    return false;
  }

  final season = invoiceData['season'] as String?;
  try {
    await DatabaseHelper.instance.assertSeasonEditable(season);
  } catch (e) {
    if (context.mounted) {
      AppToast.showError(context, e.toString());
    }
    return false;
  }

  if (!context.mounted) return false;

  final amountController = TextEditingController(
    text: ((invoiceData['totalPayable'] as num?)?.toDouble() ?? 0)
        .toStringAsFixed(0),
  );
  final remarksController = TextEditingController(
    text: (invoiceData['remarks'] as String?) ?? '',
  );
  final fuelController = TextEditingController(
    text: SaleTransactionType.isFuelAdvance(transactionType)
        ? ((invoiceData['fuelQuantity'] as num?)?.toDouble() ?? 0)
              .toStringAsFixed(0)
        : '',
  );
  var dateTime =
      DateTime.tryParse(invoiceData['dateTime'] as String? ?? '') ??
      DateTime.now();
  final typeLabel = SaleTransactionType.displayLabel(transactionType);
  final isFuel = SaleTransactionType.isFuelAdvance(transactionType);
  var isSaving = false;

  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: !isSaving,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> pickDateTime() async {
            final date = await showDatePicker(
              context: ctx,
              initialDate: dateTime,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 1)),
            );
            if (date == null || !ctx.mounted) return;
            final time = await showTimePicker(
              context: ctx,
              initialTime: TimeOfDay.fromDateTime(dateTime),
            );
            if (time == null) return;
            setDialogState(() {
              dateTime = DateTime(
                date.year,
                date.month,
                date.day,
                time.hour,
                time.minute,
              );
            });
          }

          Future<void> save() async {
            final amount =
                double.tryParse(amountController.text.trim()) ?? 0;
            if (amount <= 0) {
              AppToast.showError(ctx, 'Enter a valid amount');
              return;
            }
            double? liters;
            if (isFuel) {
              liters = double.tryParse(fuelController.text.trim());
              if (liters == null || liters <= 0) {
                AppToast.showError(ctx, 'Enter fuel quantity in liters');
                return;
              }
            }

            setDialogState(() => isSaving = true);
            try {
              await DatabaseHelper.instance.updateKisaanAdvance(
                invoiceNumber: invoiceNumber,
                dateTime: dateTime,
                transactionType: transactionType,
                amount: amount,
                fuelQuantityLiters: liters,
                remarks: remarksController.text.trim().isEmpty
                    ? null
                    : remarksController.text.trim(),
              );
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            } catch (e) {
              if (ctx.mounted) {
                setDialogState(() => isSaving = false);
                AppToast.showError(ctx, 'Failed to update advance: $e');
              }
            }
          }

          return AlertDialog(
            title: Text(
              'Edit $typeLabel',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1B4332),
              ),
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Invoice: $invoiceNumber',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  InkWell(
                    onTap: isSaving ? null : pickDateTime,
                    borderRadius: BorderRadius.circular(8),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Date & time',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      child: Text(
                        DateFormat('dd MMM yyyy · hh:mm a').format(dateTime),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: amountController,
                    enabled: !isSaving,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Amount',
                      prefixText: 'Rs ',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                  if (isFuel) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: fuelController,
                      enabled: !isSaving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Fuel quantity (L)',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: remarksController,
                    enabled: !isSaving,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: 'Description / remarks',
                      hintText: 'Optional note for this advance',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B4332),
                  foregroundColor: Colors.white,
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );

  amountController.dispose();
  remarksController.dispose();
  fuelController.dispose();

  if (saved == true && context.mounted) {
    AppToast.showSuccess(context, '$typeLabel updated');
  }
  return saved == true;
}
