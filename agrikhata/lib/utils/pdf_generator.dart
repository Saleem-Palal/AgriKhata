import 'dart:io';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../models/ledger_models.dart';
import '../Database/database_helper.dart' show SaleJoinColumns;
import 'receipt_acknowledgment.dart';
import 'shop_settings.dart';

class PdfGenerator {
  static final DateFormat _dateFormat = DateFormat('dd MMM yyyy');
  static final DateFormat _timeFormat = DateFormat('hh:mm a');
  static final DateFormat _dateTimeFormat = DateFormat('dd MMM yyyy, hh:mm a');
  static final NumberFormat _currencyFormat = NumberFormat('#,##,##0');

  /// Strips characters outside Latin-1 and replaces common Unicode punctuation.
  static String _pdfSafeText(String input) {
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
      if ((rune >= 0x20 && rune <= 0x7E) ||
          (rune >= 0xA0 && rune <= 0xFF)) {
        buffer.writeCharCode(rune);
      }
    }

    final result = buffer.toString();
    if (result.isEmpty) return '-';
    return result;
  }

  static pw.Widget _buildHeartIcon({double size = 8, PdfColor? color}) {
    final heartColor = color ?? PdfColor.fromHex('#E53935');
    return pw.SizedBox(
      width: size,
      height: size,
      child: pw.CustomPaint(
        size: PdfPoint(size, size),
        painter: (PdfGraphics canvas, PdfPoint canvasSize) {
          // PDF Y-axis grows upward — tip at bottom, lobes at top.
          final w = canvasSize.x;
          final h = canvasSize.y;
          canvas.setFillColor(heartColor);
          canvas.moveTo(w * 0.50, h * 0.12);
          canvas.curveTo(
            w * -0.05,
            h * 0.45,
            w * 0.05,
            h * 0.95,
            w * 0.50,
            h * 0.68,
          );
          canvas.curveTo(
            w * 0.95,
            h * 0.95,
            w * 1.05,
            h * 0.45,
            w * 0.50,
            h * 0.12,
          );
          canvas.closePath();
          canvas.fillPath();
        },
      ),
    );
  }

  static pw.Widget _buildMadeWithAgriKhata({
    PdfColor? textColor,
    double fontSize = 6,
  }) {
    final resolvedColor = textColor ?? PdfColors.grey700;
    final style = pw.TextStyle(fontSize: fontSize, color: resolvedColor);
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text('Built With ', style: style),
        _buildHeartIcon(size: fontSize, color: PdfColor.fromHex('#E53935')),
        pw.SizedBox(width: 1.5),
        pw.Text(
          'by Saleem Palal · WA 03331245518',
          style: style,
        ),
      ],
    );
  }

  static Future<({String name, String phone, String address})>
      _loadShopBranding() async {
    final name = await ShopSettings.getShopName();
    final phone = await ShopSettings.getShopPhone();
    final address = await ShopSettings.getShopAddress();
    return (name: name, phone: phone, address: address);
  }

  static pw.Widget _buildDocumentFooter(
    pw.Context context, {
    String? docLabel,
  }) {
    final pageText = docLabel != null && docLabel.trim().isNotEmpty
        ? 'Page ${context.pageNumber} of ${context.pagesCount} - ${_pdfSafeText(docLabel)}'
        : 'Page ${context.pageNumber} of ${context.pagesCount}';
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          _buildMadeWithAgriKhata(),
          pw.Text(
            pageText,
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
      ),
    );
  }

  /// Branding column: AgriKhata, shop name, then optional phone/address.
  static pw.Widget _buildBrandBlock({
    required String shopName,
    String shopPhone = '',
    String shopAddress = '',
    double brandSize = 10,
    double shopTitleSize = 14,
    double contactSize = 8,
    PdfColor? brandColor,
    PdfColor? shopColor,
    PdfColor? contactColor,
    pw.CrossAxisAlignment align = pw.CrossAxisAlignment.start,
  }) {
    final resolvedBrand = brandColor ?? PdfColors.white;
    final resolvedShop = shopColor ?? PdfColors.white;
    final resolvedContact = contactColor ?? resolvedShop;
    final phone = shopPhone.trim();
    final address = shopAddress.trim();
    return pw.Column(
      crossAxisAlignment: align,
      children: [
        pw.Text(
          'AgriKhata',
          style: pw.TextStyle(
            color: resolvedBrand,
            fontSize: brandSize,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          _pdfSafeText(shopName),
          style: pw.TextStyle(
            color: resolvedShop,
            fontSize: shopTitleSize,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        if (phone.isNotEmpty) ...[
          pw.SizedBox(height: 2),
          pw.Text(
            _pdfSafeText(phone),
            style: pw.TextStyle(
              color: resolvedContact,
              fontSize: contactSize,
            ),
          ),
        ],
        if (address.isNotEmpty) ...[
          pw.SizedBox(height: 1),
          pw.Text(
            _pdfSafeText(address),
            style: pw.TextStyle(
              color: resolvedContact,
              fontSize: contactSize - 0.5,
            ),
          ),
        ],
      ],
    );
  }

  static Future<Directory> _resolveOutputDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      final output = downloads ?? await getApplicationDocumentsDirectory();
      await output.create(recursive: true);
      return output;
    } catch (_) {
      final output = await getApplicationDocumentsDirectory();
      await output.create(recursive: true);
      return output;
    }
  }

  static Future<File> _writePdfBytes({
    required List<int> bytes,
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      throw StateError('Generated PDF is empty.');
    }
    final output = await _resolveOutputDirectory();
    final file = File(p.join(output.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('Failed to write PDF to ${file.path}');
    }
    return file;
  }

  static String _formatMoney(num value) {
    return 'Rs ${_currencyFormat.format(value.round())}';
  }

  static String _formatDateTimeValue(dynamic value) {
    if (value == null) return '-';
    if (value is DateTime) {
      return _pdfSafeText(_dateTimeFormat.format(value));
    }
    final raw = value.toString().trim();
    if (raw.isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      return _pdfSafeText(_dateTimeFormat.format(parsed));
    }
    return _pdfSafeText(raw);
  }

  static String _formatDateValue(dynamic value) {
    if (value == null) return '-';
    if (value is DateTime) {
      return _pdfSafeText(_dateFormat.format(value));
    }
    final raw = value.toString().trim();
    if (raw.isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      return _pdfSafeText(_dateFormat.format(parsed));
    }
    return _pdfSafeText(raw);
  }

  static Future<pw.Document> generateInvoicePdf(
    LedgerEntry entry, {
    bool isEdited = false,
  }) async {
    final pdf = pw.Document();
    final shop = await _loadShopBranding();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (isEdited) _buildEditedWatermark(),
              _buildHeader(
                shop.name,
                shopPhone: shop.phone,
                shopAddress: shop.address,
              ),
              pw.SizedBox(height: 20),
              _buildInvoiceInfo(entry),
              pw.SizedBox(height: 20),
              _buildItemsTable(entry.items),
              pw.SizedBox(height: 20),
              _buildTotalSection(entry),
              pw.Spacer(),
              _buildFooter(shopPhone: shop.phone),
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
    final shop = await _loadShopBranding();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context context) {
          return [
            _buildStatementHeader(
              season,
              ledgerType,
              shop.name,
              shopPhone: shop.phone,
              shopAddress: shop.address,
            ),
            pw.SizedBox(height: 20),
            _buildSummaryCards(summary, ledgerType),
            pw.SizedBox(height: 20),
            _buildLedgerTable(entries),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(context),
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

  static pw.Widget _buildHeader(
    String shopName, {
    String shopPhone = '',
    String shopAddress = '',
  }) {
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
            shopPhone: shopPhone,
            shopAddress: shopAddress,
            brandSize: 11,
            shopTitleSize: 16,
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
              _pdfSafeText(entry.stakeholderName),
              style: const pw.TextStyle(fontSize: 14),
            ),
            if (entry.kisaanName != null) ...[
              pw.SizedBox(height: 3),
              pw.Text(
                'Kisaan: ${_pdfSafeText(entry.kisaanName!)}',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ],
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'Invoice #: ${_pdfSafeText(entry.invoiceNumber)}',
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
              'Season: ${_pdfSafeText(entry.season)}',
              style: const pw.TextStyle(fontSize: 10),
            ),
            if (entry.createdByUserName != null &&
                entry.createdByUserName!.trim().isNotEmpty) ...[
              pw.SizedBox(height: 5),
              pw.Text(
                'Recorded By: ${_pdfSafeText(entry.createdByUserName!.trim())}',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromHex('#1B4332'),
                ),
              ),
            ],
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
        ...items.map(
          (item) => pw.TableRow(
            children: [
              _buildTableCell(_pdfSafeText(item.productName)),
              _buildTableCell(
                '${item.quantity} ${_pdfSafeText(item.unit)}',
              ),
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
              _buildTableCell(
                'Rs ${_currencyFormat.format(item.total)}',
                bold: true,
              ),
            ],
          ),
        ),
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
        _pdfSafeText(text),
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static pw.Widget _buildTotalSection(LedgerEntry entry) {
    final summaryChildren = <pw.Widget>[];

    if (entry.hasSaleDiscountBreakdown) {
      summaryChildren.addAll([
        _buildTotalRow('Gross Subtotal:', entry.grossSubtotal!),
        if ((entry.itemDiscountsTotal ?? 0) > 0)
          _buildTotalRow('Item Discount:', entry.itemDiscountsTotal!),
        if ((entry.overallDiscount ?? 0) > 0)
          _buildTotalRow('Overall Discount:', entry.overallDiscount!),
        pw.Divider(color: PdfColor.fromHex('#1B4332')),
        _buildTotalRow('Net Payable:', entry.netPayable, bold: true),
      ]);
    } else {
      summaryChildren.add(_buildTotalRow('Total Amount:', entry.total, bold: true));
    }

    summaryChildren.addAll([
      pw.Divider(color: PdfColor.fromHex('#1B4332')),
      _buildTotalRow('Paid:', entry.paid),
      pw.Divider(color: PdfColor.fromHex('#1B4332')),
      _buildTotalRow(
        'Outstanding:',
        entry.outstanding,
        bold: true,
        highlight: entry.outstanding > 0,
      ),
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
    ]);

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
            children: summaryChildren,
          ),
        ),
      ],
    );
  }

  static String _formatSaleDiscountDetail({
    required double grossSubtotal,
    required double itemDiscountsTotal,
    required double overallDiscount,
    required double netPayable,
  }) {
    final parts = <String>[
      'Subtotal: Rs ${_currencyFormat.format(grossSubtotal)}',
    ];
    if (itemDiscountsTotal > 0) {
      parts.add(
        'Item Disc: Rs ${_currencyFormat.format(itemDiscountsTotal)}',
      );
    }
    if (overallDiscount > 0) {
      parts.add(
        'Overall Disc: Rs ${_currencyFormat.format(overallDiscount)}',
      );
    }
    parts.add('Net: Rs ${_currencyFormat.format(netPayable)}');
    return parts.join(' · ');
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
    String shopName, {
    String shopPhone = '',
    String shopAddress = '',
  }) {
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
                'Season: ${_pdfSafeText(season.displayName)}',
                style: const pw.TextStyle(
                  color: PdfColors.white,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          _buildBrandBlock(
            shopName: shopName,
            shopPhone: shopPhone,
            shopAddress: shopAddress,
            brandSize: 10,
            shopTitleSize: 14,
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
            _pdfSafeText(formatStakeholderName(entry)),
            style: const pw.TextStyle(fontSize: 9),
          ),
          if (!entry.isWalkInCustomer &&
              entry.kisaanName != null &&
              entry.kisaanName!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              _pdfSafeText(entry.kisaanName!),
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

  static pw.Widget _buildSummaryCard(
    String label,
    String value,
    PdfColor color,
  ) {
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
              _pdfSafeText(value),
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
    final tableRows = <pw.TableRow>[
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
    ];

    for (final entry in entries) {
      tableRows.add(
        pw.TableRow(
          children: [
            _buildTableCell(entry.invoiceNumber),
            _buildTableCell(_dateFormat.format(entry.date)),
            _buildStakeholderCell(entry),
            _buildTableCell('${entry.items.length}'),
            _buildTableCell('Rs ${_currencyFormat.format(entry.total)}'),
            _buildTableCell('Rs ${_currencyFormat.format(entry.paid)}'),
            _buildTableCell(entry.status.displayName),
          ],
        ),
      );
      if (entry.hasSaleDiscountBreakdown) {
        tableRows.add(
          pw.TableRow(
            children: [
              _buildTableCell(''),
              _buildTableCell(''),
              _buildTableCell(''),
              _buildTableCell(
                _formatSaleDiscountDetail(
                  grossSubtotal: entry.grossSubtotal!,
                  itemDiscountsTotal: entry.itemDiscountsTotal ?? 0,
                  overallDiscount: entry.overallDiscount ?? 0,
                  netPayable: entry.netPayable,
                ),
              ),
              _buildTableCell(''),
              _buildTableCell(''),
              _buildTableCell(''),
            ],
          ),
        );
      }
    }

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
      children: tableRows,
    );
  }

  static pw.Widget _buildFooter({String shopPhone = ''}) {
    final phone = shopPhone.trim();
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
          if (phone.isNotEmpty) ...[
            pw.SizedBox(height: 5),
            pw.Text(
              'For queries, contact: ${_pdfSafeText(phone)}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
          pw.SizedBox(height: 8),
          _buildMadeWithAgriKhata(textColor: PdfColor.fromHex('#1B4332')),
        ],
      ),
    );
  }

  static Future<void> printInvoice(
    LedgerEntry entry, {
    bool isEdited = false,
  }) async {
    final pdf = await generateInvoicePdf(entry, isEdited: isEdited);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  static Future<File> saveInvoiceToFile(
    LedgerEntry entry, {
    bool isEdited = false,
  }) async {
    final pdf = await generateInvoicePdf(entry, isEdited: isEdited);
    final bytes = await pdf.save();
    final output = await getTemporaryDirectory();
    final safeInvoice =
        entry.invoiceNumber.replaceAll(RegExp(r'[^\w\-.]'), '_');
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
    final shop = await _loadShopBranding();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        build: (pw.Context context) {
          return [
            _buildConsolidatedCover(
              season,
              shop.name,
              shopPhone: shop.phone,
              shopAddress: shop.address,
            ),
            pw.SizedBox(height: 24),
            _buildStatementHeader(
              season,
              LedgerType.sales,
              shop.name,
              shopPhone: shop.phone,
              shopAddress: shop.address,
            ),
            pw.SizedBox(height: 12),
            _buildSummaryCards(salesSummary, LedgerType.sales),
            pw.SizedBox(height: 12),
            _buildLedgerTable(salesEntries),
            pw.SizedBox(height: 28),
            _buildStatementHeader(
              season,
              LedgerType.purchases,
              shop.name,
              shopPhone: shop.phone,
              shopAddress: shop.address,
            ),
            pw.SizedBox(height: 12),
            _buildSummaryCards(purchasesSummary, LedgerType.purchases),
            pw.SizedBox(height: 12),
            _buildLedgerTable(purchasesEntries),
            pw.SizedBox(height: 28),
            _buildPaymentsStatementHeader(
              season,
              shop.name,
              shopPhone: shop.phone,
              shopAddress: shop.address,
            ),
            pw.SizedBox(height: 12),
            _buildPaymentSummaryCards(paymentSummary),
            pw.SizedBox(height: 12),
            _buildPaymentsTable(paymentEntries),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(context),
      ),
    );

    return pdf;
  }

  static pw.Widget _buildConsolidatedCover(
    Season season,
    String shopName, {
    String shopPhone = '',
    String shopAddress = '',
  }) {
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
                'Season: ${_pdfSafeText(season.displayName)}',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 12),
              ),
              pw.Text(
                'Sales - Purchases - Payments',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
              ),
            ],
          ),
          _buildBrandBlock(
            shopName: shopName,
            shopPhone: shopPhone,
            shopAddress: shopAddress,
            brandSize: 10,
            shopTitleSize: 14,
            align: pw.CrossAxisAlignment.end,
          ),
        ],
      ),
    );
  }

  static pw.Widget _buildPaymentsStatementHeader(
    Season season,
    String shopName, {
    String shopPhone = '',
    String shopAddress = '',
  }) {
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
                'Season: ${_pdfSafeText(season.displayName)}',
                style: const pw.TextStyle(color: PdfColors.white, fontSize: 12),
              ),
            ],
          ),
          _buildBrandBlock(
            shopName: shopName,
            shopPhone: shopPhone,
            shopAddress: shopAddress,
            brandSize: 10,
            shopTitleSize: 14,
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
        0: const pw.FlexColumnWidth(1.2),
        1: const pw.FlexColumnWidth(2.2),
        2: const pw.FlexColumnWidth(1.2),
        3: const pw.FlexColumnWidth(1.5),
        4: const pw.FlexColumnWidth(1.2),
        5: const pw.FlexColumnWidth(1.2),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#E8F4EA'),
          ),
          children: [
            _buildTableHeader('Receipt'),
            _buildTableHeader('Description'),
            _buildTableHeader('Invoice Linked'),
            _buildTableHeader('Stakeholder'),
            _buildTableHeader('Amount'),
            _buildTableHeader('Method'),
          ],
        ),
        ...entries.map(
          (entry) {
            final description = entry.invoiceNumber != null &&
                    entry.invoiceNumber!.trim().isNotEmpty
                ? formatBillPaymentDescription(entry.invoiceNumber)
                : entry.itemsSummary;
            return pw.TableRow(
              children: [
                _buildTableCell(entry.paymentId),
                _buildTableCell(description),
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
            );
          },
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
    final fileName = buildExportFileName(
      prefix: 'agrikhata_ledger',
      subject: 'consolidated',
      seasonLabel: season.displayName,
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
  }

  static String buildWhatsAppShareMessage({
    required Season season,
    required LedgerSummary salesSummary,
    required LedgerSummary purchasesSummary,
    required PaymentSummary paymentSummary,
    required String filePath,
  }) {
    return 'AgriKhata Consolidated Ledger - ${season.displayName}\n\n'
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
    String? servedBy,
  }) async {
    final pdf = pw.Document();
    final resolvedShopName =
        (shopName == null || shopName.trim().isEmpty)
            ? await ShopSettings.getShopName()
            : shopName.trim();
    final shopPhone = await ShopSettings.getShopPhone();
    final shopAddress = await ShopSettings.getShopAddress();
    final showThumb =
        await ShopSettings.getShowThumbprintBlockOnThermal();
    final pageHeightMm = showThumb ? 235.0 : 160.0;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          80 * PdfPageFormat.mm,
          pageHeightMm * PdfPageFormat.mm,
        ),
        build: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(10),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Center(
                  child: _buildBrandBlock(
                    shopName: resolvedShopName,
                    shopPhone: shopPhone,
                    shopAddress: shopAddress,
                    brandSize: 10,
                    shopTitleSize: 13,
                    contactSize: 8,
                    brandColor: PdfColors.black,
                    shopColor: PdfColors.black,
                    contactColor: PdfColors.grey800,
                    align: pw.CrossAxisAlignment.center,
                  ),
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
                _buildReceiptRow(
                  'Received From:',
                  _pdfSafeText(zamindarName),
                ),
                if (servedBy != null && servedBy.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 6),
                  _buildReceiptRow(
                    'Recorded By:',
                    _pdfSafeText(servedBy.trim()),
                  ),
                ],
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
                if (showThumb) ...[
                  pw.SizedBox(height: 12),
                  ReceiptAcknowledgment.buildThermalBlock(),
                ],
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
                ReceiptAcknowledgment.buildThermalPromoFooter(),
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
          _pdfSafeText(value),
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
    String? servedBy,
  }) async {
    final resolvedShopName = shopName ?? await ShopSettings.getShopName();
    final pdf = await generateAdvancePaymentReceiptPdf(
      shopName: resolvedShopName,
      zamindarName: zamindarName,
      amount: amount,
      date: date,
      servedBy: servedBy,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  // ===== BILL SETTLEMENT RECEIPT =====

  static String formatBillPaymentDescription(String? invoiceNumber) {
    final trimmed = (invoiceNumber ?? '').trim();
    return trimmed.isEmpty ? 'Bill Payment' : 'Bill Payment for $trimmed';
  }

  static String formatBillPaymentDescriptionForInvoices(
    List<String> invoiceNumbers,
  ) {
    final unique = invoiceNumbers
        .map((invoice) => invoice.trim())
        .where((invoice) => invoice.isNotEmpty)
        .toList();
    if (unique.isEmpty) return 'Bill Payment';
    return 'Bill Payment for ${unique.join(', ')}';
  }

  static Future<pw.Document> generateBillSettlementReceiptPdf({
    String? shopName,
    required String zamindarName,
    required String kisaanName,
    required int amount,
    required List<String> invoiceNumbers,
    required List<BillSettlementInvoiceSummary> invoiceSummaries,
    required DateTime date,
    String? paymentMethod,
  }) async {
    final pdf = pw.Document();
    final resolvedShopName =
        (shopName == null || shopName.trim().isEmpty)
            ? await ShopSettings.getShopName()
            : shopName.trim();
    final shopPhone = await ShopSettings.getShopPhone();
    final shopAddress = await ShopSettings.getShopAddress();
    final showThumb =
        await ShopSettings.getShowThumbprintBlockOnThermal();
    final summaries = invoiceSummaries.isNotEmpty
        ? invoiceSummaries
        : invoiceNumbers
            .map(
              (invoice) => BillSettlementInvoiceSummary(
                invoiceNumber: invoice,
                cashPaidNow: invoiceNumbers.length == 1 ? amount.toDouble() : 0,
                totalPaidCash: 0,
                remainingBalance: 0,
                invoiceTotal: 0,
              ),
            )
            .toList();
    final invoiceBlockMm = 46.0;
    final baseHeightMm = showThumb ? 188.0 : 138.0;
    final pageHeightMm =
        baseHeightMm + summaries.length * invoiceBlockMm + (showThumb ? 40.0 : 0);
    final invoiceLabel = formatBillPaymentDescriptionForInvoices(invoiceNumbers);
    final method = (paymentMethod ?? 'Cash').trim();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          80 * PdfPageFormat.mm,
          pageHeightMm * PdfPageFormat.mm,
        ),
        build: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(10),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Center(
                  child: _buildBrandBlock(
                    shopName: resolvedShopName,
                    shopPhone: shopPhone,
                    shopAddress: shopAddress,
                    brandSize: 10,
                    shopTitleSize: 13,
                    contactSize: 8,
                    brandColor: PdfColors.black,
                    shopColor: PdfColors.black,
                    contactColor: PdfColors.grey800,
                    align: pw.CrossAxisAlignment.center,
                  ),
                ),
                pw.SizedBox(height: 5),
                pw.Container(
                  width: double.infinity,
                  height: 1,
                  color: PdfColors.grey600,
                ),
                pw.SizedBox(height: 10),
                pw.Text(
                  'BILL SETTLEMENT RECEIPT',
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
                _buildReceiptRow(
                  'Received From:',
                  _pdfSafeText(zamindarName),
                ),
                pw.SizedBox(height: 6),
                _buildReceiptRow(
                  'Kisaan Account:',
                  _pdfSafeText(kisaanName),
                ),
                pw.SizedBox(height: 6),
                _buildReceiptRow('Payment Method:', _pdfSafeText(method)),
                pw.SizedBox(height: 6),
                _buildReceiptRow('Description:', _pdfSafeText(invoiceLabel)),
                pw.SizedBox(height: 12),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 10,
                  ),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#E8F4EA'),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text(
                        'Cash Paid Now',
                        style: pw.TextStyle(
                          fontSize: 11,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Text(
                        'Rs ${_currencyFormat.format(amount)}',
                        style: pw.TextStyle(
                          fontSize: 14,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#27500A'),
                        ),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 12),
                ...summaries.expand((summary) {
                  return [
                    pw.Container(
                      width: double.infinity,
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(
                          color: PdfColor.fromHex('#D8E6DA'),
                        ),
                        borderRadius:
                            const pw.BorderRadius.all(pw.Radius.circular(4)),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'Invoice: ${_pdfSafeText(summary.invoiceNumber)}',
                            style: pw.TextStyle(
                              fontSize: 9,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          pw.SizedBox(height: 6),
                          _buildReceiptRow(
                            'Cash Paid Now:',
                            'Rs ${_currencyFormat.format(summary.cashPaidNow.round())}',
                          ),
                          _buildReceiptRow(
                            'Total Paid Cash:',
                            'Rs ${_currencyFormat.format(summary.totalPaidCash.round())}',
                          ),
                          _buildReceiptRow(
                            'Remaining Balance:',
                            'Rs ${_currencyFormat.format(summary.remainingBalance.round())}',
                          ),
                        ],
                      ),
                    ),
                    pw.SizedBox(height: 8),
                  ];
                }),
                if (showThumb) ...[
                  pw.SizedBox(height: 8),
                  pw.Text(
                    'Received with thanks',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                  pw.SizedBox(height: 24),
                  pw.Container(
                    width: 80,
                    height: 0.5,
                    color: PdfColors.grey600,
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'Thumb Impression',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );

    return pdf;
  }

  static Future<File> saveBillSettlementReceiptToDocuments({
    String? shopName,
    required String zamindarName,
    required String kisaanName,
    required int amount,
    required List<String> invoiceNumbers,
    required List<BillSettlementInvoiceSummary> invoiceSummaries,
    required DateTime date,
    String? paymentMethod,
  }) async {
    final pdf = await generateBillSettlementReceiptPdf(
      shopName: shopName,
      zamindarName: zamindarName,
      kisaanName: kisaanName,
      amount: amount,
      invoiceNumbers: invoiceNumbers,
      invoiceSummaries: invoiceSummaries,
      date: date,
      paymentMethod: paymentMethod,
    );
    final bytes = await pdf.save();
    final fileName = buildExportFileName(
      prefix: 'agrikhata_settlement',
      subject: zamindarName,
      seasonLabel: _dateFormat.format(date),
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
  }

  static Future<void> printBillSettlementReceipt({
    String? shopName,
    required String zamindarName,
    required String kisaanName,
    required int amount,
    required List<String> invoiceNumbers,
    required List<BillSettlementInvoiceSummary> invoiceSummaries,
    required DateTime date,
    String? paymentMethod,
  }) async {
    final resolvedShopName = shopName ?? await ShopSettings.getShopName();
    final pdf = await generateBillSettlementReceiptPdf(
      shopName: resolvedShopName,
      zamindarName: zamindarName,
      kisaanName: kisaanName,
      amount: amount,
      invoiceNumbers: invoiceNumbers,
      invoiceSummaries: invoiceSummaries,
      date: date,
      paymentMethod: paymentMethod,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
    );
  }

  // ===== SALES-INVOICE ZAMINDAR LEDGER =====

  static Future<pw.Document> generateZamindarLedgerPdf({
    required String zamindarName,
    required String seasonLabel,
    required List<Map<String, dynamic>> rows,
    required String outstandingBalance,
    required double cumulativeRemaining,
  }) async {
    final pdf = pw.Document();
    final shop = await _loadShopBranding();

    final totalBilled = rows.fold<double>(
      0,
      (sum, row) => sum + ((row['total'] as num?)?.toDouble() ?? 0),
    );
    final totalPaid = rows.fold<double>(
      0,
      (sum, row) => sum + ((row['paid'] as num?)?.toDouble() ?? 0),
    );

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
                        _pdfSafeText(zamindarName),
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 13,
                        ),
                      ),
                      pw.Text(
                        'Season: ${_pdfSafeText(seasonLabel)}',
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  _buildBrandBlock(
                    shopName: shop.name,
                    shopPhone: shop.phone,
                    shopAddress: shop.address,
                    brandSize: 10,
                    shopTitleSize: 14,
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
                  'Invoices',
                  '${rows.length}',
                  PdfColor.fromHex('#1B4332'),
                ),
                _buildSummaryCard(
                  'Total Billed',
                  _formatMoney(totalBilled),
                  PdfColor.fromHex('#A32D2D'),
                ),
                _buildSummaryCard(
                  'Total Paid',
                  _formatMoney(totalPaid),
                  PdfColor.fromHex('#0C447C'),
                ),
                _buildSummaryCard(
                  'Cumulative Remaining',
                  _formatMoney(cumulativeRemaining),
                  PdfColor.fromHex('#27500A'),
                ),
              ],
            ),
            pw.SizedBox(height: 8),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Text(
                  'Outstanding: ${_pdfSafeText(outstandingBalance)}',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromHex('#27500A'),
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 16),
            if (rows.isEmpty)
              pw.Text(
                'No ledger entries for this filter.',
                style: const pw.TextStyle(fontSize: 11),
              )
            else
              _buildSalesInvoiceLedgerTable(
                rows: rows,
                totalBilled: totalBilled,
                totalPaid: totalPaid,
                cumulativeRemaining: cumulativeRemaining,
              ),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(
          context,
          docLabel: 'AgriKhata Zamindar Ledger',
        ),
      ),
    );

    return pdf;
  }

  static pw.Widget _buildSalesInvoiceLedgerTable({
    required List<Map<String, dynamic>> rows,
    required double totalBilled,
    required double totalPaid,
    required double cumulativeRemaining,
  }) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.0),
        1: const pw.FlexColumnWidth(1.4),
        2: const pw.FlexColumnWidth(1.2),
        3: const pw.FlexColumnWidth(1.8),
        4: const pw.FlexColumnWidth(1.0),
        5: const pw.FlexColumnWidth(1.2),
        6: const pw.FlexColumnWidth(0.9),
        7: const pw.FlexColumnWidth(0.9),
        8: const pw.FlexColumnWidth(0.9),
        9: const pw.FlexColumnWidth(0.9),
      },
      children: [
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#E8F4EA'),
          ),
          children: [
            _buildTableHeader('Inv-No'),
            _buildTableHeader('Date/Time'),
            _buildTableHeader('Kisaan'),
            _buildTableHeader('Products'),
            _buildTableHeader('Products Qty'),
            _buildTableHeader('Cost / Product'),
            _buildTableHeader('Payment'),
            _buildTableHeader('Total'),
            _buildTableHeader('Paid'),
            _buildTableHeader('Remaining'),
          ],
        ),
        ...rows.expand((row) {
          final total = (row['total'] as num?)?.toDouble() ?? 0;
          final paid = (row['paid'] as num?)?.toDouble() ?? 0;
          final remaining = (row['remaining'] as num?)?.toDouble() ?? 0;
          final subtotal = (row['subtotal'] as num?)?.toDouble() ?? total;
          final itemDiscountsTotal =
              (row['item_discounts_total'] as num?)?.toDouble() ?? 0;
          final overallDiscount =
              (row['overall_discount'] as num?)?.toDouble() ?? 0;
          final hasDiscountDetail = subtotal > 0;

          final mainRow = pw.TableRow(
            children: [
              _buildTableCell(row['invoice_number']?.toString() ?? '-'),
              _buildTableCell(_formatDateTimeValue(row['date_time'])),
              _buildTableCell(row['kisaan_name']?.toString() ?? '-'),
              _buildTableCell(row['products']?.toString() ?? '-'),
              _buildTableCell(row['products_qty']?.toString() ?? '-'),
              _buildTableCell(row['cost_per_product']?.toString() ?? '-'),
              _buildTableCell(row['payment_type']?.toString() ?? '-'),
              _buildTableCell(_formatMoney(total), bold: true),
              _buildTableCell(_formatMoney(paid)),
              _buildTableCell(_formatMoney(remaining)),
            ],
          );

          if (!hasDiscountDetail) return [mainRow];

          return [
            mainRow,
            pw.TableRow(
              children: [
                _buildTableCell(''),
                _buildTableCell(''),
                _buildTableCell(''),
                _buildTableCell(
                  _formatSaleDiscountDetail(
                    grossSubtotal: subtotal,
                    itemDiscountsTotal: itemDiscountsTotal,
                    overallDiscount: overallDiscount,
                    netPayable: total,
                  ),
                ),
                _buildTableCell(''),
                _buildTableCell(''),
                _buildTableCell(''),
                _buildTableCell(''),
                _buildTableCell(''),
                _buildTableCell(''),
              ],
            ),
          ];
        }),
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#F7F9F4'),
          ),
          children: [
            _buildTableCell('Cumulative', bold: true),
            _buildTableCell(''),
            _buildTableCell(''),
            _buildTableCell(''),
            _buildTableCell(''),
            _buildTableCell(''),
            _buildTableCell(''),
            _buildTableCell(_formatMoney(totalBilled), bold: true),
            _buildTableCell(_formatMoney(totalPaid), bold: true),
            _buildTableCell(_formatMoney(cumulativeRemaining), bold: true),
          ],
        ),
      ],
    );
  }

  static Future<File> saveZamindarLedgerToDocuments({
    required String zamindarName,
    required String seasonLabel,
    required List<Map<String, dynamic>> rows,
    required String outstandingBalance,
    required double cumulativeRemaining,
  }) async {
    final pdf = await generateZamindarLedgerPdf(
      zamindarName: zamindarName,
      seasonLabel: seasonLabel,
      rows: rows,
      outstandingBalance: outstandingBalance,
      cumulativeRemaining: cumulativeRemaining,
    );
    final bytes = await pdf.save();
    final fileName = buildExportFileName(
      prefix: 'agrikhata_ledger',
      subject: zamindarName,
      seasonLabel: seasonLabel,
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
  }

  // ===== TRANSACTION-STYLE ZAMINDAR LEDGER =====

  static Future<pw.Document> generateZamindarTransactionLedgerPdf({
    required String zamindarName,
    required String seasonLabel,
    required List<Map<String, dynamic>> transactions,
    required String outstandingBalance,
    required int totalPaymentsReceived,
    required int totalDebit,
  }) async {
    final pdf = pw.Document();
    final shop = await _loadShopBranding();

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
                        _pdfSafeText(zamindarName),
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 13,
                        ),
                      ),
                      pw.Text(
                        'Season: ${_pdfSafeText(seasonLabel)}',
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  _buildBrandBlock(
                    shopName: shop.name,
                    shopPhone: shop.phone,
                    shopAddress: shop.address,
                    brandSize: 10,
                    shopTitleSize: 14,
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
                  _formatMoney(totalDebit),
                  PdfColor.fromHex('#A32D2D'),
                ),
                _buildSummaryCard(
                  'Payments Received',
                  _formatMoney(totalPaymentsReceived),
                  PdfColor.fromHex('#0C447C'),
                ),
                _buildSummaryCard(
                  'Outstanding',
                  _pdfSafeText(outstandingBalance),
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
                  ...transactions.expand((row) {
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

                    final isSaleDebit =
                        category == 'SALE' && type == 'DEBIT';
                    final grossSubtotal =
                        (row[SaleJoinColumns.subtotal] as num?)?.toDouble();
                    final itemDiscountsTotal =
                        (row[SaleJoinColumns.itemDiscountsTotal] as num?)
                                ?.toDouble() ??
                            0;
                    final overallDiscount =
                        (row[SaleJoinColumns.overallDiscount] as num?)
                                ?.toDouble() ??
                            0;
                    final hasDiscountDetail =
                        isSaleDebit && grossSubtotal != null;

                    final mainRow = pw.TableRow(
                      children: [
                        _buildTableCell(dateLabel),
                        _buildTableCell(
                          kisaanName.isEmpty ? '-' : kisaanName,
                        ),
                        _buildTableCell(description),
                        _buildTableCell(category),
                        _buildTableCell(type.toUpperCase()),
                        _buildTableCell(
                          _formatMoney(amount),
                          bold: true,
                        ),
                      ],
                    );

                    if (!hasDiscountDetail) return [mainRow];

                    final saleSubtotal = grossSubtotal ?? 0;

                    return [
                      mainRow,
                      pw.TableRow(
                        children: [
                          _buildTableCell(''),
                          _buildTableCell(''),
                          _buildTableCell(
                            _formatSaleDiscountDetail(
                              grossSubtotal: saleSubtotal,
                              itemDiscountsTotal: itemDiscountsTotal,
                              overallDiscount: overallDiscount,
                              netPayable: amount,
                            ),
                          ),
                          _buildTableCell(''),
                          _buildTableCell(''),
                          _buildTableCell(''),
                        ],
                      ),
                    ];
                  }),
                ],
              ),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(
          context,
          docLabel: 'AgriKhata Transaction Ledger',
        ),
      ),
    );

    return pdf;
  }

  static Future<File> saveZamindarTransactionLedgerToDocuments({
    required String zamindarName,
    required String seasonLabel,
    required List<Map<String, dynamic>> transactions,
    required String outstandingBalance,
    required int totalPaymentsReceived,
    required int totalDebit,
  }) async {
    final pdf = await generateZamindarTransactionLedgerPdf(
      zamindarName: zamindarName,
      seasonLabel: seasonLabel,
      transactions: transactions,
      outstandingBalance: outstandingBalance,
      totalPaymentsReceived: totalPaymentsReceived,
      totalDebit: totalDebit,
    );
    final bytes = await pdf.save();
    final fileName = buildExportFileName(
      prefix: 'agrikhata_ledger',
      subject: zamindarName,
      seasonLabel: seasonLabel,
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
  }

  // ===== KISAAN SUMMARY PDF =====

  static Future<pw.Document> generateKisaanSummaryPdf({
    required String zamindarName,
    required List<Map<String, dynamic>> rows,
  }) async {
    final pdf = pw.Document();
    final shop = await _loadShopBranding();

    final cumulativeTotal = rows.fold<double>(
      0,
      (sum, row) => sum + ((row['balance_due'] as num?)?.toDouble() ?? 0),
    );

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
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'KISAAN SUMMARY',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 20,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        _pdfSafeText(zamindarName),
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  _buildBrandBlock(
                    shopName: shop.name,
                    shopPhone: shop.phone,
                    shopAddress: shop.address,
                    brandSize: 10,
                    shopTitleSize: 14,
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
                  'Total Kisaans',
                  '${rows.length}',
                  PdfColor.fromHex('#1B4332'),
                ),
                _buildSummaryCard(
                  'Cumulative Balance Due',
                  _formatMoney(cumulativeTotal),
                  PdfColor.fromHex('#DC3545'),
                ),
              ],
            ),
            pw.SizedBox(height: 16),
            if (rows.isEmpty)
              pw.Text(
                'No kisaans to include in this summary.',
                style: const pw.TextStyle(fontSize: 11),
              )
            else
              pw.Table(
                border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
                columnWidths: {
                  0: const pw.FlexColumnWidth(2),
                  1: const pw.FlexColumnWidth(1.5),
                  2: const pw.FlexColumnWidth(1),
                  3: const pw.FlexColumnWidth(1.5),
                  4: const pw.FlexColumnWidth(1.5),
                  5: const pw.FlexColumnWidth(1.2),
                },
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#E8F4EA'),
                    ),
                    children: [
                      _buildTableHeader('Kisaan Name'),
                      _buildTableHeader('Plot Location'),
                      _buildTableHeader('Athaas'),
                      _buildTableHeader('Current Crop'),
                      _buildTableHeader('Last Purchase'),
                      _buildTableHeader('Balance Due'),
                    ],
                  ),
                  ...rows.map((row) {
                    final balance =
                        (row['balance_due'] as num?)?.toDouble() ?? 0;
                    return pw.TableRow(
                      children: [
                        _buildTableCell(row['name']?.toString() ?? '-'),
                        _buildTableCell(row['village']?.toString() ?? '-'),
                        _buildTableCell(row['athaas']?.toString() ?? '-'),
                        _buildTableCell(row['current_crop']?.toString() ?? '-'),
                        _buildTableCell(
                          _formatDateValue(row['last_purchase_date']),
                        ),
                        _buildTableCell(_formatMoney(balance), bold: true),
                      ],
                    );
                  }),
                  pw.TableRow(
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#F7F9F4'),
                    ),
                    children: [
                      _buildTableCell('Cumulative Total', bold: true),
                      _buildTableCell(''),
                      _buildTableCell(''),
                      _buildTableCell(''),
                      _buildTableCell(''),
                      _buildTableCell(
                        _formatMoney(cumulativeTotal),
                        bold: true,
                      ),
                    ],
                  ),
                ],
              ),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(
          context,
          docLabel: 'AgriKhata Kisaan Summary',
        ),
      ),
    );

    return pdf;
  }

  static Future<File> saveKisaanSummaryToDocuments({
    required String zamindarName,
    required List<Map<String, dynamic>> rows,
  }) async {
    final pdf = await generateKisaanSummaryPdf(
      zamindarName: zamindarName,
      rows: rows,
    );
    final bytes = await pdf.save();
    final fileName = buildExportFileName(
      prefix: 'agrikhata_kisaan_summary',
      subject: zamindarName,
      seasonLabel: 'All',
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
  }

  // ===== PRODUCT-WISE LEDGER PDF =====

  static Future<pw.Document> generateProductWiseLedgerPdf({
    required String zamindarName,
    required List<Map<String, dynamic>> rows,
    String filterLabel = 'All products',
    int totalQuantity = 0,
    String totalUom = 'units',
    int totalValue = 0,
  }) async {
    final pdf = pw.Document();
    final shop = await _loadShopBranding();

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
                        'PRODUCT-WISE LEDGER',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 20,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        _pdfSafeText(zamindarName),
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 13,
                        ),
                      ),
                      pw.Text(
                        'Filter: ${_pdfSafeText(filterLabel)}',
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  _buildBrandBlock(
                    shopName: shop.name,
                    shopPhone: shop.phone,
                    shopAddress: shop.address,
                    brandSize: 10,
                    shopTitleSize: 14,
                    align: pw.CrossAxisAlignment.end,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.end,
              children: [
                pw.Text(
                  'Total Quantity: $totalQuantity ${_pdfSafeText(totalUom)}'
                  '  ·  Total Value: ${_formatMoney(totalValue)}',
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromHex('#1B4332'),
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 12),
            if (rows.isEmpty)
              pw.Text(
                'No product ledger rows to export.',
                style: const pw.TextStyle(fontSize: 11),
              )
            else
              pw.Table(
                border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
                columnWidths: {
                  0: const pw.FlexColumnWidth(1.2),
                  1: const pw.FlexColumnWidth(1.5),
                  2: const pw.FlexColumnWidth(1.5),
                  3: const pw.FlexColumnWidth(1.8),
                  4: const pw.FlexColumnWidth(1),
                  5: const pw.FlexColumnWidth(1.1),
                  6: const pw.FlexColumnWidth(1.2),
                },
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#E8F4EA'),
                    ),
                    children: [
                      _buildTableHeader('Invoice No'),
                      _buildTableHeader('Date/Time'),
                      _buildTableHeader('Kisaan Name'),
                      _buildTableHeader('Product Name'),
                      _buildTableHeader('Quantity'),
                      _buildTableHeader('Product Price'),
                      _buildTableHeader('Total Price'),
                    ],
                  ),
                  ...rows.map((row) {
                    final qty = row['quantity'];
                    final uom = row['uom']?.toString() ?? '';
                    final qtyLabel = qty == null
                        ? '-'
                        : '$qty${uom.isNotEmpty ? ' $uom' : ''}';
                    final unitPrice =
                        (row['unit_price'] as num?)?.toDouble() ?? 0;
                    final lineTotal =
                        (row['line_total'] as num?)?.toDouble() ?? 0;
                    return pw.TableRow(
                      children: [
                        _buildTableCell(
                          row['invoice_number']?.toString() ?? '-',
                        ),
                        _buildTableCell(
                          _formatDateTimeValue(row['date_time']),
                        ),
                        _buildTableCell(row['kisaan_name']?.toString() ?? '-'),
                        _buildTableCell(
                          row['product_name']?.toString() ?? '-',
                        ),
                        _buildTableCell(qtyLabel),
                        _buildTableCell(_formatMoney(unitPrice)),
                        _buildTableCell(_formatMoney(lineTotal)),
                      ],
                    );
                  }),
                ],
              ),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(
          context,
          docLabel: 'AgriKhata Product Ledger',
        ),
      ),
    );

    return pdf;
  }

  static Future<File> saveProductWiseLedgerToDocuments({
    required String zamindarName,
    required List<Map<String, dynamic>> rows,
    String filterLabel = 'All products',
    int totalQuantity = 0,
    String totalUom = 'units',
    int totalValue = 0,
  }) async {
    final pdf = await generateProductWiseLedgerPdf(
      zamindarName: zamindarName,
      rows: rows,
      filterLabel: filterLabel,
      totalQuantity: totalQuantity,
      totalUom: totalUom,
      totalValue: totalValue,
    );
    final bytes = await pdf.save();
    final fileName = buildExportFileName(
      prefix: 'agrikhata_product_ledger',
      subject: zamindarName,
      seasonLabel: filterLabel,
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
  }

  // ===== STOCKED PRODUCTS PDF =====

  static Future<pw.Document> generateStockedProductsPdf({
    required List<Map<String, dynamic>> products,
  }) async {
    final pdf = pw.Document();
    final shop = await _loadShopBranding();

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
                        'STOCKED PRODUCTS',
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 20,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        '${products.length} products in stock',
                        style: const pw.TextStyle(
                          color: PdfColors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  _buildBrandBlock(
                    shopName: shop.name,
                    shopPhone: shop.phone,
                    shopAddress: shop.address,
                    brandSize: 10,
                    shopTitleSize: 14,
                    align: pw.CrossAxisAlignment.end,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            if (products.isEmpty)
              pw.Text(
                'No stocked products to export.',
                style: const pw.TextStyle(fontSize: 11),
              )
            else
              pw.Table(
                border: pw.TableBorder.all(color: PdfColor.fromHex('#E0E0E0')),
                columnWidths: {
                  0: const pw.FlexColumnWidth(2),
                  1: const pw.FlexColumnWidth(1.2),
                  2: const pw.FlexColumnWidth(1.2),
                  3: const pw.FlexColumnWidth(1),
                  4: const pw.FlexColumnWidth(1),
                  5: const pw.FlexColumnWidth(0.8),
                  6: const pw.FlexColumnWidth(0.7),
                  7: const pw.FlexColumnWidth(1),
                  8: const pw.FlexColumnWidth(0.8),
                  9: const pw.FlexColumnWidth(0.9),
                },
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#E8F4EA'),
                    ),
                    children: [
                      _buildTableHeader('Product Name'),
                      _buildTableHeader('Brand'),
                      _buildTableHeader('Type'),
                      _buildTableHeader('Pack Size'),
                      _buildTableHeader('Retail Price'),
                      _buildTableHeader('Stock'),
                      _buildTableHeader('UOM'),
                      _buildTableHeader('Expiry'),
                      _buildTableHeader('Threshold'),
                      _buildTableHeader('Status'),
                    ],
                  ),
                  ...products.map((product) {
                    final retailPrice =
                        (product['retail_price'] as num?)?.toDouble();
                    final stock = product['available_stock'];
                    final threshold = product['low_stock_threshold'];
                    return pw.TableRow(
                      children: [
                        _buildTableCell(product['name']?.toString() ?? '-'),
                        _buildTableCell(product['brand']?.toString() ?? '-'),
                        _buildTableCell(
                          product['product_type']?.toString() ?? '-',
                        ),
                        _buildTableCell(
                          product['packaging_size']?.toString() ?? '-',
                        ),
                        _buildTableCell(
                          retailPrice != null
                              ? _formatMoney(retailPrice)
                              : '-',
                        ),
                        _buildTableCell(stock?.toString() ?? '-'),
                        _buildTableCell(product['uom']?.toString() ?? '-'),
                        _buildTableCell(
                          _formatDateValue(product['expiry_date']),
                        ),
                        _buildTableCell(threshold?.toString() ?? '-'),
                        _buildTableCell(product['status']?.toString() ?? '-'),
                      ],
                    );
                  }),
                ],
              ),
          ];
        },
        footer: (pw.Context context) => _buildDocumentFooter(
          context,
          docLabel: 'AgriKhata Stock Report',
        ),
      ),
    );

    return pdf;
  }

  static Future<File> saveStockedProductsToDocuments({
    required List<Map<String, dynamic>> products,
  }) async {
    final pdf = await generateStockedProductsPdf(products: products);
    final bytes = await pdf.save();
    final fileName = buildExportFileName(
      prefix: 'agrikhata_stock',
      subject: 'products',
      seasonLabel: 'All',
    );
    return _writePdfBytes(bytes: bytes, fileName: fileName);
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
