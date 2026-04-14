import 'dart:convert';

class SavedDocument {
  const SavedDocument({
    required this.uri,
    required this.displayName,
    required this.lastOpenedAt,
    required this.lastPage,
    required this.isFavorite,
    this.pageCount,
    this.sizeBytes,
  });

  final String uri;
  final String displayName;
  final DateTime lastOpenedAt;
  final int lastPage;
  final bool isFavorite;
  final int? pageCount;
  final int? sizeBytes;

  SavedDocument copyWith({
    String? uri,
    String? displayName,
    DateTime? lastOpenedAt,
    int? lastPage,
    bool? isFavorite,
    int? pageCount,
    int? sizeBytes,
  }) {
    return SavedDocument(
      uri: uri ?? this.uri,
      displayName: displayName ?? this.displayName,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      lastPage: lastPage ?? this.lastPage,
      isFavorite: isFavorite ?? this.isFavorite,
      pageCount: pageCount ?? this.pageCount,
      sizeBytes: sizeBytes ?? this.sizeBytes,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'uri': uri,
      'displayName': displayName,
      'lastOpenedAtMillis': lastOpenedAt.millisecondsSinceEpoch,
      'lastPage': lastPage,
      'isFavorite': isFavorite,
      'pageCount': pageCount,
      'sizeBytes': sizeBytes,
    };
  }

  factory SavedDocument.fromJson(Map<String, dynamic> json) {
    return SavedDocument(
      uri: json['uri'] as String,
      displayName: json['displayName'] as String,
      lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(
        json['lastOpenedAtMillis'] as int,
      ),
      lastPage: json['lastPage'] as int? ?? 0,
      isFavorite: json['isFavorite'] as bool? ?? false,
      pageCount: json['pageCount'] as int?,
      sizeBytes: json['sizeBytes'] as int?,
    );
  }

  static String encodeList(List<SavedDocument> documents) {
    return jsonEncode(
      documents.map((document) => document.toJson()).toList(growable: false),
    );
  }

  static List<SavedDocument> decodeList(String raw) {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .cast<Map<String, dynamic>>()
        .map(SavedDocument.fromJson)
        .toList(growable: false);
  }
}
