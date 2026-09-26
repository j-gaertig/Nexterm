package dev.gnm.nexterm

import android.app.DownloadManager
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexterm/downloads"
        ).setMethodCallHandler { call, result ->
            if (call.method == "showSavedDocument") {
                try {
                    val value = call.argument<String>("value").orEmpty()
                    openSavedLocation(value)
                } catch (e: Exception) {
                }
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun openSavedLocation(value: String) {
        if (tryOpenParent(value)) return
        openDownloads()
    }

    private fun tryOpenParent(value: String): Boolean {
        val docId = extractDocumentId(value) ?: return false
        val slash = docId.lastIndexOf('/')
        if (slash <= 0) return false
        val parentId = docId.substring(0, slash)
        val authorities = arrayOf(
            "com.android.externalstorage.documents",
            "com.android.providers.downloads.documents"
        )
        for (authority in authorities) {
            try {
                val parentUri = DocumentsContract.buildDocumentUri(authority, parentId)
                val view = Intent(Intent.ACTION_VIEW)
                view.setDataAndType(parentUri, DocumentsContract.Document.MIME_TYPE_DIR)
                view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(view)
                return true
            } catch (e: Exception) {
                continue
            }
        }
        return false
    }

    private fun extractDocumentId(value: String): String? {
        try {
            if (value.isEmpty()) return null
            if (value.startsWith("content:")) {
                try {
                    val uri = Uri.parse(value)
                    if (DocumentsContract.isDocumentUri(this, uri)) {
                        return DocumentsContract.getDocumentId(uri)
                    }
                } catch (e: Exception) {
                }
                val path = Uri.parse(value).path.orEmpty()
                val marker = "/document/"
                val index = path.indexOf(marker)
                if (index >= 0) return path.substring(index + marker.length)
                return null
            }
            val marker = "/document/"
            val index = value.indexOf(marker)
            if (index >= 0) return value.substring(index + marker.length)
            val treeMarker = "/tree/"
            val treeIndex = value.indexOf(treeMarker)
            if (treeIndex >= 0) return value.substring(treeIndex + treeMarker.length)
            return null
        } catch (e: Exception) {
            return null
        }
    }

    private fun openDownloads() {
        try {
            val view = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS)
            view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(view)
        } catch (e: Exception) {
        }
    }
}
