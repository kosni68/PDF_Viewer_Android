import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

class ImportedEditorImage {
  const ImportedEditorImage({
    required this.bytes,
    required this.displayName,
  });

  final Uint8List bytes;
  final String displayName;
}

class ImageImportService {
  const ImageImportService();

  Future<ImportedEditorImage?> pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    final files = result?.files;
    final file = files != null && files.length == 1 ? files.first : null;
    if (file == null) {
      return null;
    }

    final bytes = file.bytes ?? await _readBytesFromPath(file.path);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }

    return ImportedEditorImage(
      bytes: bytes,
      displayName: file.name,
    );
  }

  Future<Uint8List?> _readBytesFromPath(String? path) async {
    if (path == null || path.isEmpty) {
      return null;
    }
    return File(path).readAsBytes();
  }
}
