import 'dart:typed_data';

import 'package:flutter/material.dart';

@immutable
class EditorDocumentState {
  const EditorDocumentState({
    this.layers = const <int, PageEditLayer>{},
  });

  final Map<int, PageEditLayer> layers;

  static const empty = EditorDocumentState();

  List<PdfEditObject> objectsForPage(int pageNumber) {
    final layer = layers[pageNumber];
    if (layer == null) {
      return const <PdfEditObject>[];
    }
    return layer.objects;
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
    final sourceLayer = updatedLayers[object.pageNumber];
    final objects = sourceLayer?.objects.toList(growable: true) ?? <PdfEditObject>[];
    final index = objects.indexWhere((candidate) => candidate.id == object.id);
    if (index >= 0) {
      objects[index] = object;
    } else {
      objects.add(object);
    }
    updatedLayers[object.pageNumber] = PageEditLayer(
      pageNumber: object.pageNumber,
      objects: List<PdfEditObject>.unmodifiable(objects),
    );
    return EditorDocumentState(layers: Map<int, PageEditLayer>.unmodifiable(updatedLayers));
  }

  EditorDocumentState removeObject(String id) {
    final updatedLayers = Map<int, PageEditLayer>.from(layers);
    for (final entry in layers.entries) {
      final objects = entry.value.objects.where((object) => object.id != id).toList(growable: false);
      if (objects.length == entry.value.objects.length) {
        continue;
      }
      if (objects.isEmpty) {
        updatedLayers.remove(entry.key);
      } else {
        updatedLayers[entry.key] = PageEditLayer(
          pageNumber: entry.key,
          objects: List<PdfEditObject>.unmodifiable(objects),
        );
      }
      break;
    }
    return EditorDocumentState(layers: Map<int, PageEditLayer>.unmodifiable(updatedLayers));
  }

  bool get hasObjects => layers.values.any((layer) => layer.objects.isNotEmpty);
}

@immutable
class PageEditLayer {
  const PageEditLayer({
    required this.pageNumber,
    required this.objects,
  });

  final int pageNumber;
  final List<PdfEditObject> objects;
}

@immutable
class TextReplacementStyle {
  const TextReplacementStyle({
    this.textColor = Colors.black,
    this.backgroundColor = Colors.white,
    this.fontScale = 0.48,
    this.fontWeight = FontWeight.w600,
    this.paddingFactor = 0.08,
  });

  final Color textColor;
  final Color backgroundColor;
  final double fontScale;
  final FontWeight fontWeight;
  final double paddingFactor;
}

sealed class PdfEditObject {
  const PdfEditObject({
    required this.id,
    required this.pageNumber,
    required this.normalizedRect,
    this.rotationDegrees = 0,
  });

  final String id;
  final int pageNumber;
  final Rect normalizedRect;
  final double rotationDegrees;
}

@immutable
class TextEditObject extends PdfEditObject {
  const TextEditObject({
    required super.id,
    required super.pageNumber,
    required super.normalizedRect,
    required this.text,
    this.style = const TextReplacementStyle(),
  });

  final String text;
  final TextReplacementStyle style;

  TextEditObject copyWith({
    Rect? normalizedRect,
    String? text,
    TextReplacementStyle? style,
  }) {
    return TextEditObject(
      id: id,
      pageNumber: pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      text: text ?? this.text,
      style: style ?? this.style,
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
  });

  SignatureEditObject copyWith({
    Rect? normalizedRect,
    Uint8List? imageBytes,
    double? rotationDegrees,
  }) {
    return SignatureEditObject(
      id: id,
      pageNumber: pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      imageBytes: imageBytes ?? this.imageBytes,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
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
  });

  ImageEditObject copyWith({
    Rect? normalizedRect,
    Uint8List? imageBytes,
    double? rotationDegrees,
  }) {
    return ImageEditObject(
      id: id,
      pageNumber: pageNumber,
      normalizedRect: normalizedRect ?? this.normalizedRect,
      imageBytes: imageBytes ?? this.imageBytes,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    );
  }
}
