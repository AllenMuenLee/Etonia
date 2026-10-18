package com.etonia.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.digitalink.DigitalInkRecognition
import com.google.mlkit.vision.digitalink.DigitalInkRecognitionModel
import com.google.mlkit.vision.digitalink.DigitalInkRecognitionModelIdentifier
import com.google.mlkit.vision.digitalink.DigitalInkRecognizer
import com.google.mlkit.vision.digitalink.DigitalInkRecognizerOptions
import com.google.mlkit.vision.digitalink.Ink
import com.google.mlkit.vision.digitalink.RecognitionContext
import com.google.mlkit.vision.digitalink.WritingArea
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Reads handwriting written on the page in AI mode with Google's on-device
 * ML Kit.
 *
 * Dart sends Etonia's own strokes, each point with its time, and an
 * offscreen PNG of them, dark on white. The strokes go to Digital Ink
 * Recognition, which reads handwriting from how it was written and is far
 * better at it than reading a picture. Its model for the device's language
 * is downloaded once, in the background, the first time it is needed; until
 * it is there, or for a language it has no model for, the picture is read
 * with text recognition instead. Nothing is kept. No system text input or
 * stylus handwriting is started, so Android never draws strokes of its own
 * over the page.
 *
 * Every failure, a missing model or an unavailable service included, answers
 * with an empty string rather than an error: there were simply no words.
 */
class HandwritingRecognizerChannel(messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "com.etonia.app/handwriting_recognizer"
        private const val FALLBACK_LANGUAGE = "en-US"
    }

    private val channel = MethodChannel(messenger, NAME)
    private var textRecognizer: TextRecognizer? = null

    private val inkModel: DigitalInkRecognitionModel? = inkModelFor(Locale.getDefault())
    private var inkRecognizer: DigitalInkRecognizer? = null
    private var inkModelReady = false
    private var inkModelDownloading = false

    init {
        channel.setMethodCallHandler(this)
        prepareInkModel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "recognize") {
            result.notImplemented()
            return
        }
        val ink = inkFrom(call.argument<List<List<Double>>>("strokes"))
        val recognizer = inkRecognizer()
        if (ink == null || recognizer == null) {
            recognizePicture(call, result)
            return
        }
        try {
            val width = call.argument<Number>("logicalWidth")?.toFloat() ?: 0f
            val height = call.argument<Number>("logicalHeight")?.toFloat() ?: 0f
            val context = RecognitionContext.builder()
                .setPreContext(call.argument<String>("preContext").orEmpty().takeLast(20))
                .apply {
                    if (width > 0f && height > 0f) setWritingArea(WritingArea(width, height))
                }
                .build()
            recognizer.recognize(ink, context)
                .addOnSuccessListener { recognized ->
                    val ranked = recognized.candidates.take(5)
                        .filter { it.text.isNotBlank() }
                    // ML Kit scores are model-specific costs (lower is
                    // better), not normalized probabilities. A moderate gap
                    // is enough for search; only a clear gap enters the
                    // reusable pool. Ambiguous scores stay as metadata.
                    val winner = ranked.firstOrNull()?.score
                    val runnerUp = ranked.getOrNull(1)?.score
                    val winnerGap = if (winner != null && runnerUp != null) {
                        runnerUp - winner
                    } else {
                        null
                    }
                    val candidates = ranked.mapIndexed { index, candidate ->
                        mapOf<String, Any?>(
                            "text" to candidate.text.trim(),
                            "confidence" to when {
                                index == 0 && winner != null && runnerUp == null ->
                                    0.90
                                index == 0 && winnerGap != null && winnerGap >= 1.0f ->
                                    0.90
                                index == 0 && winnerGap != null && winnerGap >= 0.5f ->
                                    0.75
                                candidate.score != null -> 0.60
                                else -> null
                            },
                        )
                    }
                    if (candidates.isEmpty()) {
                        recognizePicture(call, result)
                    } else {
                        result.success(mapOf("segments" to listOf(candidates)))
                    }
                }
                .addOnFailureListener { recognizePicture(call, result) }
        } catch (error: Throwable) {
            recognizePicture(call, result)
        }
    }

    /** The strokes sent from Dart, each a run of x, y, and milliseconds. */
    private fun inkFrom(strokes: List<List<Double>>?): Ink? {
        if (strokes.isNullOrEmpty()) return null
        val ink = Ink.builder()
        var any = false
        for (stroke in strokes) {
            if (stroke.size < 3) continue
            val builder = Ink.Stroke.builder()
            var i = 0
            while (i + 2 < stroke.size) {
                builder.addPoint(
                    Ink.Point.create(
                        stroke[i].toFloat(),
                        stroke[i + 1].toFloat(),
                        stroke[i + 2].toLong(),
                    )
                )
                i += 3
            }
            ink.addStroke(builder.build())
            any = true
        }
        return if (any) ink.build() else null
    }

    /** The digital ink recognizer, once its model is on the device. */
    private fun inkRecognizer(): DigitalInkRecognizer? {
        val model = inkModel ?: return null
        if (!inkModelReady) {
            prepareInkModel()
            return null
        }
        return inkRecognizer
            ?: DigitalInkRecognition.getClient(DigitalInkRecognizerOptions.builder(model).build())
                .also { inkRecognizer = it }
    }

    /** Checks for the ink model and downloads it, in the background, if missing. */
    private fun prepareInkModel() {
        val model = inkModel ?: return
        if (inkModelReady || inkModelDownloading) return
        inkModelDownloading = true
        try {
            val manager = RemoteModelManager.getInstance()
            manager.isModelDownloaded(model)
                .addOnSuccessListener { downloaded ->
                    if (downloaded) {
                        inkModelReady = true
                        inkModelDownloading = false
                    } else {
                        manager.download(model, DownloadConditions.Builder().build())
                            .addOnSuccessListener { inkModelReady = true }
                            .addOnCompleteListener { inkModelDownloading = false }
                    }
                }
                .addOnFailureListener { inkModelDownloading = false }
        } catch (error: Throwable) {
            inkModelDownloading = false
        }
    }

    /** The ink model for [locale], or for its language, or for English. */
    private fun inkModelFor(locale: Locale): DigitalInkRecognitionModel? {
        val tags = listOf(locale.toLanguageTag(), locale.language, FALLBACK_LANGUAGE)
        for (tag in tags) {
            val identifier = try {
                DigitalInkRecognitionModelIdentifier.fromLanguageTag(tag)
            } catch (error: Throwable) {
                null
            }
            if (identifier != null) {
                return DigitalInkRecognitionModel.builder(identifier).build()
            }
        }
        return null
    }

    /** Reads the PNG Dart drew of the strokes, as a picture of text. */
    private fun recognizePicture(call: MethodCall, result: MethodChannel.Result) {
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
            val client = textRecognizer
                ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                    .also { textRecognizer = it }
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
        textRecognizer?.close()
        textRecognizer = null
        inkRecognizer?.close()
        inkRecognizer = null
    }
}
