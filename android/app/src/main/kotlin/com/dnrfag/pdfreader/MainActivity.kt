package com.dnrfag.pdfreader

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.FileNotFoundException
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var pendingPickerResult: MethodChannel.Result? = null
    private var pendingSaveCopyResult: MethodChannel.Result? = null
    private var documentChannel: MethodChannel? = null
    private var pendingOpenedDocumentPayload: Map<String, Any?>? = null
    private var pendingSaveCopySourcePath: String? = null

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
                "savePdfDocumentCopy" -> {
                    val sourceLocalPath = call.argument<String>("sourceLocalPath")
                    val displayName = call.argument<String>("displayName")
                    if (sourceLocalPath.isNullOrBlank() || displayName.isNullOrBlank()) {
                        result.error("invalid_argument", "Les informations d'export sont incompletes.", null)
                        return@setMethodCallHandler
                    }
                    handleSavePdfDocumentCopy(
                        sourceLocalPath = sourceLocalPath,
                        displayName = displayName,
                        result = result,
                    )
                }
                "consumePendingOpenedPdfDocument" -> {
                    val payload = pendingOpenedDocumentPayload
                    pendingOpenedDocumentPayload = null
                    result.success(payload)
                }
                "sharePdfDocument" -> {
                    val uriString = call.argument<String>("uri")
                    val localPath = call.argument<String>("localPath")
                    val displayName = call.argument<String>("displayName")
                    if (uriString.isNullOrBlank() ||
                        localPath.isNullOrBlank() ||
                        displayName.isNullOrBlank()
                    ) {
                        result.error("invalid_argument", "Les informations de partage sont incomplètes.", null)
                        return@setMethodCallHandler
                    }

                    sharePdfDocument(
                        uri = Uri.parse(uriString),
                        localPath = localPath,
                        displayName = displayName,
                        result = result,
                    )
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

    private fun handleSavePdfDocumentCopy(
        sourceLocalPath: String,
        displayName: String,
        result: MethodChannel.Result,
    ) {
        if (pendingSaveCopyResult != null) {
            result.error("save_busy", "Une autre sauvegarde est deja en cours.", null)
            return
        }

        val sourceFile = File(sourceLocalPath).canonicalFile
        val allowedDirectory = File(filesDir, "pdf_documents").canonicalFile
        val allowedPrefix = "${allowedDirectory.path}${File.separator}"
        if (!sourceFile.exists()) {
            result.error("missing_file", "Le PDF exporte n'existe plus.", null)
            return
        }
        if (!sourceFile.path.startsWith(allowedPrefix)) {
            result.error("invalid_source", "Le PDF exporte n'est pas dans le repertoire autorise.", null)
            return
        }

        pendingSaveCopyResult = result
        pendingSaveCopySourcePath = sourceFile.path
        val intent =
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/pdf"
                putExtra(Intent.EXTRA_TITLE, displayName)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
        startActivityForResult(intent, REQUEST_CREATE_PDF)
    }

    @Deprecated("Android activity result API is not available on FlutterActivity here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_PICK_PDF -> handlePickResult(resultCode, data)
            REQUEST_CREATE_PDF -> handleSaveCopyResult(resultCode, data)
        }
    }

    private fun handlePickResult(resultCode: Int, data: Intent?) {
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

    private fun handleSaveCopyResult(resultCode: Int, data: Intent?) {
        val result = pendingSaveCopyResult ?: return
        pendingSaveCopyResult = null
        val sourceLocalPath = pendingSaveCopySourcePath
        pendingSaveCopySourcePath = null

        if (resultCode != RESULT_OK || sourceLocalPath.isNullOrBlank()) {
            result.success(null)
            return
        }

        val uri = data?.data
        if (uri == null) {
            result.success(null)
            return
        }

        runCatching {
            val intentFlags = data?.flags ?: 0
            val grantedFlags =
                (intentFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION) or
                    (intentFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (grantedFlags != 0) {
                contentResolver.takePersistableUriPermission(uri, grantedFlags)
            }
            copyLocalPdfToUri(sourceLocalPath, uri)
            buildPreparedDocumentPayload(uri)
        }.onSuccess { payload ->
            result.success(payload)
        }.onFailure { error ->
            result.error(
                "save_failed",
                error.message ?: "Impossible d'enregistrer la copie du PDF.",
                null,
            )
        }
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

    private fun sharePdfDocument(
        uri: Uri,
        localPath: String,
        displayName: String,
        result: MethodChannel.Result,
    ) {
        runCatching {
            val shareUri = resolveShareUri(uri, localPath)
            val shareIntent =
                Intent(Intent.ACTION_SEND).apply {
                    type = "application/pdf"
                    putExtra(Intent.EXTRA_STREAM, shareUri)
                    clipData = ClipData.newUri(contentResolver, displayName, shareUri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            val chooser =
                Intent.createChooser(shareIntent, "Partager le PDF").apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            startActivity(chooser)
        }.onSuccess {
            result.success(null)
        }.onFailure { error ->
            when (error) {
                is ActivityNotFoundException,
                is FileNotFoundException,
                is SecurityException,
                is IllegalArgumentException -> result.error(
                    "share_failed",
                    error.message ?: "Impossible de partager le document.",
                    null,
                )

                else -> result.error(
                    "share_failed",
                    error.message,
                    null,
                )
            }
        }
    }

    private fun resolveShareUri(uri: Uri, localPath: String): Uri {
        resolveShareableSourceUri(uri)?.let { shareableUri ->
            return shareableUri
        }
        return buildLocalShareUri(localPath)
    }

    private fun resolveShareableSourceUri(uri: Uri): Uri? {
        if (uri.scheme != "content") {
            return null
        }

        val canRead =
            runCatching {
                contentResolver.openInputStream(uri)?.use { true } == true
            }.getOrDefault(false)

        return if (canRead) uri else null
    }

    private fun buildLocalShareUri(localPath: String): Uri {
        val allowedDirectory = File(filesDir, "pdf_documents").canonicalFile
        val file = File(localPath).canonicalFile
        val allowedPrefix = "${allowedDirectory.path}${File.separator}"

        if (!file.exists()) {
            throw FileNotFoundException("Le fichier PDF local n'existe plus.")
        }
        if (!file.path.startsWith(allowedPrefix)) {
            throw SecurityException("Le fichier a partager n'est pas dans le repertoire autorise.")
        }

        return FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file,
        )
    }

    private fun copyLocalPdfToUri(sourceLocalPath: String, destinationUri: Uri) {
        val sourceFile = File(sourceLocalPath).canonicalFile
        if (!sourceFile.exists()) {
            throw FileNotFoundException("Le fichier PDF exporte n'existe plus.")
        }

        contentResolver.openOutputStream(destinationUri, "w")?.use { output ->
            sourceFile.inputStream().use { input ->
                input.copyTo(output)
            }
        } ?: throw FileNotFoundException("Impossible d'ouvrir la destination PDF.")
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
        private const val REQUEST_CREATE_PDF = 4102
    }
}
