package com.example.piliplus

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// LibrePili: a downloaded update's APK handed to the system installer
// (lib/utils/update/update_apply.dart; user 2026-10-20: updates applied on
// the next launch). The installer always asks the user; nothing installs
// silently. No plugin in pubspec opens an installer for a file: hence this.

/**
 * The app's own FileProvider for the staged update (res/xml/update_paths.xml).
 * A subclass, so its manifest entry cannot clash with a plugin's
 * androidx FileProvider.
 */
class UpdateFileProvider : FileProvider()

object UpdateInstaller {
    private const val CHANNEL = "librepili/update"

    fun attach(context: Context, flutterEngine: FlutterEngine) {
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "packageName" -> result.success(appContext.packageName)
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        result.success(if (path == null) "no path" else install(appContext, File(path)))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Null when the installer was opened; why not otherwise. */
    private fun install(context: Context, apk: File): String? {
        if (!apk.isFile) return "no file"
        return try {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.update_provider", apk)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            null
        } catch (e: IllegalArgumentException) {
            // the file is outside the provider's folder
            "not shareable: ${e.message}"
        } catch (e: ActivityNotFoundException) {
            "no installer"
        }
    }
}
