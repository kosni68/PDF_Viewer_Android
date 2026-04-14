import 'package:flutter/widgets.dart';

import 'src/app/pdf_reader_app.dart';
import 'src/data/document_repository.dart';
import 'src/data/document_store.dart';
import 'src/platform/document_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final repository = DocumentRepository(
    store: SharedPreferencesDocumentStore(),
  );

  runApp(
    PdfReaderApp(
      repository: repository,
      documentBridge: const MethodChannelDocumentBridge(),
    ),
  );
}
