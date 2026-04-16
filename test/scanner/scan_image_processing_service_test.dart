import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_reader/src/scanner/models/scanner_models.dart';
import 'package:pdf_reader/src/scanner/services/scan_image_processing_service.dart';
import 'package:pdf_reader/src/scanner/services/scanned_pdf_export_service.dart';

void main() {
  group('ScanDraftDocument', () {
    test('adds, removes and reorders pages while keeping selection sane', () {
      final first = _page(id: '1');
      final second = _page(id: '2');
      final third = _page(id: '3');

      final added = ScanDraftDocument.empty.addPages(<ScannedPageDraft>[
        first,
        second,
        third,
      ]);
      expect(added.pages, hasLength(3));
      expect(added.selectedPageId, '3');

      final reordered = added.reorderPages(2, 0);
      expect(reordered.pages.first.id, '3');
      expect(reordered.selectedPageId, '3');

      final removed = reordered.removePage('3');
      expect(removed.pages, hasLength(2));
      expect(removed.selectedPageId, anyOf('1', '2'));
    });
  });

  group('ScanImageProcessingService', () {
    const service = ScanImageProcessingService();

    test('createDraft stores image metadata', () async {
      final imageBytes = _encodeTestImage(4, 2);
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: imageBytes,
      );

      expect(draft.width, 4);
      expect(draft.height, 2);
      expect(draft.documentCornersNormalized, isNull);
      expect(draft.cropRectNormalized, ScanImageProcessingService.fullCropRect);
      expect(draft.filterPreset, ScanFilterPreset.none);
      expect(draft.colorMode, ScanColorMode.color);
    });

    test('crop round-trip remains stable in crop editor space', () async {
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: _encodeTestImage(120, 80),
      );
      final rotated = draft.copyWith(
        cropRectNormalized: const Rect.fromLTWH(0.2, 0.1, 0.45, 0.6),
        rotationQuarterTurns: 1,
        documentCornersNormalized: const ScanDocumentCorners(
          topLeft: Offset(0.1, 0.1),
          topRight: Offset(0.9, 0.08),
          bottomLeft: Offset(0.08, 0.9),
          bottomRight: Offset(0.92, 0.92),
        ),
      );

      final cropRectForEditor = service.cropRectForCropEditor(rotated);
      final restored = service.cropRectFromCropEditor(
        page: rotated,
        rotatedCropRectNormalized: cropRectForEditor,
      );

      expect(restored.left, closeTo(rotated.cropRectNormalized.left, 0.001));
      expect(restored.top, closeTo(rotated.cropRectNormalized.top, 0.001));
      expect(restored.width, closeTo(rotated.cropRectNormalized.width, 0.001));
      expect(
        restored.height,
        closeTo(rotated.cropRectNormalized.height, 0.001),
      );
    });

    test('preview applies crop, rotation and grayscale', () async {
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: _encodeTestImage(4, 2),
      );
      final transformed = draft.copyWith(
        cropRectNormalized: const Rect.fromLTWH(0, 0, 0.5, 1),
        rotationQuarterTurns: 1,
        colorMode: ScanColorMode.grayscale,
      );

      final processed = await service.buildPreviewPage(transformed);
      final decoded = img.decodeJpg(processed.bytes)!;
      final pixel = decoded.getPixel(0, 0);

      expect(processed.width, 1);
      expect(processed.height, 4);
      expect(pixel.r, pixel.g);
      expect(pixel.g, pixel.b);
    });

    test('black and white mode produces binary output', () async {
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: _encodeGradientImage(24, 24),
      );
      final processed = await service.buildPreviewPage(
        draft.copyWith(colorMode: ScanColorMode.blackWhite),
      );
      final decoded = img.decodeJpg(processed.bytes)!;
      final sample = decoded.getPixel(0, 0);

      expect(<int>{0, 255}, contains(sample.r));
      expect(sample.r, sample.g);
      expect(sample.g, sample.b);
    });

    test('filter preset applies an alternate rendering pipeline', () async {
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: _encodeTestImage(32, 32),
      );

      final processed = await service.buildPreviewPage(
        draft.copyWith(filterPreset: ScanFilterPreset.vivid),
      );

      expect(processed.bytes, isNotEmpty);
      expect(processed.width, greaterThan(0));
      expect(processed.height, greaterThan(0));
    });

    test('export quality limits long edge size', () async {
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: _encodeTestImage(3200, 1400),
      );

      final processed = await service.buildExportPage(
        draft,
        ScanExportQuality.light,
      );

      expect(
        processed.width > processed.height ? processed.width : processed.height,
        lessThanOrEqualTo(ScanExportQuality.light.maxLongEdgePx),
      );
    });

    test(
      'auto detection finds perspective corners on a skewed document',
      () async {
        final draft = await service.createDraft(
          id: 'page-1',
          sourceName: 'capture.png',
          originalBytes: _encodePerspectiveDocumentImage(),
        );

        final detected = await service.suggestAutoDetection(draft);
        final corners = detected.documentCornersNormalized;

        expect(corners, isNotNull);
        expect(
          detected.cropRectNormalized,
          ScanImageProcessingService.fullCropRect,
        );
        expect(corners!.topLeft.dx, closeTo(0.22, 0.08));
        expect(corners.topLeft.dy, closeTo(0.15, 0.08));
        expect(corners.topRight.dx, closeTo(0.82, 0.08));
        expect(corners.topRight.dy, closeTo(0.11, 0.08));
        expect(corners.bottomLeft.dx, closeTo(0.15, 0.08));
        expect(corners.bottomLeft.dy, closeTo(0.84, 0.08));
        expect(corners.bottomRight.dx, closeTo(0.87, 0.08));
        expect(corners.bottomRight.dy, closeTo(0.90, 0.08));
      },
    );

    test('preview applies perspective correction before export', () async {
      final draft = await service.createDraft(
        id: 'page-1',
        sourceName: 'capture.png',
        originalBytes: _encodePerspectiveDocumentImage(),
      );
      final detected = await service.suggestAutoDetection(draft);

      final processed = await service.buildPreviewPage(
        draft.copyWith(
          documentCornersNormalized: detected.documentCornersNormalized,
        ),
      );

      expect(processed.width, greaterThan(180));
      expect(processed.height, greaterThan(260));
    });
  });

  test('ScannedPdfExportService builds a pdf document', () async {
    const processingService = ScanImageProcessingService();
    const exportService = ScannedPdfExportService(processingService);

    final first = await processingService.createDraft(
      id: 'page-1',
      sourceName: 'page-1.png',
      originalBytes: _encodeTestImage(60, 90),
    );
    final second = await processingService.createDraft(
      id: 'page-2',
      sourceName: 'page-2.png',
      originalBytes: _encodeTestImage(90, 60),
    );

    final pdfBytes = await exportService.buildPdfBytes(
      pages: <ScannedPageDraft>[first, second],
      exportQuality: ScanExportQuality.optimized,
    );

    expect(pdfBytes, isNotEmpty);
    expect(String.fromCharCodes(pdfBytes.take(5)), '%PDF-');
  });
}

ScannedPageDraft _page({required String id}) {
  return ScannedPageDraft(
    id: id,
    sourceName: '$id.png',
    originalBytes: _encodeTestImage(10, 10),
    documentCornersNormalized: null,
    cropRectNormalized: const Rect.fromLTWH(0, 0, 1, 1),
    rotationQuarterTurns: 0,
    brightness: 0,
    contrast: 0,
    filterPreset: ScanFilterPreset.none,
    colorMode: ScanColorMode.color,
    width: 10,
    height: 10,
  );
}

Uint8List _encodeTestImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final isLeft = x < width / 2;
      image.setPixelRgb(
        x,
        y,
        isLeft ? 220 : 10,
        isLeft ? 40 : 80,
        isLeft ? 20 : 220,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _encodeGradientImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final value = ((x / (width - 1)) * 255).round();
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _encodePerspectiveDocumentImage() {
  const width = 400;
  const height = 520;
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(242, 242, 242));
  img.fillPolygon(
    image,
    vertices: <img.Point>[
      img.Point(92, 78),
      img.Point(330, 54),
      img.Point(352, 468),
      img.Point(60, 438),
    ],
    color: img.ColorRgb8(32, 32, 32),
  );
  return Uint8List.fromList(img.encodePng(image));
}
