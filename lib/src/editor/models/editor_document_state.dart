import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

@immutable
class EditorViewportState {
  const EditorViewportState({this.scale = 1, this.translation = Offset.zero});

  final double scale;
  final Offset translation;

  EditorViewportState copyWith({double? scale, Offset? translation}) {
    return EditorViewportState(
      scale: scale ?? this.scale,
      translation: translation ?? this.translation,
    );
  }
}

enum StrokeToolKind { pen, highlighter, eraser }

enum ShapeKind { rectangle, ellipse, line, arrow }

@immutable
class EditorDocumentState {
  const EditorDocumentState({this.layers = const <int, PageEditLayer>{}});

  static const empty = EditorDocumentState();

  final Map<int, PageEditLayer> layers;

  PageEditLayer? layerForPage(int pageNumber) => layers[pageNumber];

  List<PdfEditObject> objectsForPage(int pageNumber) {
    return layers[pageNumber]?.objects ?? const <PdfEditObject>[];
  }

  PdfEditObject? findObjectById(String id) {
    for (final layer in layers.values) {
      for (final object in layer.objects) {
        if (object.id == id) {
          return object;
        }
      }
    }
    return null;
  }

  EditorDocumentState upsertObject(PdfEditObject object) {
    final updatedLayers = Map<int, PageEditLayer>.from(layers);
    for (final entry in updatedLayers.entries.toList(growable: false)) {
      final index = entry.value.objects.indexWhere(
        (candidate) => candidate.id == object.id,
      );
      if (index < 0) {
        continue;
      }

      final objects = entry.value.objects.toList(growable: true);
      objects.removeAt(index);
      if (objects.isEmpty) {
        updatedLayers.remove(entry.key);
      } else {
        updatedLayers[entry.key] = entry.value.copyWith(objects: objects);
      }
      break;
    }

    final targetLayer = updatedLayers[object.pageNumber];
    final targetObjects =
        targetLayer?.objects.toList(growable: true) ?? <PdfEditObject>[];
    targetObjects.add(object);
    updatedLayers[object.pageNumber] = PageEditLayer(
      pageNumber: object.pageNumber,
      objects: List<PdfEditObject>.unmodifiable(targetObjects),
    );
    return EditorDocumentState(
      layers: Map<int, PageEditLayer>.unmodifiable(updatedLayers),
    );
  }

  EditorDocumentState updateObject(
    String id,
    PdfEditObject Function(PdfEditObject object) transform,
  ) {
    final current = findObjectById(id);
    if (current == null) {
      return this;
    }
    return upsertObject(transform(current));
  }

  EditorDocumentState removeObject(String id) {
    final updatedLayers = Map<int, PageEditLayer>.from(layers);
    for (final entry in layers.entries) {
      final objects = entry.value.objects
          .where((object) => object.id != id)
          .toList(growable: false);
      if (objects.length == entry.value.objects.length) {
        continue;
      }
      if (objects.isEmpty) {
        updatedLayers.remove(entry.key);
      } else {
        updatedLayers[entry.key] = entry.value.copyWith(objects: objects);
      }
      break;
    }
    return EditorDocumentState(
      layers: Map<int, PageEditLayer>.unmodifiable(updatedLayers),
    );
  }

  EditorDocumentState duplicateObject(
    String id, {
    required String newId,
    Offset offset = const Offset(0.02, 0.02),
  }) {
    final object = findObjectById(id);
    if (object == null) {
      return this;
    }
    return upsertObject(
      duplicatePdfEditObject(object, newId: newId, offset: offset),
    );
  }

  EditorDocumentState bringObjectForward(String id) {
    return _reorderObject(id, moveBy: 1);
  }

  EditorDocumentState sendObjectBackward(String id) {
    return _reorderObject(id, moveBy: -1);
  }

  EditorDocumentState toggleObjectLock(String id) {
    return updateObject(
      id,
      (object) => object.copyBase(isLocked: !object.isLocked),
    );
  }

