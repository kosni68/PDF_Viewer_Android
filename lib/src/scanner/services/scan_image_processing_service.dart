import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

import '../models/scanner_models.dart';

class ProcessedScanPage {
  const ProcessedScanPage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

class ScanImageProcessingService {
  const ScanImageProcessingService();

  static const Rect fullCropRect = Rect.fromLTWH(0, 0, 1, 1);
  static const int previewLongEdgePx = 1100;
  static const int cropEditorLongEdgePx = 1280;
  static const int autoCropLongEdgePx = 720;

  Future<ScannedPageDraft> createDraft({
    required String id,
    required String sourceName,
    required Uint8List originalBytes,
  }) async {
    final response = await Isolate.run<Map<String, Object?>>(
      () => _createDraftOnWorker(<String, Object?>{
        'id': id,
        'sourceName': sourceName,
        'originalBytes': TransferableTypedData.fromList(<Uint8List>[
          originalBytes,
        ]),
      }),
    );

    return ScannedPageDraft(
      id: response['id']! as String,
      sourceName: response['sourceName']! as String,
      originalBytes: originalBytes,
      cropRectNormalized: fullCropRect,
      rotationQuarterTurns: 0,
      brightness: 0,
      contrast: 0,
      colorMode: ScanColorMode.color,
      width: response['width']! as int,
      height: response['height']! as int,
    );
  }

  Future<ProcessedScanPage> buildPreviewPage(ScannedPageDraft page) async {
    return _processPage(
      page,
      maxLongEdgePx: previewLongEdgePx,
      jpegQuality: 84,
      includeCrop: true,
      includeRotation: true,
      includeAdjustments: true,
    );
  }

  Future<ProcessedScanPage> buildCropEditorPage(ScannedPageDraft page) async {
    return _processPage(
      page,
      maxLongEdgePx: cropEditorLongEdgePx,
      jpegQuality: 88,
      includeCrop: false,
      includeRotation: true,
      includeAdjustments: false,
    );
  }

  Future<ProcessedScanPage> buildExportPage(
    ScannedPageDraft page,
    ScanExportQuality quality,
  ) async {
    return _processPage(
      page,
      maxLongEdgePx: quality.maxLongEdgePx,
      jpegQuality: quality.jpegQuality,
      includeCrop: true,
      includeRotation: true,
      includeAdjustments: true,
    );
  }

  Future<Rect> suggestAutoCropRect(ScannedPageDraft page) async {
    final response = await Isolate.run<List<double>>(
      () => _suggestAutoCropOnWorker(<String, Object?>{
        ..._serializePage(page),
        'maxLongEdgePx': autoCropLongEdgePx,
      }),
    );
    return _rectFromList(response);
  }

  Rect cropRectForCropEditor(ScannedPageDraft page) {
    return _clampNormalizedRect(
      _mapOriginalRectToRotatedRect(
        page.cropRectNormalized,
        width: page.width,
        height: page.height,
        quarterTurns: page.rotationQuarterTurns,
      ),
    );
  }

  Rect cropRectFromCropEditor({
    required ScannedPageDraft page,
    required Rect rotatedCropRectNormalized,
  }) {
    return _clampNormalizedRect(
      _mapRotatedRectToOriginalRect(
        rotatedCropRectNormalized,
        width: page.width,
        height: page.height,
        quarterTurns: page.rotationQuarterTurns,
      ),
    );
  }

