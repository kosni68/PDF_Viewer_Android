import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_strings.dart';
import '../../data/document_repository.dart';
import '../../data/saved_document.dart';
import '../../platform/document_bridge.dart';
import '../reader/reader_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.documentBridge,
  });

  final DocumentRepository repository;
  final DocumentBridge documentBridge;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SavedDocument> _documents = const <SavedDocument>[];
  bool _isLoading = true;
  bool _isOpeningDocument = false;
  bool _favoritesOnly = false;
  StreamSubscription<PreparedPdfDocument>? _openedDocumentSubscription;

  @override
  void initState() {
    super.initState();
    _openedDocumentSubscription = widget.documentBridge.openedPdfDocuments
        .listen(_openPreparedDocument);
    _loadDocuments();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingOpenedDocument();
    });
  }

  @override
  void dispose() {
    _openedDocumentSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadDocuments() async {
    final documents = await widget.repository.loadDocuments();
    if (!mounted) {
      return;
    }

    setState(() {
      _documents = documents;
      _isLoading = false;
    });
  }

  Future<void> _pickDocument() async {
    setState(() => _isOpeningDocument = true);
    try {
      final preparedDocument = await widget.documentBridge.pickPdfDocument();
      if (!mounted) {
        return;
      }
      if (preparedDocument == null) {
        setState(() => _isOpeningDocument = false);
        return;
      }

      await _openPreparedDocument(preparedDocument);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isOpeningDocument = false);
      _showMessage(AppStrings.pickFailed);
    }
  }

  Future<void> _openSavedDocument(SavedDocument document) async {
    setState(() => _isOpeningDocument = true);
    try {
      final preparedDocument = await widget.documentBridge.preparePdfDocument(
        document.uri,
      );
      if (!mounted) {
        return;
      }

      if (preparedDocument == null) {
        await widget.repository.removeDocument(document.uri);
        await _loadDocuments();
        if (!mounted) {
          return;
        }
        setState(() => _isOpeningDocument = false);
        _showMessage(AppStrings.unavailableDocument);
        return;
      }

      await _openPreparedDocument(preparedDocument);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isOpeningDocument = false);
      _showMessage(AppStrings.pickFailed);
    }
  }

  Future<void> _toggleFavorite(SavedDocument document) async {
    await widget.repository.toggleFavorite(document.uri);
    await _loadDocuments();
  }

  Future<void> _consumePendingOpenedDocument() async {
    final preparedDocument = await widget.documentBridge
        .consumePendingOpenedPdfDocument();
    if (!mounted || preparedDocument == null) {
      return;
    }

    await _openPreparedDocument(preparedDocument);
  }

  Future<void> _openPreparedDocument(
    PreparedPdfDocument preparedDocument,
  ) async {
    if (_isOpeningDocument) {
      return;
    }

    setState(() => _isOpeningDocument = true);
    try {
      final savedDocument = await widget.repository.upsertOpenedDocument(
        uri: preparedDocument.uri,
        displayName: preparedDocument.displayName,
        sizeBytes: preparedDocument.sizeBytes,
      );
      await _loadDocuments();
      if (!mounted) {
        return;
      }

      setState(() => _isOpeningDocument = false);
      await _openReader(
        savedDocument: savedDocument,
        preparedDocument: preparedDocument,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _isOpeningDocument = false);
      _showMessage(AppStrings.pickFailed);
    }
  }

  Future<void> _openReader({
    required SavedDocument savedDocument,
    required PreparedPdfDocument preparedDocument,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return ReaderScreen(
            repository: widget.repository,
            documentBridge: widget.documentBridge,
            savedDocument: savedDocument,
            preparedDocument: preparedDocument,
          );
        },
      ),
    );

    await _loadDocuments();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favorites = _documents
        .where((document) => document.isFavorite)
        .toList();
    final recents = _favoritesOnly
        ? _documents.where((document) => document.isFavorite).toList()
        : _documents;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              theme.colorScheme.surface,
              theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _loadDocuments,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              children: <Widget>[
                Text(
                  AppStrings.libraryTitle,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.librarySubtitle,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                _LibraryHeroCard(
                  isOpeningDocument: _isOpeningDocument,
                  onOpenPdf: _pickDocument,
                ),
                const SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    FilterChip(
                      selected: _favoritesOnly,
                      label: const Text(AppStrings.favoritesOnly),
                      onSelected: (selected) {
                        setState(() => _favoritesOnly = selected);
                      },
                    ),
                    const Spacer(),
                    if (_isLoading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                if (_isLoading && _documents.isEmpty) ...<Widget>[
                  const SizedBox(height: 40),
                  const Center(child: CircularProgressIndicator()),
                ] else if (_documents.isEmpty) ...<Widget>[
                  const SizedBox(height: 28),
                  _EmptyStateCard(onOpenPdf: _pickDocument),
                ] else ...<Widget>[
                  if (favorites.isNotEmpty && !_favoritesOnly) ...<Widget>[
                    const SizedBox(height: 20),
                    _SectionHeader(
                      title: AppStrings.favoritesSection,
                      icon: Icons.star_rounded,
                    ),
                    const SizedBox(height: 12),
                    ...favorites.map(
                      (document) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _DocumentCard(
                          document: document,
                          emphasize: true,
                          onOpen: () => _openSavedDocument(document),
                          onToggleFavorite: () => _toggleFavorite(document),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _SectionHeader(
                    title: AppStrings.recentsSection,
                    icon: Icons.history_rounded,
                  ),
                  const SizedBox(height: 12),
                  ...recents.map(
                    (document) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DocumentCard(
                        document: document,
                        onOpen: () => _openSavedDocument(document),
                        onToggleFavorite: () => _toggleFavorite(document),
                      ),
                    ),
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

class _LibraryHeroCard extends StatelessWidget {
  const _LibraryHeroCard({
    required this.isOpeningDocument,
    required this.onOpenPdf,
  });

  final bool isOpeningDocument;
  final VoidCallback onOpenPdf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              theme.colorScheme.primary,
              theme.colorScheme.primaryContainer,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                Icons.auto_stories_rounded,
                color: theme.colorScheme.onPrimary,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.openPdf,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.librarySubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.84),
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: isOpeningDocument ? null : onOpenPdf,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.secondary,
                foregroundColor: theme.colorScheme.onSecondary,
              ),
              icon: isOpeningDocument
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.folder_open_rounded),
              label: Text(
                isOpeningDocument
                    ? AppStrings.readerLoading
                    : AppStrings.openPdf,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({required this.onOpenPdf});

  final VoidCallback onOpenPdf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              AppStrings.emptyTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppStrings.emptyBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton.icon(
              onPressed: onOpenPdf,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text(AppStrings.openPdf),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Icon(icon, color: theme.colorScheme.secondary),
        const SizedBox(width: 10),
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.document,
    required this.onOpen,
    required this.onToggleFavorite,
    this.emphasize = false,
  });

  final SavedDocument document;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final openedDate = localizations.formatShortDate(document.lastOpenedAt);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: emphasize
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.picture_as_pdf_rounded,
                  color: emphasize
                      ? theme.colorScheme.onSecondaryContainer
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      document.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      AppStrings.lastOpened(openedDate),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppStrings.lastPage(document.lastPage + 1),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (document.pageCount != null) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.pageCount(document.pageCount!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                onPressed: onToggleFavorite,
                icon: Icon(
                  document.isFavorite
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                ),
                color: document.isFavorite
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.onSurfaceVariant,
                tooltip: document.isFavorite
                    ? AppStrings.removeFavorite
                    : AppStrings.addFavorite,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
