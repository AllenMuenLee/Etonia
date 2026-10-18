package com.etonia.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Receives PDFs shared into Etonia from another app's share sheet or "Open
 * with" menu and forwards their name and bytes to Dart.
 *
 * URIs granted by a share intent may only be readable while the intent is
 * being handled, so bytes are read immediately and queued until the Flutter
 * library screen asks for initial documents, after which new arrivals are
 * pushed directly over the channel.
 */
class SharedDocumentChannel(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "com.etonia.app/shared_documents"
        private const val CONSUMED_EXTRA = "com.etonia.app.SHARED_DOCUMENT_CONSUMED"
    }

    private val channel = MethodChannel(messenger, NAME)
    private val pending = mutableListOf<Map<String, Any>>()
    private var dartReady = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takeInitialDocuments" -> {
                dartReady = true
                val drained = ArrayList(pending)
                pending.clear()
                result.success(drained)
            }
            else -> result.notImplemented()
        }
    }

    fun handleIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(CONSUMED_EXTRA, false)) {
            return
        }
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(streamUri(intent))
            Intent.ACTION_SEND_MULTIPLE -> streamUris(intent)
            Intent.ACTION_VIEW -> {
                val uri = intent.data ?: clipUri(intent)
                if (uri != null && (uri.scheme == "content" || uri.scheme == "file")) {
                    listOf(uri)
                } else {
                    emptyList()
                }
            }
            else -> emptyList()
        }
        if (uris.isEmpty()) return
        intent.putExtra(CONSUMED_EXTRA, true)

        for (uri in uris) {
            val payload = readDocument(uri) ?: continue
            if (dartReady) {
                channel.invokeMethod("onDocumentShared", payload)
            } else {
                pending.add(payload)
            }
        }
    }

    private fun readDocument(uri: Uri): Map<String, Any>? {
        val bytes = try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (_: Throwable) {
            null
        } ?: return null
        if (bytes.isEmpty()) return null
        return mapOf(
            "name" to resolveDisplayName(uri),
            "bytes" to bytes,
        )
    }

    private fun resolveDisplayName(uri: Uri): String {
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0 && cursor.moveToFirst()) {
                        val name = cursor.getString(index)?.trim()
                        if (!name.isNullOrEmpty()) return name
                    }
                }
            } catch (_: Throwable) {
                // Fall back to the URI path segment below.
            }
        }
        val segment = uri.lastPathSegment?.substringAfterLast('/')?.trim()
        return if (!segment.isNullOrEmpty()) segment else "Shared.pdf"
    }

    private fun streamUri(intent: Intent): Uri? {
        val extra = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }
        return extra ?: clipUri(intent)
    }

    private fun streamUris(intent: Intent): List<Uri> {
        val extras = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
        if (!extras.isNullOrEmpty()) return extras
        val clip = intent.clipData ?: return emptyList()
        return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it)?.uri }
    }

    private fun clipUri(intent: Intent): Uri? {
        val clip = intent.clipData ?: return null
        return if (clip.itemCount > 0) clip.getItemAt(0)?.uri else null
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
