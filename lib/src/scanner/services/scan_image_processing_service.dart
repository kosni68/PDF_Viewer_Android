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

class AutoDetectedDocument {
  const AutoDetectedDocument({
    required this.cropRectNormalized,
    required this.documentCornersNormalized,
  });

  final Rect cropRectNormalized;
  final ScanDocumentCorners? documentCornersNormalized;
}

class ScanImageProcessingService {
  const ScanImageProcessingService();

  static const Rect fullCropRect = Rect.fromLTWH(0, 0, 1, 1);
  static const int previewLongEdgePx = 900;
  static const int cropEditorLongEdgePx = 1080;
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
      documentCornersNormalized: null,
      cropRectNormalized: fullCropRect,
      rotationQuarterTurns: 0,
      brightness: 0,
      contrast: 0,
      filterPreset: ScanFilterPreset.none,
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
      includePerspectiveCorrection: true,
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
      includePerspectiveCorrection: true,
      includeAdjustments: false,
    );
  }

  Future<ProcessedScanPage> buildCornerEditorPage(ScannedPageDraft page) async {
    return _processPage(
      page,
      maxLongEdgePx: cropEditorLongEdgePx,
      jpegQuality: 88,
      includeCrop: false,
      includeRotation: true,
      includePerspectiveCorrection: false,
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
      includePerspectiveCorrection: true,
      includeAdjustments: true,
    );
  }

  Future<AutoDetectedDocument> suggestAutoDetection(
    ScannedPageDraft page,
  ) async {
    final response = await Isolate.run<Map<String, Object?>>(
      () => _suggestAutoDetectionOnWorker(<String, Object?>{
        ..._serializePage(page),
        'maxLongEdgePx': autoCropLongEdgePx,
      }),
    );

    return AutoDetectedDocument(
      cropRectNormalized: _rectFromList(
        response['cropRectNormalized']! as List<Object?>,
      ),
      documentCornersNormalized: _cornersFromMessage(
        response['documentCornersNormalized'],
      ),
    );
  }

  Rect cropRectForCropEditor(ScannedPageDraft page) {
    return _clampNormalizedRect(page.cropRectNormalized);
  }

  Rect cropRectFromCropEditor({
    required ScannedPageDraft page,
    required Rect rotatedCropRectNormalized,
  }) {
    return _clampNormalizedRect(rotatedCropRectNormalized);
  }

  Future<ProcessedScanPage> _processPage(
    ScannedPageDraft page, {
    required int maxLongEdgePx,
    required int jpegQuality,
    required bool includeCrop,
    required bool includeRotation,
    required bool includePerspectiveCorrection,
    required bool includeAdjustments,
  }) async {
    final response = await Isolate.run<Map<String, Object?>>(
      () => _processPageOnWorker(<String, Object?>{
        ..._serializePage(page),
        'maxLongEdgePx': maxLongEdgePx,
        'jpegQuality': jpegQuality,
        'includeCrop': includeCrop,
        'includeRotation': includeRotation,
        'includePerspectiveCorrection': includePerspectiveCorrection,
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

class _AutoDetectionWorkerResult {
  const _AutoDetectionWorkerResult({
    required this.cropRectNormalized,
    required this.documentCornersNormalized,
  });

  final Rect cropRectNormalized;
  final ScanDocumentCorners? documentCornersNormalized;
}

Map<String, Object?> _serializePage(ScannedPageDraft page) {
  return <String, Object?>{
    'id': page.id,
    'sourceName': page.sourceName,
    'originalBytes': TransferableTypedData.fromList(<Uint8List>[
      page.originalBytes,
    ]),
    'documentCornersNormalized': page.documentCornersNormalized == null
        ? null
        : _cornersToList(page.documentCornersNormalized!),
    'cropRectNormalized': _rectToList(page.cropRectNormalized),
    'rotationQuarterTurns': page.rotationQuarterTurns,
    'brightness': page.brightness,
    'contrast': page.contrast,
    'filterPresetIndex': page.filterPreset.index,
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
  if (request['includeRotation']! as bool) {
    processedImage = _applyRotation(
      processedImage,
      request['rotationQuarterTurns']! as int,
    );
  }
  if (request['includePerspectiveCorrection']! as bool) {
    final rawCorners = request['documentCornersNormalized'];
    if (rawCorners != null) {
      processedImage = _applyPerspectiveCorrection(
        processedImage,
        _cornersFromList(rawCorners as List<Object?>),
      );
    }
  }
  if (request['includeCrop']! as bool) {
    processedImage = _applyCrop(
      processedImage,
      _rectFromList(request['cropRectNormalized']! as List<Object?>),
    );
  }
  if (request['includeAdjustments']! as bool) {
    processedImage = _applyAdjustments(
      processedImage,
      brightness: request['brightness']! as double,
      contrast: request['contrast']! as double,
      filterPreset:
          ScanFilterPreset.values[request['filterPresetIndex']! as int],
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

Map<String, Object?> _suggestAutoDetectionOnWorker(
  Map<String, Object?> request,
) {
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

  final detection = _detectDocument(rotatedImage);
  return <String, Object?>{
    'cropRectNormalized': _rectToList(detection.cropRectNormalized),
    'documentCornersNormalized': detection.documentCornersNormalized == null
        ? null
        : _cornersToList(detection.documentCornersNormalized!),
  };
}

_AutoDetectionWorkerResult _detectDocument(img.Image rotatedImage) {
  final grayscaleImage = img.grayscale(img.Image.from(rotatedImage));
  final width = grayscaleImage.width;
  final height = grayscaleImage.height;
  if (width < 24 || height < 24) {
    return const _AutoDetectionWorkerResult(
      cropRectNormalized: ScanImageProcessingService.fullCropRect,
      documentCornersNormalized: null,
    );
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
    return const _AutoDetectionWorkerResult(
      cropRectNormalized: ScanImageProcessingService.fullCropRect,
      documentCornersNormalized: null,
    );
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
  var candidateCount = 0;

  Offset? topLeft;
  Offset? topRight;
  Offset? bottomLeft;
  Offset? bottomRight;
  var topLeftScore = double.infinity;
  var topRightScore = double.negativeInfinity;
  var bottomLeftScore = double.negativeInfinity;
  var bottomRightScore = double.negativeInfinity;

  for (var y = borderThickness; y < height - borderThickness; y += 1) {
    for (var x = borderThickness; x < width - borderThickness; x += 1) {
      final luminance = grayscaleImage.getPixel(x, y).r.toDouble();
      if ((luminance - borderAverage).abs() < diffThreshold) {
        continue;
      }

      candidateCount += 1;
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

      final point = Offset(x.toDouble(), y.toDouble());
      final sumScore = point.dx + point.dy;
      final rightScore = point.dx - point.dy;
      final leftScore = point.dy - point.dx;

      if (sumScore < topLeftScore) {
        topLeftScore = sumScore;
        topLeft = point;
      }
      if (rightScore > topRightScore) {
        topRightScore = rightScore;
        topRight = point;
      }
      if (leftScore > bottomLeftScore) {
        bottomLeftScore = leftScore;
        bottomLeft = point;
      }
      if (sumScore > bottomRightScore) {
        bottomRightScore = sumScore;
        bottomRight = point;
      }
    }
  }

  if (maxX < minX || maxY < minY || candidateCount == 0) {
    return const _AutoDetectionWorkerResult(
      cropRectNormalized: ScanImageProcessingService.fullCropRect,
      documentCornersNormalized: null,
    );
  }

  final fallbackCropRect = _expandedBoundingRect(
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
    width: width,
    height: height,
    borderThickness: borderThickness,
  );

  final detectedWidth = maxX - minX + 1;
  final detectedHeight = maxY - minY + 1;
  final coverage = candidateCount / (width * height);
  if (detectedWidth < width * 0.28 ||
      detectedHeight < height * 0.28 ||
      coverage < 0.08) {
    return _AutoDetectionWorkerResult(
      cropRectNormalized: fallbackCropRect,
      documentCornersNormalized: null,
    );
  }

  final corners = _expandDetectedCorners(
    ScanDocumentCorners(
      topLeft: topLeft!,
      topRight: topRight!,
      bottomLeft: bottomLeft!,
      bottomRight: bottomRight!,
    ),
    width: width,
    height: height,
  );

  if (!_isValidDocumentCorners(corners, width: width, height: height)) {
    return _AutoDetectionWorkerResult(
      cropRectNormalized: fallbackCropRect,
      documentCornersNormalized: null,
    );
  }

  return _AutoDetectionWorkerResult(
    cropRectNormalized: ScanImageProcessingService.fullCropRect,
    documentCornersNormalized: _normalizeCorners(corners, width, height),
  );
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

img.Image _applyPerspectiveCorrection(
  img.Image source,
  ScanDocumentCorners documentCornersNormalized,
) {
  final topLeft = _pixelPointFromNormalized(
    documentCornersNormalized.topLeft,
    width: source.width,
    height: source.height,
  );
  final topRight = _pixelPointFromNormalized(
    documentCornersNormalized.topRight,
    width: source.width,
    height: source.height,
  );
  final bottomLeft = _pixelPointFromNormalized(
    documentCornersNormalized.bottomLeft,
    width: source.width,
    height: source.height,
  );
  final bottomRight = _pixelPointFromNormalized(
    documentCornersNormalized.bottomRight,
    width: source.width,
    height: source.height,
  );

  final targetWidth = math.max(
    1,
    ((_distance(topLeft, topRight) + _distance(bottomLeft, bottomRight)) / 2)
        .round(),
  );
  final targetHeight = math.max(
    1,
    ((_distance(topLeft, bottomLeft) + _distance(topRight, bottomRight)) / 2)
        .round(),
  );

  return img.copyRectify(
    source,
    topLeft: img.Point(topLeft.dx, topLeft.dy),
    topRight: img.Point(topRight.dx, topRight.dy),
    bottomLeft: img.Point(bottomLeft.dx, bottomLeft.dy),
    bottomRight: img.Point(bottomRight.dx, bottomRight.dy),
    interpolation: img.Interpolation.linear,
    toImage: img.Image(width: targetWidth, height: targetHeight),
  );
}

img.Image _applyAdjustments(
  img.Image source, {
  required double brightness,
  required double contrast,
  required ScanFilterPreset filterPreset,
  required ScanColorMode colorMode,
}) {
  source = _applyFilterPreset(source, filterPreset);

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

img.Image _applyFilterPreset(img.Image source, ScanFilterPreset filterPreset) {
  switch (filterPreset) {
    case ScanFilterPreset.none:
      return source;
    case ScanFilterPreset.document:
      source = img.histogramStretch(
        source,
        mode: img.HistogramEqualizeMode.color,
      );
      return img.adjustColor(
        source,
        contrast: 1.16,
        brightness: 1.04,
        saturation: 1.02,
      );
    case ScanFilterPreset.vivid:
      return img.adjustColor(
        source,
        contrast: 1.12,
        brightness: 1.03,
        saturation: 1.24,
      );
    case ScanFilterPreset.warm:
      return img.adjustColor(
        source,
        brightness: 1.03,
        saturation: 1.08,
        hue: 8,
      );
    case ScanFilterPreset.cool:
      return img.adjustColor(
        source,
        brightness: 1.0,
        saturation: 1.04,
        hue: -8,
      );
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

Rect _expandedBoundingRect({
  required int minX,
  required int minY,
  required int maxX,
  required int maxY,
  required int width,
  required int height,
  required int borderThickness,
}) {
  final margin = math.max(6, borderThickness ~/ 2);
  final expandedRect = Rect.fromLTRB(
    (minX - margin).clamp(0, width - 1).toDouble(),
    (minY - margin).clamp(0, height - 1).toDouble(),
    (maxX + margin + 1).clamp(1, width).toDouble(),
    (maxY + margin + 1).clamp(1, height).toDouble(),
  );

  return Rect.fromLTRB(
    expandedRect.left / width,
    expandedRect.top / height,
    expandedRect.right / width,
    expandedRect.bottom / height,
  );
}

ScanDocumentCorners _expandDetectedCorners(
  ScanDocumentCorners corners, {
  required int width,
  required int height,
}) {
  final center = Offset(
    (corners.topLeft.dx +
            corners.topRight.dx +
            corners.bottomLeft.dx +
            corners.bottomRight.dx) /
        4,
    (corners.topLeft.dy +
            corners.topRight.dy +
            corners.bottomLeft.dy +
            corners.bottomRight.dy) /
        4,
  );

  Offset expand(Offset point) {
    final dx = point.dx - center.dx;
    final dy = point.dy - center.dy;
    return Offset(
      (point.dx + dx * 0.04).clamp(0, width - 1).toDouble(),
      (point.dy + dy * 0.04).clamp(0, height - 1).toDouble(),
    );
  }

  return ScanDocumentCorners(
    topLeft: expand(corners.topLeft),
    topRight: expand(corners.topRight),
    bottomLeft: expand(corners.bottomLeft),
    bottomRight: expand(corners.bottomRight),
  );
}

bool _isValidDocumentCorners(
  ScanDocumentCorners corners, {
  required int width,
  required int height,
}) {
  final polygon = <Offset>[
    corners.topLeft,
    corners.topRight,
    corners.bottomRight,
    corners.bottomLeft,
  ];
  final area = _polygonArea(polygon);
  final minArea = width * height * 0.12;
  if (area < minArea) {
    return false;
  }

  final topWidth = _distance(corners.topLeft, corners.topRight);
  final bottomWidth = _distance(corners.bottomLeft, corners.bottomRight);
  final leftHeight = _distance(corners.topLeft, corners.bottomLeft);
  final rightHeight = _distance(corners.topRight, corners.bottomRight);
  if (topWidth < width * 0.25 ||
      bottomWidth < width * 0.25 ||
      leftHeight < height * 0.25 ||
      rightHeight < height * 0.25) {
    return false;
  }

  if (corners.topLeft.dy > corners.bottomLeft.dy ||
      corners.topRight.dy > corners.bottomRight.dy ||
      corners.topLeft.dx > corners.topRight.dx ||
      corners.bottomLeft.dx > corners.bottomRight.dx) {
    return false;
  }

  return true;
}

double _polygonArea(List<Offset> points) {
  var sum = 0.0;
  for (var index = 0; index < points.length; index += 1) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    sum += (current.dx * next.dy) - (next.dx * current.dy);
  }
  return sum.abs() / 2;
}

ScanDocumentCorners _normalizeCorners(
  ScanDocumentCorners corners,
  int width,
  int height,
) {
  Offset normalize(Offset point) {
    return Offset(
      (point.dx / width).clamp(0.0, 1.0).toDouble(),
      (point.dy / height).clamp(0.0, 1.0).toDouble(),
    );
  }

  return ScanDocumentCorners(
    topLeft: normalize(corners.topLeft),
    topRight: normalize(corners.topRight),
    bottomLeft: normalize(corners.bottomLeft),
    bottomRight: normalize(corners.bottomRight),
  );
}

Offset _pixelPointFromNormalized(
  Offset point, {
  required int width,
  required int height,
}) {
  return Offset(
    (point.dx * (width - 1)).clamp(0, width - 1).toDouble(),
    (point.dy * (height - 1)).clamp(0, height - 1).toDouble(),
  );
}

double _distance(Offset first, Offset second) {
  final dx = second.dx - first.dx;
  final dy = second.dy - first.dy;
  return math.sqrt((dx * dx) + (dy * dy));
}

Rect _clampNormalizedRect(Rect rect) {
  final left = rect.left.clamp(0.0, 1.0).toDouble();
  final top = rect.top.clamp(0.0, 1.0).toDouble();
  final right = rect.right.clamp(left + 0.001, 1.0).toDouble();
  final bottom = rect.bottom.clamp(top + 0.001, 1.0).toDouble();
  return Rect.fromLTRB(left, top, right, bottom);
}

ScanDocumentCorners? _cornersFromMessage(Object? rawCorners) {
  if (rawCorners == null) {
    return null;
  }
  return _cornersFromList(rawCorners as List<Object?>);
}

ScanDocumentCorners _cornersFromList(List<Object?> values) {
  return ScanDocumentCorners(
    topLeft: Offset(
      (values[0]! as num).toDouble(),
      (values[1]! as num).toDouble(),
    ),
    topRight: Offset(
      (values[2]! as num).toDouble(),
      (values[3]! as num).toDouble(),
    ),
    bottomLeft: Offset(
      (values[4]! as num).toDouble(),
      (values[5]! as num).toDouble(),
    ),
    bottomRight: Offset(
      (values[6]! as num).toDouble(),
      (values[7]! as num).toDouble(),
    ),
  );
}

List<double> _cornersToList(ScanDocumentCorners corners) {
  return <double>[
    corners.topLeft.dx,
    corners.topLeft.dy,
    corners.topRight.dx,
    corners.topRight.dy,
    corners.bottomLeft.dx,
    corners.bottomLeft.dy,
    corners.bottomRight.dx,
    corners.bottomRight.dy,
  ];
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
