import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Shared physical ink thumbprint / signature / stamp blocks for receipts.
///
/// Uses built-in Helvetica only. Custom TTFs (e.g. Noto Nastaliq via
/// PdfGoogleFonts) crash the pdf package subsetter with
/// `Bad state: No element` in [TtfWriter.withChars].
class ReceiptAcknowledgment {
  ReceiptAcknowledgment._();

  /// Latin-safe bilingual labels (romanized Urdu — Helvetica compatible).
  static const String zamindarLabel =
      'Zamindar Sign / Thumb (Dastkhat / Angootha)';
  static const String shopLabel = 'Shop Stamp & Sign (Dastkhat o Mohr)';
  static const String a4ZamindarTitle =
      'Zamindar Thumb Impression / Signature';
  static const String a4ShopTitle =
      'AgriKhata Authorized Stamp & Signature';
  static const String legalDisclaimer =
      'I acknowledge receipt of the items listed above and accept '
      'responsibility for any outstanding balance noted.';

  /// Developer promo for thermal (80mm) receipts only — Helvetica-safe.
  /// (Script Urdu crashes the pdf TTF subsetter; romanized here.)
  static const String thermalPromoWhatsApp = 'WhatsApp: 03331245518';
  static const String thermalPromoUrduRomanized =
      '(Apne karobar ka software banwane ke liye rabta karein)';

  /// Centered WhatsApp promo block for the bottom of thermal receipts.
  static pw.Widget buildThermalPromoFooter({double fontSize = 7}) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.SizedBox(height: 6),
        pw.Container(
          width: double.infinity,
          height: 0.5,
          color: PdfColors.grey500,
        ),
        pw.SizedBox(height: 5),
        pw.Text(
          thermalPromoWhatsApp,
          style: pw.TextStyle(
            fontSize: fontSize,
            fontWeight: pw.FontWeight.bold,
          ),
          textAlign: pw.TextAlign.center,
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          thermalPromoUrduRomanized,
          style: pw.TextStyle(
            fontSize: fontSize - 0.5,
            color: PdfColors.grey700,
          ),
          textAlign: pw.TextAlign.center,
        ),
      ],
    );
  }

  /// Dual-column ink boxes for 80mm thermal receipts.
  static pw.Widget buildThermalBlock({pw.Font? urduFont}) {
    // [urduFont] ignored — kept for call-site compatibility.
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          width: double.infinity,
          height: 0.6,
          color: PdfColors.grey600,
        ),
        pw.SizedBox(height: 6),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: _thermalSignBox(
                title: 'Customer / Zamindar',
                label: zamindarLabel,
                prompt: 'Thumb / Sign:',
              ),
            ),
            pw.SizedBox(width: 6),
            pw.Expanded(
              child: _thermalSignBox(
                title: 'Shopkeeper',
                label: shopLabel,
                prompt: 'Sign / Stamp:',
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Container(
          width: double.infinity,
          height: 0.6,
          color: PdfColors.grey600,
        ),
      ],
    );
  }

  static pw.Widget _thermalSignBox({
    required String title,
    required String label,
    required String prompt,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(4),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey700, width: 0.7),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text(label, style: const pw.TextStyle(fontSize: 6)),
          pw.SizedBox(height: 10),
          pw.Text(prompt, style: const pw.TextStyle(fontSize: 6)),
          pw.SizedBox(height: 2),
          pw.Container(
            width: double.infinity,
            height: 0.5,
            color: PdfColors.grey500,
          ),
          pw.SizedBox(height: 14),
        ],
      ),
    );
  }

  /// Structured 2×2 inch ink boxes for A4 invoices / ledger statements.
  static pw.Widget buildA4Block({pw.Font? urduFont}) {
    // [urduFont] ignored — kept for call-site compatibility.
    const boxSize = 144.0; // 2 inches at 72 pt/inch
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.SizedBox(height: 12),
        pw.Text(
          legalDisclaimer,
          style: pw.TextStyle(
            fontSize: 9,
            fontStyle: pw.FontStyle.italic,
            color: PdfColors.grey800,
          ),
          textAlign: pw.TextAlign.center,
        ),
        pw.SizedBox(height: 14),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _a4InkBox(
              title: a4ZamindarTitle,
              subtitle: zamindarLabel,
              size: boxSize,
            ),
            pw.SizedBox(width: 24),
            _a4InkBox(
              title: a4ShopTitle,
              subtitle: shopLabel,
              size: boxSize,
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _a4InkBox({
    required String title,
    required String subtitle,
    required double size,
  }) {
    return pw.Container(
      width: size,
      height: size,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(
          color: PdfColor.fromHex('#1B4332'),
          width: 1.2,
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 8.5,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#1B4332'),
            ),
            textAlign: pw.TextAlign.center,
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            subtitle,
            style: const pw.TextStyle(fontSize: 7.5),
            textAlign: pw.TextAlign.center,
          ),
          pw.Spacer(),
          pw.Text(
            'Ink area',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey500),
          ),
        ],
      ),
    );
  }
}
