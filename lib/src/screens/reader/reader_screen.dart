import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../app/app_strings.dart';
import '../../data/document_repository.dart';
import '../../data/saved_document.dart';
import '../../platform/document_bridge.dart';
import '../editor/editor_screen.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.repository,
    required this.documentBridge,
    required this.savedDocument,
    this.preparedDocument,
  });

  final DocumentRepository repository;
  final DocumentBridge documentBridge;
  final SavedDocument savedDocument;
  final PreparedPdfDocument? preparedDocument;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

enum _ReaderStatus { loading, ready, notFound, unreadable }

class _ReaderScreenState extends State<ReaderScreen> {
  static const _largeFileThreshold = 250 * 1024 * 1024;
  static const _maxViewerScale = 4.0;
  static const _onePassRenderingScaleThreshold = 1.5;
  static const _onePassRenderingSizeThreshold = 1600.0;
  static const _maxRenderedPagePixels = 4096.0;
  static const _maxImageBytesCachedOnMemory = 160 * 1024 * 1024;

  late SavedDocument _document;
  late final PdfViewerController _viewerController;
  PdfTextSearcher? _textSearcher;
  VoidCallback? _disposeSearchListener;
  final TextEditingController _searchController = TextEditingController();

  PreparedPdfDocument? _preparedDocument;
  _ReaderStatus _status = _ReaderStatus.loading;
  int? _currentPageNumber;
  int? _pageCount;
  bool _showSearch = false;
  bool _isSharingDocument = false;
  bool _isOpeningEditor = false;
  bool _viewerReady = false;

  @override
  void initState() {
    super.initState();
    _document = widget.savedDocument;
    _currentPageNumber = _document.lastPage + 1;
    _pageCount = _document.pageCount;
    _viewerController = PdfViewerController();
    _searchController.addListener(_onSearchQueryChanged);
    _prepareDocument();
  }

  @override
  void dispose() {
    _disposeSearchListener?.call();
    _searchController
      ..removeListener(_onSearchQueryChanged)
      ..dispose();
    _textSearcher?.dispose();
    super.dispose();
  }

  Future<void> _prepareDocument() async {
    setState(() {
      _status = _ReaderStatus.loading;
      _viewerReady = false;
      _showSearch = false;
    });

    try {
      final preparedDocument = widget.preparedDocument?.uri == _document.uri
          ? widget.preparedDocument
          : await widget.documentBridge.preparePdfDocument(_document.uri);

      if (!mounted) {
        return;
      }

      if (preparedDocument == null) {
        await widget.repository.removeDocument(_document.uri);
        if (!mounted) {
          return;
        }
        setState(() => _status = _ReaderStatus.notFound);
        return;
      }

      final refreshedDocument = await widget.repository.upsertOpenedDocument(
        uri: preparedDocument.uri,
        displayName: preparedDocument.displayName,
        sizeBytes: preparedDocument.sizeBytes,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        _preparedDocument = preparedDocument;
        _document = refreshedDocument;
        _currentPageNumber = refreshedDocument.lastPage + 1;
        _pageCount = refreshedDocument.pageCount;
        _status = _ReaderStatus.ready;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _status = _ReaderStatus.unreadable);
    }
  }

  void _onSearchQueryChanged() {
    final query = _searchController.text.trim();
    _textSearcher?.startTextSearch(query);
    if (mounted) {
      setState(() {});
    }
  }

  void _onSearchStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleFavorite() async {
    await widget.repository.toggleFavorite(_document.uri);
    if (!mounted) {
      return;
    }

    setState(() {
      _document = _document.copyWith(isFavorite: !_document.isFavorite);
    });
  }

  Future<void> _shareDocument() async {
    final preparedDocument = _preparedDocument;
    if (_status != _ReaderStatus.ready ||
        preparedDocument == null ||
        _isSharingDocument) {
      return;
    }

    setState(() => _isSharingDocument = true);

    try {
      await widget.documentBridge.sharePdfDocument(
        uri: preparedDocument.uri,
        localPath: preparedDocument.localPath,
        displayName: preparedDocument.displayName,
      );
    } on PlatformException {
      _showMessage(AppStrings.shareFailed);
    } catch (_) {
      _showMessage(AppStrings.shareFailed);
    } finally {
      if (mounted) {
        setState(() => _isSharingDocument = false);
      }
    }
  }

