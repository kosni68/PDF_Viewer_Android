import 'dart:async';

import 'package:flutter/services.dart';

class PreparedPdfDocument {
  const PreparedPdfDocument({
    required this.uri,
    required this.displayName,
    required this.localPath,
    this.sizeBytes,
  });

  final String uri;
  final String displayName;
  final String localPath;
  final int? sizeBytes;

  factory PreparedPdfDocument.fromMap(Map<dynamic, dynamic> map) {
    return PreparedPdfDocument(
      uri: map['uri'] as String,
      displayName: map['displayName'] as String,
      localPath: map['localPath'] as String,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt(),
    );
  }
}

abstract interface class DocumentBridge {
  Future<PreparedPdfDocument?> pickPdfDocument();
  Future<PreparedPdfDocument?> preparePdfDocument(String uri);
  Future<PreparedPdfDocument?> consumePendingOpenedPdfDocument();
  Stream<PreparedPdfDocument> get openedPdfDocuments;
  Future<void> sharePdfDocument({
    required String uri,
    required String localPath,
    required String displayName,
  });
}

class MethodChannelDocumentBridge implements DocumentBridge {
  MethodChannelDocumentBridge([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const _channelName = 'com.dnrfag.pdfreader/documents';

  final MethodChannel _channel;
  final StreamController<PreparedPdfDocument> _openedPdfDocumentsController =
      StreamController<PreparedPdfDocument>.broadcast();

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'openPdfDocument') {
      return;
    }

    final arguments = call.arguments;
    if (arguments is! Map<dynamic, dynamic>) {
      return;
    }

    _openedPdfDocumentsController.add(PreparedPdfDocument.fromMap(arguments));
  }

  @override
  Future<PreparedPdfDocument?> pickPdfDocument() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'pickPdfDocument',
    );
    if (result == null) {
      return null;
    }
    return PreparedPdfDocument.fromMap(result);
  }

  @override
  Future<PreparedPdfDocument?> preparePdfDocument(String uri) async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'preparePdfDocument',
      <String, Object?>{'uri': uri},
    );
    if (result == null) {
      return null;
    }
    return PreparedPdfDocument.fromMap(result);
  }

  @override
  Future<PreparedPdfDocument?> consumePendingOpenedPdfDocument() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'consumePendingOpenedPdfDocument',
    );
    if (result == null) {
      return null;
    }
    return PreparedPdfDocument.fromMap(result);
  }

  @override
  Stream<PreparedPdfDocument> get openedPdfDocuments =>
      _openedPdfDocumentsController.stream;

  @override
  Future<void> sharePdfDocument({
    required String uri,
    required String localPath,
    required String displayName,
  }) {
    return _channel.invokeMethod<void>('sharePdfDocument', <String, Object?>{
      'uri': uri,
      'localPath': localPath,
      'displayName': displayName,
    });
  }
}
