import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:pdf_reader/src/app/pdf_reader_app.dart';
import 'package:pdf_reader/src/data/document_repository.dart';
import 'package:pdf_reader/src/data/document_store.dart';
import 'package:pdf_reader/src/platform/document_bridge.dart';

void main() {
  testWidgets('shows empty library state', (tester) async {
    final repository = DocumentRepository(store: _MemoryDocumentStore());

    await tester.pumpWidget(
      PdfReaderApp(
        repository: repository,
        documentBridge: const _FakeDocumentBridge(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Aucun document'), findsOneWidget);
    expect(find.text('Ouvrir un PDF'), findsWidgets);
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

class _FakeDocumentBridge implements DocumentBridge {
  const _FakeDocumentBridge();

  @override
  Future<PreparedPdfDocument?> pickPdfDocument() async => null;

  @override
  Future<PreparedPdfDocument?> preparePdfDocument(String uri) async => null;

  @override
  Future<PreparedPdfDocument?> consumePendingOpenedPdfDocument() async => null;

  @override
  Stream<PreparedPdfDocument> get openedPdfDocuments =>
      const Stream<PreparedPdfDocument>.empty();

  @override
  Future<void> sharePdfDocument({
    required String uri,
    required String localPath,
    required String displayName,
  }) async {}
}
