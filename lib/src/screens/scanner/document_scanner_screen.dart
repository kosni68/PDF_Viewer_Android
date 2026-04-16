import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/app_strings.dart';
import '../../data/document_repository.dart';
import '../../data/saved_document.dart';
import '../../platform/document_bridge.dart';
import '../../scanner/models/scanner_models.dart';
import '../../scanner/services/scan_image_processing_service.dart';
import '../../scanner/services/scan_import_service.dart';
import '../../scanner/services/scanned_pdf_export_service.dart';

class DocumentScannerResult {
  const DocumentScannerResult({
    required this.savedDocument,
    required this.preparedDocument,
  });

  final SavedDocument savedDocument;
  final PreparedPdfDocument preparedDocument;
}

class DocumentScannerScreen extends StatefulWidget {
  const DocumentScannerScreen({
    super.key,
    required this.repository,
    required this.documentBridge,
  });

  final DocumentRepository repository;
  final DocumentBridge documentBridge;

  @override
  State<DocumentScannerScreen> createState() => _DocumentScannerScreenState();
}

enum _ScanCropEditMode { rectangle, corners }

class _DocumentScannerScreenState extends State<DocumentScannerScreen> {
  final ScanImportService _importService = const ScanImportService();
  final ScanImageProcessingService _imageProcessingService =
      const ScanImageProcessingService();
  late final ScannedPdfExportService _exportService = ScannedPdfExportService(
    _imageProcessingService,
  );
  final CropController _cropController = CropController();

  ScanDraftDocument _draft = ScanDraftDocument.empty;
  Future<ProcessedScanPage>? _previewFuture;
  Future<ProcessedScanPage>? _cropEditorFuture;
  Future<ProcessedScanPage>? _cornerEditorFuture;
  bool _isImporting = false;
  bool _isSaving = false;
  bool _isAutoCropping = false;
  bool _isCropping = false;
  _ScanCropEditMode _cropEditMode = _ScanCropEditMode.rectangle;
  Rect? _pendingCropRectNormalized;
  ScanDocumentCorners? _pendingDocumentCornersNormalized;
  int _pageCounter = 0;
  Timer? _previewRefreshDebounce;

  @override
  void initState() {
    super.initState();
    unawaited(_recoverLostImages());
  }

  @override
  void dispose() {
    _previewRefreshDebounce?.cancel();
    super.dispose();
  }

  String _newPageId() {
    _pageCounter += 1;
    return 'scan-page-${DateTime.now().microsecondsSinceEpoch}-$_pageCounter';
  }

  ScannedPageDraft? get _selectedPage => _draft.selectedPage;

  Future<void> _recoverLostImages() async {
    final recoveredImages = await _importService.retrieveLostImages();
    if (!mounted || recoveredImages.isEmpty) {
      return;
    }
    await _appendImportedImages(recoveredImages);
  }

