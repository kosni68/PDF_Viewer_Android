import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';

import '../../data/document_repository.dart';
import '../../data/saved_document.dart';
import '../../editor/models/editor_document_state.dart';
import '../../editor/services/image_import_service.dart';
import '../../editor/services/pdf_flatten_export_service.dart';
import '../../editor/services/signature_capture_service.dart';
import '../../platform/document_bridge.dart';

class PdfEditorResult {
  const PdfEditorResult({
    required this.savedDocument,
    required this.preparedDocument,
  });

  final SavedDocument savedDocument;
  final PreparedPdfDocument preparedDocument;
}

class PdfEditorScreen extends StatefulWidget {
  const PdfEditorScreen({
    super.key,
    required this.repository,
    required this.documentBridge,
    required this.savedDocument,
    required this.preparedDocument,
  });

  final DocumentRepository repository;
  final DocumentBridge documentBridge;
  final SavedDocument savedDocument;
  final PreparedPdfDocument preparedDocument;

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

enum _EditorStatus { loading, ready, error }

enum _EditorTool { select, text }

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  static const double _minimumObjectWidth = 0.08;
  static const double _minimumObjectHeight = 0.04;

  final ImageImportService _imageImportService = const ImageImportService();
  final SignatureCaptureService _signatureCaptureService =
      const SignatureCaptureService();
  final PdfFlattenExportService _exportService =
      const PdfFlattenExportService();
  final List<EditorDocumentState> _undoStack = <EditorDocumentState>[];

