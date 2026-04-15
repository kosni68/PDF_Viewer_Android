import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import '../editor_rendering.dart';
import '../models/editor_document_state.dart';

class PdfFlattenExportService {
  const PdfFlattenExportService();

  static const double _maxRenderEdge = 1800;
  static const int _jpegQuality = 90;

  Future<void> exportToFile({
    required String sourcePdfPath,
    required String outputPdfPath,
    required EditorDocumentState state,
  }) async {
    await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);

    final sourceDocument = await PdfDocument.openFile(sourcePdfPath);
    final pageDocuments = <PdfDocument>[];
    final overlayImages = <String, ui.Image>{};
    PdfDocument? outputDocument;

    try {
      for (final page in sourceDocument.pages) {
        final pageDoc = await _flattenPage(
          page: await page.ensureLoaded(),
          objects: state.objectsForPage(page.pageNumber),
          overlayImages: overlayImages,
        );
        pageDocuments.add(pageDoc);
      }

      outputDocument = await PdfDocument.createNew(sourceName: outputPdfPath);
      outputDocument.pages = pageDocuments
          .expand((document) => document.pages)
          .toList(growable: false);
      final outputBytes = await outputDocument.encodePdf();
      await File(outputPdfPath).writeAsBytes(outputBytes, flush: true);
    } finally {
      for (final image in overlayImages.values) {
        image.dispose();
      }
      await outputDocument?.dispose();
      for (final document in pageDocuments) {
        await document.dispose();
      }
      await sourceDocument.dispose();
    }
  }

  Future<PdfDocument> _flattenPage({
    required PdfPage page,
    required List<PdfEditObject> objects,
    required Map<String, ui.Image> overlayImages,
  }) async {
    final renderScale = _maxRenderEdge / math.max(page.width, page.height);
    final fullWidth = math
        .max(1, (page.width * renderScale).round())
        .toDouble();
    final fullHeight = math
        .max(1, (page.height * renderScale).round())
        .toDouble();
    final rendered = await page.render(
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      backgroundColor: 0xffffffff,
      annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
    );
    if (rendered == null) {
      throw StateError('Impossible de rendre la page ${page.pageNumber}.');
    }

    final baseImage = await rendered.createImage();
    rendered.dispose();

    try {
      final composedImage = await _composePageImage(
        baseImage: baseImage,
        objects: objects,
        overlayImages: overlayImages,
      );
      try {
        final rawBytes = await composedImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (rawBytes == null) {
          throw StateError(
            'Impossible de convertir la page ${page.pageNumber} en image exportable.',
          );
        }

        final jpegBytes = await compute(
          _encodeJpeg,
          _JpegEncodeRequest(
            width: composedImage.width,
            height: composedImage.height,
            rgbaBytes: rawBytes.buffer.asUint8List(),
            quality: _jpegQuality,
          ),
        );

        return PdfDocument.createFromJpegData(
          jpegBytes,
          width: page.width,
          height: page.height,
          sourceName: 'flattened-page-${page.pageNumber}',
        );
      } finally {
        composedImage.dispose();
      }
    } finally {
      baseImage.dispose();
    }
  }

  Future<ui.Image> _composePageImage({
    required ui.Image baseImage,
    required List<PdfEditObject> objects,
    required Map<String, ui.Image> overlayImages,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final pageRect = ui.Rect.fromLTWH(
      0,
      0,
      baseImage.width.toDouble(),
      baseImage.height.toDouble(),
    );

    canvas.drawImage(baseImage, ui.Offset.zero, ui.Paint());

    for (final object in objects) {
      final rect = _normalizedRectToPixels(
        object.normalizedRect,
        pageRect.width,
        pageRect.height,
      );
      switch (object) {
        case TextEditObject():
          paintTextObject(canvas, object, rect);
        case StrokeEditObject():
          paintStrokeObject(canvas, object, rect, pageRect.size);
        case ShapeEditObject():
          paintShapeObject(canvas, object, rect, pageRect.size);
        case SignatureEditObject():
          final image = await _loadOverlayImage(
            object.id,
            object.imageBytes,
            overlayImages,
          );
          paintImageObject(
            canvas,
            image,
            rect,
            object.rotationDegrees,
            object.opacity,
          );
        case ImageEditObject():
          final image = await _loadOverlayImage(
            object.id,
            object.imageBytes,
            overlayImages,
          );
          paintImageObject(
            canvas,
            image,
            rect,
            object.rotationDegrees,
            object.opacity,
          );
      }
    }

    final picture = recorder.endRecording();
    return picture.toImage(baseImage.width, baseImage.height);
  }

  ui.Rect _normalizedRectToPixels(
    ui.Rect rect,
    double pageWidth,
    double pageHeight,
  ) {
    return ui.Rect.fromLTWH(
      rect.left * pageWidth,
      rect.top * pageHeight,
      rect.width * pageWidth,
      rect.height * pageHeight,
    );
  }

  Future<ui.Image> _loadOverlayImage(
    String cacheKey,
    Uint8List bytes,
    Map<String, ui.Image> overlayImages,
  ) async {
    final cached = overlayImages[cacheKey];
    if (cached != null) {
      return cached;
    }

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    overlayImages[cacheKey] = frame.image;
    return frame.image;
  }
}

class _JpegEncodeRequest {
  const _JpegEncodeRequest({
    required this.width,
    required this.height,
    required this.rgbaBytes,
    required this.quality,
  });

  final int width;
  final int height;
  final Uint8List rgbaBytes;
  final int quality;
}

Uint8List _encodeJpeg(_JpegEncodeRequest request) {
  final image = img.Image.fromBytes(
    width: request.width,
    height: request.height,
    bytes: request.rgbaBytes.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: request.quality));
}