  Future<void> _captureWithCamera() async {
    if (_isImporting || _isSaving) {
      return;
    }

    setState(() => _isImporting = true);
    try {
      final importedImage = await _importService.captureWithCamera();
      if (!mounted || importedImage == null) {
        return;
      }
      await _appendImportedImages(<ImportedScanImage>[
        importedImage,
      ], openCropEditor: true);
    } catch (_) {
      if (mounted) {
        _showMessage(AppStrings.scannerImportFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _importFromGallery() async {
    if (_isImporting || _isSaving) {
      return;
    }

    setState(() => _isImporting = true);
    try {
      final importedImages = await _importService.pickMultipleFromGallery();
      if (!mounted || importedImages.isEmpty) {
        return;
      }
      await _appendImportedImages(importedImages);
    } catch (_) {
      if (mounted) {
        _showMessage(AppStrings.scannerImportFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _appendImportedImages(
    List<ImportedScanImage> importedImages, {
    bool openCropEditor = false,
  }) async {
    final pages = await Future.wait<ScannedPageDraft>(
      importedImages.map(
        (importedImage) => _imageProcessingService.createDraft(
          id: _newPageId(),
          sourceName: importedImage.displayName,
          originalBytes: importedImage.bytes,
        ),
      ),
    );
    if (!mounted || pages.isEmpty) {
      return;
    }

    setState(() {
      _draft = _draft.addPages(pages);
      _isCropping = false;
      _cropEditMode = _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = null;
      _pendingDocumentCornersNormalized = null;
      _syncPreviewFutures();
    });

    if (openCropEditor && pages.length == 1) {
      await _openCropEditorForSelectedPage(triggerAutoDetection: true);
    }
  }

  Future<void> _openCropEditorForSelectedPage({
    bool triggerAutoDetection = false,
  }) async {
    final selectedPage = _selectedPage;
    if (selectedPage == null || !mounted) {
      return;
    }

    setState(() {
      _isCropping = true;
      _cropEditMode = selectedPage.documentCornersNormalized != null
          ? _ScanCropEditMode.corners
          : _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = selectedPage.cropRectNormalized;
      _pendingDocumentCornersNormalized =
          selectedPage.documentCornersNormalized ?? _defaultDocumentCorners();
      _syncPreviewFutures();
    });

    if (triggerAutoDetection) {
      await _autoCropSelectedPage();
    }
  }

  void _syncPreviewFutures() {
    final selectedPage = _draft.selectedPage;
    _previewFuture = selectedPage == null
        ? null
        : _imageProcessingService.buildPreviewPage(selectedPage);
    _cropEditorFuture =
        !_isCropping ||
            selectedPage == null ||
            _cropEditMode != _ScanCropEditMode.rectangle
        ? null
        : _imageProcessingService.buildCropEditorPage(selectedPage);
    _cornerEditorFuture =
        !_isCropping ||
            selectedPage == null ||
            _cropEditMode != _ScanCropEditMode.corners
        ? null
        : _imageProcessingService.buildCornerEditorPage(selectedPage);
  }

  void _schedulePreviewRefresh() {
    _previewRefreshDebounce?.cancel();
    _previewRefreshDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) {
        return;
      }
      setState(_syncPreviewFutures);
    });
  }

  void _selectPage(String pageId) {
    setState(() {
      _draft = _draft.copyWith(selectedPageId: pageId);
      _isCropping = false;
      _cropEditMode = _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = null;
      _pendingDocumentCornersNormalized = null;
      _syncPreviewFutures();
    });
  }

  void _reorderPages(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    setState(() {
      _draft = _draft.reorderPages(oldIndex, newIndex);
      _syncPreviewFutures();
    });
  }

  void _deleteSelectedPage() {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    setState(() {
      _draft = _draft.removePage(selectedPage.id);
      _isCropping = false;
      _cropEditMode = _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = null;
      _pendingDocumentCornersNormalized = null;
      _syncPreviewFutures();
    });
  }

  void _rotateSelectedPage(int deltaQuarterTurns) {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    final nextRotation =
        (selectedPage.rotationQuarterTurns + deltaQuarterTurns) % 4;
    setState(() {
      _draft = _draft.replacePage(
        selectedPage.copyWith(
          rotationQuarterTurns: nextRotation,
          cropRectNormalized: ScanImageProcessingService.fullCropRect,
          clearDocumentCorners: true,
        ),
      );
      _isCropping = false;
      _cropEditMode = _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = null;
      _pendingDocumentCornersNormalized = null;
      _syncPreviewFutures();
    });
  }

  void _updateSelectedPage(
    ScannedPageDraft Function(ScannedPageDraft page) update, {
    bool debouncePreview = false,
  }) {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    setState(() {
      _draft = _draft.replacePage(update(selectedPage));
      if (!debouncePreview) {
        _syncPreviewFutures();
      }
    });

    if (debouncePreview) {
      _schedulePreviewRefresh();
    }
  }

  ScanDocumentCorners _defaultDocumentCorners() {
    return const ScanDocumentCorners(
      topLeft: Offset(0.12, 0.12),
      topRight: Offset(0.88, 0.12),
      bottomLeft: Offset(0.12, 0.88),
      bottomRight: Offset(0.88, 0.88),
    );
  }

  void _toggleCropMode() {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    setState(() {
      if (_isCropping) {
        _isCropping = false;
        _cropEditMode = _ScanCropEditMode.rectangle;
        _pendingCropRectNormalized = null;
        _pendingDocumentCornersNormalized = null;
      } else {
        _isCropping = true;
        _cropEditMode = selectedPage.documentCornersNormalized != null
            ? _ScanCropEditMode.corners
            : _ScanCropEditMode.rectangle;
        _pendingCropRectNormalized = selectedPage.cropRectNormalized;
        _pendingDocumentCornersNormalized =
            selectedPage.documentCornersNormalized ?? _defaultDocumentCorners();
      }
      _syncPreviewFutures();
    });
  }

  void _setCropEditMode(_ScanCropEditMode cropEditMode) {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    setState(() {
      _cropEditMode = cropEditMode;
      _pendingCropRectNormalized ??= selectedPage.cropRectNormalized;
      _pendingDocumentCornersNormalized ??=
          selectedPage.documentCornersNormalized ?? _defaultDocumentCorners();
    });
  }

  void _applyCrop() {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    setState(() {
      if (_cropEditMode == _ScanCropEditMode.corners) {
        _draft = _draft.replacePage(
          selectedPage.copyWith(
            documentCornersNormalized:
                _pendingDocumentCornersNormalized ?? _defaultDocumentCorners(),
          ),
        );
      } else {
        final pendingCropRectNormalized = _pendingCropRectNormalized;
        if (pendingCropRectNormalized != null) {
          _draft = _draft.replacePage(
            selectedPage.copyWith(
              cropRectNormalized: pendingCropRectNormalized,
            ),
          );
        }
      }
      _isCropping = false;
      _cropEditMode = _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = null;
      _pendingDocumentCornersNormalized = null;
      _syncPreviewFutures();
    });
  }

  Future<void> _autoCropSelectedPage() async {
    final selectedPage = _selectedPage;
    if (selectedPage == null || _isAutoCropping) {
      return;
    }

    setState(() => _isAutoCropping = true);
    try {
      final detectedDocument = await _imageProcessingService
          .suggestAutoDetection(selectedPage);
      if (!mounted) {
        return;
      }

      if (detectedDocument.documentCornersNormalized == null &&
          detectedDocument.cropRectNormalized ==
              ScanImageProcessingService.fullCropRect) {
        _showMessage(AppStrings.scannerAutoCropFailed);
        return;
      }

      setState(() {
        _draft = _draft.replacePage(
          selectedPage.copyWith(
            cropRectNormalized:
                detectedDocument.documentCornersNormalized == null
                ? detectedDocument.cropRectNormalized
                : ScanImageProcessingService.fullCropRect,
            documentCornersNormalized:
                detectedDocument.documentCornersNormalized,
            clearDocumentCorners:
                detectedDocument.documentCornersNormalized == null,
          ),
        );
        _cropEditMode = detectedDocument.documentCornersNormalized == null
            ? _ScanCropEditMode.rectangle
            : _ScanCropEditMode.corners;
        _pendingCropRectNormalized =
            detectedDocument.documentCornersNormalized == null
            ? detectedDocument.cropRectNormalized
            : ScanImageProcessingService.fullCropRect;
        _pendingDocumentCornersNormalized =
            detectedDocument.documentCornersNormalized ??
            _defaultDocumentCorners();
        _syncPreviewFutures();
      });
    } catch (_) {
      if (mounted) {
        _showMessage(AppStrings.scannerAutoCropFailed);
      }
    } finally {
      if (mounted) {
        setState(() => _isAutoCropping = false);
      }
    }
  }

  void _resetCropSelectedPage() {
    final selectedPage = _selectedPage;
    if (selectedPage == null) {
      return;
    }

    setState(() {
      _draft = _draft.replacePage(
        selectedPage.copyWith(
          cropRectNormalized: ScanImageProcessingService.fullCropRect,
          clearDocumentCorners: true,
        ),
      );
      _cropEditMode = _ScanCropEditMode.rectangle;
      _pendingCropRectNormalized = ScanImageProcessingService.fullCropRect;
      _pendingDocumentCornersNormalized = _defaultDocumentCorners();
      _syncPreviewFutures();
    });
  }

  void _updatePendingDocumentCorner(
    _ScanCornerHandle cornerHandle,
    Offset normalizedPoint,
  ) {
    final currentCorners =
        _pendingDocumentCornersNormalized ??
        _selectedPage?.documentCornersNormalized;
    if (currentCorners == null) {
      return;
    }

    const minGap = 0.04;
    var nextPoint = Offset(
      normalizedPoint.dx.clamp(0.0, 1.0).toDouble(),
      normalizedPoint.dy.clamp(0.0, 1.0).toDouble(),
    );

    switch (cornerHandle) {
      case _ScanCornerHandle.topLeft:
        nextPoint = Offset(
          nextPoint.dx
              .clamp(0.0, currentCorners.topRight.dx - minGap)
              .toDouble(),
          nextPoint.dy
              .clamp(0.0, currentCorners.bottomLeft.dy - minGap)
              .toDouble(),
        );
      case _ScanCornerHandle.topRight:
        nextPoint = Offset(
          nextPoint.dx
              .clamp(currentCorners.topLeft.dx + minGap, 1.0)
              .toDouble(),
          nextPoint.dy
              .clamp(0.0, currentCorners.bottomRight.dy - minGap)
              .toDouble(),
        );
      case _ScanCornerHandle.bottomLeft:
        nextPoint = Offset(
          nextPoint.dx
              .clamp(0.0, currentCorners.bottomRight.dx - minGap)
              .toDouble(),
          nextPoint.dy
              .clamp(currentCorners.topLeft.dy + minGap, 1.0)
              .toDouble(),
        );
      case _ScanCornerHandle.bottomRight:
        nextPoint = Offset(
          nextPoint.dx
              .clamp(currentCorners.bottomLeft.dx + minGap, 1.0)
              .toDouble(),
          nextPoint.dy
              .clamp(currentCorners.topRight.dy + minGap, 1.0)
              .toDouble(),
        );
    }

    setState(() {
      _pendingDocumentCornersNormalized = switch (cornerHandle) {
        _ScanCornerHandle.topLeft => currentCorners.copyWith(
          topLeft: nextPoint,
        ),
        _ScanCornerHandle.topRight => currentCorners.copyWith(
          topRight: nextPoint,
        ),
        _ScanCornerHandle.bottomLeft => currentCorners.copyWith(
          bottomLeft: nextPoint,
        ),
        _ScanCornerHandle.bottomRight => currentCorners.copyWith(
          bottomRight: nextPoint,
        ),
      };
    });
  }

  void _updateBrightness(double value) {
    _updateSelectedPage(
      (page) => page.copyWith(brightness: value),
      debouncePreview: true,
    );
  }

  void _updateContrast(double value) {
    _updateSelectedPage(
      (page) => page.copyWith(contrast: value),
      debouncePreview: true,
    );
  }

  void _updateFilterPreset(ScanFilterPreset filterPreset) {
    _updateSelectedPage((page) => page.copyWith(filterPreset: filterPreset));
  }

  void _updateColorMode(ScanColorMode colorMode) {
    _updateSelectedPage((page) => page.copyWith(colorMode: colorMode));
  }

  void _updateExportQuality(ScanExportQuality exportQuality) {
    setState(() {
      _draft = _draft.copyWith(exportQuality: exportQuality);
    });
  }

  Future<void> _saveDocument() async {
    if (_isSaving || !_draft.hasPages) {
      return;
    }

    setState(() => _isSaving = true);
    String? temporaryPath;
    try {
      temporaryPath = await _exportService.exportToTemporaryFile(
        pages: _draft.pages,
        exportQuality: _draft.exportQuality,
        fileNameStem: _buildSuggestedFileNameStem(),
      );

      final preparedDocument = await widget.documentBridge.savePdfDocumentCopy(
        sourceLocalPath: temporaryPath,
        displayName: '${_buildSuggestedFileNameStem()}.pdf',
      );
      if (!mounted || preparedDocument == null) {
        return;
      }

      final savedDocument = await widget.repository.upsertOpenedDocument(
        uri: preparedDocument.uri,
        displayName: preparedDocument.displayName,
        sizeBytes: preparedDocument.sizeBytes,
      );
      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(
        DocumentScannerResult(
          savedDocument: savedDocument,
          preparedDocument: preparedDocument,
        ),
      );
    } catch (_) {
      if (mounted) {
        _showMessage(AppStrings.scannerSaveFailed);
      }
    } finally {
      if (temporaryPath != null) {
        final fileToDelete = File(temporaryPath);
        unawaited(fileToDelete.delete().catchError((_) => fileToDelete));
      }
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String _buildSuggestedFileNameStem() {
    final selectedPage = _selectedPage;
    final baseName = selectedPage == null
        ? 'document-scanne'
        : p.basenameWithoutExtension(selectedPage.sourceName).trim();
    return baseName.isEmpty ? 'document-scanne' : '$baseName-scan';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedPage = _selectedPage;

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.scanDocument),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _draft.hasPages && !_isSaving ? _saveDocument : null,
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt_rounded),
            label: Text(
              _isSaving ? AppStrings.readerLoading : AppStrings.saveDocument,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (_isImporting || _isSaving || _isAutoCropping)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: !_draft.hasPages
                  ? _buildEmptyState(theme)
                  : _buildEditorLayout(theme, selectedPage),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.document_scanner_rounded,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.scannerEmptyTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.scannerEmptyBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _captureWithCamera,
              icon: const Icon(Icons.camera_alt_rounded),
              label: const Text(AppStrings.scanTakePhoto),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _importFromGallery,
              icon: const Icon(Icons.photo_library_rounded),
              label: const Text(AppStrings.scanImportImages),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorLayout(ThemeData theme, ScannedPageDraft? selectedPage) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _buildPreviewCard(theme, selectedPage),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _buildActionBar(theme, selectedPage),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _buildInspectorCard(theme, selectedPage),
        ),
        const SizedBox(height: 8),
        SizedBox(height: 118, child: _buildThumbnailStrip(theme)),
      ],
    );
  }

  Widget _buildPreviewCard(ThemeData theme, ScannedPageDraft? selectedPage) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        child: selectedPage == null
            ? const SizedBox.expand()
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _isCropping
                    ? (_cropEditMode == _ScanCropEditMode.corners
                          ? _buildCornerPreview(theme, selectedPage)
                          : _buildRectCropPreview(theme, selectedPage))
                    : _buildProcessedPreview(theme),
              ),
      ),
    );
  }

  Widget _buildProcessedPreview(ThemeData theme) {
    final previewFuture = _previewFuture;
    if (previewFuture == null) {
      return const SizedBox.expand();
    }

    return FutureBuilder<ProcessedScanPage>(
      future: previewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Text(
              AppStrings.scannerPreviewFailed,
              style: theme.textTheme.bodyMedium,
            ),
          );
        }

        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: Image.memory(
              snapshot.data!.bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        );
      },
    );
  }

  Widget _buildRectCropPreview(ThemeData theme, ScannedPageDraft selectedPage) {
    final cropEditorFuture = _cropEditorFuture;
    if (cropEditorFuture == null) {
      return const SizedBox.expand();
    }

    return FutureBuilder<ProcessedScanPage>(
      future: cropEditorFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Text(
              AppStrings.scannerPreviewFailed,
              style: theme.textTheme.bodyMedium,
            ),
          );
        }

        final cropEditorPage = snapshot.data!;
        final initialCropRect = _imageProcessingService.cropRectForCropEditor(
          selectedPage,
        );
        final imageBasedRect = Rect.fromLTWH(
          initialCropRect.left * cropEditorPage.width,
          initialCropRect.top * cropEditorPage.height,
          initialCropRect.width * cropEditorPage.width,
          initialCropRect.height * cropEditorPage.height,
        );

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Crop(
            key: ValueKey(
              '${selectedPage.id}-${selectedPage.rotationQuarterTurns}-${selectedPage.cropRectNormalized}-${selectedPage.documentCornersNormalized?.ordered.join('|')}',
            ),
            image: cropEditorPage.bytes,
            controller: _cropController,
            initialRectBuilder: InitialRectBuilder.withArea(imageBasedRect),
            interactive: true,
            baseColor: theme.colorScheme.surfaceContainerHighest,
            maskColor: theme.colorScheme.scrim.withValues(alpha: 0.42),
            radius: 14,
            progressIndicator: const CircularProgressIndicator(),
            onCropped: (_) {},
            onMoved: (_, imageRect) {
              _pendingCropRectNormalized = _imageProcessingService
                  .cropRectFromCropEditor(
                    page: selectedPage,
                    rotatedCropRectNormalized: Rect.fromLTWH(
                      imageRect.left / cropEditorPage.width,
                      imageRect.top / cropEditorPage.height,
                      imageRect.width / cropEditorPage.width,
                      imageRect.height / cropEditorPage.height,
                    ),
                  );
            },
          ),
        );
      },
    );
  }

  Widget _buildCornerPreview(ThemeData theme, ScannedPageDraft selectedPage) {
    final cornerEditorFuture = _cornerEditorFuture;
    if (cornerEditorFuture == null) {
      return const SizedBox.expand();
    }

    return FutureBuilder<ProcessedScanPage>(
      future: cornerEditorFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Text(
              AppStrings.scannerPreviewFailed,
              style: theme.textTheme.bodyMedium,
            ),
          );
        }

        final cornerEditorPage = snapshot.data!;
        final documentCorners =
            _pendingDocumentCornersNormalized ??
            selectedPage.documentCornersNormalized ??
            _defaultDocumentCorners();

        return Padding(
          padding: const EdgeInsets.all(12),
          child: _CornerCropEditor(
            key: ValueKey(
              '${selectedPage.id}-${selectedPage.rotationQuarterTurns}-${selectedPage.documentCornersNormalized?.ordered.join('|')}',
            ),
            imageBytes: cornerEditorPage.bytes,
            imageWidth: cornerEditorPage.width,
            imageHeight: cornerEditorPage.height,
            documentCorners: documentCorners,
            onCornerChanged: _updatePendingDocumentCorner,
          ),
        );
      },
    );
  }

  Widget _buildActionBar(ThemeData theme, ScannedPageDraft? selectedPage) {
    final buttons = <Widget>[
      FilledButton.tonalIcon(
        onPressed: _captureWithCamera,
        icon: const Icon(Icons.camera_alt_rounded),
        label: const Text(AppStrings.scanTakePhoto),
      ),
      OutlinedButton.icon(
        onPressed: _importFromGallery,
        icon: const Icon(Icons.photo_library_rounded),
        label: const Text(AppStrings.scanImportImages),
      ),
      OutlinedButton.icon(
        onPressed: selectedPage == null ? null : _toggleCropMode,
        icon: Icon(_isCropping ? Icons.crop_free_rounded : Icons.crop_rounded),
        label: Text(
          _isCropping ? AppStrings.scanCancelCrop : AppStrings.scanCrop,
        ),
      ),
      OutlinedButton.icon(
        onPressed: selectedPage == null || _isAutoCropping
            ? null
            : _autoCropSelectedPage,
        icon: _isAutoCropping
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_fix_high_rounded),
        label: const Text(AppStrings.scanAutoCrop),
      ),
      OutlinedButton.icon(
        onPressed: selectedPage == null ? null : () => _rotateSelectedPage(-1),
        icon: const Icon(Icons.rotate_left_rounded),
        label: const Text(AppStrings.scanRotateLeft),
      ),
      OutlinedButton.icon(
        onPressed: selectedPage == null ? null : () => _rotateSelectedPage(1),
        icon: const Icon(Icons.rotate_right_rounded),
        label: const Text(AppStrings.scanRotateRight),
      ),
      FilledButton.tonalIcon(
        onPressed: selectedPage == null ? null : _deleteSelectedPage,
        icon: const Icon(Icons.delete_outline_rounded),
        label: const Text(AppStrings.scanDeletePage),
      ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: buttons
            .map(
              (button) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: button,
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Widget _buildInspectorCard(ThemeData theme, ScannedPageDraft? selectedPage) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 230),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: _isCropping
              ? _buildCropInspector(theme, selectedPage)
              : _buildAdjustmentsInspector(theme, selectedPage),
        ),
      ),
    );
  }

  Widget _buildCropInspector(ThemeData theme, ScannedPageDraft? selectedPage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          AppStrings.scanCropTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _cropEditMode == _ScanCropEditMode.corners
              ? AppStrings.scanCornerCropBody
              : AppStrings.scanCropBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: const Text(AppStrings.scanRectCropMode),
              selected: _cropEditMode == _ScanCropEditMode.rectangle,
              onSelected: selectedPage == null
                  ? null
                  : (_) => _setCropEditMode(_ScanCropEditMode.rectangle),
            ),
            ChoiceChip(
              label: const Text(AppStrings.scanCornerCropMode),
              selected: _cropEditMode == _ScanCropEditMode.corners,
              onSelected: selectedPage == null
                  ? null
                  : (_) => _setCropEditMode(_ScanCropEditMode.corners),
            ),
          ],
        ),
        const SizedBox(height: 16),
        OverflowBar(
          spacing: 8,
          overflowSpacing: 8,
          alignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: _toggleCropMode,
              icon: const Icon(Icons.close_rounded),
              label: const Text(AppStrings.scanCancelCrop),
            ),
            OutlinedButton.icon(
              onPressed: _resetCropSelectedPage,
              icon: const Icon(Icons.aspect_ratio_rounded),
              label: const Text(AppStrings.scanResetCrop),
            ),
            OutlinedButton.icon(
              onPressed: _isAutoCropping ? null : _autoCropSelectedPage,
              icon: _isAutoCropping
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_fix_high_rounded),
              label: const Text(AppStrings.scanAutoCrop),
            ),
            FilledButton.icon(
              onPressed: _applyCrop,
              icon: const Icon(Icons.check_rounded),
              label: const Text(AppStrings.scanApplyCrop),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAdjustmentsInspector(
    ThemeData theme,
    ScannedPageDraft? selectedPage,
  ) {
    final brightness = selectedPage?.brightness ?? 0.0;
    final contrast = selectedPage?.contrast ?? 0.0;
    final filterPreset = selectedPage?.filterPreset ?? ScanFilterPreset.none;
    final colorMode = selectedPage?.colorMode ?? ScanColorMode.color;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          AppStrings.scanAdjustments,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        if (selectedPage?.documentCornersNormalized != null) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              AppStrings.scanPerspectiveCorrectionActive,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _LabeledValueSlider(
          label: AppStrings.scanBrightness,
          value: brightness,
          min: -1,
          max: 1,
          divisions: 20,
          onChanged: selectedPage == null ? null : _updateBrightness,
        ),
        _LabeledValueSlider(
          label: AppStrings.scanContrast,
          value: contrast,
          min: -1,
          max: 1,
          divisions: 20,
          onChanged: selectedPage == null ? null : _updateContrast,
        ),
        const SizedBox(height: 10),
        Text(AppStrings.scanFilter, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ScanFilterPreset.values
              .map(
                (preset) => ChoiceChip(
                  label: Text(_labelForFilterPreset(preset)),
                  selected: filterPreset == preset,
                  onSelected: selectedPage == null
                      ? null
                      : (_) => _updateFilterPreset(preset),
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 10),
        Text(AppStrings.scanColorMode, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ScanColorMode.values
              .map(
                (mode) => ChoiceChip(
                  label: Text(_labelForColorMode(mode)),
                  selected: colorMode == mode,
                  onSelected: selectedPage == null
                      ? null
                      : (_) => _updateColorMode(mode),
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 16),
        Text(AppStrings.scanQuality, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ScanExportQuality.values
              .map(
                (quality) => ChoiceChip(
                  label: Text(_labelForExportQuality(quality)),
                  selected: _draft.exportQuality == quality,
                  onSelected: (_) => _updateExportQuality(quality),
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 10),
        Text(
          AppStrings.scanReorderHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildThumbnailStrip(ThemeData theme) {
    return ReorderableListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: _draft.pages.length,
      onReorder: _reorderPages,
      buildDefaultDragHandles: false,
      itemBuilder: (context, index) {
        final page = _draft.pages[index];
        final selected = page.id == _draft.selectedPageId;
        return Padding(
          key: ValueKey(page.id),
          padding: const EdgeInsets.only(right: 10),
          child: ReorderableDelayedDragStartListener(
            index: index,
            child: GestureDetector(
              onTap: () => _selectPage(page.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 84,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: RotatedBox(
                            quarterTurns: page.rotationQuarterTurns,
                            child: Image.memory(
                              page.originalBytes,
                              fit: BoxFit.cover,
                              cacheWidth: 168,
                              cacheHeight: 168,
                              filterQuality: FilterQuality.low,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        AppStrings.scanPageIndex(index + 1),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _labelForColorMode(ScanColorMode colorMode) {
    return switch (colorMode) {
      ScanColorMode.color => AppStrings.scanColorModeColor,
      ScanColorMode.grayscale => AppStrings.scanColorModeGrayscale,
      ScanColorMode.blackWhite => AppStrings.scanColorModeBlackWhite,
    };
  }

  String _labelForFilterPreset(ScanFilterPreset filterPreset) {
    return switch (filterPreset) {
      ScanFilterPreset.none => AppStrings.scanFilterNone,
      ScanFilterPreset.document => AppStrings.scanFilterDocument,
      ScanFilterPreset.vivid => AppStrings.scanFilterVivid,
      ScanFilterPreset.warm => AppStrings.scanFilterWarm,
      ScanFilterPreset.cool => AppStrings.scanFilterCool,
    };
  }

  String _labelForExportQuality(ScanExportQuality quality) {
    return switch (quality) {
      ScanExportQuality.original => AppStrings.scanQualityOriginal,
      ScanExportQuality.optimized => AppStrings.scanQualityOptimized,
      ScanExportQuality.light => AppStrings.scanQualityLight,
    };
  }
}

class _LabeledValueSlider extends StatelessWidget {
  const _LabeledValueSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text(value.toStringAsFixed(2)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

enum _ScanCornerHandle { topLeft, topRight, bottomLeft, bottomRight }

class _CornerCropEditor extends StatelessWidget {
  const _CornerCropEditor({
    super.key,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.documentCorners,
    required this.onCornerChanged,
  });

  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final ScanDocumentCorners documentCorners;
  final void Function(_ScanCornerHandle handle, Offset point) onCornerChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportRect = _fitRect(
          Size(constraints.maxWidth, constraints.maxHeight),
          Size(imageWidth.toDouble(), imageHeight.toDouble()),
        );
        final points = <_ScanCornerHandle, Offset>{
          _ScanCornerHandle.topLeft: _normalizedToViewport(
            documentCorners.topLeft,
            viewportRect,
          ),
          _ScanCornerHandle.topRight: _normalizedToViewport(
            documentCorners.topRight,
            viewportRect,
          ),
          _ScanCornerHandle.bottomLeft: _normalizedToViewport(
            documentCorners.bottomLeft,
            viewportRect,
          ),
          _ScanCornerHandle.bottomRight: _normalizedToViewport(
            documentCorners.bottomRight,
            viewportRect,
          ),
        };

        return Stack(
          children: <Widget>[
            Positioned.fromRect(
              rect: viewportRect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _CornerCropOverlayPainter(
                    viewportRect: viewportRect,
                    corners: points,
                    colorScheme: Theme.of(context).colorScheme,
                  ),
                ),
              ),
            ),
            ...points.entries.map(
              (entry) => Positioned(
                left: entry.value.dx - 18,
                top: entry.value.dy - 18,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) {
                    final nextViewportPoint = Offset(
                      (entry.value.dx + details.delta.dx)
                          .clamp(viewportRect.left, viewportRect.right)
                          .toDouble(),
                      (entry.value.dy + details.delta.dy)
                          .clamp(viewportRect.top, viewportRect.bottom)
                          .toDouble(),
                    );
                    onCornerChanged(
                      entry.key,
                      _viewportToNormalized(nextViewportPoint, viewportRect),
                    );
                  },
                  child: _CornerHandleChip(label: _labelForHandle(entry.key)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static Rect _fitRect(Size box, Size image) {
    if (box.width <= 0 ||
        box.height <= 0 ||
        image.width <= 0 ||
        image.height <= 0) {
      return Rect.zero;
    }

    final imageAspectRatio = image.width / image.height;
    final boxAspectRatio = box.width / box.height;
    if (imageAspectRatio > boxAspectRatio) {
      final fittedHeight = box.width / imageAspectRatio;
      final top = (box.height - fittedHeight) / 2;
      return Rect.fromLTWH(0, top, box.width, fittedHeight);
    }

    final fittedWidth = box.height * imageAspectRatio;
    final left = (box.width - fittedWidth) / 2;
    return Rect.fromLTWH(left, 0, fittedWidth, box.height);
  }

  static Offset _normalizedToViewport(Offset point, Rect viewportRect) {
    return Offset(
      viewportRect.left + (point.dx * viewportRect.width),
      viewportRect.top + (point.dy * viewportRect.height),
    );
  }

  static Offset _viewportToNormalized(Offset point, Rect viewportRect) {
    return Offset(
      ((point.dx - viewportRect.left) / viewportRect.width)
          .clamp(0.0, 1.0)
          .toDouble(),
      ((point.dy - viewportRect.top) / viewportRect.height)
          .clamp(0.0, 1.0)
          .toDouble(),
    );
  }

  static String _labelForHandle(_ScanCornerHandle handle) {
    return switch (handle) {
      _ScanCornerHandle.topLeft => '1',
      _ScanCornerHandle.topRight => '2',
      _ScanCornerHandle.bottomRight => '3',
      _ScanCornerHandle.bottomLeft => '4',
    };
  }
}

class _CornerHandleChip extends StatelessWidget {
  const _CornerHandleChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: colorScheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: colorScheme.onPrimary, width: 2),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CornerCropOverlayPainter extends CustomPainter {
  const _CornerCropOverlayPainter({
    required this.viewportRect,
    required this.corners,
    required this.colorScheme,
  });

  final Rect viewportRect;
  final Map<_ScanCornerHandle, Offset> corners;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    final polygon = <Offset>[
      corners[_ScanCornerHandle.topLeft]!,
      corners[_ScanCornerHandle.topRight]!,
      corners[_ScanCornerHandle.bottomRight]!,
      corners[_ScanCornerHandle.bottomLeft]!,
    ];

    final dimPaint = Paint()..color = colorScheme.scrim.withValues(alpha: 0.28);
    final clearPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final polygonPath = Path()..addPolygon(polygon, true);
    final overlayPath = Path.combine(
      PathOperation.difference,
      clearPath,
      polygonPath,
    );
    canvas.drawPath(overlayPath, dimPaint);

    final edgePaint = Paint()
      ..color = colorScheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath(polygonPath, edgePaint);
  }

  @override
  bool shouldRepaint(covariant _CornerCropOverlayPainter oldDelegate) {
    return viewportRect != oldDelegate.viewportRect ||
        corners[_ScanCornerHandle.topLeft] !=
            oldDelegate.corners[_ScanCornerHandle.topLeft] ||
        corners[_ScanCornerHandle.topRight] !=
            oldDelegate.corners[_ScanCornerHandle.topRight] ||
        corners[_ScanCornerHandle.bottomLeft] !=
            oldDelegate.corners[_ScanCornerHandle.bottomLeft] ||
        corners[_ScanCornerHandle.bottomRight] !=
            oldDelegate.corners[_ScanCornerHandle.bottomRight] ||
        colorScheme != oldDelegate.colorScheme;
  }
}