  PdfDocument? _document;
  _RenderedEditorPage? _renderedPage;
  _EditorStatus _status = _EditorStatus.loading;
  _EditorTool _tool = _EditorTool.select;
  EditorDocumentState _editorState = EditorDocumentState.empty;
  int _currentPageNumber = 1;
  int _nextObjectId = 1;
  String? _selectedObjectId;
  Object? _loadError;
  Rect? _draftTextRect;
  Offset? _draftStart;
  bool _isRenderingPage = false;
  bool _isSaving = false;
  bool _isPickingImage = false;
  bool _isCapturingSignature = false;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  @override
  void dispose() {
    unawaited(_document?.dispose());
    _renderedPage?.dispose();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    setState(() {
      _status = _EditorStatus.loading;
      _loadError = null;
    });

    try {
      await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);
      final document = await PdfDocument.openFile(
        widget.preparedDocument.localPath,
      );
      if (!mounted) {
        await document.dispose();
        return;
      }

      _document = document;
      await _renderPage(1);
      if (!mounted) {
        return;
      }
      setState(() => _status = _EditorStatus.ready);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _EditorStatus.error;
        _loadError = error;
      });
    }
  }

  Future<void> _renderPage(int pageNumber) async {
    final document = _document;
    if (document == null) {
      return;
    }

    setState(() {
      _isRenderingPage = true;
      _selectedObjectId = null;
      _draftTextRect = null;
      _draftStart = null;
    });

    try {
      final page = await document.pages[pageNumber - 1].ensureLoaded();
      final image = await _renderPageImage(page);
      if (!mounted) {
        image.dispose();
        return;
      }

      final previous = _renderedPage;
      setState(() {
        _currentPageNumber = pageNumber;
        _renderedPage = _RenderedEditorPage(page: page, image: image);
      });
      previous?.dispose();
    } finally {
      if (mounted) {
        setState(() => _isRenderingPage = false);
      }
    }
  }

  Future<ui.Image> _renderPageImage(PdfPage page) async {
    const maxEdge = 1400.0;
    final scale = maxEdge / math.max(page.width, page.height);
    final rendered = await page.render(
      fullWidth: math.max(1, (page.width * scale).round()).toDouble(),
      fullHeight: math.max(1, (page.height * scale).round()).toDouble(),
      backgroundColor: 0xffffffff,
    );
    if (rendered == null) {
      throw StateError('Impossible de preparer la page ${page.pageNumber}.');
    }

    try {
      return rendered.createImage();
    } finally {
      rendered.dispose();
    }
  }

  Future<void> _goToPage(int pageNumber) async {
    final document = _document;
    if (document == null ||
        pageNumber < 1 ||
        pageNumber > document.pages.length ||
        pageNumber == _currentPageNumber ||
        _isRenderingPage) {
      return;
    }
    await _renderPage(pageNumber);
  }

  void _pushUndoState() {
    _undoStack.add(_editorState);
    if (_undoStack.length > 60) {
      _undoStack.removeAt(0);
    }
  }

  void _undo() {
    if (_undoStack.isEmpty) {
      return;
    }
    final previous = _undoStack.removeLast();
    setState(() {
      _editorState = previous;
      if (_selectedObjectId != null &&
          previous.findObjectById(_selectedObjectId!) == null) {
        _selectedObjectId = null;
      }
    });
  }

  Future<void> _pickImage() async {
    if (_isPickingImage) {
      return;
    }

    setState(() => _isPickingImage = true);
    try {
      final imported = await _imageImportService.pickImage();
      if (!mounted || imported == null) {
        return;
      }

      final imageSize = await _decodeImageSize(imported.bytes);
      if (!mounted) {
        return;
      }

      _pushUndoState();
      final object = ImageEditObject(
        id: _nextId('image'),
        pageNumber: _currentPageNumber,
        normalizedRect: _buildCenteredRectForImage(imageSize),
        imageBytes: imported.bytes,
      );
      setState(() {
        _editorState = _editorState.upsertObject(object);
        _selectedObjectId = object.id;
        _tool = _EditorTool.select;
      });
    } finally {
      if (mounted) {
        setState(() => _isPickingImage = false);
      }
    }
  }

  Future<void> _captureSignature() async {
    if (_isCapturingSignature) {
      return;
    }

    setState(() => _isCapturingSignature = true);
    try {
      final bytes = await _signatureCaptureService.captureSignature(context);
      if (!mounted || bytes == null || bytes.isEmpty) {
        return;
      }

      final imageSize = await _decodeImageSize(bytes);
      if (!mounted) {
        return;
      }

      _pushUndoState();
      final object = SignatureEditObject(
        id: _nextId('signature'),
        pageNumber: _currentPageNumber,
        normalizedRect: _buildCenteredRectForImage(
          imageSize,
          preferredWidth: 0.34,
        ),
        imageBytes: bytes,
      );
      setState(() {
        _editorState = _editorState.upsertObject(object);
        _selectedObjectId = object.id;
        _tool = _EditorTool.select;
      });
    } finally {
      if (mounted) {
        setState(() => _isCapturingSignature = false);
      }
    }
  }

  Future<void> _saveEdits() async {
    if (_isSaving) {
      return;
    }

    setState(() => _isSaving = true);
    final tempPath = _buildTemporaryExportPath();
    try {
      await _exportService.exportToFile(
        sourcePdfPath: widget.preparedDocument.localPath,
        outputPdfPath: tempPath,
        state: _editorState,
      );

      if (!mounted) {
        return;
      }

      final preparedDocument = await widget.documentBridge.savePdfDocumentCopy(
        sourceLocalPath: tempPath,
        displayName: _buildSuggestedExportName(),
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
        PdfEditorResult(
          savedDocument: savedDocument,
          preparedDocument: preparedDocument,
        ),
      );
    } catch (_) {
      if (mounted) {
        _showMessage('Impossible de sauvegarder la copie modifiee.');
      }
    } finally {
      try {
        final file = File(tempPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}

      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String _buildSuggestedExportName() {
    final original = widget.preparedDocument.displayName;
    final extension = path.extension(original);
    final baseName = extension.isEmpty
        ? original
        : original.substring(0, original.length - extension.length);
    return '${baseName}_modifie.pdf';
  }

  String _buildTemporaryExportPath() {
    final parent = File(widget.preparedDocument.localPath).parent.path;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return path.join(parent, 'edited_export_$timestamp.pdf');
  }

  Rect _buildCenteredRectForImage(
    Size imageSize, {
    double preferredWidth = 0.42,
  }) {
    final page = _document?.pages[_currentPageNumber - 1];
    final pageWidth = page?.width ?? 1;
    final pageHeight = page?.height ?? 1;
    final imageAspect = imageSize.width / imageSize.height;
    final pageAspect = pageWidth / pageHeight;

    var width = preferredWidth;
    var height = width * pageAspect / imageAspect;
    if (height > 0.48) {
      final scale = 0.48 / height;
      height *= scale;
      width *= scale;
    }

    return Rect.fromLTWH((1 - width) / 2, (1 - height) / 2, width, height);
  }

  Future<Size> _decodeImageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    return size;
  }

  void _selectForTextPlacement() {
    setState(() {
      _tool = _tool == _EditorTool.text ? _EditorTool.select : _EditorTool.text;
      _selectedObjectId = null;
      _draftTextRect = null;
      _draftStart = null;
    });
  }

  void _deleteSelectedObject() {
    final selectedId = _selectedObjectId;
    if (selectedId == null) {
      return;
    }

    _pushUndoState();
    setState(() {
      _editorState = _editorState.removeObject(selectedId);
      _selectedObjectId = null;
    });
  }

  void _rotateSelectedObject(double deltaDegrees) {
    final selected = _selectedObject;
    if (selected is! SignatureEditObject && selected is! ImageEditObject) {
      return;
    }

    _pushUndoState();
    final updated = selected is SignatureEditObject
        ? selected.copyWith(
            rotationDegrees: selected.rotationDegrees + deltaDegrees,
          )
        : (selected as ImageEditObject).copyWith(
            rotationDegrees: selected.rotationDegrees + deltaDegrees,
          );

    setState(() {
      _editorState = _editorState.upsertObject(updated);
      _selectedObjectId = updated.id;
    });
  }

  Future<void> _editSelectedText() async {
    final selected = _selectedObject;
    if (selected is! TextEditObject) {
      return;
    }
    final updatedText = await _requestReplacementText(initialValue: selected.text);
    if (!mounted || updatedText == null) {
      return;
    }

    _pushUndoState();
    final updated = selected.copyWith(text: updatedText);
    setState(() {
      _editorState = _editorState.upsertObject(updated);
      _selectedObjectId = updated.id;
    });
  }

  Future<String?> _requestReplacementText({String initialValue = ''}) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _ReplacementTextSheet(initialValue: initialValue);
      },
    );
  }

  void _startDraft(Offset position, Size pageSize) {
    if (_tool != _EditorTool.text) {
      return;
    }
    final clamped = _clampOffset(position, pageSize);
    setState(() {
      _draftStart = clamped;
      _draftTextRect = Rect.fromPoints(clamped, clamped);
    });
  }

  void _updateDraft(Offset position, Size pageSize) {
    final start = _draftStart;
    if (_tool != _EditorTool.text || start == null) {
      return;
    }
    final clamped = _clampOffset(position, pageSize);
    setState(() => _draftTextRect = Rect.fromPoints(start, clamped));
  }

  Future<void> _finishDraft(Size pageSize) async {
    final draft = _draftTextRect;
    setState(() {
      _draftStart = null;
      _draftTextRect = null;
    });

    if (draft == null || draft.width < 28 || draft.height < 20) {
      _showMessage('La zone est trop petite.');
      return;
    }

    final text = await _requestReplacementText();
    if (!mounted || text == null) {
      return;
    }

    _pushUndoState();
    final normalizedRect = Rect.fromLTWH(
      draft.left / pageSize.width,
      draft.top / pageSize.height,
      draft.width / pageSize.width,
      draft.height / pageSize.height,
    );
    final object = TextEditObject(
      id: _nextId('text'),
      pageNumber: _currentPageNumber,
      normalizedRect: _clampNormalizedRect(normalizedRect),
      text: text,
    );

    setState(() {
      _editorState = _editorState.upsertObject(object);
      _selectedObjectId = object.id;
      _tool = _EditorTool.select;
    });
  }

  Offset _clampOffset(Offset position, Size pageSize) {
    return Offset(
      position.dx.clamp(0.0, pageSize.width),
      position.dy.clamp(0.0, pageSize.height),
    );
  }

  Rect _clampNormalizedRect(Rect rect) {
    var left = rect.left.clamp(0.0, 1.0 - _minimumObjectWidth);
    var top = rect.top.clamp(0.0, 1.0 - _minimumObjectHeight);
    var width = rect.width.clamp(_minimumObjectWidth, 1.0 - left);
    var height = rect.height.clamp(_minimumObjectHeight, 1.0 - top);
    if (left + width > 1) {
      left = 1 - width;
    }
    if (top + height > 1) {
      top = 1 - height;
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  void _moveObject(PdfEditObject object, Offset delta, Size pageSize) {
    final normalizedDelta = Offset(
      delta.dx / pageSize.width,
      delta.dy / pageSize.height,
    );
    _upsertObjectGeometry(
      object,
      _clampNormalizedRect(object.normalizedRect.shift(normalizedDelta)),
    );
  }

  void _resizeObject(PdfEditObject object, Offset delta, Size pageSize) {
    final rect = object.normalizedRect;
    _upsertObjectGeometry(
      object,
      _clampNormalizedRect(
        Rect.fromLTWH(
          rect.left,
          rect.top,
          rect.width + (delta.dx / pageSize.width),
          rect.height + (delta.dy / pageSize.height),
        ),
      ),
    );
  }

  void _upsertObjectGeometry(PdfEditObject object, Rect normalizedRect) {
    final updated = switch (object) {
      TextEditObject() => object.copyWith(normalizedRect: normalizedRect),
      SignatureEditObject() => object.copyWith(normalizedRect: normalizedRect),
      ImageEditObject() => object.copyWith(normalizedRect: normalizedRect),
    };
    setState(() {
      _editorState = _editorState.upsertObject(updated);
      _selectedObjectId = updated.id;
    });
  }

  String _nextId(String prefix) => '$prefix-${_nextObjectId++}';

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  PdfEditObject? get _selectedObject =>
      _selectedObjectId == null ? null : _editorState.findObjectById(_selectedObjectId!);

  List<PdfEditObject> get _currentPageObjects =>
      _editorState.objectsForPage(_currentPageNumber);

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Modifier le PDF'),
        actions: <Widget>[
          if (_selectedObject is TextEditObject)
            IconButton(
              onPressed: _editSelectedText,
              tooltip: 'Modifier le texte',
              icon: const Icon(Icons.edit_note_rounded),
            ),
          if (_selectedObject is SignatureEditObject ||
              _selectedObject is ImageEditObject)
            IconButton(
              onPressed: () => _rotateSelectedObject(-15),
              tooltip: 'Rotation gauche',
              icon: const Icon(Icons.rotate_90_degrees_ccw_rounded),
            ),
          if (_selectedObject is SignatureEditObject ||
              _selectedObject is ImageEditObject)
            IconButton(
              onPressed: () => _rotateSelectedObject(15),
              tooltip: 'Rotation droite',
              icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
            ),
          if (_selectedObject != null)
            IconButton(
              onPressed: _deleteSelectedObject,
              tooltip: 'Supprimer',
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: switch (_status) {
        _EditorStatus.loading => const Center(child: CircularProgressIndicator()),
        _EditorStatus.error => _EditorErrorView(
          error: _loadError,
          onRetry: _loadDocument,
        ),
        _EditorStatus.ready when document != null => _EditorReadyView(
          documentName: widget.preparedDocument.displayName,
          currentPageNumber: _currentPageNumber,
          pageCount: document.pages.length,
          renderedPage: _renderedPage,
          currentPageObjects: _currentPageObjects,
          selectedObjectId: _selectedObjectId,
          isRenderingPage: _isRenderingPage,
          tool: _tool,
          draftTextRect: _draftTextRect,
          isSaving: _isSaving,
          isPickingImage: _isPickingImage,
          isCapturingSignature: _isCapturingSignature,
          canUndo: _undoStack.isNotEmpty,
          onPreviousPage: _currentPageNumber > 1
              ? () => _goToPage(_currentPageNumber - 1)
              : null,
          onNextPage: _currentPageNumber < document.pages.length
              ? () => _goToPage(_currentPageNumber + 1)
              : null,
          onCanvasTap: _tool == _EditorTool.select
              ? () => setState(() => _selectedObjectId = null)
              : null,
          onDraftStart: _tool == _EditorTool.text ? _startDraft : null,
          onDraftUpdate: _tool == _EditorTool.text ? _updateDraft : null,
          onDraftEnd: _tool == _EditorTool.text ? _finishDraft : null,
          onToggleTextTool: _selectForTextPlacement,
          onCaptureSignature: _captureSignature,
          onPickImage: _pickImage,
          onUndo: _undo,
          onSave: _saveEdits,
          onObjectTap: (object) {
            setState(() {
              _selectedObjectId = object.id;
              _tool = _EditorTool.select;
            });
          },
          onObjectDragStart: (object) {
            _pushUndoState();
            setState(() {
              _selectedObjectId = object.id;
              _tool = _EditorTool.select;
            });
          },
          onObjectDrag: _moveObject,
          onObjectResizeStart: (_) => _pushUndoState(),
          onObjectResize: _resizeObject,
          onEditText: _editSelectedText,
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _EditorReadyView extends StatelessWidget {
  const _EditorReadyView({
    required this.documentName,
    required this.currentPageNumber,
    required this.pageCount,
    required this.renderedPage,
    required this.currentPageObjects,
    required this.selectedObjectId,
    required this.isRenderingPage,
    required this.tool,
    required this.draftTextRect,
    required this.isSaving,
    required this.isPickingImage,
    required this.isCapturingSignature,
    required this.canUndo,
    required this.onPreviousPage,
    required this.onNextPage,
    required this.onCanvasTap,
    required this.onDraftStart,
    required this.onDraftUpdate,
    required this.onDraftEnd,
    required this.onToggleTextTool,
    required this.onCaptureSignature,
    required this.onPickImage,
    required this.onUndo,
    required this.onSave,
    required this.onObjectTap,
    required this.onObjectDragStart,
    required this.onObjectDrag,
    required this.onObjectResizeStart,
    required this.onObjectResize,
    required this.onEditText,
  });

  final String documentName;
  final int currentPageNumber;
  final int pageCount;
  final _RenderedEditorPage? renderedPage;
  final List<PdfEditObject> currentPageObjects;
  final String? selectedObjectId;
  final bool isRenderingPage;
  final _EditorTool tool;
  final Rect? draftTextRect;
  final bool isSaving;
  final bool isPickingImage;
  final bool isCapturingSignature;
  final bool canUndo;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final VoidCallback? onCanvasTap;
  final void Function(Offset position, Size pageSize)? onDraftStart;
  final void Function(Offset position, Size pageSize)? onDraftUpdate;
  final Future<void> Function(Size pageSize)? onDraftEnd;
  final VoidCallback onToggleTextTool;
  final Future<void> Function() onCaptureSignature;
  final Future<void> Function() onPickImage;
  final VoidCallback onUndo;
  final Future<void> Function() onSave;
  final void Function(PdfEditObject object) onObjectTap;
  final void Function(PdfEditObject object) onObjectDragStart;
  final void Function(PdfEditObject object, Offset delta, Size pageSize)
      onObjectDrag;
  final void Function(PdfEditObject object) onObjectResizeStart;
  final void Function(PdfEditObject object, Offset delta, Size pageSize)
      onObjectResize;
  final Future<void> Function() onEditText;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: onPreviousPage,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    Text(
                      documentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Page $currentPageNumber / $pageCount',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onNextPage,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
              ),
              child: renderedPage == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final fitted = applyBoxFit(
                          BoxFit.contain,
                          renderedPage!.size,
                          constraints.biggest,
                        ).destination;

                        return Stack(
                          children: <Widget>[
                            Center(
                              child: SizedBox(
                                width: fitted.width,
                                height: fitted.height,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: onCanvasTap,
                                  onPanStart: onDraftStart == null
                                      ? null
                                      : (details) => onDraftStart!(
                                            details.localPosition,
                                            fitted,
                                          ),
                                  onPanUpdate: onDraftUpdate == null
                                      ? null
                                      : (details) => onDraftUpdate!(
                                            details.localPosition,
                                            fitted,
                                          ),
                                  onPanEnd: onDraftEnd == null
                                      ? null
                                      : (_) => onDraftEnd!(fitted),
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: <Widget>[
                                      Positioned.fill(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(18),
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(18),
                                            child: RawImage(
                                              image: renderedPage!.image,
                                              fit: BoxFit.fill,
                                            ),
                                          ),
                                        ),
                                      ),
                                      ...currentPageObjects.map(
                                        (object) => _EditorObjectWidget(
                                          object: object,
                                          pageSize: fitted,
                                          isSelected: selectedObjectId == object.id,
                                          onTap: () => onObjectTap(object),
                                          onDragStart: () => onObjectDragStart(object),
                                          onDrag: (delta) =>
                                              onObjectDrag(object, delta, fitted),
                                          onResizeStart: () =>
                                              onObjectResizeStart(object),
                                          onResize: (delta) => onObjectResize(
                                            object,
                                            delta,
                                            fitted,
                                          ),
                                          onEditText: object is TextEditObject
                                              ? onEditText
                                              : null,
                                        ),
                                      ),
                                      if (draftTextRect != null)
                                        Positioned.fromRect(
                                          rect: draftTextRect!,
                                          child: IgnorePointer(
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .withValues(alpha: 0.16),
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary,
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (isRenderingPage)
                              const Positioned.fill(
                                child: ColoredBox(
                                  color: Color(0x55000000),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  FilledButton.tonalIcon(
                    onPressed: onToggleTextTool,
                    icon: Icon(
                      tool == _EditorTool.text
                          ? Icons.crop_square_rounded
                          : Icons.text_fields_rounded,
                    ),
                    label: Text(tool == _EditorTool.text ? 'Tracer' : 'Texte'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: isCapturingSignature ? null : onCaptureSignature,
                    icon: isCapturingSignature
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.draw_rounded),
                    label: const Text('Signature'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: isPickingImage ? null : onPickImage,
                    icon: isPickingImage
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image_outlined),
                    label: const Text('Image'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: canUndo ? onUndo : null,
                    icon: const Icon(Icons.undo_rounded),
                    label: const Text('Annuler'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: isSaving ? null : onSave,
                    icon: isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EditorObjectWidget extends StatelessWidget {
  const _EditorObjectWidget({
    required this.object,
    required this.pageSize,
    required this.isSelected,
    required this.onTap,
    required this.onDragStart,
    required this.onDrag,
    required this.onResizeStart,
    required this.onResize,
    this.onEditText,
  });

  final PdfEditObject object;
  final Size pageSize;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDragStart;
  final void Function(Offset delta) onDrag;
  final VoidCallback onResizeStart;
  final void Function(Offset delta) onResize;
  final Future<void> Function()? onEditText;

  @override
  Widget build(BuildContext context) {
    final rect = Rect.fromLTWH(
      object.normalizedRect.left * pageSize.width,
      object.normalizedRect.top * pageSize.height,
      object.normalizedRect.width * pageSize.width,
      object.normalizedRect.height * pageSize.height,
    );

    return Positioned(
      key: ValueKey(object.id),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onDoubleTap: onEditText,
              onPanStart: (_) => onDragStart(),
              onPanUpdate: (details) => onDrag(details.delta),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: isSelected
                      ? Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        )
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Transform.rotate(
                    angle: object.rotationDegrees * math.pi / 180,
                    child: switch (object) {
                      TextEditObject textObject => Container(
                        color: textObject.style.backgroundColor,
                        padding: const EdgeInsets.all(10),
                        alignment: Alignment.topLeft,
                        child: Text(
                          textObject.text,
                          maxLines: null,
                          overflow: TextOverflow.visible,
                          style: TextStyle(
                            color: textObject.style.textColor,
                            fontWeight: textObject.style.fontWeight,
                          ),
                        ),
                      ),
                      SignatureEditObject signatureObject => Image.memory(
                        signatureObject.imageBytes,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                      ImageEditObject imageObject => Image.memory(
                        imageObject.imageBytes,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                    },
                  ),
                ),
              ),
            ),
          ),
          if (isSelected)
            Positioned(
              right: -10,
              bottom: -10,
              child: GestureDetector(
                onPanStart: (_) => onResizeStart(),
                onPanUpdate: (details) => onResize(details.delta),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.onPrimary,
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.open_in_full_rounded,
                    size: 14,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditorErrorView extends StatelessWidget {
  const _EditorErrorView({
    required this.error,
    required this.onRetry,
  });

  final Object? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline_rounded, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Impossible de charger le mode edition.',
              textAlign: TextAlign.center,
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(error.toString(), textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => onRetry(),
              child: const Text('Reessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplacementTextSheet extends StatefulWidget {
  const _ReplacementTextSheet({
    required this.initialValue,
  });

  final String initialValue;

  @override
  State<_ReplacementTextSheet> createState() => _ReplacementTextSheetState();
}

class _ReplacementTextSheetState extends State<_ReplacementTextSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Remplacer le texte',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Entrez le texte a afficher',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('Valider'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RenderedEditorPage {
  const _RenderedEditorPage({
    required this.page,
    required this.image,
  });

  final PdfPage page;
  final ui.Image image;

  Size get size => Size(page.width, page.height);

  void dispose() {
    image.dispose();
  }
}
