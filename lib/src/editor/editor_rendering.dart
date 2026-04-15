import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'editor_style_catalog.dart';
import 'models/editor_document_state.dart';

Color applyObjectOpacity(Color color, double opacity) {
  return Color.from(
    alpha: (color.a * opacity).clamp(0, 1),
    red: color.r,
    green: color.g,
    blue: color.b,
    colorSpace: color.colorSpace,
  );
}

double strokeWidthForScale(double scale, Size size) {
  return math.max(1.5, math.min(size.width, size.height) * scale);
}

TextStyle buildEditorTextStyle(
  TextReplacementStyle style, {
  required double fontSize,
  required double opacity,
}) {
  return TextStyle(
    fontFamily: style.fontFamily,
    fontSize: fontSize,
    color: applyObjectOpacity(style.textColor, opacity),
    fontWeight: style.fontWeight,
    fontVariations: EditorStyleCatalog.fontVariations(style.fontWeight),
    height: 1.08,
  );
}

void paintStrokeObject(
  Canvas canvas,
  StrokeEditObject object,
  Rect rect,
  Size pageSize,
) {
  if (object.points.length < 2) {
    return;
  }

  final localPoints = object.points
      .map(
        (point) => Offset(
          point.dx * pageSize.width - rect.left,
          point.dy * pageSize.height - rect.top,
        ),
      )
      .toList(growable: false);
  if (localPoints.length < 2) {
    return;
  }

  final paint = Paint()
    ..color = applyObjectOpacity(object.style.color, object.opacity)
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidthForScale(object.style.widthScale, pageSize)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  final path = Path()..moveTo(localPoints.first.dx, localPoints.first.dy);
  for (var index = 1; index < localPoints.length; index += 1) {
    path.lineTo(localPoints[index].dx, localPoints[index].dy);
  }

  canvas.drawPath(path, paint);
}

void paintShapeObject(
  Canvas canvas,
  ShapeEditObject object,
  Rect rect,
  Size pageSize,
) {
  final strokePaint = Paint()
    ..color = applyObjectOpacity(object.style.strokeColor, object.opacity)
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidthForScale(
      object.style.strokeWidthScale,
      pageSize,
    );
  final fillColor = object.style.fillColor == null
      ? null
      : applyObjectOpacity(object.style.fillColor!, object.opacity);

  canvas.save();
  canvas.translate(rect.center.dx, rect.center.dy);
  canvas.rotate(object.rotationDegrees * math.pi / 180);
  final localRect = Rect.fromCenter(
    center: Offset.zero,
    width: rect.width,
    height: rect.height,
  );

  switch (object.kind) {
    case ShapeKind.rectangle:
      if (fillColor != null) {
        canvas.drawRect(localRect, Paint()..color = fillColor);
      }
      canvas.drawRect(localRect, strokePaint);
    case ShapeKind.ellipse:
      if (fillColor != null) {
        canvas.drawOval(localRect, Paint()..color = fillColor);
      }
      canvas.drawOval(localRect, strokePaint);
    case ShapeKind.line:
      canvas.drawLine(localRect.topLeft, localRect.bottomRight, strokePaint);
    case ShapeKind.arrow:
      final start = localRect.topLeft;
      final end = localRect.bottomRight;
      canvas.drawLine(start, end, strokePaint);
      final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
      final headLength = math.max(12, strokePaint.strokeWidth * 4);
      final left = Offset(
        end.dx - headLength * math.cos(angle - math.pi / 6),
        end.dy - headLength * math.sin(angle - math.pi / 6),
      );
      final right = Offset(
        end.dx - headLength * math.cos(angle + math.pi / 6),
        end.dy - headLength * math.sin(angle + math.pi / 6),
      );
      final arrowPath = Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(left.dx, left.dy)
        ..moveTo(end.dx, end.dy)
        ..lineTo(right.dx, right.dy);
      canvas.drawPath(arrowPath, strokePaint);
  }

  canvas.restore();
}

void paintTextObject(Canvas canvas, TextEditObject object, Rect rect) {
  final padding = math.max(
    6.0,
    math.min(rect.width, rect.height) * object.style.paddingFactor,
  );
  final textStyle = buildEditorTextStyle(
    object.style,
    fontSize: math.max(
      EditorStyleCatalog.minTextFontSize,
      rect.height * object.style.fontSizeScale,
    ),
    opacity: object.opacity,
  );

  canvas.save();
  canvas.translate(rect.left, rect.top);
  canvas.rotate(object.rotationDegrees * math.pi / 180);
  final localRect = Rect.fromLTWH(0, 0, rect.width, rect.height);
  canvas.clipRect(localRect);

  if (object.style.backgroundColor != null) {
    canvas.drawRect(
      localRect,
      Paint()
        ..color = applyObjectOpacity(
          object.style.backgroundColor!,
          object.opacity,
        ),
    );
  }

  final textPainter = TextPainter(
    text: TextSpan(text: object.text, style: textStyle),
    textDirection: TextDirection.ltr,
    maxLines: null,
  )..layout(maxWidth: math.max(24, localRect.width - (padding * 2)));
  textPainter.paint(canvas, Offset(padding, padding));
  canvas.restore();
}

void paintImageObject(
  Canvas canvas,
  ui.Image image,
  Rect rect,
  double rotationDegrees,
  double opacity,
) {
  final destination = Rect.fromCenter(
    center: Offset.zero,
    width: rect.width,
    height: rect.height,
  );
  final source = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );

  canvas.save();
  canvas.translate(rect.center.dx, rect.center.dy);
  canvas.rotate(rotationDegrees * math.pi / 180);
  canvas.drawImageRect(
    image,
    source,
    destination,
    Paint()
      ..filterQuality = FilterQuality.high
      ..colorFilter = ColorFilter.mode(
        Color.fromARGB((255 * opacity).round(), 255, 255, 255),
        BlendMode.modulate,
      ),
  );
  canvas.restore();
}
