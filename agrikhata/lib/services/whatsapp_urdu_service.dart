import 'dart:io';

import 'package:agrikhata/utils/pdf_share.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Localized Urdu WhatsApp messaging helpers for reminders, PDF statements,
/// and post-sale receipts.
class WhatsAppUrduService {
  WhatsAppUrduService._();

  static final NumberFormat _amountFormat = NumberFormat('#,##,##0');

  /// Developer contact promo appended to WhatsApp text receipts only
  /// (never to PDF documents).
  static const String receiptPromoFooter =
      'WhatsApp: 03331245518\n\n'
      '(اپنے کاروبار کا سافٹ ویئر بنوانے کے لیے رابطہ کریں)';

  /// Formats [amount] as `Rs 1,23,456` for Urdu message bodies.
  static String formatAmount(double amount) =>
      'Rs ${_amountFormat.format(amount.round())}';

  /// Converts local Pakistani numbers (e.g. `03001234567`) to international
  /// digits without `+` (e.g. `923001234567`) for `wa.me` links.
  static String? normalizePhone(String? raw) {
    if (raw == null) return null;
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;

    if (digits.startsWith('00')) {
      digits = digits.substring(2);
    }
    if (digits.startsWith('0') && digits.length == 11) {
      digits = '92${digits.substring(1)}';
    } else if (digits.length == 10 && digits.startsWith('3')) {
      digits = '92$digits';
    }

    if (digits.length < 10) return null;
    return digits;
  }

  /// Builds the standard outstanding-balance reminder (exact template).
  static String buildUrduReminderText({
    required String zamindarName,
    required String shopName,
    required double amount,
  }) {
    final name = zamindarName.trim().isEmpty ? 'محترم' : zamindarName.trim();
    final shop = shopName.trim().isEmpty ? 'AgriKhata' : shopName.trim();
    final rs = formatAmount(amount);

    return 'السلام علیکم $name صاحب،\n\n'
        'امید ہے آپ خیریت سے ہوں گے۔ $shop کی طرف سے یاد دہانی کرائی جاتی ہے '
        'کہ آپ کا بقایا کھاتہ $rs واجب الادا ہے۔\n\n'
        'براہ کرم جلد از جلد رقم جمع کروائیں یا دکان پر تشریف لائیں۔\n\n'
        'شکریہ!\n'
        '$shop';
  }

  /// Builds the PDF statement caption (exact template).
  static String buildUrduPdfCaption({
    required String zamindarName,
    required String shopName,
    required double amount,
    List<String>? detailLines,
  }) {
    final name = zamindarName.trim().isEmpty ? 'محترم' : zamindarName.trim();
    final shop = shopName.trim().isEmpty ? 'AgriKhata' : shopName.trim();
    final rs = formatAmount(amount);

    final buffer = StringBuffer()
      ..writeln('السلام علیکم $name صاحب،')
      ..writeln()
      ..writeln(
        '$shop کی طرف سے آپ کے کھاتے کی تفصیلی رپورٹ (PDF) ارسال کی جا رہی ہے۔',
      )
      ..writeln();

    if (detailLines != null && detailLines.isNotEmpty) {
      for (final line in detailLines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        buffer.writeln(trimmed);
      }
      buffer.writeln();
    }

    buffer
      ..writeln('مجموعی واجب الادا رقم: $rs')
      ..writeln()
      ..writeln('شکریہ!')
      ..write(shop);

    return buffer.toString();
  }

  /// Builds a post-sale Urdu receipt summary with invoice + line items.
  static String buildSaleReceiptText({
    required String zamindarName,
    required String shopName,
    required String invoiceNo,
    required double totalAmount,
    required List<String> itemsSummary,
    String? servedBy,
  }) {
    final name = zamindarName.trim().isEmpty ? 'محترم' : zamindarName.trim();
    final shop = shopName.trim().isEmpty ? 'AgriKhata' : shopName.trim();
    final rs = formatAmount(totalAmount);
    final invoice = invoiceNo.trim().isEmpty ? '—' : invoiceNo.trim();

    final buffer = StringBuffer()
      ..writeln('السلام علیکم $name صاحب،')
      ..writeln()
      ..writeln('$shop کی طرف سے آپ کی فروخت کی رسید پیش خدمت ہے۔')
      ..writeln()
      ..writeln('انوائس نمبر: $invoice');

    final server = servedBy?.trim() ?? '';
    if (server.isNotEmpty) {
      buffer.writeln('Recorded By: $server');
    }
    buffer.writeln();

    if (itemsSummary.isNotEmpty) {
      buffer.writeln('تفصیل:');
      for (final line in itemsSummary) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        buffer.writeln('• $trimmed');
      }
      buffer.writeln();
    }

