import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_reader/src/data/document_repository.dart';
import 'package:pdf_reader/src/data/document_store.dart';

void main() {
  group('DocumentRepository', () {
    late _MemoryDocumentStore store;
    late DocumentRepository repository;

    setUp(() {
      store = _MemoryDocumentStore();
      repository = DocumentRepository(store: store);
    });

    test('upsertOpenedDocument preserves favorite, progress and page count', () async {
      final first = await repository.upsertOpenedDocument(
        uri: 'content://pdfs/alpha.pdf',
        displayName: 'alpha.pdf',
        sizeBytes: 1024,
      );

      await repository.toggleFavorite(first.uri);
      await repository.saveReadingProgress(
        uri: first.uri,
        lastPage: 6,
        pageCount: 20,
      );

      final updated = await repository.upsertOpenedDocument(
        uri: first.uri,
        displayName: 'alpha-v2.pdf',
        sizeBytes: 2048,
      );

      expect(updated.displayName, 'alpha-v2.pdf');
      expect(updated.isFavorite, isTrue);
      expect(updated.lastPage, 6);
      expect(updated.pageCount, 20);
      expect(updated.sizeBytes, 2048);
    });

    test('toggleFavorite moves state without removing document', () async {
      final document = await repository.upsertOpenedDocument(
        uri: 'content://pdfs/favorite.pdf',
        displayName: 'favorite.pdf',
      );

      final documents = await repository.toggleFavorite(document.uri);

      expect(documents, hasLength(1));
      expect(documents.single.isFavorite, isTrue);
    });

    test('saveReadingProgress updates persisted page and page count', () async {
      final document = await repository.upsertOpenedDocument(
        uri: 'content://pdfs/progress.pdf',
        displayName: 'progress.pdf',
      );

      final documents = await repository.saveReadingProgress(
        uri: document.uri,
        lastPage: 9,
        pageCount: 42,
      );

      expect(documents.single.lastPage, 9);
      expect(documents.single.pageCount, 42);
    });

    test('removeDocument deletes the target entry', () async {
      await repository.upsertOpenedDocument(
        uri: 'content://pdfs/one.pdf',
        displayName: 'one.pdf',
      );
      await repository.upsertOpenedDocument(
        uri: 'content://pdfs/two.pdf',
        displayName: 'two.pdf',
      );

      final documents = await repository.removeDocument('content://pdfs/one.pdf');

      expect(documents, hasLength(1));
      expect(documents.single.uri, 'content://pdfs/two.pdf');
    });
  });
}

class _MemoryDocumentStore implements DocumentStore {
  String? value;

  @override
  Future<String?> readDocumentsJson() async => value;

  @override
  Future<void> writeDocumentsJson(String json) async {
    value = json;
  }
}
