import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

class ImportedScanImage {
  const ImportedScanImage({required this.bytes, required this.displayName});

  final Uint8List bytes;
  final String displayName;
}

class ScanImportService {
  const ScanImportService([ImagePicker? picker]) : _picker = picker;

  final ImagePicker? _picker;

  ImagePicker get _imagePicker => _picker ?? ImagePicker();

  Future<ImportedScanImage?> captureWithCamera() async {
    final file = await _imagePicker.pickImage(source: ImageSource.camera);
    if (file == null) {
      return null;
    }
    return _toImportedImage(file);
  }

  Future<List<ImportedScanImage>> pickMultipleFromGallery() async {
    final files = await _imagePicker.pickMultiImage();
    return _toImportedImages(files);
  }

  Future<List<ImportedScanImage>> retrieveLostImages() async {
    final response = await _imagePicker.retrieveLostData();
    if (response.isEmpty) {
      return const <ImportedScanImage>[];
    }

    final files = response.files;
    if (files == null || files.isEmpty) {
      return const <ImportedScanImage>[];
    }

    return _toImportedImages(files);
  }

  Future<List<ImportedScanImage>> _toImportedImages(List<XFile> files) async {
    final imported = <ImportedScanImage>[];
    for (final file in files) {
      imported.add(await _toImportedImage(file));
    }
    return List<ImportedScanImage>.unmodifiable(imported);
  }

  Future<ImportedScanImage> _toImportedImage(XFile file) async {
    final bytes = await file.readAsBytes();
    final fileName = file.name.trim().isNotEmpty
        ? file.name
        : p.basename(file.path);
    return ImportedScanImage(
      bytes: bytes,
      displayName: fileName.isEmpty ? 'scan-image.jpg' : fileName,
    );
  }
}
