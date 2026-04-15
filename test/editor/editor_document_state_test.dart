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
}
