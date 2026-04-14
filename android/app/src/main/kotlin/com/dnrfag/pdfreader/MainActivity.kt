package com.dnrfag.pdfreader

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.FileNotFoundException
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var pendingPickerResult: MethodChannel.Result? = null
    private var documentChannel: MethodChannel? = null
    private var pendingOpenedDocumentPayload: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel =
            MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        documentChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickPdfDocument" -> handlePickPdfDocument(result)
                "consumePendingOpenedPdfDocument" -> {
                    val payload = pendingOpenedDocumentPayload
                    pendingOpenedDocumentPayload = null
                    result.success(payload)
                }

                "preparePdfDocument" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString.isNullOrBlank()) {
                        result.error("invalid_argument", "L'URI du document est manquant.", null)
                        return@setMethodCallHandler
                    }
                    respondWithPreparedDocument(Uri.parse(uriString), result)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun handleIncomingIntent(intent: Intent?) {
        val payload = resolveOpenedDocumentPayload(intent) ?: return
        pendingOpenedDocumentPayload = payload
        documentChannel?.invokeMethod("openPdfDocument", payload)
    }

    private fun resolveOpenedDocumentPayload(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != Intent.ACTION_VIEW) {
            return null
        }

        val uri = intent.data ?: return null
        if (intent.type?.equals("application/pdf", ignoreCase = true) == false) {
            return null
        }

        if (intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
            runCatching {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
        }

        return runCatching {
            buildPreparedDocumentPayload(uri)
        }.getOrNull()
    }

    private fun handlePickPdfDocument(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("picker_busy", "Un sélecteur de documents est déjà ouvert.", null)
            return
        }

        pendingPickerResult = result
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/pdf"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
        startActivityForResult(intent, REQUEST_PICK_PDF)
    }

    @Deprecated("Android activity result API is not available on FlutterActivity here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_PDF) {
            return
        }

        val result = pendingPickerResult ?: return
        pendingPickerResult = null

        if (resultCode != RESULT_OK) {
            result.success(null)
            return
        }

        val uri = data?.data
        if (uri == null) {
            result.success(null)
            return
        }

        runCatching {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }.onFailure { error ->
            result.error(
                "permission_denied",
                error.message,
                null,
            )
            return
        }

        respondWithPreparedDocument(uri, result)
    }

    private fun respondWithPreparedDocument(uri: Uri, result: MethodChannel.Result) {
        runCatching {
            buildPreparedDocumentPayload(uri)
        }.onSuccess { payload ->
            result.success(payload)
        }.onFailure { error ->
            when (error) {
                is SecurityException,
                is FileNotFoundException -> result.success(null)

                else -> result.error(
                    "prepare_failed",
                    error.message,
                    null,
                )
            }
        }
    }

    private fun buildPreparedDocumentPayload(uri: Uri): Map<String, Any?>? {
        val metadata = resolveMetadata(uri) ?: return null
        val localPath = copyToLocalStorage(uri) ?: return null

        return hashMapOf(
            "uri" to uri.toString(),
            "displayName" to metadata.displayName,
            "sizeBytes" to metadata.sizeBytes,
            "localPath" to localPath,
        )
    }

    private fun resolveMetadata(uri: Uri): DocumentMetadata? {
        contentResolver.openInputStream(uri)?.use { inputStream ->
            if (inputStream.available() < 0) {
                return null
            }
        } ?: return null

        var displayName: String? = null
        var sizeBytes: Long? = null

        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) {
                    displayName = cursor.getString(nameIndex)
                }
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    sizeBytes = cursor.getLong(sizeIndex)
                }
            }
        }

        return DocumentMetadata(
            displayName = displayName?.takeIf { it.isNotBlank() } ?: "Document PDF",
            sizeBytes = sizeBytes,
        )
    }

    private fun copyToLocalStorage(uri: Uri): String? {
        val directory = File(filesDir, "pdf_documents")
        if (!directory.exists() && !directory.mkdirs()) {
            return null
        }

        val file = File(directory, "${sha256(uri.toString())}.pdf")
        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(file, false).use { output ->
                input.copyTo(output)
            }
        } ?: return null

        return file.absolutePath
    }

    private fun sha256(value: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
        return buildString(digest.size * 2) {
            digest.forEach { byte ->
                append("%02x".format(byte))
            }
        }
    }

    private data class DocumentMetadata(
        val displayName: String,
        val sizeBytes: Long?,
    )

    companion object {
        private const val CHANNEL_NAME = "com.dnrfag.pdfreader/documents"
        private const val REQUEST_PICK_PDF = 4101
    }
}
