import 'package:flutter/foundation.dart';

import 'document_store.dart';
import 'saved_document.dart';

class DocumentRepository {
  DocumentRepository({
    required DocumentStore store,
  }) : _store = store;

  final DocumentStore _store;

  Future<List<SavedDocument>> loadDocuments() async {
    try {
      final raw = await _store.readDocumentsJson();
      if (raw == null || raw.isEmpty) {
        return const <SavedDocument>[];
      }

      final documents = SavedDocument.decodeList(raw).toList(growable: true);
      documents.sort(_sortByLastOpened);
      return List<SavedDocument>.unmodifiable(documents);
    } catch (error, stackTrace) {
      debugPrint('DocumentRepository.loadDocuments failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await _store.writeDocumentsJson('[]');
      return const <SavedDocument>[];
    }
  }

  Future<SavedDocument> upsertOpenedDocument({
    required String uri,
    required String displayName,
    int? sizeBytes,
  }) async {
    final documents = (await loadDocuments()).toList(growable: true);
    final existingIndex = documents.indexWhere((document) => document.uri == uri);
    final existing = existingIndex >= 0 ? documents.removeAt(existingIndex) : null;
    final updated = SavedDocument(
      uri: uri,
      displayName: displayName,
      lastOpenedAt: DateTime.now(),
      lastPage: existing?.lastPage ?? 0,
      isFavorite: existing?.isFavorite ?? false,
      pageCount: existing?.pageCount,
      sizeBytes: sizeBytes ?? existing?.sizeBytes,
    );
    documents.insert(0, updated);
    await _persist(documents);
    return updated;
  }

  Future<List<SavedDocument>> toggleFavorite(String uri) async {
    final documents = (await loadDocuments()).toList(growable: true);
    final index = documents.indexWhere((document) => document.uri == uri);
    if (index < 0) {
      return List<SavedDocument>.unmodifiable(documents);
    }

    final current = documents[index];
    documents[index] = current.copyWith(isFavorite: !current.isFavorite);
    await _persist(documents);
    return List<SavedDocument>.unmodifiable(documents);
  }

  Future<List<SavedDocument>> saveReadingProgress({
    required String uri,
    required int lastPage,
    int? pageCount,
  }) async {
    final documents = (await loadDocuments()).toList(growable: true);
    final index = documents.indexWhere((document) => document.uri == uri);
    if (index < 0) {
      return List<SavedDocument>.unmodifiable(documents);
    }

    final current = documents[index];
    documents[index] = current.copyWith(
      lastPage: lastPage,
      pageCount: pageCount ?? current.pageCount,
    );
    await _persist(documents);
    return List<SavedDocument>.unmodifiable(documents);
  }

  Future<List<SavedDocument>> removeDocument(String uri) async {
    final documents = (await loadDocuments())
        .where((document) => document.uri != uri)
        .toList(growable: false);
    await _persist(documents);
    return documents;
  }

  Future<SavedDocument?> findByUri(String uri) async {
    final documents = await loadDocuments();
    return documents.where((document) => document.uri == uri).firstOrNull;
  }

  Future<void> _persist(List<SavedDocument> documents) {
    documents.sort(_sortByLastOpened);
    return _store.writeDocumentsJson(
      SavedDocument.encodeList(documents),
    );
  }

  static int _sortByLastOpened(SavedDocument left, SavedDocument right) {
    return right.lastOpenedAt.compareTo(left.lastOpenedAt);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
