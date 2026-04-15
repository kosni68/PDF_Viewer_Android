import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../app/app_strings.dart';
import '../../data/document_repository.dart';
import '../../data/saved_document.dart';
import '../../editor/editor_rendering.dart';
import '../../editor/editor_style_catalog.dart';
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

enum _EditorTool { select, text, pen, highlighter, eraser, shape }

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  static const double _maxPreviewEdge = 1800;
  static const double _minObjectExtent = 0.04;

  final PdfFlattenExportService _exportService =
      const PdfFlattenExportService();
  final ImageImportService _imageImportService = const ImageImportService();
  final SignatureCaptureService _signatureCaptureService =
      const SignatureCaptureService();
  final TransformationController _transformationController =
      TransformationController();
  final TextEditingController _textInspectorController =
      TextEditingController();
  final FocusNode _textInspectorFocusNode = FocusNode();

  PdfDocument? _pdfDocument;
  ui.Image? _pageImage;
  bool _isLoadingDocument = true;
  bool _isRenderingPage = false;
  bool _isSaving = false;
  int _renderGeneration = 0;

  late int _currentPageNumber;
  int _pageCount = 1;

  EditorDocumentState _state = EditorDocumentState.empty;
  List<EditorDocumentState> _history = const <EditorDocumentState>[
    EditorDocumentState.empty,
  ];
  int _historyIndex = 0;
  String? _selectedObjectId;
  bool _isChromeCollapsed = true;
  String? _textInspectorSyncedObjectId;
  bool _isSyncingTextInspector = false;
  bool _hasPendingTextInspectorCommit = false;

  _EditorTool _activeTool = _EditorTool.select;
  ShapeKind _selectedShapeKind = ShapeKind.rectangle;

  TextReplacementStyle _draftTextStyle = EditorStyleCatalog.defaultTextStyle;
  double _draftTextOpacity = 1;
  StrokeStyle _draftPenStyle = EditorStyleCatalog.defaultPenStyle;
  double _draftPenOpacity = 1;
  StrokeStyle _draftHighlighterStyle =
      EditorStyleCatalog.defaultHighlighterStyle;
  double _draftHighlighterOpacity = 0.36;
  StrokeStyle _draftEraserStyle = EditorStyleCatalog.defaultEraserStyle;
  double _draftEraserOpacity = 1;
  ShapeStyle _draftShapeStyle = EditorStyleCatalog.defaultShapeStyle;
  double _draftShapeOpacity = 1;

  Offset? _draftStartPoint;
  Rect? _draftTextRect;
  Rect? _draftShapeRect;
  List<Offset> _draftStrokePoints = const <Offset>[];

  @override
  void initState() {
    super.initState();
    _currentPageNumber = widget.savedDocument.lastPage + 1;
    _textInspectorController.addListener(_handleTextInspectorChanged);
    _textInspectorFocusNode.addListener(_handleTextInspectorFocusChanged);
    _loadDocument();
  }

  @override
  void dispose() {
    _pageImage?.dispose();
    unawaited(_pdfDocument?.dispose());
    _textInspectorController
      ..removeListener(_handleTextInspectorChanged)
      ..dispose();
    _textInspectorFocusNode
      ..removeListener(_handleTextInspectorFocusChanged)
      ..dispose();
    _transformationController.dispose();
    super.dispose();
  }

  PdfEditObject? get _selectedObject {
    final selectedObjectId = _selectedObjectId;
    if (selectedObjectId == null) {
      return null;
    }
    return _state.findObjectById(selectedObjectId);
  }

  List<PdfEditObject> get _currentPageObjects =>
      _state.objectsForPage(_currentPageNumber);

  StrokeStyle get _currentStrokeDraftStyle {
    return switch (_activeTool) {
      _EditorTool.highlighter => _draftHighlighterStyle,
      _EditorTool.eraser => _draftEraserStyle,
      _ => _draftPenStyle,
    };
  }

  double get _currentStrokeDraftOpacity {
    return switch (_activeTool) {
      _EditorTool.highlighter => _draftHighlighterOpacity,
      _EditorTool.eraser => _draftEraserOpacity,
      _ => _draftPenOpacity,
    };
  }

  Future<void> _loadDocument() async {
    setState(() => _isLoadingDocument = true);
    await pdfrxFlutterInitialize(dismissPdfiumWasmWarnings: true);

    final pdfDocument = await PdfDocument.openFile(
      widget.preparedDocument.localPath,
    );

    if (!mounted) {
      await pdfDocument.dispose();
      return;
    }

    final pageCount = pdfDocument.pages.length;
    final clampedPageNumber = _currentPageNumber.clamp(1, pageCount);

    setState(() {
      _pdfDocument = pdfDocument;
      _pageCount = pageCount;
      _currentPageNumber = clampedPageNumber;
      _isLoadingDocument = false;
    });

    await _renderCurrentPage();
  }

  Future<void> _renderCurrentPage() async {
    final pdfDocument = _pdfDocument;
    if (pdfDocument == null) {
      return;
    }

    final generation = ++_renderGeneration;
    setState(() => _isRenderingPage = true);

    final page = await pdfDocument.pages[_currentPageNumber - 1].ensureLoaded();
    final renderScale = _maxPreviewEdge / math.max(page.width, page.height);
    final rendered = await page.render(
      fullWidth: math.max(1, (page.width * renderScale).round()).toDouble(),
      fullHeight: math.max(1, (page.height * renderScale).round()).toDouble(),
      backgroundColor: 0xffffffff,
      annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
    );
    if (rendered == null) {
      throw StateError('Impossible de rendre la page $_currentPageNumber.');
    }

    final image = await rendered.createImage();
    rendered.dispose();

    if (!mounted || generation != _renderGeneration) {
      image.dispose();
      return;
    }

    final previousImage = _pageImage;
    setState(() {
      _pageImage = image;
      _isRenderingPage = false;
      _selectedObjectId = null;
      _clearDrafts();
    });
    previousImage?.dispose();
    _syncTextInspectorWithSelection();
    _transformationController.value = Matrix4.identity();
  }

  Future<void> _goToPage(int pageNumber) async {
    if (pageNumber < 1 ||
        pageNumber > _pageCount ||
        pageNumber == _currentPageNumber) {
      return;
    }
    _flushPendingTextInspectorChanges();
    setState(() {
      _currentPageNumber = pageNumber;
      _selectedObjectId = null;
      _clearDrafts();
    });
    _syncTextInspectorWithSelection();
    await _renderCurrentPage();
  }

  void _clearDrafts() {
    _draftStartPoint = null;
    _draftTextRect = null;
    _draftShapeRect = null;
    _draftStrokePoints = const <Offset>[];
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleTextInspectorChanged() {
    if (_isSyncingTextInspector) {
      return;
    }

    final selectedObject = _selectedObject;
    if (selectedObject is! TextEditObject) {
      return;
    }

    final nextText = _textInspectorController.text;
    if (selectedObject.text == nextText) {
      return;
    }

    _hasPendingTextInspectorCommit = true;
    _previewState(
      _state.upsertObject(selectedObject.copyWith(text: nextText)),
      selectedObjectId: selectedObject.id,
    );
  }

  void _handleTextInspectorFocusChanged() {
    if (_textInspectorFocusNode.hasFocus) {
      return;
    }
    _flushPendingTextInspectorChanges();
  }

  void _syncTextInspectorWithSelection() {
    final selectedObject = _selectedObject;
    if (selectedObject is! TextEditObject) {
      if (_textInspectorSyncedObjectId != null ||
          _textInspectorController.text.isNotEmpty) {
        _isSyncingTextInspector = true;
        _textInspectorController.clear();
        _isSyncingTextInspector = false;
      }
      _textInspectorSyncedObjectId = null;
      return;
    }

    if (_textInspectorSyncedObjectId == selectedObject.id &&
        _textInspectorController.text == selectedObject.text) {
      return;
    }

    _isSyncingTextInspector = true;
    _textInspectorController.value = TextEditingValue(
      text: selectedObject.text,
      selection: TextSelection.collapsed(offset: selectedObject.text.length),
    );
    _isSyncingTextInspector = false;
    _textInspectorSyncedObjectId = selectedObject.id;
  }

  void _scheduleTextInspectorFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _textInspectorFocusNode.requestFocus();
    });
  }

  void _flushPendingTextInspectorChanges() {
    if (!_hasPendingTextInspectorCommit) {
      return;
    }
    _hasPendingTextInspectorCommit = false;
    _commitCurrentState(selectedObjectId: _selectedObjectId);
  }

  void _toggleChromeVisibility() {
    if (_isChromeCollapsed) {
      _syncTextInspectorWithSelection();
    } else {
      _flushPendingTextInspectorChanges();
    }
    setState(() {
      _isChromeCollapsed = !_isChromeCollapsed;
    });
  }

  String _toolLabel(_EditorTool tool) {
    return switch (tool) {
      _EditorTool.select => 'Selection',
      _EditorTool.text => 'Texte',
      _EditorTool.pen => 'Stylo',
      _EditorTool.highlighter => 'Surligneur',
      _EditorTool.eraser => 'Gomme',
      _EditorTool.shape => 'Forme',
    };
  }

  IconData _toolIcon(_EditorTool tool) {
    return switch (tool) {
      _EditorTool.select => Icons.near_me_rounded,
      _EditorTool.text => Icons.text_fields_rounded,
      _EditorTool.pen => Icons.draw_rounded,
      _EditorTool.highlighter => Icons.auto_fix_high_rounded,
      _EditorTool.eraser => Icons.cleaning_services_rounded,
      _EditorTool.shape => Icons.crop_square_rounded,
    };
  }

  void _setActiveTool(_EditorTool tool) {
    _flushPendingTextInspectorChanges();
    setState(() {
      _activeTool = tool;
      if (tool != _EditorTool.select) {
        _selectedObjectId = null;
      }
      _clearDrafts();
    });
    _syncTextInspectorWithSelection();
  }

  void _selectObject(String? objectId) {
    _flushPendingTextInspectorChanges();
    setState(() {
      _selectedObjectId = objectId;
      _activeTool = _EditorTool.select;
    });
    _syncTextInspectorWithSelection();
  }

  void _previewState(EditorDocumentState next, {String? selectedObjectId}) {
    setState(() {
      _state = next;
      if (selectedObjectId != null) {
        _selectedObjectId = selectedObjectId;
      }
    });
  }

  void _commitCurrentState({String? selectedObjectId}) {
    final history =
        _history.sublist(0, _historyIndex + 1).toList(growable: true)
          ..add(_state);
    setState(() {
      _history = List<EditorDocumentState>.unmodifiable(history);
      _historyIndex = history.length - 1;
      if (selectedObjectId != null) {
        _selectedObjectId = selectedObjectId;
      }
      if (_selectedObjectId != null &&
          _state.findObjectById(_selectedObjectId!) == null) {
        _selectedObjectId = null;
      }
    });
    _syncTextInspectorWithSelection();
  }

  void _applyAndCommit(EditorDocumentState next, {String? selectedObjectId}) {
    setState(() {
      _state = next;
      if (selectedObjectId != null) {
        _selectedObjectId = selectedObjectId;
      }
    });
    _commitCurrentState(selectedObjectId: selectedObjectId);
  }

  void _undo() {
    if (_historyIndex == 0) {
      return;
    }
    _flushPendingTextInspectorChanges();
    setState(() {
      _historyIndex -= 1;
      _state = _history[_historyIndex];
      if (_selectedObjectId != null &&
          _state.findObjectById(_selectedObjectId!) == null) {
        _selectedObjectId = null;
      }
    });
    _syncTextInspectorWithSelection();
  }

  void _redo() {
    if (_historyIndex >= _history.length - 1) {
      return;
    }
    _flushPendingTextInspectorChanges();
    setState(() {
      _historyIndex += 1;
      _state = _history[_historyIndex];
      if (_selectedObjectId != null &&
          _state.findObjectById(_selectedObjectId!) == null) {
        _selectedObjectId = null;
      }
    });
    _syncTextInspectorWithSelection();
  }

  Offset _toNormalized(Offset localPosition, Size canvasSize) {
    return clampNormalizedOffset(
      Offset(
        canvasSize.width == 0 ? 0 : localPosition.dx / canvasSize.width,
        canvasSize.height == 0 ? 0 : localPosition.dy / canvasSize.height,
      ),
    );
  }

  Rect _normalizedRectFromPoints(Offset start, Offset end) {
    final left = math.min(start.dx, end.dx);
    final top = math.min(start.dy, end.dy);
    final right = math.max(start.dx, end.dx);
    final bottom = math.max(start.dy, end.dy);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect _clampRect(Rect rect) {
    final safeWidth = rect.width.clamp(_minObjectExtent, 1.0).toDouble();
    final safeHeight = rect.height.clamp(_minObjectExtent, 1.0).toDouble();
    final left = rect.left.clamp(0.0, 1.0 - safeWidth).toDouble();
    final top = rect.top.clamp(0.0, 1.0 - safeHeight).toDouble();
    return Rect.fromLTWH(left, top, safeWidth, safeHeight);
  }

  Rect _buildCenteredRect({required double width, required double height}) {
    final safeWidth = width.clamp(_minObjectExtent, 0.8).toDouble();
    final safeHeight = height.clamp(_minObjectExtent, 0.8).toDouble();
    return Rect.fromLTWH(
      (1 - safeWidth) / 2,
      (1 - safeHeight) / 2,
      safeWidth,
      safeHeight,
    );
  }

  Rect _normalizedToCanvasRect(Rect rect, Size canvasSize) {
    return Rect.fromLTWH(
      rect.left * canvasSize.width,
      rect.top * canvasSize.height,
      rect.width * canvasSize.width,
      rect.height * canvasSize.height,
    );
  }

  Future<void> _handleCanvasPanStart(
    DragStartDetails details,
    Size canvasSize,
  ) async {
    final normalized = _toNormalized(details.localPosition, canvasSize);
    switch (_activeTool) {
      case _EditorTool.text:
        setState(() {
          _draftStartPoint = normalized;
          _draftTextRect = Rect.fromLTWH(normalized.dx, normalized.dy, 0, 0);
        });
      case _EditorTool.shape:
        setState(() {
          _draftStartPoint = normalized;
          _draftShapeRect = Rect.fromLTWH(normalized.dx, normalized.dy, 0, 0);
        });
      case _EditorTool.pen || _EditorTool.highlighter || _EditorTool.eraser:
        setState(() {
          _draftStartPoint = normalized;
          _draftStrokePoints = <Offset>[normalized];
        });
      case _EditorTool.select:
        break;
    }
  }

  void _handleCanvasPanUpdate(DragUpdateDetails details, Size canvasSize) {
    final normalized = _toNormalized(details.localPosition, canvasSize);
    switch (_activeTool) {
      case _EditorTool.text:
        final start = _draftStartPoint;
        if (start == null) {
          return;
        }
        setState(() {
          _draftTextRect = _normalizedRectFromPoints(start, normalized);
        });
      case _EditorTool.shape:
        final start = _draftStartPoint;
        if (start == null) {
          return;
        }
        setState(() {
          _draftShapeRect = _normalizedRectFromPoints(start, normalized);
        });
      case _EditorTool.pen || _EditorTool.highlighter || _EditorTool.eraser:
        if (_draftStrokePoints.isEmpty) {
          return;
        }
        setState(() {
          _draftStrokePoints = List<Offset>.unmodifiable(<Offset>[
            ..._draftStrokePoints,
            normalized,
          ]);
        });
      case _EditorTool.select:
        break;
    }
  }

  Future<void> _handleCanvasPanEnd() async {
    switch (_activeTool) {
      case _EditorTool.text:
        final rect = _draftTextRect;
        setState(_clearDrafts);
        if (rect == null ||
            rect.width < _minObjectExtent ||
            rect.height < _minObjectExtent) {
          return;
        }
        final object = TextEditObject(
          id: _newObjectId('text'),
          pageNumber: _currentPageNumber,
          normalizedRect: _clampRect(rect),
          text: '',
          style: _draftTextStyle,
          opacity: _draftTextOpacity,
        );
        _applyAndCommit(
          _state.upsertObject(object),
          selectedObjectId: object.id,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _activeTool = _EditorTool.select;
          _isChromeCollapsed = false;
        });
        _syncTextInspectorWithSelection();
        _scheduleTextInspectorFocus();
      case _EditorTool.shape:
        final rect = _draftShapeRect;
        setState(_clearDrafts);
        if (rect == null ||
            rect.width < _minObjectExtent ||
            rect.height < _minObjectExtent) {
          return;
        }
        final object = ShapeEditObject(
          id: _newObjectId('shape'),
          pageNumber: _currentPageNumber,
          normalizedRect: _clampRect(rect),
          kind: _selectedShapeKind,
          style: _draftShapeStyle,
          opacity: _draftShapeOpacity,
        );
        _applyAndCommit(
          _state.upsertObject(object),
          selectedObjectId: object.id,
        );
      case _EditorTool.pen || _EditorTool.highlighter || _EditorTool.eraser:
        final points = _draftStrokePoints;
        setState(_clearDrafts);
        if (points.length < 2) {
          return;
        }
        final object = StrokeEditObject(
          id: _newObjectId('stroke'),
          pageNumber: _currentPageNumber,
          normalizedRect: computeNormalizedBounds(points),
          points: points,
          style: _currentStrokeDraftStyle,
          opacity: _currentStrokeDraftOpacity,
        );
        _applyAndCommit(
          _state.upsertObject(object),
          selectedObjectId: object.id,
        );
      case _EditorTool.select:
        break;
    }
  }

  String _newObjectId(String prefix) {
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}';
  }

  EditorDocumentState _moveObjectInState(
    EditorDocumentState state,
    String objectId,
    Offset delta,
  ) {
    final object = state.findObjectById(objectId);
    if (object == null || object.isLocked) {
      return state;
    }

    switch (object) {
      case TextEditObject():
        return state.upsertObject(
          object.copyWith(
            normalizedRect: shiftNormalizedRect(object.normalizedRect, delta),
          ),
        );
      case ImageEditObject():
        return state.upsertObject(
          object.copyWith(
            normalizedRect: shiftNormalizedRect(object.normalizedRect, delta),
          ),
        );
      case SignatureEditObject():
        return state.upsertObject(
          object.copyWith(
            normalizedRect: shiftNormalizedRect(object.normalizedRect, delta),
          ),
        );
      case ShapeEditObject():
        return state.upsertObject(
          object.copyWith(
            normalizedRect: shiftNormalizedRect(object.normalizedRect, delta),
          ),
        );
      case StrokeEditObject():
        final movedPoints = object.points
            .map((point) => clampNormalizedOffset(point + delta))
            .toList(growable: false);
        return state.upsertObject(
          object.copyWith(
            points: movedPoints,
            normalizedRect: computeNormalizedBounds(movedPoints),
          ),
        );
    }
  }

  EditorDocumentState _resizeObjectInState(
    EditorDocumentState state,
    String objectId,
    Offset delta,
  ) {
    final object = state.findObjectById(objectId);
    if (object == null || object.isLocked || object is StrokeEditObject) {
      return state;
    }

    final rect = object.normalizedRect;
    final width = (rect.width + delta.dx)
        .clamp(_minObjectExtent, 1.0 - rect.left)
        .toDouble();
    final height = (rect.height + delta.dy)
        .clamp(_minObjectExtent, 1.0 - rect.top)
        .toDouble();
    final resizedRect = Rect.fromLTWH(rect.left, rect.top, width, height);

    return switch (object) {
      TextEditObject() => state.upsertObject(
        object.copyWith(normalizedRect: _clampRect(resizedRect)),
      ),
      ImageEditObject() => state.upsertObject(
        object.copyWith(normalizedRect: _clampRect(resizedRect)),
      ),
      SignatureEditObject() => state.upsertObject(
        object.copyWith(normalizedRect: _clampRect(resizedRect)),
      ),
      ShapeEditObject() => state.upsertObject(
        object.copyWith(normalizedRect: _clampRect(resizedRect)),
      ),
      StrokeEditObject() => state,
    };
  }

  void _duplicateSelectedObject() {
    final selectedObjectId = _selectedObjectId;
    if (selectedObjectId == null) {
      return;
    }
    final duplicatedId = _newObjectId('copy');
    _applyAndCommit(
      _state.duplicateObject(selectedObjectId, newId: duplicatedId),
      selectedObjectId: duplicatedId,
    );
  }

  void _deleteSelectedObject() {
    final selectedObjectId = _selectedObjectId;
    if (selectedObjectId == null) {
      return;
    }
    _applyAndCommit(
      _state.removeObject(selectedObjectId),
      selectedObjectId: null,
    );
  }

  void _bringSelectedObjectForward() {
    final selectedObjectId = _selectedObjectId;
    if (selectedObjectId == null) {
      return;
    }
    _applyAndCommit(
      _state.bringObjectForward(selectedObjectId),
      selectedObjectId: selectedObjectId,
    );
  }

  void _sendSelectedObjectBackward() {
    final selectedObjectId = _selectedObjectId;
    if (selectedObjectId == null) {
      return;
    }
    _applyAndCommit(
      _state.sendObjectBackward(selectedObjectId),
      selectedObjectId: selectedObjectId,
    );
  }

  void _toggleSelectedObjectLock() {
    final selectedObjectId = _selectedObjectId;
    if (selectedObjectId == null) {
      return;
    }
    _applyAndCommit(
      _state.toggleObjectLock(selectedObjectId),
      selectedObjectId: selectedObjectId,
    );
  }

  void _rotateSelectedObject(double deltaDegrees) {
    final selectedObject = _selectedObject;
    if (selectedObject == null || selectedObject.isLocked) {
      return;
    }

    switch (selectedObject) {
      case TextEditObject():
        _applyAndCommit(
          _state.upsertObject(
            selectedObject.copyWith(
              rotationDegrees: selectedObject.rotationDegrees + deltaDegrees,
            ),
          ),
          selectedObjectId: selectedObject.id,
        );
      case ImageEditObject():
        _applyAndCommit(
          _state.upsertObject(
            selectedObject.copyWith(
              rotationDegrees: selectedObject.rotationDegrees + deltaDegrees,
            ),
          ),
          selectedObjectId: selectedObject.id,
        );
      case SignatureEditObject():
        _applyAndCommit(
          _state.upsertObject(
            selectedObject.copyWith(
              rotationDegrees: selectedObject.rotationDegrees + deltaDegrees,
            ),
          ),
          selectedObjectId: selectedObject.id,
        );
      case ShapeEditObject():
        _applyAndCommit(
          _state.upsertObject(
            selectedObject.copyWith(
              rotationDegrees: selectedObject.rotationDegrees + deltaDegrees,
            ),
          ),
          selectedObjectId: selectedObject.id,
        );
      case StrokeEditObject():
        break;
    }
  }

  void _updateTextStyle(
    TextReplacementStyle Function(TextReplacementStyle style) transform,
  ) {
    final selectedObject = _selectedObject;
    if (selectedObject is TextEditObject) {
      _applyAndCommit(
        _state.upsertObject(
          selectedObject.copyWith(style: transform(selectedObject.style)),
        ),
        selectedObjectId: selectedObject.id,
      );
      return;
    }
    setState(() {
      _draftTextStyle = transform(_draftTextStyle);
    });
  }

  void _updateTextOpacity(double opacity) {
    final selectedObject = _selectedObject;
    if (selectedObject is TextEditObject) {
      _applyAndCommit(
        _state.upsertObject(selectedObject.copyWith(opacity: opacity)),
        selectedObjectId: selectedObject.id,
      );
      return;
    }
    setState(() {
      _draftTextOpacity = opacity;
    });
  }

  void _updateStrokeStyle(StrokeStyle Function(StrokeStyle style) transform) {
    final selectedObject = _selectedObject;
    if (selectedObject is StrokeEditObject) {
      _applyAndCommit(
        _state.upsertObject(
          selectedObject.copyWith(style: transform(selectedObject.style)),
        ),
        selectedObjectId: selectedObject.id,
      );
      return;
    }

    setState(() {
      switch (_activeTool) {
        case _EditorTool.highlighter:
          _draftHighlighterStyle = transform(_draftHighlighterStyle);
        case _EditorTool.eraser:
          _draftEraserStyle = transform(_draftEraserStyle);
        case _EditorTool.pen:
          _draftPenStyle = transform(_draftPenStyle);
        case _EditorTool.select || _EditorTool.text || _EditorTool.shape:
          break;
      }
    });
  }

  void _updateStrokeOpacity(double opacity) {
    final selectedObject = _selectedObject;
    if (selectedObject is StrokeEditObject) {
      _applyAndCommit(
        _state.upsertObject(selectedObject.copyWith(opacity: opacity)),
        selectedObjectId: selectedObject.id,
      );
      return;
    }

    setState(() {
      switch (_activeTool) {
        case _EditorTool.highlighter:
          _draftHighlighterOpacity = opacity;
        case _EditorTool.eraser:
          _draftEraserOpacity = opacity;
        case _EditorTool.pen:
          _draftPenOpacity = opacity;
        case _EditorTool.select || _EditorTool.text || _EditorTool.shape:
          break;
      }
    });
  }

  void _updateShapeStyle(ShapeStyle Function(ShapeStyle style) transform) {
    final selectedObject = _selectedObject;
    if (selectedObject is ShapeEditObject) {
      _applyAndCommit(
        _state.upsertObject(
          selectedObject.copyWith(style: transform(selectedObject.style)),
        ),
        selectedObjectId: selectedObject.id,
      );
      return;
    }

    setState(() {
      _draftShapeStyle = transform(_draftShapeStyle);
    });
  }

  void _updateShapeOpacity(double opacity) {
    final selectedObject = _selectedObject;
    if (selectedObject is ShapeEditObject) {
      _applyAndCommit(
        _state.upsertObject(selectedObject.copyWith(opacity: opacity)),
        selectedObjectId: selectedObject.id,
      );
      return;
    }

    setState(() {
      _draftShapeOpacity = opacity;
    });
  }

  void _updateVisualObjectOpacity(double opacity) {
    final selectedObject = _selectedObject;
    if (selectedObject == null) {
      return;
    }
    _applyAndCommit(
      _state.upsertObject(selectedObject.copyBase(opacity: opacity)),
      selectedObjectId: selectedObject.id,
    );
  }

  Future<void> _editSelectedText() async {
    final selectedObject = _selectedObject;
    if (selectedObject is! TextEditObject) {
      return;
    }

    if (_isChromeCollapsed) {
      setState(() {
        _isChromeCollapsed = false;
      });
    }
    _syncTextInspectorWithSelection();
    _scheduleTextInspectorFocus();
  }

  Future<void> _insertSignature() async {
    final bytes = await _signatureCaptureService.captureSignature(context);
    if (!mounted || bytes == null || bytes.isEmpty) {
      return;
    }

    final rect = await _buildRectForImage(
      bytes,
      maxWidth: 0.42,
      maxHeight: 0.18,
    );
    if (!mounted) {
      return;
    }

    final object = SignatureEditObject(
      id: _newObjectId('signature'),
      pageNumber: _currentPageNumber,
      normalizedRect: rect,
      imageBytes: bytes,
    );
    _applyAndCommit(_state.upsertObject(object), selectedObjectId: object.id);
  }

  Future<void> _insertImage() async {
    final importedImage = await _imageImportService.pickImage();
    if (!mounted || importedImage == null || importedImage.bytes.isEmpty) {
      return;
    }

    final rect = await _buildRectForImage(
      importedImage.bytes,
      maxWidth: 0.48,
      maxHeight: 0.32,
    );
    if (!mounted) {
      return;
    }

    final object = ImageEditObject(
      id: _newObjectId('image'),
      pageNumber: _currentPageNumber,
      normalizedRect: rect,
      imageBytes: importedImage.bytes,
    );
    _applyAndCommit(_state.upsertObject(object), selectedObjectId: object.id);
  }

  Future<Rect> _buildRectForImage(
    Uint8List bytes, {
    required double maxWidth,
    required double maxHeight,
  }) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final aspectRatio = frame.image.width / math.max(1, frame.image.height);
    frame.image.dispose();
    codec.dispose();

    var width = maxWidth;
    var height = width / aspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspectRatio;
    }
    return _buildCenteredRect(width: width, height: height);
  }

  Future<void> _saveEditedCopy() async {
    if (_isSaving) {
      return;
    }
    _flushPendingTextInspectorChanges();

    setState(() => _isSaving = true);
    final tempPath = p.join(
      p.dirname(widget.preparedDocument.localPath),
      'edited-${DateTime.now().millisecondsSinceEpoch}.pdf',
    );

    try {
      await _exportService.exportToFile(
        sourcePdfPath: widget.preparedDocument.localPath,
        outputPdfPath: tempPath,
        state: _state,
      );

      final preparedDocument = await widget.documentBridge.savePdfDocumentCopy(
        sourceLocalPath: tempPath,
        displayName: _buildEditedDisplayName(
          widget.preparedDocument.displayName,
        ),
      );
      if (!mounted || preparedDocument == null) {
        return;
      }

      var savedDocument = await widget.repository.upsertOpenedDocument(
        uri: preparedDocument.uri,
        displayName: preparedDocument.displayName,
        sizeBytes: preparedDocument.sizeBytes,
      );
      await widget.repository.saveReadingProgress(
        uri: savedDocument.uri,
        lastPage: _currentPageNumber - 1,
        pageCount: _pageCount,
      );
      savedDocument =
          (await widget.repository.findByUri(savedDocument.uri)) ??
          savedDocument.copyWith(
            lastPage: _currentPageNumber - 1,
            pageCount: _pageCount,
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
      _showMessage('Impossible d enregistrer la copie modifiee.');
    } finally {
      try {
        await File(tempPath).delete();
      } catch (_) {}
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String _buildEditedDisplayName(String originalName) {
    final extension = p.extension(originalName);
    final baseName = p.basenameWithoutExtension(originalName);
    final safeExtension = extension.isEmpty ? '.pdf' : extension;
    return '$baseName - modifie$safeExtension';
  }

  @override
  Widget build(BuildContext context) {
    final pageImage = _pageImage;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: _isLoadingDocument
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final inspectorMaxHeight = math.min(
                  constraints.maxHeight * 0.42,
                  360.0,
                );

                return Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: pageImage == null
                          ? const Center(child: CircularProgressIndicator())
                          : _buildCanvas(pageImage),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _buildTopBar(),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: _isChromeCollapsed
                                    ? const SizedBox.shrink()
                                    : Padding(
                                        key: const ValueKey<String>(
                                          'expanded-top-chrome',
                                        ),
                                        padding: const EdgeInsets.only(top: 12),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            _buildToolbar(),
                                            const SizedBox(height: 8),
                                            _buildPageNavigationRow(),
                                          ],
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!_isChromeCollapsed)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 12,
                        child: SafeArea(
                          top: false,
                          child: _buildInspectorPanel(inspectorMaxHeight),
                        ),
                      ),
                    if (_isChromeCollapsed)
                      Positioned(
                        left: 16,
                        bottom: 16 + MediaQuery.paddingOf(context).bottom,
                        child: FloatingActionButton.small(
                          heroTag: 'editor_chrome_toggle',
                          onPressed: _toggleChromeVisibility,
                          tooltip: 'Afficher les outils',
                          child: const Icon(Icons.tune_rounded),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildTopBar() {
    final title = widget.savedDocument.displayName.isEmpty
        ? AppStrings.unknownDocument
        : widget.savedDocument.displayName;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: <Widget>[
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Retour',
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _isRenderingPage
                        ? 'Page $_currentPageNumber / $_pageCount - rendu...'
                        : 'Page $_currentPageNumber / $_pageCount',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
            if (!_isChromeCollapsed)
              IconButton(
                onPressed: _toggleChromeVisibility,
                tooltip: 'Masquer les controles',
                icon: const Icon(Icons.fullscreen_rounded),
              ),
            IconButton(
              onPressed: _isSaving ? null : _saveEditedCopy,
              tooltip: 'Enregistrer',
              icon: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        height: 72,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          scrollDirection: Axis.horizontal,
          children: <Widget>[
            for (final tool in _EditorTool.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _ToolChip(
                  icon: _toolIcon(tool),
                  label: _toolLabel(tool),
                  selected: _activeTool == tool,
                  onPressed: () => _setActiveTool(tool),
                ),
              ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _insertSignature,
              icon: const Icon(Icons.border_color_rounded),
              label: const Text('Signature'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _insertImage,
              icon: const Icon(Icons.image_rounded),
              label: const Text('Image'),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _historyIndex == 0 ? null : _undo,
              tooltip: 'Annuler',
              icon: const Icon(Icons.undo_rounded),
            ),
            IconButton(
              onPressed: _historyIndex >= _history.length - 1 ? null : _redo,
              tooltip: 'Retablir',
              icon: const Icon(Icons.redo_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageNavigationRow() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: <Widget>[
            IconButton(
              onPressed: _currentPageNumber <= 1
                  ? null
                  : () => _goToPage(_currentPageNumber - 1),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Navigation de page',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    '$_currentPageNumber / $_pageCount',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _currentPageNumber >= _pageCount
                  ? null
                  : () => _goToPage(_currentPageNumber + 1),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () {
                _transformationController.value = Matrix4.identity();
              },
              icon: const Icon(Icons.center_focus_strong_rounded),
              label: const Text('Vue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas(ui.Image pageImage) {
    final scaleGesturesEnabled = _activeTool == _EditorTool.select;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: InteractiveViewer(
            transformationController: _transformationController,
            minScale: 1,
            maxScale: 5,
            panEnabled: scaleGesturesEnabled,
            scaleEnabled: scaleGesturesEnabled,
            clipBehavior: Clip.none,
            child: AspectRatio(
              aspectRatio: pageImage.width / pageImage.height,
              child: LayoutBuilder(
                builder: (context, canvasConstraints) {
                  final canvasSize = Size(
                    canvasConstraints.maxWidth,
                    canvasConstraints.maxHeight,
                  );

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _activeTool == _EditorTool.select
                        ? () => _selectObject(null)
                        : null,
                    onPanStart: _activeTool == _EditorTool.select
                        ? null
                        : (details) =>
                              _handleCanvasPanStart(details, canvasSize),
                    onPanUpdate: _activeTool == _EditorTool.select
                        ? null
                        : (details) =>
                              _handleCanvasPanUpdate(details, canvasSize),
                    onPanEnd: _activeTool == _EditorTool.select
                        ? null
                        : (_) => _handleCanvasPanEnd(),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: Colors.black12),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 24,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: RawImage(image: pageImage, fit: BoxFit.fill),
                        ),
                        for (final object in _currentPageObjects)
                          _buildObjectWidget(object, canvasSize),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _DraftCanvasPainter(
                                pageSize: canvasSize,
                                draftTextRect: _draftTextRect,
                                draftShapeRect: _draftShapeRect,
                                draftShapeKind: _selectedShapeKind,
                                draftShapeStyle: _draftShapeStyle,
                                draftShapeOpacity: _draftShapeOpacity,
                                draftStrokePoints: _draftStrokePoints,
                                draftStrokeStyle: _currentStrokeDraftStyle,
                                draftStrokeOpacity: _currentStrokeDraftOpacity,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildObjectWidget(PdfEditObject object, Size canvasSize) {
    final canvasRect = _normalizedToCanvasRect(
      object.normalizedRect,
      canvasSize,
    );
    final isSelected = object.id == _selectedObjectId;
    final isLocked = object.isLocked;

    return Positioned.fromRect(
      rect: canvasRect,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _selectObject(object.id),
            onPanStart: _activeTool != _EditorTool.select || isLocked
                ? null
                : (_) => _selectObject(object.id),
            onPanUpdate: _activeTool != _EditorTool.select || isLocked
                ? null
                : (details) {
                    _previewState(
                      _moveObjectInState(
                        _state,
                        object.id,
                        Offset(
                          details.delta.dx / canvasSize.width,
                          details.delta.dy / canvasSize.height,
                        ),
                      ),
                      selectedObjectId: object.id,
                    );
                  },
            onPanEnd: _activeTool != _EditorTool.select || isLocked
                ? null
                : (_) => _commitCurrentState(selectedObjectId: object.id),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: isSelected
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      )
                    : null,
              ),
              child: _buildObjectContents(object, canvasSize, canvasRect.size),
            ),
          ),
          if (isSelected && isLocked)
            Positioned(
              top: -10,
              left: -10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.lock_rounded, size: 16),
                ),
              ),
            ),
          if (isSelected &&
              _activeTool == _EditorTool.select &&
              !isLocked &&
              object is! StrokeEditObject)
            Positioned(
              right: -12,
              bottom: -12,
              child: _ResizeHandle(
                onPanUpdate: (details) {
                  _previewState(
                    _resizeObjectInState(
                      _state,
                      object.id,
                      Offset(
                        details.delta.dx / canvasSize.width,
                        details.delta.dy / canvasSize.height,
                      ),
                    ),
                    selectedObjectId: object.id,
                  );
                },
                onPanEnd: () =>
                    _commitCurrentState(selectedObjectId: object.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildObjectContents(
    PdfEditObject object,
    Size pageSize,
    Size objectSize,
  ) {
    switch (object) {
      case TextEditObject():
        final fontSize = math.max(
          EditorStyleCatalog.minTextFontSize,
          objectSize.height * object.style.fontSizeScale,
        );
        return Transform.rotate(
          angle: object.rotationDegrees * math.pi / 180,
          child: ClipRect(
            child: Container(
              color: object.style.backgroundColor == null
                  ? null
                  : applyObjectOpacity(
                      object.style.backgroundColor!,
                      object.opacity,
                    ),
              padding: EdgeInsets.all(
                math.max(
                  6,
                  math.min(objectSize.width, objectSize.height) *
                      object.style.paddingFactor,
                ),
              ),
              alignment: Alignment.topLeft,
              child: Text(
                object.text,
                style: buildEditorTextStyle(
                  object.style,
                  fontSize: fontSize,
                  opacity: object.opacity,
                ),
              ),
            ),
          ),
        );
      case SignatureEditObject():
        return Transform.rotate(
          angle: object.rotationDegrees * math.pi / 180,
          child: Opacity(
            opacity: object.opacity,
            child: Image.memory(
              object.imageBytes,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        );
      case ImageEditObject():
        return Transform.rotate(
          angle: object.rotationDegrees * math.pi / 180,
          child: Opacity(
            opacity: object.opacity,
            child: Image.memory(
              object.imageBytes,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.high,
            ),
          ),
        );
      case StrokeEditObject():
        return CustomPaint(
          painter: _StrokeObjectPainter(object: object, pageSize: pageSize),
          child: const SizedBox.expand(),
        );
      case ShapeEditObject():
        return Transform.rotate(
          angle: object.rotationDegrees * math.pi / 180,
          child: CustomPaint(
            painter: _ShapeObjectPainter(object: object, pageSize: pageSize),
            child: const SizedBox.expand(),
          ),
        );
    }
  }

  Widget _buildSelectedObjectActions() {
    final selectedObject = _selectedObject;
    if (selectedObject == null) {
      return const SizedBox.shrink();
    }

    final canRotate = selectedObject is! StrokeEditObject;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        OutlinedButton.icon(
          onPressed: _duplicateSelectedObject,
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Dupliquer'),
        ),
        OutlinedButton.icon(
          onPressed: _bringSelectedObjectForward,
          icon: const Icon(Icons.flip_to_front_rounded),
          label: const Text('Avant'),
        ),
        OutlinedButton.icon(
          onPressed: _sendSelectedObjectBackward,
          icon: const Icon(Icons.flip_to_back_rounded),
          label: const Text('Arriere'),
        ),
        OutlinedButton.icon(
          onPressed: _toggleSelectedObjectLock,
          icon: Icon(
            selectedObject.isLocked
                ? Icons.lock_open_rounded
                : Icons.lock_rounded,
          ),
          label: Text(
            selectedObject.isLocked ? 'Deverrouiller' : 'Verrouiller',
          ),
        ),
        if (selectedObject is TextEditObject)
          OutlinedButton.icon(
            onPressed: _editSelectedText,
            icon: const Icon(Icons.edit_note_rounded),
            label: const Text('Texte'),
          ),
        if (canRotate)
          OutlinedButton.icon(
            onPressed: () => _rotateSelectedObject(-15),
            icon: const Icon(Icons.rotate_left_rounded),
            label: const Text('-15'),
          ),
        if (canRotate)
          OutlinedButton.icon(
            onPressed: () => _rotateSelectedObject(15),
            icon: const Icon(Icons.rotate_right_rounded),
            label: const Text('+15'),
          ),
        FilledButton.tonalIcon(
          onPressed: _deleteSelectedObject,
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Supprimer'),
        ),
      ],
    );
  }

  Widget _buildInspectorPanel(double maxHeight) {
    final selectedObject = _selectedObject;
    final showPanel =
        selectedObject != null || _activeTool != _EditorTool.select;
    if (!showPanel) {
      return const SizedBox.shrink();
    }

    Widget panel;
    if (selectedObject is TextEditObject || _activeTool == _EditorTool.text) {
      panel = _buildTextInspector(selectedObject as TextEditObject?);
    } else if (selectedObject is StrokeEditObject ||
        _activeTool == _EditorTool.pen ||
        _activeTool == _EditorTool.highlighter ||
        _activeTool == _EditorTool.eraser) {
      panel = _buildStrokeInspector(selectedObject as StrokeEditObject?);
    } else if (selectedObject is ShapeEditObject ||
        _activeTool == _EditorTool.shape) {
      panel = _buildShapeInspector(selectedObject as ShapeEditObject?);
    } else {
      panel = _buildVisualObjectInspector(selectedObject);
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Options d edition',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleChromeVisibility,
                    tooltip: 'Masquer les controles',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
              if (selectedObject != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Objet selectionne',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 10),
                _buildSelectedObjectActions(),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 12),
              ],
              panel,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextInspector(TextEditObject? selectedObject) {
    final style = selectedObject?.style ?? _draftTextStyle;
    final opacity = selectedObject?.opacity ?? _draftTextOpacity;
    final transparentBackground = style.backgroundColor == null;
    final hasSelectedObject = selectedObject != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Texte',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _textInspectorController,
          focusNode: _textInspectorFocusNode,
          enabled: hasSelectedObject,
          minLines: 3,
          maxLines: 6,
          textInputAction: TextInputAction.newline,
          decoration: InputDecoration(
            labelText: 'Contenu',
            alignLabelWithHint: true,
            hintText: hasSelectedObject
                ? 'Saisir le texte'
                : 'Dessinez une zone texte pour commencer',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          hasSelectedObject
              ? 'Le texte est applique en direct sur la zone selectionnee.'
              : 'Dessinez une zone texte sur la page puis saisissez son contenu ici.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: style.fontFamily,
          decoration: const InputDecoration(
            labelText: 'Police',
            border: OutlineInputBorder(),
          ),
          items: EditorStyleCatalog.fonts
              .map(
                (font) => DropdownMenuItem<String>(
                  value: font.family,
                  child: Text(font.label),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            if (value == null) {
              return;
            }
            _updateTextStyle((current) => current.copyWith(fontFamily: value));
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<FontWeight>(
          initialValue: style.fontWeight,
          decoration: const InputDecoration(
            labelText: 'Graisse',
            border: OutlineInputBorder(),
          ),
          items: EditorStyleCatalog.fontWeights
              .map(
                (weight) => DropdownMenuItem<FontWeight>(
                  value: weight,
                  child: Text(EditorStyleCatalog.labelForWeight(weight)),
                ),
              )
              .toList(growable: false),
          onChanged: (weight) {
            if (weight == null) {
              return;
            }
            _updateTextStyle((current) => current.copyWith(fontWeight: weight));
          },
        ),
        const SizedBox(height: 12),
        Text('Taille', style: Theme.of(context).textTheme.labelLarge),
        Wrap(
          spacing: 8,
          children: EditorStyleCatalog.textSizes
              .map(
                (size) => ChoiceChip(
                  label: Text((size * 100).round().toString()),
                  selected: (style.fontSizeScale - size).abs() < 0.001,
                  onSelected: (_) {
                    _updateTextStyle(
                      (current) => current.copyWith(fontSizeScale: size),
                    );
                  },
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 12),
        Text('Couleur', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        _ColorPresetWrap(
          selectedColor: style.textColor,
          onColorSelected: (color) {
            _updateTextStyle((current) => current.copyWith(textColor: color));
          },
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fond transparent'),
          value: transparentBackground,
          onChanged: (value) {
            _updateTextStyle(
              (current) => value
                  ? current.copyWith(clearBackgroundColor: true)
                  : current.copyWith(backgroundColor: Colors.white),
            );
          },
        ),
        if (!transparentBackground) ...<Widget>[
          Text(
            'Couleur de fond',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          _ColorPresetWrap(
            selectedColor: style.backgroundColor,
            onColorSelected: (color) {
              _updateTextStyle(
                (current) => current.copyWith(backgroundColor: color),
              );
            },
          ),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Options avancees'),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: <Widget>[
            _LabeledSlider(
              label: 'Opacite',
              value: opacity,
              min: 0.1,
              max: 1,
              divisions: 18,
              onChanged: _updateTextOpacity,
            ),
            _LabeledSlider(
              label: 'Echelle police',
              value: style.fontSizeScale,
              min: 0.06,
              max: 0.9,
              divisions: 42,
              onChanged: (value) {
                _updateTextStyle(
                  (current) => current.copyWith(fontSizeScale: value),
                );
              },
            ),
            _LabeledSlider(
              label: 'Marge interne',
              value: style.paddingFactor,
              min: 0.02,
              max: 0.2,
              divisions: 18,
              onChanged: (value) {
                _updateTextStyle(
                  (current) => current.copyWith(paddingFactor: value),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStrokeInspector(StrokeEditObject? selectedObject) {
    final style = selectedObject?.style ?? _currentStrokeDraftStyle;
    final opacity = selectedObject?.opacity ?? _currentStrokeDraftOpacity;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          selectedObject?.style.kind.name ?? _toolLabel(_activeTool),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text('Couleur', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        _ColorPresetWrap(
          selectedColor: style.color,
          onColorSelected: (color) {
            _updateStrokeStyle((current) => current.copyWith(color: color));
          },
        ),
        const SizedBox(height: 12),
        Text('Epaisseur', style: Theme.of(context).textTheme.labelLarge),
        Wrap(
          spacing: 8,
          children: EditorStyleCatalog.strokeSizes
              .map(
                (size) => ChoiceChip(
                  label: Text(size.toStringAsFixed(3)),
                  selected: (style.widthScale - size).abs() < 0.0005,
                  onSelected: (_) {
                    _updateStrokeStyle(
                      (current) => current.copyWith(widthScale: size),
                    );
                  },
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Options avancees'),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: <Widget>[
            _LabeledSlider(
              label: 'Opacite',
              value: opacity,
              min: 0.1,
              max: 1,
              divisions: 18,
              onChanged: _updateStrokeOpacity,
            ),
            _LabeledSlider(
              label: 'Epaisseur exacte',
              value: style.widthScale,
              min: 0.002,
              max: 0.03,
              divisions: 28,
              onChanged: (value) {
                _updateStrokeStyle(
                  (current) => current.copyWith(widthScale: value),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildShapeInspector(ShapeEditObject? selectedObject) {
    final style = selectedObject?.style ?? _draftShapeStyle;
    final opacity = selectedObject?.opacity ?? _draftShapeOpacity;
    final kind = selectedObject?.kind ?? _selectedShapeKind;
    final fillTransparent = style.fillColor == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Forme',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<ShapeKind>(
          initialValue: kind,
          decoration: const InputDecoration(
            labelText: 'Type',
            border: OutlineInputBorder(),
          ),
          items: ShapeKind.values
              .map(
                (value) => DropdownMenuItem<ShapeKind>(
                  value: value,
                  child: Text(_shapeLabel(value)),
                ),
              )
              .toList(growable: false),
          onChanged: (value) {
            if (value == null) {
              return;
            }
            if (selectedObject != null) {
              _applyAndCommit(
                _state.upsertObject(selectedObject.copyWith(kind: value)),
                selectedObjectId: selectedObject.id,
              );
            } else {
              setState(() {
                _selectedShapeKind = value;
              });
            }
          },
        ),
        const SizedBox(height: 12),
        Text('Contour', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        _ColorPresetWrap(
          selectedColor: style.strokeColor,
          onColorSelected: (color) {
            _updateShapeStyle(
              (current) => current.copyWith(strokeColor: color),
            );
          },
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fond transparent'),
          value: fillTransparent,
          onChanged: (value) {
            _updateShapeStyle(
              (current) => value
                  ? current.copyWith(clearFillColor: true)
                  : current.copyWith(fillColor: Colors.white),
            );
          },
        ),
        if (!fillTransparent) ...<Widget>[
          const SizedBox(height: 4),
          _ColorPresetWrap(
            selectedColor: style.fillColor,
            onColorSelected: (color) {
              _updateShapeStyle(
                (current) => current.copyWith(fillColor: color),
              );
            },
          ),
        ],
        const SizedBox(height: 12),
        Text('Epaisseur', style: Theme.of(context).textTheme.labelLarge),
        Wrap(
          spacing: 8,
          children: EditorStyleCatalog.strokeSizes
              .map(
                (size) => ChoiceChip(
                  label: Text(size.toStringAsFixed(3)),
                  selected: (style.strokeWidthScale - size).abs() < 0.0005,
                  onSelected: (_) {
                    _updateShapeStyle(
                      (current) => current.copyWith(strokeWidthScale: size),
                    );
                  },
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Options avancees'),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: <Widget>[
            _LabeledSlider(
              label: 'Opacite',
              value: opacity,
              min: 0.1,
              max: 1,
              divisions: 18,
              onChanged: _updateShapeOpacity,
            ),
            _LabeledSlider(
              label: 'Epaisseur exacte',
              value: style.strokeWidthScale,
              min: 0.002,
              max: 0.03,
              divisions: 28,
              onChanged: (value) {
                _updateShapeStyle(
                  (current) => current.copyWith(strokeWidthScale: value),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVisualObjectInspector(PdfEditObject? selectedObject) {
    if (selectedObject == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          selectedObject is SignatureEditObject ? 'Signature' : 'Image',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        _LabeledSlider(
          label: 'Opacite',
          value: selectedObject.opacity,
          min: 0.1,
          max: 1,
          divisions: 18,
          onChanged: _updateVisualObjectOpacity,
        ),
      ],
    );
  }

  String _shapeLabel(ShapeKind kind) {
    return switch (kind) {
      ShapeKind.rectangle => 'Rectangle',
      ShapeKind.ellipse => 'Cercle',
      ShapeKind.line => 'Ligne',
      ShapeKind.arrow => 'Fleche',
    };
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      onSelected: (_) => onPressed(),
      avatar: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class _ColorPresetWrap extends StatelessWidget {
  const _ColorPresetWrap({
    required this.selectedColor,
    required this.onColorSelected,
  });

  final Color? selectedColor;
  final ValueChanged<Color> onColorSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: EditorStyleCatalog.colorPresets
          .map(
            (color) => _ColorPresetButton(
              color: color,
              selected: selectedColor == color,
              onPressed: () => onColorSelected(color),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _ColorPresetButton extends StatelessWidget {
  const _ColorPresetButton({
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : Colors.black26;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onPressed,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: selected ? 3 : 1),
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label),
            const Spacer(),
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

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onPanUpdate, required this.onPanEnd});

  final ValueChanged<DragUpdateDetails> onPanUpdate;
  final VoidCallback onPanEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: onPanUpdate,
      onPanEnd: (_) => onPanEnd(),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Icon(
          Icons.open_in_full_rounded,
          size: 14,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _StrokeObjectPainter extends CustomPainter {
  const _StrokeObjectPainter({required this.object, required this.pageSize});

  final StrokeEditObject object;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (object.points.length < 2) {
      return;
    }

    final rect = object.normalizedRect;
    final points = object.points
        .map(
          (point) => Offset(
            rect.width == 0
                ? 0
                : ((point.dx - rect.left) / rect.width) * size.width,
            rect.height == 0
                ? 0
                : ((point.dy - rect.top) / rect.height) * size.height,
          ),
        )
        .toList(growable: false);

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index += 1) {
      path.lineTo(points[index].dx, points[index].dy);
    }

    final paint = Paint()
      ..color = applyObjectOpacity(object.style.color, object.opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidthForScale(object.style.widthScale, pageSize)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokeObjectPainter oldDelegate) {
    return oldDelegate.object != object || oldDelegate.pageSize != pageSize;
  }
}

class _ShapeObjectPainter extends CustomPainter {
  const _ShapeObjectPainter({required this.object, required this.pageSize});

  final ShapeEditObject object;
  final Size pageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = applyObjectOpacity(object.style.strokeColor, object.opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidthForScale(
        object.style.strokeWidthScale,
        pageSize,
      );
    final fillColor = object.style.fillColor == null
        ? null
        : applyObjectOpacity(object.style.fillColor!, object.opacity);
    final rect = Offset.zero & size;

    switch (object.kind) {
      case ShapeKind.rectangle:
        if (fillColor != null) {
          canvas.drawRect(rect, Paint()..color = fillColor);
        }
        canvas.drawRect(rect, strokePaint);
      case ShapeKind.ellipse:
        if (fillColor != null) {
          canvas.drawOval(rect, Paint()..color = fillColor);
        }
        canvas.drawOval(rect, strokePaint);
      case ShapeKind.line:
        canvas.drawLine(rect.topLeft, rect.bottomRight, strokePaint);
      case ShapeKind.arrow:
        canvas.drawLine(rect.topLeft, rect.bottomRight, strokePaint);
        final angle = math.atan2(rect.height, rect.width);
        final headLength = math.max(12, strokePaint.strokeWidth * 4);
        final end = rect.bottomRight;
        final left = Offset(
          end.dx - headLength * math.cos(angle - math.pi / 6),
          end.dy - headLength * math.sin(angle - math.pi / 6),
        );
        final right = Offset(
          end.dx - headLength * math.cos(angle + math.pi / 6),
          end.dy - headLength * math.sin(angle + math.pi / 6),
        );
        final path = Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(left.dx, left.dy)
          ..moveTo(end.dx, end.dy)
          ..lineTo(right.dx, right.dy);
        canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ShapeObjectPainter oldDelegate) {
    return oldDelegate.object != object || oldDelegate.pageSize != pageSize;
  }
}

class _DraftCanvasPainter extends CustomPainter {
  const _DraftCanvasPainter({
    required this.pageSize,
    required this.draftTextRect,
    required this.draftShapeRect,
    required this.draftShapeKind,
    required this.draftShapeStyle,
    required this.draftShapeOpacity,
    required this.draftStrokePoints,
    required this.draftStrokeStyle,
    required this.draftStrokeOpacity,
  });

  final Size pageSize;
  final Rect? draftTextRect;
  final Rect? draftShapeRect;
  final ShapeKind draftShapeKind;
  final ShapeStyle draftShapeStyle;
  final double draftShapeOpacity;
  final List<Offset> draftStrokePoints;
  final StrokeStyle draftStrokeStyle;
  final double draftStrokeOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final textRect = draftTextRect;
    if (textRect != null && textRect.width > 0 && textRect.height > 0) {
      final canvasRect = Rect.fromLTWH(
        textRect.left * size.width,
        textRect.top * size.height,
        textRect.width * size.width,
        textRect.height * size.height,
      );
      final paint = Paint()
        ..color = Colors.blueGrey
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRect(canvasRect, paint);
    }

    final shapeRect = draftShapeRect;
    if (shapeRect != null && shapeRect.width > 0 && shapeRect.height > 0) {
      final object = ShapeEditObject(
        id: 'draft-shape',
        pageNumber: 1,
        normalizedRect: shapeRect,
        kind: draftShapeKind,
        style: draftShapeStyle,
        opacity: draftShapeOpacity,
      );
      final canvasRect = Rect.fromLTWH(
        shapeRect.left * size.width,
        shapeRect.top * size.height,
        shapeRect.width * size.width,
        shapeRect.height * size.height,
      );
      canvas.save();
      canvas.translate(canvasRect.left, canvasRect.top);
      _ShapeObjectPainter(
        object: object,
        pageSize: pageSize,
      ).paint(canvas, canvasRect.size);
      canvas.restore();
    }

    if (draftStrokePoints.length > 1) {
      final object = StrokeEditObject(
        id: 'draft-stroke',
        pageNumber: 1,
        normalizedRect: computeNormalizedBounds(draftStrokePoints),
        points: draftStrokePoints,
        style: draftStrokeStyle,
        opacity: draftStrokeOpacity,
      );
      final rect = object.normalizedRect;
      final canvasRect = Rect.fromLTWH(
        rect.left * size.width,
        rect.top * size.height,
        rect.width * size.width,
        rect.height * size.height,
      );
      canvas.save();
      canvas.translate(canvasRect.left, canvasRect.top);
      _StrokeObjectPainter(
        object: object,
        pageSize: pageSize,
      ).paint(canvas, canvasRect.size);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _DraftCanvasPainter oldDelegate) {
    return oldDelegate.pageSize != pageSize ||
        oldDelegate.draftTextRect != draftTextRect ||
        oldDelegate.draftShapeRect != draftShapeRect ||
        oldDelegate.draftShapeKind != draftShapeKind ||
        oldDelegate.draftShapeStyle != draftShapeStyle ||
        oldDelegate.draftShapeOpacity != draftShapeOpacity ||
        oldDelegate.draftStrokePoints != draftStrokePoints ||
        oldDelegate.draftStrokeStyle != draftStrokeStyle ||
        oldDelegate.draftStrokeOpacity != draftStrokeOpacity;
  }
}
