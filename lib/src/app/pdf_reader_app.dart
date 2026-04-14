import 'package:flutter/material.dart';

import '../data/document_repository.dart';
import '../platform/document_bridge.dart';
import '../screens/home/home_screen.dart';
import '../theme/app_theme.dart';
import 'app_strings.dart';

class PdfReaderApp extends StatelessWidget {
  const PdfReaderApp({
    super.key,
    required this.repository,
    required this.documentBridge,
  });

  final DocumentRepository repository;
  final DocumentBridge documentBridge;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppStrings.appName,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: HomeScreen(
        repository: repository,
        documentBridge: documentBridge,
      ),
    );
  }
}
