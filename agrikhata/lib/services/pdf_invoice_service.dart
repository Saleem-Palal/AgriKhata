import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../Database/database_helper.dart';
import '../utils/shop_settings.dart';

/// Wholesaler profile snapshot used when generating printable statements.
class WholesalerStatementProfile {
  const WholesalerStatementProfile({
    required this.name,
    required this.phone,
    required this.city,
    this.address = '',
    required this.outstandingBalance,
  });

  final String name;
  final String phone;
  final String city;
  final String address;
  final double outstandingBalance;
}

/// Generates and opens printable PDFs for wholesaler khata statements.
class PdfInvoiceService {
  PdfInvoiceService._();

  static final NumberFormat _currency = NumberFormat('#,##,##0');
  static final DateFormat _date = DateFormat('dd MMM yyyy');

  static String _rs(num value) => 'Rs ${_currency.format(value.round())}';

  static String _safe(String input) {
    if (input.isEmpty) return '-';
    var text = input
        .replaceAll('\u2014', '-')
        .replaceAll('\u2013', '-')
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
    final result = buffer.toString().trim();
    return result.isEmpty ? '-' : result;
  }

  static String _formatDate(String? raw) {
    if (raw == null || raw.isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return _safe(raw);
    return _date.format(parsed);
  }

  /// Builds a wholesaler account statement PDF and opens the desktop print
  /// preview via the `printing` package.
  static Future<void> generateWholesalerStatementPdf(
    WholesalerStatementProfile wholesaler,
    List<Map<String, dynamic>> transactions, {
    List<Map<String, dynamic>> purchases = const [],
    List<Map<String, dynamic>> payments = const [],
  }) async {
    final pdf = await buildWholesalerStatementPdf(
      wholesaler,
      transactions,
      purchases: purchases,
      payments: payments,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Wholesaler Statement - ${_safe(wholesaler.name)}',
    );
  }

  static Future<pw.Document> buildWholesalerStatementPdf(
    WholesalerStatementProfile wholesaler,
    List<Map<String, dynamic>> transactions, {
    List<Map<String, dynamic>> purchases = const [],
    List<Map<String, dynamic>> payments = const [],
  }) async {
    final shopName = await ShopSettings.getShopName();
    final shopPhone = await ShopSettings.getShopPhone();
    final shopAddress = await ShopSettings.getShopAddress();

    // Chronological (oldest first) for opening → running balance narrative.
    final ordered = [...transactions]
      ..sort((a, b) {
        final da = DateTime.tryParse(
              a[WholesalerLedgerTable.date] as String? ?? '',
            ) ??
            DateTime(1970);
        final db = DateTime.tryParse(
              b[WholesalerLedgerTable.date] as String? ?? '',
            ) ??
            DateTime(1970);
        final byDate = da.compareTo(db);
        if (byDate != 0) return byDate;
        final ia = (a[WholesalerLedgerTable.id] as num?)?.toInt() ?? 0;
        final ib = (b[WholesalerLedgerTable.id] as num?)?.toInt() ?? 0;
        return ia.compareTo(ib);
      });

    double openingBalance = 0;
    if (ordered.isNotEmpty) {
      final first = ordered.first;
      final run =
          (first[WholesalerLedgerTable.runningBalance] as num?)?.toDouble() ??
              0;
      final debit =
          (first[WholesalerLedgerTable.debit] as num?)?.toDouble() ?? 0;
      final credit =
          (first[WholesalerLedgerTable.credit] as num?)?.toDouble() ?? 0;
      openingBalance = run - debit + credit;
    }

    final totalPurchases = purchases.fold<double>(
      0,
      (sum, row) =>
          sum +
          ((row[PurchaseInvoicesTable.grandTotal] as num?)?.toDouble() ?? 0),
    );
    final totalPayments = payments.fold<double>(
      0,
      (sum, row) =>
          sum + ((row[WholesalerPaymentsTable.amount] as num?)?.toDouble() ?? 0),
    );

    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          _header(
            shopName: shopName,
            shopPhone: shopPhone,
            shopAddress: shopAddress,
          ),
          pw.SizedBox(height: 16),
          _wholesalerBlock(wholesaler),
          pw.SizedBox(height: 14),
          _summaryRow(
            opening: openingBalance,
            purchases: totalPurchases,
            payments: totalPayments,
            outstanding: wholesaler.outstandingBalance,
          ),
          pw.SizedBox(height: 18),
          _sectionTitle('Itemized Purchases'),
          pw.SizedBox(height: 6),
          if (purchases.isEmpty)
            _emptyNote('No purchase invoices recorded.')
          else
            _purchasesTable(purchases),
          pw.SizedBox(height: 16),
          _sectionTitle('Payment Logs'),
          pw.SizedBox(height: 6),
          if (payments.isEmpty)
            _emptyNote('No payments recorded.')
          else
            _paymentsTable(payments),
          pw.SizedBox(height: 16),
          _sectionTitle('Khata Statement'),
          pw.SizedBox(height: 6),
          if (ordered.isEmpty)
            _emptyNote('No ledger transactions recorded.')
          else
            _ledgerTable(ordered),
          pw.SizedBox(height: 18),
          _finalBalance(wholesaler.outstandingBalance),
        ],
      ),
    );
    return pdf;
  }

  static pw.Widget _header({
    required String shopName,
    required String shopPhone,
    required String shopAddress,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#1B4332'),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'WHOLESALER ACCOUNT STATEMENT',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                'Generated ${_date.format(DateTime.now())}',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 9),
              ),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                _safe(shopName),
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (shopPhone.trim().isNotEmpty)
                pw.Text(
                  _safe(shopPhone),
                  style: const pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 9,
                  ),
                ),
              if (shopAddress.trim().isNotEmpty)
                pw.Text(
                  _safe(shopAddress),
                  style: const pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 9,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _wholesalerBlock(WholesalerStatementProfile w) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColor.fromHex('#C6DEC9')),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            _safe(w.name),
            style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#1B4332'),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Phone: ${_safe(w.phone)}   |   City: ${_safe(w.city)}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
          if (w.address.trim().isNotEmpty)
            pw.Text(
              'Address: ${_safe(w.address)}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
        ],
      ),
    );
  }

  static pw.Widget _summaryRow({
    required double opening,
    required double purchases,
    required double payments,
    required double outstanding,
  }) {
    pw.Widget card(String label, String value, {bool emphasize = false}) {
      return pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(right: 6),
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: emphasize
                ? PdfColor.fromHex('#1B4332')
                : PdfColor.fromHex('#F7F9F4'),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
            border: emphasize
                ? null
                : pw.Border.all(color: PdfColor.fromHex('#C6DEC9')),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                label,
                style: pw.TextStyle(
                  fontSize: 7,
                  fontWeight: pw.FontWeight.bold,
                  color: emphasize ? PdfColors.white : PdfColors.grey700,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: emphasize
                      ? PdfColors.white
                      : PdfColor.fromHex('#1B4332'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return pw.Row(
      children: [
        card('OPENING BALANCE', _rs(opening)),
        card('TOTAL PURCHASES', _rs(purchases)),
        card('TOTAL PAYMENTS', _rs(payments)),
        card('NET OUTSTANDING', _rs(outstanding), emphasize: true),
      ],
    );
  }

  static pw.Widget _sectionTitle(String title) {
    return pw.Text(
      title.toUpperCase(),
      style: pw.TextStyle(
        fontSize: 10,
        fontWeight: pw.FontWeight.bold,
        color: PdfColor.fromHex('#1B4332'),
      ),
    );
  }

  static pw.Widget _emptyNote(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 6),
      child: pw.Text(
        text,
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
      ),
    );
  }

  static pw.Widget _purchasesTable(List<Map<String, dynamic>> rows) {
    return pw.TableHelper.fromTextArray(
      headerDecoration: const pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFF0F4EE),
      ),
      headerStyle: pw.TextStyle(
        fontSize: 8,
        fontWeight: pw.FontWeight.bold,
        color: PdfColor.fromHex('#1B4332'),
      ),
      cellStyle: const pw.TextStyle(fontSize: 8),
      cellAlignment: pw.Alignment.centerLeft,
      headerAlignment: pw.Alignment.centerLeft,
      columnWidths: {
        0: const pw.FlexColumnWidth(1.2),
        1: const pw.FlexColumnWidth(1.4),
        2: const pw.FlexColumnWidth(1.1),
        3: const pw.FlexColumnWidth(1.1),
        4: const pw.FlexColumnWidth(1.1),
      },
      headers: const [
        'Date',
        'Invoice',
        'Transport',
        'Total',
        'Type',
      ],
      data: [
        for (final row in rows)
          [
            _formatDate(row[PurchaseInvoicesTable.dateTime] as String?),
            _safe(row[PurchaseInvoicesTable.invoiceNumber] as String? ?? '-'),
            _rs(
              (row[PurchaseInvoicesTable.transportCharges] as num?)
                      ?.toDouble() ??
                  0,
            ),
            _rs(
              (row[PurchaseInvoicesTable.grandTotal] as num?)?.toDouble() ?? 0,
            ),
            _safe(row[PurchaseInvoicesTable.paymentType] as String? ?? '-'),
          ],
      ],
    );
  }

  static pw.Widget _paymentsTable(List<Map<String, dynamic>> rows) {
    return pw.TableHelper.fromTextArray(
      headerDecoration: const pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFF0F4EE),
      ),
      headerStyle: pw.TextStyle(
        fontSize: 8,
        fontWeight: pw.FontWeight.bold,
        color: PdfColor.fromHex('#1B4332'),
      ),
      cellStyle: const pw.TextStyle(fontSize: 8),
      cellAlignment: pw.Alignment.centerLeft,
      headerAlignment: pw.Alignment.centerLeft,
      headers: const ['Date', 'Reference', 'Amount', 'Method', 'Notes'],
      data: [
        for (final row in rows)
          [
            _formatDate(row[WholesalerPaymentsTable.date] as String?),
            _safe(row[WholesalerPaymentsTable.referenceNo] as String? ?? '-'),
            _rs(
              (row[WholesalerPaymentsTable.amount] as num?)?.toDouble() ?? 0,
            ),
            _safe(row[WholesalerPaymentsTable.paymentMethod] as String? ?? '-'),
            _safe(row[WholesalerPaymentsTable.notes] as String? ?? '-'),
          ],
      ],
    );
  }

  static pw.Widget _ledgerTable(List<Map<String, dynamic>> rows) {
    return pw.TableHelper.fromTextArray(
      headerDecoration: const pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFF0F4EE),
      ),
      headerStyle: pw.TextStyle(
        fontSize: 8,
        fontWeight: pw.FontWeight.bold,
        color: PdfColor.fromHex('#1B4332'),
      ),
      cellStyle: const pw.TextStyle(fontSize: 8),
      cellAlignment: pw.Alignment.centerLeft,
      headerAlignment: pw.Alignment.centerLeft,
      headers: const [
        'Date',
        'Type',
        'Reference',
        'Debit',
        'Credit',
        'Balance',
      ],
      data: [
        for (final row in rows)
          [
            _formatDate(row[WholesalerLedgerTable.date] as String?),
            _safe(row[WholesalerLedgerTable.transactionType] as String? ?? '-'),
            _safe(row[WholesalerLedgerTable.referenceId] as String? ?? '-'),
            _rs((row[WholesalerLedgerTable.debit] as num?)?.toDouble() ?? 0),
            _rs((row[WholesalerLedgerTable.credit] as num?)?.toDouble() ?? 0),
            _rs(
              (row[WholesalerLedgerTable.runningBalance] as num?)?.toDouble() ??
                  0,
            ),
          ],
      ],
    );
  }

  static pw.Widget _finalBalance(double outstanding) {
    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Container(
        width: 220,
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#1B4332'),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'FINAL NET OUTSTANDING',
              style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              _rs(outstanding),
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
