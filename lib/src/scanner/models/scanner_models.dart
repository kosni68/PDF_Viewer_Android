import 'dart:typed_data';
import 'dart:ui';

enum ScanColorMode { color, grayscale, blackWhite }

enum ScanExportQuality { original, optimized, light }

class ScanDocumentCorners {
  const ScanDocumentCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomLeft,
    required this.bottomRight,
  });

  final Offset topLeft;
  final Offset topRight;
  final Offset bottomLeft;
  final Offset bottomRight;

  List<Offset> get ordered => <Offset>[
    topLeft,
    topRight,
    bottomLeft,
    bottomRight,
  ];

  ScanDocumentCorners copyWith({
    Offset? topLeft,
    Offset? topRight,
    Offset? bottomLeft,
    Offset? bottomRight,
  }) {
    return ScanDocumentCorners(
      topLeft: topLeft ?? this.topLeft,
      topRight: topRight ?? this.topRight,
      bottomLeft: bottomLeft ?? this.bottomLeft,
      bottomRight: bottomRight ?? this.bottomRight,
    );
  }
}

extension ScanExportQualityConfig on ScanExportQuality {
  int get maxLongEdgePx {
    return switch (this) {
      ScanExportQuality.original => 2480,
      ScanExportQuality.optimized => 1800,
      ScanExportQuality.light => 1280,
    };
  }

  int get jpegQuality {
    return switch (this) {
      ScanExportQuality.original => 92,
      ScanExportQuality.optimized => 85,
      ScanExportQuality.light => 75,
    };
  }
}

class ScannedPageDraft {
  const ScannedPageDraft({
    required this.id,
    required this.sourceName,
    required this.originalBytes,
    required this.documentCornersNormalized,
    required this.cropRectNormalized,
    required this.rotationQuarterTurns,
    required this.brightness,
    required this.contrast,
    required this.colorMode,
    required this.width,
    required this.height,
  });

  final String id;
  final String sourceName;
  final Uint8List originalBytes;
  final ScanDocumentCorners? documentCornersNormalized;
  final Rect cropRectNormalized;
  final int rotationQuarterTurns;
  final double brightness;
  final double contrast;
  final ScanColorMode colorMode;
  final int width;
  final int height;

  ScannedPageDraft copyWith({
    String? id,
    String? sourceName,
    Uint8List? originalBytes,
    ScanDocumentCorners? documentCornersNormalized,
    bool clearDocumentCorners = false,
    Rect? cropRectNormalized,
    int? rotationQuarterTurns,
    double? brightness,
    double? contrast,
    ScanColorMode? colorMode,
    int? width,
    int? height,
  }) {
    return ScannedPageDraft(
      id: id ?? this.id,
      sourceName: sourceName ?? this.sourceName,
      originalBytes: originalBytes ?? this.originalBytes,
      documentCornersNormalized: clearDocumentCorners
          ? null
          : documentCornersNormalized ?? this.documentCornersNormalized,
      cropRectNormalized: cropRectNormalized ?? this.cropRectNormalized,
      rotationQuarterTurns: rotationQuarterTurns ?? this.rotationQuarterTurns,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      colorMode: colorMode ?? this.colorMode,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }
}

class ScanDraftDocument {
  const ScanDraftDocument({
    required this.pages,
    required this.selectedPageId,
    required this.exportQuality,
  });

  static const empty = ScanDraftDocument(
    pages: <ScannedPageDraft>[],
    selectedPageId: null,
    exportQuality: ScanExportQuality.optimized,
  );

  final List<ScannedPageDraft> pages;
  final String? selectedPageId;
  final ScanExportQuality exportQuality;

  bool get hasPages => pages.isNotEmpty;

  ScannedPageDraft? get selectedPage {
    final selectedPageId = this.selectedPageId;
    if (selectedPageId == null) {
      return null;
    }
    for (final page in pages) {
      if (page.id == selectedPageId) {
        return page;
      }
    }
    return null;
  }

  ScanDraftDocument copyWith({
    List<ScannedPageDraft>? pages,
    String? selectedPageId,
    bool clearSelectedPage = false,
    ScanExportQuality? exportQuality,
  }) {
    return ScanDraftDocument(
      pages: List<ScannedPageDraft>.unmodifiable(pages ?? this.pages),
      selectedPageId: clearSelectedPage
          ? null
          : selectedPageId ?? this.selectedPageId,
      exportQuality: exportQuality ?? this.exportQuality,
    );
  }

  ScanDraftDocument addPages(List<ScannedPageDraft> newPages) {
    if (newPages.isEmpty) {
      return this;
    }
    return copyWith(
      pages: <ScannedPageDraft>[...pages, ...newPages],
      selectedPageId: newPages.last.id,
    );
  }

  ScanDraftDocument replacePage(ScannedPageDraft page) {
    final index = pages.indexWhere((candidate) => candidate.id == page.id);
    if (index < 0) {
      return this;
    }

    final updatedPages = pages.toList(growable: true);
    updatedPages[index] = page;
    return copyWith(pages: updatedPages, selectedPageId: page.id);
  }

  ScanDraftDocument removePage(String pageId) {
    final index = pages.indexWhere((page) => page.id == pageId);
    if (index < 0) {
      return this;
    }

    final updatedPages = pages.toList(growable: true)..removeAt(index);
    if (updatedPages.isEmpty) {
      return copyWith(pages: updatedPages, clearSelectedPage: true);
    }

    final nextIndex = index.clamp(0, updatedPages.length - 1);
    return copyWith(
      pages: updatedPages,
      selectedPageId: updatedPages[nextIndex].id,
    );
  }

  ScanDraftDocument reorderPages(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= pages.length ||
        newIndex < 0 ||
        newIndex >= pages.length ||
        oldIndex == newIndex) {
      return this;
    }

    final updatedPages = pages.toList(growable: true);
    final movedPage = updatedPages.removeAt(oldIndex);
    updatedPages.insert(newIndex, movedPage);
    return copyWith(pages: updatedPages);
  }
}
