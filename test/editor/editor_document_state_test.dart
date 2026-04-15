import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_reader/src/editor/models/editor_document_state.dart';

void main() {
  test('upsertObject stores and updates objects by page', () {
    const first = TextEditObject(
      id: 'text-1',
      pageNumber: 1,
      normalizedRect: Rect.fromLTWH(0.1, 0.2, 0.3, 0.1),
      text: 'Alpha',
      style: TextReplacementStyle(
        textColor: Colors.black,
        backgroundColor: Colors.white,
      ),
    );

    final state = EditorDocumentState.empty.upsertObject(first);
    final updated = state.upsertObject(
      first.copyWith(
        normalizedRect: const Rect.fromLTWH(0.2, 0.2, 0.4, 0.1),
        text: 'Bravo',
      ),
    );

    expect(state.objectsForPage(1), hasLength(1));
    expect(updated.objectsForPage(1), hasLength(1));
    expect(updated.objectsForPage(1).single, isA<TextEditObject>());
    expect((updated.objectsForPage(1).single as TextEditObject).text, 'Bravo');
  });

  test('removeObject drops the matching object only', () {
    final state = EditorDocumentState.empty
        .upsertObject(
          const TextEditObject(
            id: 'text-1',
            pageNumber: 1,
            normalizedRect: Rect.fromLTWH(0.1, 0.2, 0.3, 0.1),
            text: 'One',
          ),
        )
        .upsertObject(
          ImageEditObject(
            id: 'image-1',
            pageNumber: 2,
            normalizedRect: Rect.fromLTWH(0.3, 0.2, 0.2, 0.2),
            imageBytes: Uint8List(0),
          ),
        );

    final updated = state.removeObject('text-1');

    expect(updated.objectsForPage(1), isEmpty);
    expect(updated.objectsForPage(2), hasLength(1));
    expect(updated.findObjectById('image-1'), isNotNull);
  });

  test('duplicate, reorder and lock shape objects', () {
    const shape = ShapeEditObject(
      id: 'shape-1',
      pageNumber: 1,
      normalizedRect: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
      kind: ShapeKind.rectangle,
      style: ShapeStyle(strokeColor: Colors.blue, strokeWidthScale: 0.006),
    );
    const text = TextEditObject(
      id: 'text-1',
      pageNumber: 1,
      normalizedRect: Rect.fromLTWH(0.4, 0.1, 0.2, 0.1),
      text: 'Hello',
    );

    final base = EditorDocumentState.empty
        .upsertObject(shape)
        .upsertObject(text);
    final duplicated = base.duplicateObject(
      'shape-1',
      newId: 'shape-2',
      offset: const Offset(0.05, 0.04),
    );

    expect(duplicated.objectsForPage(1), hasLength(3));
    final copied = duplicated.findObjectById('shape-2') as ShapeEditObject;
    expect(copied, isA<ShapeEditObject>());
    expect(copied.normalizedRect.width, closeTo(shape.normalizedRect.width, 0.0001));
    expect(copied.normalizedRect.height, closeTo(shape.normalizedRect.height, 0.0001));
    expect(copied.normalizedRect.left, greaterThan(shape.normalizedRect.left));
    expect(copied.normalizedRect.top, greaterThanOrEqualTo(shape.normalizedRect.top));

    final broughtForward = duplicated.bringObjectForward('shape-1');
    expect(broughtForward.objectsForPage(1)[1].id, 'shape-1');

    final locked = broughtForward.toggleObjectLock('shape-1');
    expect(
      (locked.findObjectById('shape-1') as ShapeEditObject).isLocked,
      isTrue,
    );
  });

  test('stroke duplication preserves translated points and bounds', () {
    const stroke = StrokeEditObject(
      id: 'stroke-1',
      pageNumber: 2,
      normalizedRect: Rect.fromLTWH(0.1, 0.2, 0.3, 0.2),
      points: <Offset>[Offset(0.1, 0.2), Offset(0.2, 0.25), Offset(0.4, 0.4)],
      style: StrokeStyle(
        kind: StrokeToolKind.pen,
        color: Colors.black,
        widthScale: 0.006,
      ),
    );

    final duplicated = EditorDocumentState.empty
        .upsertObject(stroke)
        .duplicateObject(
          'stroke-1',
          newId: 'stroke-2',
          offset: const Offset(0.1, 0.05),
        );

    final copied = duplicated.findObjectById('stroke-2') as StrokeEditObject;
    expect(copied.points, hasLength(3));
    expect(copied.points[0].dx, closeTo(0.2, 0.0001));
    expect(copied.points[0].dy, closeTo(0.25, 0.0001));
    expect(copied.points[1].dx, closeTo(0.3, 0.0001));
    expect(copied.points[1].dy, closeTo(0.3, 0.0001));
    expect(copied.points[2].dx, closeTo(0.5, 0.0001));
    expect(copied.points[2].dy, closeTo(0.45, 0.0001));
    expect(copied.normalizedRect, computeNormalizedBounds(copied.points));
  });

  test('text style can represent transparent background', () {
    const style = TextReplacementStyle(backgroundColor: Colors.white);

    final updated = style.copyWith(clearBackgroundColor: true);

    expect(updated.backgroundColor, isNull);
  });
}
