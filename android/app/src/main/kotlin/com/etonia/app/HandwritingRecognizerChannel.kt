package com.greatnote.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reads handwriting written on the page in AI mode with Google's on-device
 * ML Kit text recognition.
 *
 * Dart sends an offscreen PNG of Greatnote's own strokes, dark on white. The
 * bitmap is decoded here, read, and recycled at once; nothing is kept. No
 * system text input or stylus handwriting is started, so Android never draws
 * strokes of its own over the page.
 *
 * Every failure, a missing model or an unavailable service included, answers
 * with an empty string rather than an error: there were simply no words.
 */
class HandwritingRecognizerChannel(messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "com.greatnote.app/handwriting_recognizer"
    }

    private val channel = MethodChannel(messenger, NAME)
    private var recognizer: TextRecognizer? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "recognize") {
            result.notImplemented()
            return
        }
        val png = call.argument<ByteArray>("png")
        val bitmap: Bitmap? = try {
            png?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        } catch (error: Throwable) {
            null
        }
        if (bitmap == null) {
            result.success("")
            return
        }
        try {
            val client = recognizer
                ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                    .also { recognizer = it }
            client.process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener { text ->
                    bitmap.recycle()
                    result.success(readingOrder(text))
                }
                .addOnFailureListener {
                    bitmap.recycle()
                    result.success("")
                }
        } catch (error: Throwable) {
            bitmap.recycle()
            result.success("")
        }
    }

    /** The lines of [text], top to bottom and, along a line, left to right. */
    private fun readingOrder(text: Text): String {
        val lines = text.textBlocks.flatMap { it.lines }.filter { it.boundingBox != null }
        val sorted = lines.sortedWith { a, b ->
            val boxA = a.boundingBox!!
            val boxB = b.boundingBox!!
            val sameRow = Math.abs(boxA.centerY() - boxB.centerY()) <
                minOf(boxA.height(), boxB.height()) / 2
            if (sameRow) boxA.left.compareTo(boxB.left) else boxA.top.compareTo(boxB.top)
        }
        return sorted.joinToString(" ") { it.text.trim() }.trim()
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        recognizer?.close()
        recognizer = null
    }
}