    buffer
      ..writeln('کل رقم: $rs')
      ..writeln()
      ..writeln('شکریہ!')
      ..writeln(shop)
      ..writeln()
      ..write(receiptPromoFooter);

    return buffer.toString();
  }

  /// Opens WhatsApp chat with the standard Urdu outstanding reminder.
  static Future<bool> sendUrduReminder({
    required String phone,
    required String zamindarName,
    required String shopName,
    required double amount,
  }) async {
    final text = buildUrduReminderText(
      zamindarName: zamindarName,
      shopName: shopName,
      amount: amount,
    );
    return _launchWhatsAppChat(phone: phone, text: text);
  }

  /// Shares a PDF file with the standard Urdu statement caption via
  /// `Share.shareXFiles` (routed through [PdfShare] for Windows reliability).
  ///
  /// [phone] is retained for API consistency / call-site validation; the PDF
  /// itself is delivered through the system share sheet (pick WhatsApp there).
  static Future<bool> sharePdfWithUrduCaption({
    required String phone,
    required String zamindarName,
    required String shopName,
    required double amount,
    required String pdfPath,
    List<String>? detailLines,
    String? subject,
  }) async {
    final caption = buildUrduPdfCaption(
      zamindarName: zamindarName,
      shopName: shopName,
      amount: amount,
      detailLines: detailLines,
    );

    final file = File(pdfPath);
    if (!await file.exists()) {
      throw StateError('PDF file does not exist: $pdfPath');
    }

    await PdfShare.sharePdfFile(
      file: file,
      // Include normalized phone hint in subject when available (share sheet).
      text: caption,
      subject: subject ??
          (normalizePhone(phone) != null
              ? 'AgriKhata کھاتہ رپورٹ ($phone)'
              : 'AgriKhata کھاتہ رپورٹ'),
    );

    return true;
  }

  /// Opens WhatsApp with a post-sale Urdu receipt summary.
  static Future<bool> sendSaleReceipt({
    required String phone,
    required String zamindarName,
    required String shopName,
    required String invoiceNo,
    required double totalAmount,
    required List<String> itemsSummary,
    String? servedBy,
  }) async {
    final text = buildSaleReceiptText(
      zamindarName: zamindarName,
      shopName: shopName,
      invoiceNo: invoiceNo,
      totalAmount: totalAmount,
      itemsSummary: itemsSummary,
      servedBy: servedBy,
    );
    return _launchWhatsAppChat(phone: phone, text: text);
  }

  /// Sends an itemized Kisaan balances summary under a Zamindar (Urdu).
  static Future<bool> sendKisaanSummaryLedger({
    required String phone,
    required String zamindarName,
    required String shopName,
    required double amount,
    required List<String> kisaanLines,
  }) async {
    final name = zamindarName.trim().isEmpty ? 'محترم' : zamindarName.trim();
    final shop = shopName.trim().isEmpty ? 'AgriKhata' : shopName.trim();
    final rs = formatAmount(amount);

    final buffer = StringBuffer()
      ..writeln('السلام علیکم $name صاحب،')
      ..writeln()
      ..writeln('$shop کی طرف سے کسانوں کے کھاتے کا خلاصہ پیش خدمت ہے:')
      ..writeln();

    if (kisaanLines.isEmpty) {
      buffer.writeln('• کوئی کسان ریکارڈ نہیں ملا');
    } else {
      for (final line in kisaanLines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        buffer.writeln('• $trimmed');
      }
    }

    buffer
      ..writeln()
      ..writeln('مجموعی واجب الادا رقم: $rs')
      ..writeln()
      ..writeln('شکریہ!')
      ..write(shop);

    return _launchWhatsAppChat(phone: phone, text: buffer.toString());
  }

  /// Low-level helper: share an arbitrary PDF path with caption via share_plus.
  /// Prefer [sharePdfWithUrduCaption] for the standard Urdu template.
  static Future<void> sharePdfFileRaw({
    required String pdfPath,
    required String caption,
    String? subject,
  }) async {
    final xFile = XFile(pdfPath, mimeType: 'application/pdf');
    await Share.shareXFiles(
      [xFile],
      text: caption,
      subject: subject ?? 'AgriKhata PDF',
    );
  }

  static Future<bool> _launchWhatsAppChat({
    required String phone,
    required String text,
  }) async {
    final normalized = normalizePhone(phone);
    if (normalized == null) {
      return false;
    }

    final uri = Uri.parse(
      'https://wa.me/$normalized?text=${Uri.encodeComponent(text)}',
    );

    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
