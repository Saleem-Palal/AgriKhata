import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Reliable PDF file sharing, especially on Windows where share_plus
/// silently falls back to text-only if the path is not normalized.
class PdfShare {
  /// Shares an existing PDF file as a real attachment (not a path string).
  static Future<void> sharePdfFile({
    required File file,
    required String text,
    String? subject,
    String? fileName,
  }) async {
    if (!await file.exists()) {
      throw StateError('PDF file does not exist: ${file.path}');
    }

    // Copy into temp with a clean name so Windows Share can resolve StorageFile.
    final tempDir = await getTemporaryDirectory();
    final safeName = _sanitizeFileName(
      fileName ?? p.basename(file.path),
    );
    final sharePath = p.normalize(p.join(tempDir.path, safeName));
    final shareFile = File(sharePath);
    await shareFile.writeAsBytes(await file.readAsBytes(), flush: true);

    if (!await shareFile.exists() || await shareFile.length() == 0) {
      throw StateError('Failed to prepare PDF for sharing.');
    }

    final normalizedPath = Platform.isWindows
        ? p.normalize(shareFile.absolute.path).replaceAll('/', r'\')
        : shareFile.absolute.path;

    final xFile = XFile(
      normalizedPath,
      mimeType: 'application/pdf',
      name: safeName,
    );

    // Windows Share contract needs a primary text payload before it accepts
    // StorageItems; without it the sheet may open with text-only / path-only.
    await Share.shareXFiles(
      [xFile],
      text: text.trim().isEmpty ? 'AgriKhata PDF' : text,
      subject: subject ?? 'AgriKhata PDF',
    );
  }

  static String _sanitizeFileName(String name) {
    var cleaned = name.replaceAll(RegExp(r'[^\w.\- ]'), '_').trim();
    if (cleaned.isEmpty) cleaned = 'agrikhata_ledger.pdf';
    if (!cleaned.toLowerCase().endsWith('.pdf')) {
      cleaned = '$cleaned.pdf';
    }
    return cleaned;
  }
}
