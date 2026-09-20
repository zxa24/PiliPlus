package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // LibrePili: index files written to shared storage (e.g. finished
        // downloads in Download/LibrePili) so galleries / players list them.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "librepili/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARG", "path is required", null)
                        } else {
                            MediaScannerConnection.scanFile(
                                applicationContext,
                                arrayOf(path),
                                arrayOf(call.argument<String>("mimeType") ?: "video/mp4"),
                            ) { _, uri -> runOnUiThread { result.success(uri?.toString()) } }
                        }
                    }
                    // Local player: files / folders the user grants through the
                    // system picker (Storage Access Framework). No storage
                    // permission, and the video is never copied.
                    "pickVideoFile" -> pick(result, REQUEST_PICK_FILE) {
                        // some providers label MKV / FLV as untyped: offer those
                        // too, Dart rejects what is not a video
                        Intent(Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("*/*")
                            .putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf(
                                    "video/*",
                                    "video/x-matroska",
                                    "video/x-flv",
                                    "application/octet-stream",
                                ),
                            )
                    }
                    "pickVideoFolder" -> pick(result, REQUEST_PICK_FOLDER) {
                        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    }
                    "listTree" -> {
                        val uri = call.argument<String>("uri")
                        val docId = call.argument<String>("docId")
                        if (uri == null) {
                            result.error("ARG", "uri is required", null)
                        } else {
                            background(result) { listChildren(Uri.parse(uri), docId) }
                        }
                    }
                    "copyDocuments" -> {
                        val items = call.argument<List<Map<String, String>>>("items")
                        if (items == null) {
                            result.error("ARG", "items is required", null)
                        } else {
                            background(result) { copyDocuments(items) }
                        }
                    }
                    "openFd" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("ARG", "uri is required", null)
                        } else {
                            background(result) {
                                contentResolver.openFileDescriptor(Uri.parse(uri), "r")
                                    ?.detachFd() ?: -1
                            }
                        }
                    }
                    "closeFd" -> {
                        val fd = call.argument<Int>("fd")
                        if (fd == null) {
                            result.error("ARG", "fd is required", null)
                        } else {
                            // a descriptor from openFd the player did not take
                            try {
                                ParcelFileDescriptor.adoptFd(fd).close()
                            } catch (_: Exception) {
                            }
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pick(result: MethodChannel.Result, requestCode: Int, intent: () -> Intent) {
        if (pendingPick != null) {
            result.error("BUSY", "a picker is already open", null)
            return
        }
        pendingPick = result
        try {
            startActivityForResult(
                intent().addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                requestCode,
            )
        } catch (e: Exception) {
            pendingPick = null
            result.error("PICKER", e.message, null)
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io().execute {
            try {
                val value = work()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("IO", e.message, null) }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_FILE && requestCode != REQUEST_PICK_FOLDER) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick ?: return
        pendingPick = null
        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return
        }
        // the grant is not persisted: nothing reopens a document later (the
        // URI is not saved), and the session grant covers playing it now
        background(result) {
            if (requestCode == REQUEST_PICK_FOLDER) {
                mapOf("uri" to uri.toString(), "children" to listChildren(uri, null))
            } else {
                describe(uri)
            }
        }
    }

    /** Stable identity of a document (the same file picked again). */
    private fun keyOf(uri: Uri): String = try {
        "${uri.authority}/${DocumentsContract.getDocumentId(uri)}"
    } catch (_: Exception) {
        uri.toString()
    }

    private fun describe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size = 0L
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0)
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        return mapOf(
            "name" to (name ?: uri.lastPathSegment ?: "video"),
            "uri" to uri.toString(),
            "size" to size,
            "key" to keyOf(uri),
            "mime" to contentResolver.getType(uri),
        )
    }

    /** Children of [docId] (null: the granted folder itself) in [treeUri]. */
    private fun listChildren(treeUri: Uri, docId: String?): List<Map<String, Any?>> {
        val parent = docId ?: DocumentsContract.getTreeDocumentId(treeUri)
        val out = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parent),
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
            ),
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                out.add(
                    mapOf(
                        "name" to c.getString(1),
                        "uri" to uri.toString(),
                        "isDir" to (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                        "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
                        "docId" to id,
                        "key" to "${uri.authority}/$id",
                    ),
                )
            }
        }
        return out
    }

    /** Copies small side files (danmaku, subtitles, comments, cover, images). */
    private fun copyDocuments(items: List<Map<String, String>>): Int {
        var copied = 0
        for (item in items) {
            val from = item["uri"] ?: continue
            val to = item["path"] ?: continue
            // written beside and renamed once complete: a copy that fails
            // part-way never leaves a truncated danmaku / comments file
            val file = File(to)
            val part = File("$to.part")
            try {
                file.parentFile?.mkdirs()
                contentResolver.openInputStream(Uri.parse(from))?.use { input ->
                    part.outputStream().use { input.copyTo(it) }
                    // replace, never delete first: a rename that fails must
                    // not lose the old copy as well as the new one
                    if (part.renameTo(file)) {
                        copied++
                    } else {
                        val old = File("$to.old")
                        old.delete()
                        if (!file.exists() || file.renameTo(old)) {
                            if (part.renameTo(file)) {
                                copied++
                                old.delete()
                            } else if (old.exists()) {
                                old.renameTo(file)
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // best-effort: a missing side file only loses that extra
            } finally {
                part.delete()
            }
        }
        return copied
    }

    companion object {
        private const val REQUEST_PICK_FILE = 0x4c50
        private const val REQUEST_PICK_FOLDER = 0x4c51

        // The FlutterEngine is cached across activity instances (audio
        // service): a picker result may arrive in a recreated activity, so
        // the pending call and the I/O thread live here, not per instance.
        private var pendingPick: MethodChannel.Result? = null
        private var executor: ExecutorService? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        private fun io(): ExecutorService =
            executor?.takeIf { !it.isShutdown }
                ?: Executors.newSingleThreadExecutor().also { executor = it }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        if (isFinishing) {
            // gone for good (not recreated): no picker result will come
            pendingPick?.success(null)
            pendingPick = null
            executor?.shutdown()
            executor = null
        }
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
