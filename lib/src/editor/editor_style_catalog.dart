import 'package:flutter/material.dart';

import 'models/editor_document_state.dart';

@immutable
class EditorFontOption {
  const EditorFontOption({required this.family, required this.label});

  final String family;
  final String label;
}

abstract final class EditorStyleCatalog {
  static const fonts = <EditorFontOption>[
    EditorFontOption(family: 'NotoSans', label: 'Noto Sans'),
    EditorFontOption(family: 'NotoSerif', label: 'Noto Serif'),
    EditorFontOption(family: 'RobotoMono', label: 'Roboto Mono'),
    EditorFontOption(family: 'Oswald', label: 'Oswald'),
    EditorFontOption(family: 'Caveat', label: 'Caveat'),
  ];

  static const colorPresets = <Color>[
    Color(0xFF111111),
    Color(0xFFFFFFFF),
    Color(0xFFB00020),
    Color(0xFF006C4C),
    Color(0xFF0B57D0),
    Color(0xFFF57C00),
    Color(0xFF6A1B9A),
    Color(0xFF455A64),
    Color(0xFFFFC107),
    Color(0xFFD84315),
  ];

  static const textSizes = <double>[
    0.06,
    0.08,
    0.1,
    0.12,
    0.18,
    0.24,
    0.32,
    0.46,
    0.58,
    0.7,
  ];
  static const strokeSizes = <double>[0.003, 0.006, 0.01, 0.016, 0.024];
  static const minTextFontSize = 6.0;

  static const defaultTextStyle = TextReplacementStyle(
    fontFamily: 'NotoSans',
    textColor: Color(0xFF111111),
    backgroundColor: Colors.white,
    fontSizeScale: 0.46,
    fontWeight: FontWeight.w500,
  );

  static const defaultPenStyle = StrokeStyle(
    kind: StrokeToolKind.pen,
    color: Color(0xFF111111),
    widthScale: 0.006,
  );

  static const defaultHighlighterStyle = StrokeStyle(
    kind: StrokeToolKind.highlighter,
    color: Color(0xFFFFEB3B),
    widthScale: 0.018,
  );

  static const defaultEraserStyle = StrokeStyle(
    kind: StrokeToolKind.eraser,
    color: Colors.white,
    widthScale: 0.024,
  );

  static const defaultShapeStyle = ShapeStyle(
    strokeColor: Color(0xFF0B57D0),
    strokeWidthScale: 0.006,
    fillColor: null,
  );

  static const fontWeights = <FontWeight>[
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
  ];

  static String labelForWeight(FontWeight weight) {
    return switch (weight) {
      FontWeight.w400 => 'Regular',
      FontWeight.w500 => 'Medium',
      FontWeight.w600 => 'SemiBold',
      _ => 'Bold',
    };
  }

  static double fontVariationWeight(FontWeight weight) {
    return switch (weight) {
      FontWeight.w100 => 100,
      FontWeight.w200 => 200,
      FontWeight.w300 => 300,
      FontWeight.w400 => 400,
      FontWeight.w500 => 500,
      FontWeight.w600 => 600,
      FontWeight.w700 => 700,
      FontWeight.w800 => 800,
      FontWeight.w900 => 900,
      _ => 400,
    };
  }

  static List<FontVariation> fontVariations(FontWeight weight) {
    return <FontVariation>[FontVariation('wght', fontVariationWeight(weight))];
  }
}