  Future<void> _openEditor() async {
    final preparedDocument = _preparedDocument;
    if (_status != _ReaderStatus.ready ||
        preparedDocument == null ||
        _isOpeningEditor) {
      return;
    }

    setState(() => _isOpeningEditor = true);
    try {
      final result = await Navigator.of(context).push<PdfEditorResult>(
        MaterialPageRoute<PdfEditorResult>(
          builder: (context) {
            return PdfEditorScreen(
              repository: widget.repository,
              documentBridge: widget.documentBridge,
              savedDocument: _document,
              preparedDocument: preparedDocument,
            );
          },
        ),
      );
      if (!mounted || result == null) {
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (context) {
            return ReaderScreen(
              repository: widget.repository,
              documentBridge: widget.documentBridge,
              savedDocument: result.savedDocument,
              preparedDocument: result.preparedDocument,
            );
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isOpeningEditor = false);
      }
    }
  }

  Future<void> _onViewerReady(PdfDocument document) async {
    final pageCount = document.pages.length;
    _ensureTextSearcherInitialized();
    await widget.repository.saveReadingProgress(
      uri: _document.uri,
      lastPage: (_currentPageNumber ?? _document.lastPage + 1) - 1,
      pageCount: pageCount,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _pageCount = pageCount;
      _viewerReady = true;
      _document = _document.copyWith(pageCount: pageCount);
    });
  }

  Future<void> _onPageChanged(int? pageNumber) async {
    if (pageNumber == null) {
      return;
    }

    await widget.repository.saveReadingProgress(
      uri: _document.uri,
      lastPage: pageNumber - 1,
      pageCount: _pageCount,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _currentPageNumber = pageNumber;
      _document = _document.copyWith(lastPage: pageNumber - 1);
    });
  }

  void _toggleSearch() {
    if (!_viewerReady || _textSearcher == null) {
      return;
    }

    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchController.clear();
        _textSearcher?.resetTextSearch();
      }
    });
  }

  Future<void> _goToPreviousMatch() async {
    await _textSearcher?.goToPrevMatch();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _goToNextMatch() async {
    await _textSearcher?.goToNextMatch();
    if (mounted) {
      setState(() {});
    }
  }

  void _ensureTextSearcherInitialized() {
    if (_textSearcher != null) {
      return;
    }

    final textSearcher = PdfTextSearcher(_viewerController);
    _disposeSearchListener = textSearcher.addListener(_onSearchStateChanged);
    _textSearcher = textSearcher;

    final query = _searchController.text.trim();
    if (query.isNotEmpty) {
      textSearcher.startTextSearch(query, searchImmediately: true);
    }
  }

  double _getSafeRenderingScale(PdfPage page, double estimatedScale) {
    final maxScaleForWidth = _maxRenderedPagePixels / page.width;
    final maxScaleForHeight = _maxRenderedPagePixels / page.height;
    return math.min(
      estimatedScale,
      math.min(maxScaleForWidth, maxScaleForHeight),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final preparedDocument = _preparedDocument;
    final title = _document.displayName.isEmpty
        ? AppStrings.unknownDocument
        : _document.displayName;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (_pageCount != null && _currentPageNumber != null)
              Text(
                '${_currentPageNumber!} / ${_pageCount!}',
                style: Theme.of(context).textTheme.labelMedium,
              ),
          ],
        ),
        actions: <Widget>[
          if (_status == _ReaderStatus.ready && preparedDocument != null)
            IconButton(
              onPressed: _isOpeningEditor ? null : _openEditor,
              tooltip: 'Modifier le PDF',
              icon: const Icon(Icons.edit_rounded),
            ),
          if (_status == _ReaderStatus.ready && preparedDocument != null)
            IconButton(
              onPressed: _isSharingDocument ? null : _shareDocument,
              tooltip: AppStrings.sharePdf,
              icon: const Icon(Icons.share_rounded),
            ),
          if (_status == _ReaderStatus.ready && _viewerReady)
            IconButton(
              onPressed: _toggleSearch,
              icon: Icon(
                _showSearch ? Icons.search_off_rounded : Icons.search_rounded,
              ),
            ),
          IconButton(
            onPressed: _toggleFavorite,
            tooltip: _document.isFavorite
                ? AppStrings.removeFavorite
                : AppStrings.addFavorite,
            icon: Icon(
              _document.isFavorite
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
            ),
          ),
        ],
        bottom: _showSearch && _status == _ReaderStatus.ready && _viewerReady
            ? PreferredSize(
                preferredSize: const Size.fromHeight(106),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: <Widget>[
                      TextField(
                        controller: _searchController,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: AppStrings.searchHint,
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    _searchController.clear();
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              _buildSearchStatusLabel(),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            onPressed: (_textSearcher?.matches.isEmpty ?? true)
                                ? null
                                : _goToPreviousMatch,
                            icon: const Icon(Icons.keyboard_arrow_up_rounded),
                          ),
                          IconButton(
                            onPressed: (_textSearcher?.matches.isEmpty ?? true)
                                ? null
                                : _goToNextMatch,
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: switch (_status) {
        _ReaderStatus.loading => const _ReaderLoadingView(),
        _ReaderStatus.notFound => _ReaderStatusView(
          title: AppStrings.documentNotFoundTitle,
          body: AppStrings.documentNotFoundBody,
          primaryLabel: AppStrings.backToLibrary,
          onPrimaryPressed: () => Navigator.of(context).pop(),
        ),
        _ReaderStatus.unreadable => _ReaderStatusView(
          title: AppStrings.unreadableTitle,
          body: AppStrings.unreadableBody,
          primaryLabel: AppStrings.retry,
          onPrimaryPressed: _prepareDocument,
          secondaryLabel: AppStrings.backToLibrary,
          onSecondaryPressed: () => Navigator.of(context).pop(),
        ),
        _ReaderStatus.ready when preparedDocument != null => Column(
          children: <Widget>[
            if ((preparedDocument.sizeBytes ?? 0) > _largeFileThreshold)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.warning_amber_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            AppStrings.largeFileWarning,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  PdfViewer.file(
                    preparedDocument.localPath,
                    controller: _viewerController,
                    initialPageNumber: _document.lastPage + 1,
                    params: PdfViewerParams(
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      maxScale: _maxViewerScale,
                      onePassRenderingScaleThreshold:
                          _onePassRenderingScaleThreshold,
                      onePassRenderingSizeThreshold:
                          _onePassRenderingSizeThreshold,
                      maxImageBytesCachedOnMemory: _maxImageBytesCachedOnMemory,
                      limitRenderingCache: false,
                      getPageRenderingScale:
                          (context, page, controller, estimatedScale) {
                            return _getSafeRenderingScale(page, estimatedScale);
                          },
                      onInteractionEnd: (_) {
                        if (_viewerController.isReady) {
                          _viewerController.invalidate();
                        }
                      },
                      pagePaintCallbacks: <PdfViewerPagePaintCallback>[
                        (canvas, pageRect, page) {
                          _textSearcher?.pageTextMatchPaintCallback(
                            canvas,
                            pageRect,
                            page,
                          );
                        },
                      ],
                      onViewerReady: (document, controller) {
                        _onViewerReady(document);
                      },
                      onPageChanged: _onPageChanged,
                      onDocumentLoadFinished: (documentRef, loadSucceeded) {
                        if (!loadSucceeded && mounted) {
                          setState(() => _status = _ReaderStatus.unreadable);
                        }
                      },
                      loadingBannerBuilder:
                          (context, bytesDownloaded, totalBytes) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          },
                      errorBannerBuilder:
                          (context, error, stackTrace, documentRef) {
                            return const SizedBox.shrink();
                          },
                      viewerOverlayBuilder: (context, size, handleLinkTap) {
                        return <Widget>[
                          PdfViewerScrollThumb(
                            controller: _viewerController,
                            orientation: ScrollbarOrientation.right,
                          ),
                        ];
                      },
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: IgnorePointer(
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.68),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Text(
                              _pageCount != null && _currentPageNumber != null
                                  ? '${_currentPageNumber!} / ${_pageCount!}'
                                  : AppStrings.readerLoading,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }

  String _buildSearchStatusLabel() {
    final textSearcher = _textSearcher;
    if (_searchController.text.trim().isEmpty) {
      return AppStrings.searchHint;
    }
    if (textSearcher == null) {
      return AppStrings.readerLoading;
    }
    if (textSearcher.isSearching) {
      return AppStrings.searchProgress;
    }
    if (textSearcher.matches.isEmpty) {
      return AppStrings.searchNoResult;
    }
    final current = (textSearcher.currentIndex ?? 0) + 1;
    final total = textSearcher.matches.length;
    return AppStrings.searchResults(current, total);
  }
}

class _ReaderLoadingView extends StatelessWidget {
  const _ReaderLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 14),
          Text(AppStrings.readerLoading),
        ],
      ),
    );
  }
}

class _ReaderStatusView extends StatelessWidget {
  const _ReaderStatusView({
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimaryPressed,
    this.secondaryLabel,
    this.onSecondaryPressed,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final FutureOr<void> Function()? onPrimaryPressed;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: onPrimaryPressed == null
                      ? null
                      : () async => onPrimaryPressed!.call(),
                  child: Text(primaryLabel),
                ),
                if (secondaryLabel != null &&
                    onSecondaryPressed != null) ...<Widget>[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: onSecondaryPressed,
                    child: Text(secondaryLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
