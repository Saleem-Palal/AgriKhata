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

  /// Developer promo for thermal (80mm) receipts only — Helvetica-safe.
  /// (Script Urdu crashes the pdf TTF subsetter; romanized here.)
  static const String thermalPromoLine =
      'Karobar ka software banwana hai to is number pe rabta karen';
  static const String thermalPromoWhatsApp = '03331245518';

  /// Centered WhatsApp promo block for the bottom of thermal receipts.
  static pw.Widget buildThermalPromoFooter({double fontSize = 5}) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.SizedBox(height: 5),
        pw.Container(
          width: double.infinity,
          height: 0.5,
          color: PdfColors.grey500,
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          thermalPromoLine,
          style: pw.TextStyle(
            fontSize: fontSize,
            color: PdfColors.grey700,
          ),
          textAlign: pw.TextAlign.center,
        ),
        pw.SizedBox(height: 1),
        pw.Text(
          thermalPromoWhatsApp,
          style: pw.TextStyle(
            fontSize: fontSize,
            fontWeight: pw.FontWeight.bold,
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
}
