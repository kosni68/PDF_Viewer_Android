import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/scanner_models.dart';
import 'scan_image_processing_service.dart';

class ScannedPdfExportService {
  const ScannedPdfExportService([
    ScanImageProcessingService? imageProcessingService,
  ]) : _imageProcessingService =
           imageProcessingService ?? const ScanImageProcessingService();

  final ScanImageProcessingService _imageProcessingService;

  Future<Uint8List> buildPdfBytes({
    required List<ScannedPageDraft> pages,
    required ScanExportQuality exportQuality,
  }) async {
    final pdfDocument = pw.Document(
      compress: true,
      title: 'scan-document',
      author: 'Lecteur PDF',
    );

    for (final page in pages) {
      final processedPage = await _imageProcessingService.buildExportPage(
        page,
        exportQuality,
      );
      final pageFormat = processedPage.width >= processedPage.height
          ? PdfPageFormat.a4.landscape
          : PdfPageFormat.a4;
      final memoryImage = pw.MemoryImage(processedPage.bytes);

      pdfDocument.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (context) {
            return pw.Container(
              color: PdfColors.white,
              alignment: pw.Alignment.center,
              child: pw.FittedBox(
                fit: pw.BoxFit.contain,
                child: pw.Image(memoryImage),
              ),
            );
          },
        ),
      );
    }

    return pdfDocument.save();
  }

  Future<String> exportToTemporaryFile({
    required List<ScannedPageDraft> pages,
    required ScanExportQuality exportQuality,
    required String fileNameStem,
  }) async {
    final bytes = await buildPdfBytes(
      pages: pages,
      exportQuality: exportQuality,
    );
    final temporaryDirectory = await getTemporaryDirectory();
    final safeStem = fileNameStem.trim().isEmpty ? 'scan' : fileNameStem.trim();
    final outputPath = p.join(
      temporaryDirectory.path,
      '$safeStem-${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    final outputFile = File(outputPath);
    await outputFile.writeAsBytes(bytes, flush: true);
    return outputFile.path;
  }
}
