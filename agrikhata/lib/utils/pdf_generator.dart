import 'dart:io';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../models/ledger_models.dart';
import 'shop_settings.dart';

class PdfGenerator {
  static final DateFormat _dateFormat = DateFormat('dd MMM yyyy');
  static final DateFormat _timeFormat = DateFormat('hh:mm a');
  static final NumberFormat _currencyFormat = NumberFormat('#,##,##0');

  /// Branding column used across invoice / statement / voucher headers.
  static pw.Widget _buildBrandBlock({
    required String shopName,
    double titleSize = 22,
    double shopSize = 11,
    PdfColor? titleColor,
    PdfColor? shopColor,
    pw.CrossAxisAlignment align = pw.CrossAxisAlignment.start,
  }) {
    final resolvedTitle = titleColor ?? PdfColors.white;
    final resolvedShop = shopColor ?? PdfColors.white;
    return pw.Column(
      crossAxisAlignment: align,
      children: [
        pw.Text(
          'AgriKhata',
          style: pw.TextStyle(
            color: resolvedTitle,
            fontSize: titleSize,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          shopName,
          style: pw.TextStyle(
            color: resolvedShop,
            fontSize: shopSize,
          ),
        ),
      ],
    );
  }

  static Future<pw.Document> generateInvoicePdf(LedgerEntry entry, {bool isEdited = false}) async {
    final pdf = pw.Document();
    final shopName = await ShopSettings.getShopName();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (isEdited) _buildEditedWatermark(),
              _buildHeader(shopName),
              pw.SizedBox(height: 20),
              _buildInvoiceInfo(entry),
              pw.SizedBox(height: 20),
              _buildItemsTable(entry.items),
              pw.SizedBox(height: 20),
              _buildTotalSection(entry),
              pw.Spacer(),
              _buildFooter(),
            ],
          );
        },
      ),
    );

    return pdf;
  }

  static Future<pw.Document> generateLedgerStatementPdf(
    List<LedgerEntry> entries,
    Season season,
    LedgerType ledgerType,
  ) async {
    final pdf = pw.Document();
    final summary = LedgerSummary.fromEntries(entries);
    final shopName = await ShopSettings.getShopName();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context context) {
          return [
            _buildStatementHeader(season, ledgerType, shopName),
            pw.SizedBox(height: 20),
            _buildSummaryCards(summary, ledgerType),
            pw.SizedBox(height: 20),
            _buildLedgerTable(entries),
            pw.SizedBox(height: 20),
          ];
        },
        footer: (pw.Context context) {
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(top: 10),
            child: pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 10),
            ),
          );
        },
      ),
    );

    return pdf;
  }

  static pw.Widget _buildEditedWatermark() {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(vertical: 12),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#FFF3CD'),
        border: pw.Border.all(
          color: PdfColor.fromHex('#FFC107'),
          width: 2,
        ),
      ),
      child: pw.Center(
        child: pw.Text(
          '** REVISED / EDITED INVOICE **',
          style: pw.TextStyle(
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
            color: PdfColor.fromHex('#856404'),
          ),
        ),
      ),
    );
  }

  static pw.Widget _buildHeader(String shopName) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(20),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#1B4332'),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          _buildBrandBlock(
            shopName: shopName,
            titleSize: 24,
            shopSize: 12,
          ),
          pw.Text(
            'INVOICE',
            style: pw.TextStyle(
              color: PdfColors.white,
              fontSize: 28,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildInvoiceInfo(LedgerEntry entry) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Bill To:',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: PdfColor.fromHex('#1B4332'),
              ),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              entry.stakeholderName,
              style: const pw.TextStyle(fontSize: 14),
            ),
            if (entry.kisaanName != null) ...[
              pw.SizedBox(height: 3),
              pw.Text(
                'Kisaan: ${entry.kisaanName}',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ],
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'Invoice #: ${entry.invoiceNumber}',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              'Date: ${_dateFormat.format(entry.date)}',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.Text(
              'Time: ${_timeFormat.format(entry.date)}',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              'Season: ${entry.season}',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildItemsTable(List<LineItem> items) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
      columnWidths: {
        0: const pw.FlexColumnWidth(3),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(1.5),
        3: const pw.FlexColumnWidth(1.5),
        4: const pw.FlexColumnWidth(1.5),
        5: const pw.FlexColumnWidth(2),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#F7F9F4'),
          ),
          children: [
            _buildTableHeader('Product'),
            _buildTableHeader('Qty'),
            _buildTableHeader('Unit Price'),
            _buildTableHeader('Inc.'),
            _buildTableHeader('Disc.'),
            _buildTableHeader('Total'),
          ],
        ),
        ...items.map((item) => pw.TableRow(
              children: [
                _buildTableCell(item.productName),
                _buildTableCell('${item.quantity} ${item.unit}'),
                _buildTableCell('Rs ${_currencyFormat.format(item.unitPrice)}'),
                _buildTableCell(
                  item.seasonalIncrement > 0
                      ? 'Rs ${_currencyFormat.format(item.seasonalIncrement)}'
                      : '-',
                ),
                _buildTableCell(
                  item.discount > 0
                      ? 'Rs ${_currencyFormat.format(item.discount)}'
                      : '-',
                ),
                _buildTableCell('Rs ${_currencyFormat.format(item.total)}',
                    bold: true),
              ],
            )),
      ],
    );
  }

  static pw.Widget _buildTableHeader(String text) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: PdfColor.fromHex('#1B4332'),
        ),
      ),
    );
  }

  static pw.Widget _buildTableCell(String text, {bool bold = false}) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static pw.Widget _buildTotalSection(LedgerEntry entry) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [
        pw.Container(
          width: 250,
          padding: const pw.EdgeInsets.all(15),
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#F7F9F4'),
            border: pw.Border.all(color: PdfColor.fromHex('#1B4332'), width: 2),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _buildTotalRow('Total Amount:', entry.total, bold: true),
              pw.Divider(color: PdfColor.fromHex('#1B4332')),
              _buildTotalRow('Paid:', entry.paid),
              pw.Divider(color: PdfColor.fromHex('#1B4332')),
              _buildTotalRow('Outstanding:', entry.outstanding,
                  bold: true, highlight: entry.outstanding > 0),
              pw.SizedBox(height: 5),
              pw.Text(
                'Status: ${entry.status.displayName}',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: entry.status == PaymentStatus.paid
                      ? PdfColor.fromHex('#28A745')
                      : entry.status == PaymentStatus.partial
                          ? PdfColor.fromHex('#FFA500')
                          : PdfColor.fromHex('#DC3545'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildTotalRow(
    String label,
    double amount, {
    bool bold = false,
    bool highlight = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
          pw.Text(
            'Rs ${_currencyFormat.format(amount)}',
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: highlight
                  ? PdfColor.fromHex('#DC3545')
                  : PdfColor.fromHex('#000000'),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildStatementHeader(
    Season season,
    LedgerType ledgerType,
    String shopName,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(15),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#1B4332'),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                ledgerType.displayName.toUpperCase(),
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                'Season: ${season.displayName}',
                style: const pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          _buildBrandBlock(
            shopName: shopName,
            titleSize: 16,
            shopSize: 10,
            align: pw.CrossAxisAlignment.end,
          ),
        ],
      ),
    );
  }

  static String formatStakeholderName(LedgerEntry entry) {
    if (entry.isWalkInCustomer) {
      return '${entry.stakeholderName} (Walk-In Customer)';
    }
    return entry.stakeholderName;
  }

  static String formatStakeholderBlock(LedgerEntry entry) {
    final name = formatStakeholderName(entry);
    if (entry.isWalkInCustomer) return name;
    if (entry.kisaanName != null && entry.kisaanName!.trim().isNotEmpty) {
      return '$name\n${entry.kisaanName}';
    }
    return name;
  }

  static pw.Widget _buildSummaryCards(
    LedgerSummary summary,
    LedgerType ledgerType,
  ) {
    switch (ledgerType) {
      case LedgerType.purchases:
        return pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
          children: [
            _buildSummaryCard(
              'Total Volume Purchased',
              'Rs ${_currencyFormat.format(summary.totalVolume)}',
              PdfColor.fromHex('#1B4332'),
            ),
            _buildSummaryCard(
              'Total Cash Paid',
              'Rs ${_currencyFormat.format(summary.totalCashReceived)}',
              PdfColor.fromHex('#28A745'),
            ),
            _buildSummaryCard(
              'Outstanding Debit / Balance',
              'Rs ${_currencyFormat.format(summary.outstandingCredit)}',
              PdfColor.fromHex('#DC3545'),
            ),
          ],
        );
      case LedgerType.sales:
        return pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
          children: [
            _buildSummaryCard(
              'Total Volume Sold',
              'Rs ${_currencyFormat.format(summary.totalVolume)}',
              PdfColor.fromHex('#1B4332'),
            ),
            _buildSummaryCard(
              'Total Cash Received',
              'Rs ${_currencyFormat.format(summary.totalCashReceived)}',
              PdfColor.fromHex('#28A745'),
            ),
            _buildSummaryCard(
              'Outstanding Credit',
              'Rs ${_currencyFormat.format(summary.outstandingCredit)}',
              PdfColor.fromHex('#DC3545'),
            ),
          ],
        );
    }
  }

  static pw.Widget _buildStakeholderCell(LedgerEntry entry) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            formatStakeholderName(entry),
            style: const pw.TextStyle(fontSize: 9),
          ),
          if (!entry.isWalkInCustomer &&
              entry.kisaanName != null &&
              entry.kisaanName!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              entry.kisaanName!,
              style: pw.TextStyle(
                fontSize: 8,
                color: PdfColor.fromHex('#6B8F71'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static pw.Widget _buildSummaryCard(String label, String value, PdfColor color) {
    return pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.symmetric(horizontal: 5),
        padding: const pw.EdgeInsets.all(15),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: color, width: 2),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
        ),
        child: pw.Column(
          children: [
            pw.Text(
              label,
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _buildLedgerTable(List<LedgerEntry> entries) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.5),
        1: const pw.FlexColumnWidth(2),
        2: const pw.FlexColumnWidth(3),
        3: const pw.FlexColumnWidth(1.5),
        4: const pw.FlexColumnWidth(1.5),
        5: const pw.FlexColumnWidth(1.5),
        6: const pw.FlexColumnWidth(1.5),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#F7F9F4'),
          ),
          children: [
            _buildTableHeader('Invoice'),
            _buildTableHeader('Date'),
            _buildTableHeader('Stakeholder'),
            _buildTableHeader('Items'),
            _buildTableHeader('Total'),
            _buildTableHeader('Paid'),
            _buildTableHeader('Status'),
          ],
        ),
        ...entries.map((entry) => pw.TableRow(
              children: [
                _buildTableCell(entry.invoiceNumber),
                _buildTableCell(_dateFormat.format(entry.date)),
                _buildStakeholderCell(entry),
                _buildTableCell('${entry.items.length}'),
                _buildTableCell('Rs ${_currencyFormat.format(entry.total)}'),
                _buildTableCell('Rs ${_currencyFormat.format(entry.paid)}'),
                _buildTableCell(entry.status.displayName),
              ],
            )),
      ],
    );
  }

  static pw.Widget _buildFooter() {
    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: PdfColor.fromHex('#1B4332'), width: 2),
        ),
      ),
      child: pw.Column(
        children: [
          pw.Text(
            'Thank you for your business!',
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#1B4332'),
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Text(
            'For queries, contact: +92 XXX XXXXXXX',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
      ),
    );
  }

  static Future<void> printInvoice(LedgerEntry entry, {bool isEdited = false}) async {
    final pdf = await generateInvoicePdf(entry, isEdited: isEdited);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  static Future<File> saveInvoiceToFile(LedgerEntry entry, {bool isEdited = false}) async {
    final pdf = await generateInvoicePdf(entry, isEdited: isEdited);
    final bytes = await pdf.save();
    final output = await getTemporaryDirectory();
    final safeInvoice = entry.invoiceNumber.replaceAll(RegExp(r'[^\w\-.]'), '_');
    final file = File(p.join(output.path, 'invoice_$safeInvoice.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<pw.Document> generateConsolidatedLedgerPdf({
    required List<LedgerEntry> salesEntries,
    required List<LedgerEntry> purchasesEntries,
    required List<PaymentLedgerEntry> paymentEntries,
    required Season season,
  }) async {
    final pdf = pw.Document();
    final salesSummary = LedgerSummary.fromEntries(salesEntries);
    final purchasesSummary = LedgerSummary.fromEntries(purchasesEntries);
    final paymentSummary = PaymentSummary.fromEntries(paymentEntries);
    final shopName = await ShopSettings.getShopName();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context context) {
          return [
            _buildConsolidatedCover(season, shopName),
            pw.SizedBox(height: 24),
            _buildStatementHeader(season, LedgerType.sales, shopName),
            pw.SizedBox(height: 12),
            _buildSummaryCards(salesSummary, LedgerType.sales),
            pw.SizedBox(height: 12),
            _buildLedgerTable(salesEntries),
            pw.SizedBox(height: 28),
            _buildStatementHeader(season, LedgerType.purchases, shopName),
            pw.SizedBox(height: 12),
            _buildSummaryCards(purchasesSummary, LedgerType.purchases),
            pw.SizedBox(height: 12),
            _buildLedgerTable(purchasesEntries),
            pw.SizedBox(height: 28),
            _buildPaymentsStatementHeader(season, shopName),
            pw.SizedBox(height: 12),
            _buildPaymentSummaryCards(paymentSummary),
            pw.SizedBox(height: 12),
            _buildPaymentsTable(paymentEntries),
          ];
        },
        footer: (pw.Context context) {
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(top: 10),
            child: pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 10),
            ),
          );
        },
      ),
    );

    return pdf;
  }

  static pw.Widget _buildConsolidatedCover(Season season, String shopName) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(20),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#1B4332'),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'CONSOLIDATED FINANCE LEDGER',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                'Season: ${season.displayName}',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 12),
              ),
              pw.Text(
                'Sales · Purchases · Payments',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
              ),
            ],
          ),
          _buildBrandBlock(
            shopName: shopName,
            titleSize: 16,
            shopSize: 10,
            align: pw.CrossAxisAlignment.end,
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildPaymentsStatementHeader(
    Season season,
    String shopName,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(15),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#2D6A4F'),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'PAYMENTS LEDGER',
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                'Season: ${season.displayName}',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 12),
              ),
            ],
          ),
          _buildBrandBlock(
            shopName: shopName,
            titleSize: 16,
            shopSize: 10,
            align: pw.CrossAxisAlignment.end,
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildPaymentSummaryCards(PaymentSummary summary) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
      children: [
        _buildSummaryCard(
          'Total Payments Received',
          'Rs ${_currencyFormat.format(summary.totalPaymentsReceived)}',
          PdfColor.fromHex('#1B4332'),
        ),
        _buildSummaryCard(
          'Total Advance Collected',
          'Rs ${_currencyFormat.format(summary.totalAdvanceCollected)}',
          PdfColor.fromHex('#2D6A4F'),
        ),
        _buildSummaryCard(
          'Total Wallet Deductions',
          'Rs ${_currencyFormat.format(summary.totalWalletDeductions)}',
          PdfColor.fromHex('#1565C0'),
        ),
      ],
    );
  }

  static pw.Widget _buildPaymentsTable(List<PaymentLedgerEntry> entries) {
    if (entries.isEmpty) {
      return pw.Text(
        'No payment settlements recorded for this season.',
        style: const pw.TextStyle(fontSize: 11),
      );
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.5),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(2),
        3: const pw.FlexColumnWidth(1.5),
        4: const pw.FlexColumnWidth(1.5),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#E8F4EA'),
          ),
          children: [
            _buildTableHeader('Receipt'),
            _buildTableHeader('Invoice Linked'),
            _buildTableHeader('Stakeholder'),
            _buildTableHeader('Amount'),
            _buildTableHeader('Method'),
          ],
        ),
        ...entries.map(
          (entry) => pw.TableRow(
            children: [
              _buildTableCell(entry.paymentId),
              _buildTableCell(entry.invoiceNumber ?? 'Advance Collection'),
              _buildTableCell(
                entry.kisaanName != null
                    ? '${entry.zamindarName}\n${entry.kisaanName}'
                    : entry.zamindarName,
              ),
              _buildTableCell(
                'Rs ${_currencyFormat.format(entry.amountPaid)}',
                bold: true,
              ),
              _buildTableCell(entry.paymentMethod),
            ],
          ),
        ),
      ],
    );
  }

  static Future<File> saveConsolidatedLedgerToDocuments({
    required List<LedgerEntry> salesEntries,
    required List<LedgerEntry> purchasesEntries,
    required List<PaymentLedgerEntry> paymentEntries,
    required Season season,
  }) async {
    final pdf = await generateConsolidatedLedgerPdf(
      salesEntries: salesEntries,
      purchasesEntries: purchasesEntries,
      paymentEntries: paymentEntries,
      season: season,
    );
    final bytes = await pdf.save();
    if (bytes.isEmpty) {
      throw StateError('Generated PDF is empty.');
    }

    Directory output;
    try {
      final downloads = await getDownloadsDirectory();
      output = downloads ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      output = await getApplicationDocumentsDirectory();
    }
    await output.create(recursive: true);

    final fileName = buildExportFileName(
      prefix: 'agrikhata_ledger',
      subject: 'consolidated',
      seasonLabel: season.displayName,
    );
    final file = File(p.join(output.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('Failed to write PDF to ${file.path}');
    }
    return file;
  }

  static String buildWhatsAppShareMessage({
    required Season season,
    required LedgerSummary salesSummary,
    required LedgerSummary purchasesSummary,
    required PaymentSummary paymentSummary,
    required String filePath,
  }) {
    return 'AgriKhata Consolidated Ledger — ${season.displayName}\n\n'
        'Sales Volume: Rs ${_currencyFormat.format(salesSummary.totalVolume)}\n'
        'Sales Cash Received: Rs ${_currencyFormat.format(salesSummary.totalCashReceived)}\n'
        'Sales Outstanding: Rs ${_currencyFormat.format(salesSummary.outstandingCredit)}\n\n'
        'Purchases Volume: Rs ${_currencyFormat.format(purchasesSummary.totalVolume)}\n'
        'Purchases Cash Paid: Rs ${_currencyFormat.format(purchasesSummary.totalCashReceived)}\n\n'
        'Payments Received: Rs ${_currencyFormat.format(paymentSummary.totalPaymentsReceived)}\n'
        'Advance Collected: Rs ${_currencyFormat.format(paymentSummary.totalAdvanceCollected)}\n'
        'Wallet Deductions: Rs ${_currencyFormat.format(paymentSummary.totalWalletDeductions)}\n\n'
        'PDF saved at:\n$filePath';
  }

  // ===== ADVANCE PAYMENT RECEIPT =====

  static Future<pw.Document> generateAdvancePaymentReceiptPdf({
    String? shopName,
    required String zamindarName,
    required int amount,
    required DateTime date,
  }) async {
    final pdf = pw.Document();
    final resolvedShopName =
        (shopName == null || shopName.trim().isEmpty)
            ? await ShopSettings.getShopName()
            : shopName.trim();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          80 * PdfPageFormat.mm,
          120 * PdfPageFormat.mm,
        ),
        build: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(10),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Text(
                  'AgriKhata',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  resolvedShopName,
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
                pw.SizedBox(height: 5),
                pw.Container(
                  width: double.infinity,
                  height: 1,
                  color: PdfColors.grey600,
                ),
                pw.SizedBox(height: 10),
                pw.Text(
                  'ADVANCE PAYMENT RECEIPT',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
                pw.SizedBox(height: 15),
                _buildReceiptRow('Date:', _dateFormat.format(date)),
                _buildReceiptRow('Time:', _timeFormat.format(date)),
                pw.SizedBox(height: 10),
                pw.Container(
                  width: double.infinity,
                  height: 0.5,
                  color: PdfColors.grey400,
                ),
                pw.SizedBox(height: 10),
                _buildReceiptRow('Received From:', zamindarName),
                pw.SizedBox(height: 15),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(
                      color: PdfColor.fromHex('#1B4332'),
                      width: 2,
                    ),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(5),
                    ),
                  ),
                  child: pw.Column(
                    children: [
                      pw.Text(
                        'AMOUNT RECEIVED',
                        style: const pw.TextStyle(
                          fontSize: 9,
                          color: PdfColors.grey700,
                        ),
                      ),
                      pw.SizedBox(height: 5),
                      pw.Text(
                        'Rs ${_currencyFormat.format(amount)}',
                        style: pw.TextStyle(
                          fontSize: 18,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#1B4332'),
                        ),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 15),
                pw.Container(
                  width: double.infinity,
                  height: 0.5,
                  color: PdfColors.grey400,
                ),
                pw.SizedBox(height: 10),
                _buildReceiptRow('Payment Type:', 'Advance Deposit'),
                pw.SizedBox(height: 10),
                pw.Text(
                  'This advance will be adjusted against future purchases',
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
                pw.Spacer(),
                pw.Container(
                  width: double.infinity,
                  height: 0.5,
                  color: PdfColors.grey400,
                ),
                pw.SizedBox(height: 5),
                pw.Text(
                  'Thank you for your trust!',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
              ],
            ),
          );
        },
      ),
    );

    return pdf;
  }

  static pw.Widget _buildReceiptRow(String label, String value) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          label,
          style: const pw.TextStyle(
            fontSize: 9,
            color: PdfColors.grey700,
          ),
        ),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ],
    );
  }

  static Future<void> printAdvancePaymentReceipt({
    String? shopName,
    required String zamindarName,
    required int amount,
    required DateTime date,
  }) async {
    final resolvedShopName = shopName ?? await ShopSettings.getShopName();
    final pdf = await generateAdvancePaymentReceiptPdf(
      shopName: resolvedShopName,
      zamindarName: zamindarName,
      amount: amount,
      date: date,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  // ===== ZAMINDAR PROFILE LEDGER =====

  static Future<pw.Document> generateZamindarLedgerPdf({
    required String zamindarName,
    required String seasonLabel,
    required List<Map<String, dynamic>> transactions,
    required String outstandingBalance,
    required int totalPaymentsReceived,
    required int totalDebit,
  }) async {
    final pdf = pw.Document();
    final shopName = await ShopSettings.getShopName();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context context) {
          return [
            pw.Container(
              padding: const pw.EdgeInsets.all(16),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#1B4332'),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'ZAMINDAR LEDGER',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 20,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        zamindarName,
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 13,
                        ),
                      ),
                      pw.Text(
                        'Season: $seasonLabel',
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  _buildBrandBlock(
                    shopName: shopName,
                    titleSize: 14,
                    shopSize: 9,
                    align: pw.CrossAxisAlignment.end,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
              children: [
                _buildSummaryCard(
                  'Total Sales (Debit)',
                  'Rs ${_currencyFormat.format(totalDebit)}',
                  PdfColor.fromHex('#A32D2D'),
                ),
                _buildSummaryCard(
                  'Payments Received',
                  'Rs ${_currencyFormat.format(totalPaymentsReceived)}',
                  PdfColor.fromHex('#0C447C'),
                ),
                _buildSummaryCard(
                  'Outstanding',
                  outstandingBalance,
                  PdfColor.fromHex('#27500A'),
                ),
              ],
            ),
            pw.SizedBox(height: 16),
            if (transactions.isEmpty)
              pw.Text(
                'No ledger entries for this filter.',
                style: const pw.TextStyle(fontSize: 11),
              )
            else
              pw.Table(
                border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.1),
                  1: const pw.FlexColumnWidth(1.4),
                  2: const pw.FlexColumnWidth(2.8),
                  3: const pw.FlexColumnWidth(1.1),
                  4: const pw.FlexColumnWidth(0.9),
                  5: const pw.FlexColumnWidth(1.1),
                },
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#E8F4EA'),
                    ),
                    children: [
                      _buildTableHeader('Date'),
                      _buildTableHeader('Kisaan'),
                      _buildTableHeader('Description'),
                      _buildTableHeader('Category'),
                      _buildTableHeader('Type'),
                      _buildTableHeader('Amount'),
                    ],
                  ),
                  ...transactions.map((row) {
                    final type = row['type'] as String? ?? '';
                    final amount =
                        (row['amount'] as num?)?.toDouble() ?? 0.0;
                    final description =
                        row['description'] as String? ?? '';
                    final category =
                        (row['category'] as String? ?? '').toUpperCase();
                    final kisaanName =
                        (row['kisaan_name'] as String?)?.trim() ?? '';
                    final dateRaw = row['date_time'] as String? ?? '';
                    DateTime? parsed;
                    try {
                      parsed = DateTime.parse(dateRaw);
                    } catch (_) {}
                    final dateLabel = parsed != null
                        ? _dateFormat.format(parsed)
                        : dateRaw;
                    return pw.TableRow(
                      children: [
                        _buildTableCell(dateLabel),
                        _buildTableCell(
                          kisaanName.isEmpty ? '—' : kisaanName,
                        ),
                        _buildTableCell(description),
                        _buildTableCell(category),
                        _buildTableCell(type.toUpperCase()),
                        _buildTableCell(
                          'Rs ${_currencyFormat.format(amount)}',
                          bold: true,
                        ),
                      ],
                    );
                  }),
                ],
              ),
          ];
        },
        footer: (pw.Context context) {
          return pw.Container(
            alignment: pw.Alignment.centerRight,
            margin: const pw.EdgeInsets.only(top: 10),
            child: pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 10),
            ),
          );
        },
      ),
    );

    return pdf;
  }

  static Future<File> saveZamindarLedgerToDocuments({
    required String zamindarName,
    required String seasonLabel,
    required List<Map<String, dynamic>> transactions,
    required String outstandingBalance,
    required int totalPaymentsReceived,
    required int totalDebit,
  }) async {
    final pdf = await generateZamindarLedgerPdf(
      zamindarName: zamindarName,
      seasonLabel: seasonLabel,
      transactions: transactions,
      outstandingBalance: outstandingBalance,
      totalPaymentsReceived: totalPaymentsReceived,
      totalDebit: totalDebit,
    );
    final bytes = await pdf.save();
    if (bytes.isEmpty) {
      throw StateError('Generated PDF is empty.');
    }

    // Prefer Downloads when available so the file is easy to find on Windows.
    Directory output;
    try {
      final downloads = await getDownloadsDirectory();
      output = downloads ?? await getApplicationDocumentsDirectory();
    } catch (_) {
      output = await getApplicationDocumentsDirectory();
    }
    await output.create(recursive: true);

    final fileName = buildExportFileName(
      prefix: 'agrikhata_ledger',
      subject: zamindarName,
      seasonLabel: seasonLabel,
    );
    final filePath = p.join(output.path, fileName);
    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);

    if (!await file.exists() || await file.length() == 0) {
      throw StateError('Failed to write PDF to ${file.path}');
    }
    return file;
  }

  /// Example: agrikhata_ledger_Atta_Muhammad_Kharif 2026_1_52_AM_7_11_26.pdf
  static String buildExportFileName({
    required String prefix,
    required String subject,
    required String seasonLabel,
    DateTime? at,
  }) {
    final now = at ?? DateTime.now();
    final safeSubject = subject
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final safeSeason = seasonLabel
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final minute = now.minute.toString().padLeft(2, '0');
    final ampm = now.hour >= 12 ? 'PM' : 'AM';
    final yy = (now.year % 100).toString().padLeft(2, '0');
    final subjectPart = safeSubject.isEmpty ? 'export' : safeSubject;
    final seasonPart = safeSeason.isEmpty ? 'All' : safeSeason;
    return '${prefix}_${subjectPart}_${seasonPart}_${hour12}_${minute}_${ampm}_${now.month}_${now.day}_$yy.pdf';
  }

  static Future<void> printDocument(pw.Document pdf) async {
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }
}