  EditorDocumentState _reorderObject(String id, {required int moveBy}) {
    final updatedLayers = Map<int, PageEditLayer>.from(layers);
    for (final entry in updatedLayers.entries.toList(growable: false)) {
      final objects = entry.value.objects.toList(growable: true);
      final index = objects.indexWhere((object) => object.id == id);
      if (index < 0) {
        continue;
      }

      final targetIndex = (index + moveBy).clamp(0, objects.length - 1);
      if (targetIndex == index) {
        return this;
      }

      final object = objects.removeAt(index);
      objects.insert(targetIndex, object);
      updatedLayers[entry.key] = entry.value.copyWith(objects: objects);
      return EditorDocumentState(
        layers: Map<int, PageEditLayer>.unmodifiable(updatedLayers),
      );
    }
    return this;
  }

  bool get hasObjects => layers.values.any((layer) => layer.objects.isNotEmpty);
}

@immutable
class PageEditLayer {
  const PageEditLayer({required this.pageNumber, required this.objects});

  final int pageNumber;
  final List<PdfEditObject> objects;

  PageEditLayer copyWith({List<PdfEditObject>? objects}) {
    return PageEditLayer(
      pageNumber: pageNumber,
      objects: List<PdfEditObject>.unmodifiable(objects ?? this.objects),
    );
  }
}

@immutable
class TextReplacementStyle {
  const TextReplacementStyle({
    this.fontFamily = 'NotoSans',
    this.textColor = Colors.black,
    this.backgroundColor,
    this.fontSizeScale = 0.46,
    this.fontWeight = FontWeight.w500,
    this.paddingFactor = 0.08,
  });

  final String fontFamily;
  final Color textColor;
  final Color? backgroundColor;
  final double fontSizeScale;
  final FontWeight fontWeight;
  final double paddingFactor;

  TextReplacementStyle copyWith({
    String? fontFamily,
    Color? textColor,
    Color? backgroundColor,
    bool clearBackgroundColor = false,
    double? fontSizeScale,
    FontWeight? fontWeight,
    double? paddingFactor,
  }) {
    return TextReplacementStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      textColor: textColor ?? this.textColor,
      backgroundColor: clearBackgroundColor
          ? null
          : backgroundColor ?? this.backgroundColor,
      fontSizeScale: fontSizeScale ?? this.fontSizeScale,
      fontWeight: fontWeight ?? this.fontWeight,
      paddingFactor: paddingFactor ?? this.paddingFactor,
    );
  }
}

@immutable
class StrokeStyle {
  const StrokeStyle({
    required this.kind,
    required this.color,
    required this.widthScale,
  });

  final StrokeToolKind kind;
  final Color color;
  final double widthScale;

  StrokeStyle copyWith({
    StrokeToolKind? kind,
    Color? color,
    double? widthScale,
  }) {
    return StrokeStyle(
      kind: kind ?? this.kind,
      color: color ?? this.color,
      widthScale: widthScale ?? this.widthScale,
    );
  }
}

@immutable
class ShapeStyle {
  const ShapeStyle({
    required this.strokeColor,
    required this.strokeWidthScale,
    this.fillColor,
  });

  final Color strokeColor;
  final double strokeWidthScale;
  final Color? fillColor;

  ShapeStyle copyWith({
    Color? strokeColor,
    double? strokeWidthScale,
    Color? fillColor,
    bool clearFillColor = false,
  }) {
    return ShapeStyle(
      strokeColor: strokeColor ?? this.strokeColor,
      strokeWidthScale: strokeWidthScale ?? this.strokeWidthScale,
      fillColor: clearFillColor ? null : fillColor ?? this.fillColor,
    );
  }
}

sealed class PdfEditObject {
  const PdfEditObject({
    required this.id,
    required this.pageNumber,
    required this.normalizedRect,
    this.rotationDegrees = 0,
    this.opacity = 1,
    this.isLocked = false,
  });

  final String id;
  final int pageNumber;
  final Rect normalizedRect;
  final double rotationDegrees;
  final double opacity;
  final bool isLocked;

