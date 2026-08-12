import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/ledger_models.dart';
import '../utils/pdf_generator.dart';
import '../utils/receipt_acknowledgment.dart';
import '../utils/shop_settings.dart';

/// Thermal receipt printing with optional ink acknowledgment blocks
/// (Zamindar thumb/sign + shop stamp/sign). A4/PDF documents do not include
/// thumbprint blocks — those are thermal-only.
class PrintService {
  PrintService._();

  static final NumberFormat _currencyFormat = NumberFormat('#,##,##0');
  static final DateFormat _dateFormat = DateFormat('dd MMM yyyy');
  static final DateFormat _timeFormat = DateFormat('hh:mm a');

  // ---------------------------------------------------------------------------
  // Acknowledgment blocks (delegates)
  // ---------------------------------------------------------------------------

  static pw.Widget buildThermalAcknowledgmentBlock() =>
      ReceiptAcknowledgment.buildThermalBlock();

  // ---------------------------------------------------------------------------
  // Print APIs
  // ---------------------------------------------------------------------------

  /// 80mm thermal sale receipt with optional thumbprint block (settings-gated).
  static Future<void> printThermalSaleReceipt(LedgerEntry entry) async {
    final pdf = await generateThermalSaleReceiptPdf(entry);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'AgriKhata Receipt ${entry.invoiceNumber}',
    );
  }

  /// A4 formal invoice with acknowledgment boxes.
  static Future<void> printA4Invoice(
    LedgerEntry entry, {
    bool isEdited = false,
  }) async {
    await PdfGenerator.printInvoice(entry, isEdited: isEdited);
  }

  /// A4 statement / ledger document print helper.
  static Future<void> printA4Document(pw.Document pdf, {String? name}) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: name ?? 'AgriKhata Statement',
    );
  }

  static Future<pw.Document> generateThermalSaleReceiptPdf(
    LedgerEntry entry,
  ) async {
    final shopName = await ShopSettings.getShopName();
    final shopPhone = await ShopSettings.getShopPhone();
    final shopAddress = await ShopSettings.getShopAddress();
    final showThumb =
        await ShopSettings.getShowThumbprintBlockOnThermal();
    final pdf = pw.Document();

    // Tall roll so acknowledgment + promo footer always fit.
    final pageHeight = showThumb ? 250.0 : 185.0;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          80 * PdfPageFormat.mm,
          pageHeight * PdfPageFormat.mm,
        ),
        build: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Center(
                  child: pw.Column(
                    children: [
                      pw.Text(
                        'AgriKhata',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        _safe(shopName),
                        style: pw.TextStyle(
                          fontSize: 12,
                          fontWeight: pw.FontWeight.bold,
                        ),
                        textAlign: pw.TextAlign.center,
                      ),
                      if (shopPhone.trim().isNotEmpty) ...[
                        pw.SizedBox(height: 2),
                        pw.Text(
                          _safe(shopPhone),
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ],
                      if (shopAddress.trim().isNotEmpty) ...[
                        pw.SizedBox(height: 1),
                        pw.Text(
                          _safe(shopAddress),
                          style: const pw.TextStyle(
                            fontSize: 7,
                            color: PdfColors.grey800,
                          ),
                          textAlign: pw.TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Container(
                  width: double.infinity,
                  height: 0.7,
                  color: PdfColors.grey700,
                ),
                pw.SizedBox(height: 6),
                pw.Center(
                  child: pw.Text(
                    'SALE RECEIPT',
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.SizedBox(height: 8),
                _receiptRow('Invoice:', entry.invoiceNumber),
                _receiptRow('Date:', _dateFormat.format(entry.date)),
                _receiptRow('Time:', _timeFormat.format(entry.date)),
                _receiptRow('Customer:', entry.stakeholderName),
                if (entry.kisaanName != null &&
                    entry.kisaanName!.trim().isNotEmpty)
                  _receiptRow('Kisaan:', entry.kisaanName!),
                if (entry.createdByUserName != null &&
                    entry.createdByUserName!.trim().isNotEmpty)
                  _receiptRow('Recorded By:', entry.createdByUserName!.trim()),
                pw.SizedBox(height: 6),
                pw.Container(
                  width: double.infinity,
                  height: 0.5,
                  color: PdfColors.grey500,
                ),
                pw.SizedBox(height: 4),
                ...entry.items.map((item) {
                  final lineTotal = item.total;
                  return pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 2),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          _safe(item.productName),
                          style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text(
                              '${item.quantity} ${item.unit} x Rs ${_currencyFormat.format(item.unitPrice)}',
                              style: const pw.TextStyle(fontSize: 7.5),
                            ),
                            pw.Text(
                              'Rs ${_currencyFormat.format(lineTotal)}',
                              style: const pw.TextStyle(fontSize: 7.5),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),
                pw.SizedBox(height: 4),
                pw.Container(
                  width: double.infinity,
                  height: 0.5,
                  color: PdfColors.grey500,
                ),
                pw.SizedBox(height: 6),
                _receiptRow(
                  'Total:',
                  'Rs ${_currencyFormat.format(entry.total)}',
                  bold: true,
                ),
                _receiptRow(
                  'Paid:',
                  'Rs ${_currencyFormat.format(entry.paid)}',
                ),
                _receiptRow(
                  'Outstanding:',
                  'Rs ${_currencyFormat.format(entry.outstanding)}',
                  bold: true,
                ),
                _receiptRow('Status:', entry.status.displayName),
                if (entry.description?.trim().isNotEmpty == true) ...[
                  pw.SizedBox(height: 6),
                  pw.Container(
                    width: double.infinity,
                    height: 0.5,
                    color: PdfColors.grey500,
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'Note: ${_safe(entry.description!.trim())}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
                if (showThumb) ...[
                  pw.SizedBox(height: 10),
                  buildThermalAcknowledgmentBlock(),
                ],
                pw.SizedBox(height: 8),
                pw.Center(
                  child: pw.Text(
                    'Thank you for your business!',
                    style: pw.TextStyle(
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                ReceiptAcknowledgment.buildThermalPromoFooter(),
              ],
            ),
          );
        },
      ),
    );

    return pdf;
  }

  static pw.Widget _receiptRow(
    String label,
    String value, {
    bool bold = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.Expanded(
            child: pw.Text(
              _safe(value),
              style: pw.TextStyle(
                fontSize: 8,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              ),
              textAlign: pw.TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  static String _safe(String input) {
    if (input.isEmpty) return '';
    var text = input
        .replaceAll('\u2014', '-')
        .replaceAll('\u2013', '-')
        .replaceAll('\u00B7', '-')
        .replaceAll('\u2022', '-')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"');
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      if ((rune >= 0x20 && rune <= 0x7E) || (rune >= 0xA0 && rune <= 0xFF)) {
        buffer.writeCharCode(rune);
      }
    }
    final result = buffer.toString();
    return result.isEmpty ? '-' : result;
  }
}
