import 'package:shared_preferences/shared_preferences.dart';

abstract interface class DocumentStore {
  Future<String?> readDocumentsJson();
  Future<void> writeDocumentsJson(String json);
}

class SharedPreferencesDocumentStore implements DocumentStore {
  SharedPreferencesDocumentStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _storageKey = 'saved_documents_v1';

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> readDocumentsJson() {
    return _preferences.getString(_storageKey);
  }

  @override
  Future<void> writeDocumentsJson(String json) {
    return _preferences.setString(_storageKey, json);
  }
}