  PdfEditObject copyBase({
    int? pageNumber,
    Rect? normalizedRect,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  });
}

@immutable
class TextEditObject extends PdfEditObject {
  const TextEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required this.text,
    this.style = const TextReplacementStyle(backgroundColor: Colors.white),
    super.rotationDegrees,
    super.opacity,
    super.isLocked,
  });

  final String text;
  final TextReplacementStyle style;

  TextEditObject copyWith({
    int? pageNumber,
    Rect? normalizedRect,
    String? text,
    TextReplacementStyle? style,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return TextEditObject(
      id: id,
      pageNumber: pageNumber ?? this.pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      text: text ?? this.text,
      style: style ?? this.style,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      opacity: opacity ?? this.opacity,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  @override
  TextEditObject copyBase({
    int? pageNumber,
    Rect? normalizedRect,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return copyWith(
      pageNumber: pageNumber,
      normalizedRect: normalizedRect,
      rotationDegrees: rotationDegrees,
      opacity: opacity,
      isLocked: isLocked,
    );
  }
}

@immutable
sealed class _ImagePdfEditObject extends PdfEditObject {
  const _ImagePdfEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required this.imageBytes,
    super.rotationDegrees,
    super.opacity,
    super.isLocked,
  });

  final Uint8List imageBytes;
}

@immutable
class SignatureEditObject extends _ImagePdfEditObject {
  const SignatureEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required super.imageBytes,
    super.rotationDegrees,
    super.opacity,
    super.isLocked,
  });

  SignatureEditObject copyWith({
    int? pageNumber,
    Rect? normalizedRect,
    Uint8List? imageBytes,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return SignatureEditObject(
      id: id,
      pageNumber: pageNumber ?? this.pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      imageBytes: imageBytes ?? this.imageBytes,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      opacity: opacity ?? this.opacity,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  @override
  SignatureEditObject copyBase({
    int? pageNumber,
    Rect? normalizedRect,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return copyWith(
      pageNumber: pageNumber,
      normalizedRect: normalizedRect,
      rotationDegrees: rotationDegrees,
      opacity: opacity,
      isLocked: isLocked,
    );
  }
}

@immutable
class ImageEditObject extends _ImagePdfEditObject {
  const ImageEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required super.imageBytes,
    super.rotationDegrees,
    super.opacity,
    super.isLocked,
  });

  ImageEditObject copyWith({
    int? pageNumber,
    Rect? normalizedRect,
    Uint8List? imageBytes,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return ImageEditObject(
      id: id,
      pageNumber: pageNumber ?? this.pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      imageBytes: imageBytes ?? this.imageBytes,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      opacity: opacity ?? this.opacity,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  @override
  ImageEditObject copyBase({
    int? pageNumber,
    Rect? normalizedRect,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return copyWith(
      pageNumber: pageNumber,
      normalizedRect: normalizedRect,
      rotationDegrees: rotationDegrees,
      opacity: opacity,
      isLocked: isLocked,
    );
  }
}

@immutable
class StrokeEditObject extends PdfEditObject {
  const StrokeEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required this.points,
    required this.style,
    super.opacity,
    super.isLocked,
  }) : super(rotationDegrees: 0);

  final List<Offset> points;
  final StrokeStyle style;

  StrokeEditObject copyWith({
    int? pageNumber,
    Rect? normalizedRect,
    List<Offset>? points,
    StrokeStyle? style,
    double? opacity,
    bool? isLocked,
  }) {
    return StrokeEditObject(
      id: id,
      pageNumber: pageNumber ?? this.pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      points: List<Offset>.unmodifiable(points ?? this.points),
      style: style ?? this.style,
      opacity: opacity ?? this.opacity,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  @override
  StrokeEditObject copyBase({
    int? pageNumber,
    Rect? normalizedRect,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return copyWith(
      pageNumber: pageNumber,
      normalizedRect: normalizedRect,
      opacity: opacity,
      isLocked: isLocked,
    );
  }
}

@immutable
class ShapeEditObject extends PdfEditObject {
  const ShapeEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required this.kind,
    required this.style,
    super.rotationDegrees,
    super.opacity,
    super.isLocked,
  });

  final ShapeKind kind;
  final ShapeStyle style;

  ShapeEditObject copyWith({
    int? pageNumber,
    Rect? normalizedRect,
    ShapeKind? kind,
    ShapeStyle? style,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return ShapeEditObject(
      id: id,
      pageNumber: pageNumber ?? this.pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      kind: kind ?? this.kind,
      style: style ?? this.style,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      opacity: opacity ?? this.opacity,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  @override
  ShapeEditObject copyBase({
    int? pageNumber,
    Rect? normalizedRect,
    double? rotationDegrees,
    double? opacity,
    bool? isLocked,
  }) {
    return copyWith(
      pageNumber: pageNumber,
      normalizedRect: normalizedRect,
      rotationDegrees: rotationDegrees,
      opacity: opacity,
      isLocked: isLocked,
    );
  }
}

PdfEditObject duplicatePdfEditObject(
  PdfEditObject object, {
  required String newId,
  Offset offset = const Offset(0.02, 0.02),
}) {
  switch (object) {
    case TextEditObject():
      return TextEditObject(
        id: newId,
        pageNumber: object.pageNumber,
        normalizedRect: shiftNormalizedRect(object.normalizedRect, offset),
        text: object.text,
        style: object.style,
        rotationDegrees: object.rotationDegrees,
        opacity: object.opacity,
      );
    case SignatureEditObject():
      return SignatureEditObject(
        id: newId,
        pageNumber: object.pageNumber,
        normalizedRect: shiftNormalizedRect(object.normalizedRect, offset),
        imageBytes: object.imageBytes,
        rotationDegrees: object.rotationDegrees,
        opacity: object.opacity,
      );
    case ImageEditObject():
      return ImageEditObject(
        id: newId,
        pageNumber: object.pageNumber,
        normalizedRect: shiftNormalizedRect(object.normalizedRect, offset),
        imageBytes: object.imageBytes,
        rotationDegrees: object.rotationDegrees,
        opacity: object.opacity,
      );
    case StrokeEditObject():
      final shiftedPoints = object.points
          .map((point) => clampNormalizedOffset(point + offset))
          .toList(growable: false);
      return StrokeEditObject(
        id: newId,
        pageNumber: object.pageNumber,
        normalizedRect: computeNormalizedBounds(shiftedPoints),
        points: shiftedPoints,
        style: object.style,
        opacity: object.opacity,
      );
    case ShapeEditObject():
      return ShapeEditObject(
        id: newId,
        pageNumber: object.pageNumber,
        normalizedRect: shiftNormalizedRect(object.normalizedRect, offset),
        kind: object.kind,
        style: object.style,
        rotationDegrees: object.rotationDegrees,
        opacity: object.opacity,
      );
  }
}

Rect computeNormalizedBounds(Iterable<Offset> points) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;

  for (final point in points) {
    minX = math.min(minX, point.dx);
    minY = math.min(minY, point.dy);
    maxX = math.max(maxX, point.dx);
    maxY = math.max(maxY, point.dy);
  }

  if (!minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite) {
    return const Rect.fromLTWH(0, 0, 0, 0);
  }

  final rect = Rect.fromLTRB(minX, minY, maxX, maxY);
  final safeWidth = math.max(rect.width, 0.002);
  final safeHeight = math.max(rect.height, 0.002);
  return Rect.fromLTWH(rect.left, rect.top, safeWidth, safeHeight);
}

Offset clampNormalizedOffset(Offset offset) {
  return Offset(offset.dx.clamp(0.0, 1.0), offset.dy.clamp(0.0, 1.0));
}

Rect shiftNormalizedRect(Rect rect, Offset offset) {
  final shifted = rect.shift(offset);
  final left = shifted.left.clamp(0.0, 1.0 - shifted.width);
  final top = shifted.top.clamp(0.0, 1.0 - shifted.height);
  return Rect.fromLTWH(left, top, shifted.width, shifted.height);
}