  Future<ProcessedScanPage> _processPage(
    ScannedPageDraft page, {
    required int maxLongEdgePx,
    required int jpegQuality,
    required bool includeCrop,
    required bool includeRotation,
    required bool includeAdjustments,
  }) async {
    final response = await Isolate.run<Map<String, Object?>>(
      () => _processPageOnWorker(<String, Object?>{
        ..._serializePage(page),
        'maxLongEdgePx': maxLongEdgePx,
        'jpegQuality': jpegQuality,
        'includeCrop': includeCrop,
        'includeRotation': includeRotation,
        'includeAdjustments': includeAdjustments,
      }),
    );

    return ProcessedScanPage(
      bytes: (response['bytes']! as TransferableTypedData)
          .materialize()
          .asUint8List(),
      width: response['width']! as int,
      height: response['height']! as int,
    );
  }
}

Map<String, Object?> _serializePage(ScannedPageDraft page) {
  return <String, Object?>{
    'id': page.id,
    'sourceName': page.sourceName,
    'originalBytes': TransferableTypedData.fromList(<Uint8List>[
      page.originalBytes,
    ]),
    'cropRectNormalized': _rectToList(page.cropRectNormalized),
    'rotationQuarterTurns': page.rotationQuarterTurns,
    'brightness': page.brightness,
    'contrast': page.contrast,
    'colorModeIndex': page.colorMode.index,
    'width': page.width,
    'height': page.height,
  };
}

Map<String, Object?> _createDraftOnWorker(Map<String, Object?> request) {
  final decodedImage = img.decodeImage(_bytesFromMessage(request));
  if (decodedImage == null) {
    throw const FormatException('Image non lisible');
  }

  return <String, Object?>{
    'id': request['id']! as String,
    'sourceName': request['sourceName']! as String,
    'width': decodedImage.width,
    'height': decodedImage.height,
  };
}

Map<String, Object?> _processPageOnWorker(Map<String, Object?> request) {
  final decodedImage = img.decodeImage(_bytesFromMessage(request));
  if (decodedImage == null) {
    throw const FormatException('Image non lisible');
  }

  img.Image processedImage = img.Image.from(decodedImage);
  if (request['includeCrop']! as bool) {
    processedImage = _applyCrop(
      processedImage,
      _rectFromList(request['cropRectNormalized']! as List<Object?>),
    );
  }
  if (request['includeRotation']! as bool) {
    processedImage = _applyRotation(
      processedImage,
      request['rotationQuarterTurns']! as int,
    );
  }
  if (request['includeAdjustments']! as bool) {
    processedImage = _applyAdjustments(
      processedImage,
      brightness: request['brightness']! as double,
      contrast: request['contrast']! as double,
      colorMode: ScanColorMode.values[request['colorModeIndex']! as int],
    );
  }
  processedImage = _resizeToLongEdge(
    processedImage,
    request['maxLongEdgePx']! as int,
  );

  return <String, Object?>{
    'bytes': TransferableTypedData.fromList(<Uint8List>[
      Uint8List.fromList(
        img.encodeJpg(processedImage, quality: request['jpegQuality']! as int),
      ),
    ]),
    'width': processedImage.width,
    'height': processedImage.height,
  };
}

List<double> _suggestAutoCropOnWorker(Map<String, Object?> request) {
  final decodedImage = img.decodeImage(_bytesFromMessage(request));
  if (decodedImage == null) {
    throw const FormatException('Image non lisible');
  }

  var rotatedImage = _applyRotation(
    img.Image.from(decodedImage),
    request['rotationQuarterTurns']! as int,
  );
  rotatedImage = _resizeToLongEdge(
    rotatedImage,
    request['maxLongEdgePx']! as int,
  );

  final grayscaleImage = img.grayscale(rotatedImage);
  final width = grayscaleImage.width;
  final height = grayscaleImage.height;
  if (width < 20 || height < 20) {
    return _rectToList(ScanImageProcessingService.fullCropRect);
  }

  final borderThickness = math.max(8, math.min(width, height) ~/ 28);
  var borderSum = 0.0;
  var borderSumSquares = 0.0;
  var borderCount = 0;

  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final isBorder =
          x < borderThickness ||
          y < borderThickness ||
          x >= width - borderThickness ||
          y >= height - borderThickness;
      if (!isBorder) {
        continue;
      }
      final luminance = grayscaleImage.getPixel(x, y).r.toDouble();
      borderSum += luminance;
      borderSumSquares += luminance * luminance;
      borderCount += 1;
    }
  }

  if (borderCount == 0) {
    return _rectToList(ScanImageProcessingService.fullCropRect);
  }

  final borderAverage = borderSum / borderCount;
  final borderVariance =
      (borderSumSquares / borderCount) - (borderAverage * borderAverage);
  final borderStdDev = math.sqrt(math.max(0.0, borderVariance));
  final diffThreshold = math.max(18.0, borderStdDev * 2.4);

  var minX = width;
  var minY = height;
  var maxX = -1;
  var maxY = -1;

  for (var y = borderThickness; y < height - borderThickness; y += 1) {
    for (var x = borderThickness; x < width - borderThickness; x += 1) {
      final luminance = grayscaleImage.getPixel(x, y).r.toDouble();
      if ((luminance - borderAverage).abs() < diffThreshold) {
        continue;
      }

      if (x < minX) {
        minX = x;
      }
      if (y < minY) {
        minY = y;
      }
      if (x > maxX) {
        maxX = x;
      }
      if (y > maxY) {
        maxY = y;
      }
    }
  }

  if (maxX < minX || maxY < minY) {
    return _rectToList(ScanImageProcessingService.fullCropRect);
  }

  final detectedWidth = maxX - minX + 1;
  final detectedHeight = maxY - minY + 1;
  if (detectedWidth < width * 0.28 || detectedHeight < height * 0.28) {
    return _rectToList(ScanImageProcessingService.fullCropRect);
  }

  final margin = math.max(6, borderThickness ~/ 2);
  final expandedRect = Rect.fromLTRB(
    (minX - margin).clamp(0, width - 1).toDouble(),
    (minY - margin).clamp(0, height - 1).toDouble(),
    (maxX + margin + 1).clamp(1, width).toDouble(),
    (maxY + margin + 1).clamp(1, height).toDouble(),
  );

  final rotatedCropRectNormalized = Rect.fromLTRB(
    expandedRect.left / width,
    expandedRect.top / height,
    expandedRect.right / width,
    expandedRect.bottom / height,
  );

  final cropRect = _clampNormalizedRect(
    _mapRotatedRectToOriginalRect(
      rotatedCropRectNormalized,
      width: request['width']! as int,
      height: request['height']! as int,
      quarterTurns: request['rotationQuarterTurns']! as int,
    ),
  );

  return _rectToList(cropRect);
}

Uint8List _bytesFromMessage(Map<String, Object?> request) {
  return (request['originalBytes']! as TransferableTypedData)
      .materialize()
      .asUint8List();
}

img.Image _applyCrop(img.Image source, Rect cropRectNormalized) {
  final safeRect = _clampNormalizedRect(cropRectNormalized);
  final left = (safeRect.left * source.width).floor().clamp(
    0,
    source.width - 1,
  );
  final top = (safeRect.top * source.height).floor().clamp(
    0,
    source.height - 1,
  );
  final right = (safeRect.right * source.width).ceil().clamp(
    left + 1,
    source.width,
  );
  final bottom = (safeRect.bottom * source.height).ceil().clamp(
    top + 1,
    source.height,
  );

  return img.copyCrop(
    source,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
}

img.Image _applyRotation(img.Image source, int rotationQuarterTurns) {
  final normalizedTurns = rotationQuarterTurns % 4;
  if (normalizedTurns == 0) {
    return source;
  }
  return img.copyRotate(source, angle: normalizedTurns * 90);
}

img.Image _applyAdjustments(
  img.Image source, {
  required double brightness,
  required double contrast,
  required ScanColorMode colorMode,
}) {
  if (brightness != 0 || contrast != 0) {
    source = img.adjustColor(
      source,
      brightness: (1 + brightness).clamp(0, 2),
      contrast: (1 + contrast).clamp(0, 2),
    );
  }

  switch (colorMode) {
    case ScanColorMode.color:
      return source;
    case ScanColorMode.grayscale:
      return img.grayscale(source);
    case ScanColorMode.blackWhite:
      return img.luminanceThreshold(img.grayscale(source), threshold: 0.62);
  }
}

img.Image _resizeToLongEdge(img.Image source, int maxLongEdgePx) {
  final longEdge = math.max(source.width, source.height);
  if (longEdge <= maxLongEdgePx) {
    return source;
  }

  if (source.width >= source.height) {
    return img.copyResize(source, width: maxLongEdgePx);
  }
  return img.copyResize(source, height: maxLongEdgePx);
}

Rect _clampNormalizedRect(Rect rect) {
  final left = rect.left.clamp(0.0, 1.0).toDouble();
  final top = rect.top.clamp(0.0, 1.0).toDouble();
  final right = rect.right.clamp(left + 0.001, 1.0).toDouble();
  final bottom = rect.bottom.clamp(top + 0.001, 1.0).toDouble();
  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _mapOriginalRectToRotatedRect(
  Rect originalRect, {
  required int width,
  required int height,
  required int quarterTurns,
}) {
  final rectPx = Rect.fromLTWH(
    originalRect.left * width,
    originalRect.top * height,
    originalRect.width * width,
    originalRect.height * height,
  );
  final transformed = _transformRect(
    rectPx,
    (point) => _transformOriginalPointToRotated(
      point,
      width: width,
      height: height,
      quarterTurns: quarterTurns,
    ),
  );
  final rotatedSize = _rotatedSize(width, height, quarterTurns);
  return Rect.fromLTWH(
    transformed.left / rotatedSize.width,
    transformed.top / rotatedSize.height,
    transformed.width / rotatedSize.width,
    transformed.height / rotatedSize.height,
  );
}

Rect _mapRotatedRectToOriginalRect(
  Rect rotatedRect, {
  required int width,
  required int height,
  required int quarterTurns,
}) {
  final rotatedSize = _rotatedSize(width, height, quarterTurns);
  final rectPx = Rect.fromLTWH(
    rotatedRect.left * rotatedSize.width,
    rotatedRect.top * rotatedSize.height,
    rotatedRect.width * rotatedSize.width,
    rotatedRect.height * rotatedSize.height,
  );
  final transformed = _transformRect(
    rectPx,
    (point) => _transformRotatedPointToOriginal(
      point,
      width: width,
      height: height,
      quarterTurns: quarterTurns,
    ),
  );
  return Rect.fromLTWH(
    transformed.left / width,
    transformed.top / height,
    transformed.width / width,
    transformed.height / height,
  );
}

Rect _transformRect(Rect rect, Offset Function(Offset point) transform) {
  final points = <Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomLeft,
    rect.bottomRight,
  ].map(transform).toList(growable: false);
  final left = points.map((point) => point.dx).reduce(math.min);
  final top = points.map((point) => point.dy).reduce(math.min);
  final right = points.map((point) => point.dx).reduce(math.max);
  final bottom = points.map((point) => point.dy).reduce(math.max);
  return Rect.fromLTRB(left, top, right, bottom);
}

Size _rotatedSize(int width, int height, int quarterTurns) {
  return switch (quarterTurns % 4) {
    1 || 3 => Size(height.toDouble(), width.toDouble()),
    _ => Size(width.toDouble(), height.toDouble()),
  };
}

Offset _transformOriginalPointToRotated(
  Offset point, {
  required int width,
  required int height,
  required int quarterTurns,
}) {
  return switch (quarterTurns % 4) {
    1 => Offset(height - point.dy, point.dx),
    2 => Offset(width - point.dx, height - point.dy),
    3 => Offset(point.dy, width - point.dx),
    _ => point,
  };
}

Offset _transformRotatedPointToOriginal(
  Offset point, {
  required int width,
  required int height,
  required int quarterTurns,
}) {
  return switch (quarterTurns % 4) {
    1 => Offset(point.dy, height - point.dx),
    2 => Offset(width - point.dx, height - point.dy),
    3 => Offset(width - point.dy, point.dx),
    _ => point,
  };
}

Rect _rectFromList(List<Object?> values) {
  return Rect.fromLTRB(
    (values[0]! as num).toDouble(),
    (values[1]! as num).toDouble(),
    (values[2]! as num).toDouble(),
    (values[3]! as num).toDouble(),
  );
}

List<double> _rectToList(Rect rect) {
  return <double>[rect.left, rect.top, rect.right, rect.bottom];
}
