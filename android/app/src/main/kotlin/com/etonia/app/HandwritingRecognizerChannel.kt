package com.etonia.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
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

        /** Logical units below which a line is too flat to judge by its height. */
        private const val MIN_LINE_HEIGHT = 12f
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
        val strokes = call.argument<List<List<Double>>>("strokes")
            ?.filter { it.size >= 3 }
            .orEmpty()
        val recognizer = inkRecognizer()
        if (strokes.isEmpty() || recognizer == null) {
            recognizePicture(call, result)
            return
        }
        // Digital Ink reads one line of writing at a time: several lines
        // sent as one ink come back run together or misread. Each line is
        // read on its own, top to bottom, the lines above it as context.
        val lines = linesOf(strokes)
        val width = call.argument<Number>("logicalWidth")?.toFloat() ?: 0f
        val segments = mutableListOf<List<Map<String, Any?>>>()
        var preContext = call.argument<String>("preContext").orEmpty()
        fun next(index: Int) {
            if (index >= lines.size) {
                if (segments.isEmpty()) {
                    recognizePicture(call, result)
                } else {
                    result.success(mapOf("segments" to segments))
                }
                return
            }
            val line = lines[index]
            try {
                val context = RecognitionContext.builder()
                    .setPreContext(preContext.takeLast(20))
                    .apply {
                        val height = line.bottom - line.top
                        if (width > 0f && height > 0f) {
                            setWritingArea(WritingArea(width, height))
                        }
                    }
                    .build()
                recognizer.recognize(inkFrom(line.strokes), context)
                    .addOnSuccessListener { recognized ->
                        val candidates = rankedCandidates(recognized.candidates)
                        if (candidates.isNotEmpty()) {
                            segments.add(candidates)
                            preContext = "$preContext ${candidates.first()["text"]}".trim()
                        }
                        next(index + 1)
                    }
                    .addOnFailureListener { next(index + 1) }
            } catch (error: Throwable) {
                next(index + 1)
            }
        }
        next(0)
    }

    /** ML Kit's candidates for one line, best first, with confidences. */
    private fun rankedCandidates(
        recognized: List<com.google.mlkit.vision.digitalink.RecognitionCandidate>,
    ): List<Map<String, Any?>> {
        val ranked = recognized.take(5).filter { it.text.isNotBlank() }
        // ML Kit scores are model-specific costs (lower is better), not
        // normalized probabilities. A moderate gap is enough for search;
        // only a clear gap enters the reusable pool. Ambiguous scores stay
        // as metadata.
        val winner = ranked.firstOrNull()?.score
        val runnerUp = ranked.getOrNull(1)?.score
        val winnerGap = if (winner != null && runnerUp != null) runnerUp - winner else null
        return ranked.mapIndexed { index, candidate ->
            mapOf<String, Any?>(
                "text" to candidate.text.trim(),
                "confidence" to when {
                    index == 0 && winner != null && runnerUp == null -> 0.90
                    index == 0 && winnerGap != null && winnerGap >= 1.0f -> 0.90
                    index == 0 && winnerGap != null && winnerGap >= 0.5f -> 0.75
                    candidate.score != null -> 0.60
                    else -> null
                },
            )
        }
    }

    /** One line of writing: its strokes, in the order written, and its extent. */
    private class Line(var top: Float, var bottom: Float) {
        val strokes = mutableListOf<List<Double>>()
        val center: Float get() = (top + bottom) / 2
    }

    /**
     * Groups strokes into lines of writing, top to bottom. A stroke joins
     * the line its middle falls within, give or take part of the line's
     * height, so dots, accents, and descenders stay with their letters; a
     * stroke clear of every line starts a new one.
     */
    private fun linesOf(strokes: List<List<Double>>): List<Line> {
        val lines = mutableListOf<Line>()
        for (stroke in strokes) {
            var top = Float.MAX_VALUE
            var bottom = -Float.MAX_VALUE
            var i = 1
            while (i < stroke.size) {
                val y = stroke[i].toFloat()
                if (y < top) top = y
                if (y > bottom) bottom = y
                i += 3
            }
            val middle = (top + bottom) / 2
            val line = lines
                .filter { line ->
                    // A flat stroke, such as a minus, still reaches the
                    // letters beside it.
                    val reach = maxOf(line.bottom - line.top, bottom - top, MIN_LINE_HEIGHT) * 0.5f
                    middle >= line.top - reach && middle <= line.bottom + reach
                }
                .minByOrNull { Math.abs(it.center - middle) }
            if (line == null) {
                lines.add(Line(top, bottom).also { it.strokes.add(stroke) })
            } else {
                line.strokes.add(stroke)
                // A tall stroke, such as a bracket, does not stretch an
                // established line over the next one.
                val height = line.bottom - line.top
                if (height < MIN_LINE_HEIGHT || bottom - top <= height * 1.5f) {
                    line.top = minOf(line.top, top)
                    line.bottom = maxOf(line.bottom, bottom)
                }
            }
        }
        return lines.sortedBy { it.top }
    }

    /** Strokes sent from Dart, each a run of x, y, and milliseconds. */
    private fun inkFrom(strokes: List<List<Double>>): Ink {
        val ink = Ink.builder()
        for (stroke in strokes) {
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
        }
        return ink.build()
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
        // ML Kit names Chinese models by script, as zh-Hani-TW, which no
        // device locale (zh-TW, zh-Hant-TW) spells out.
        val han = if (locale.language == "zh" && locale.country.isNotEmpty()) {
            listOf("zh-Hani-${locale.country}")
        } else {
            emptyList()
        }
        val tags = listOf(locale.toLanguageTag()) + han +
            listOf(locale.language, FALLBACK_LANGUAGE)
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

    /** Reads a picture of the strokes, rasterizing vectors only on fallback. */
    private fun recognizePicture(call: MethodCall, result: MethodChannel.Result) {
        val png = call.argument<ByteArray>("png")
        val bitmap: Bitmap? = try {
            if (png != null && png.isNotEmpty()) BitmapFactory.decodeByteArray(png, 0, png.size)
            else bitmapFromStrokes(call)
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

    /** Builds the OCR fallback bitmap off Flutter's UI isolate. */
    private fun bitmapFromStrokes(call: MethodCall): Bitmap? {
        val strokes = call.argument<List<List<Double>>>("strokes") ?: return null
        val width = (call.argument<Number>("width")?.toInt() ?: 0).coerceIn(1, 4096)
        val height = (call.argument<Number>("height")?.toInt() ?: 0).coerceIn(1, 4096)
        val logicalWidth = call.argument<Number>("logicalWidth")?.toFloat() ?: return null
        val logicalHeight = call.argument<Number>("logicalHeight")?.toFloat() ?: return null
        if (logicalWidth <= 0f || logicalHeight <= 0f) return null
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        canvas.scale(width / logicalWidth, height / logicalHeight)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            style = Paint.Style.STROKE
            strokeWidth = 3f
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        for (stroke in strokes) {
            val count = stroke.size / 3
            if (count == 0) continue
            val path = Path()
            path.moveTo(stroke[0].toFloat(), stroke[1].toFloat())
            path.lineTo(stroke[0].toFloat(), stroke[1].toFloat())
            for (point in 1 until count - 1) {
                val at = point * 3
                val next = (point + 1) * 3
                path.quadTo(
                    stroke[at].toFloat(), stroke[at + 1].toFloat(),
                    ((stroke[at] + stroke[next]) / 2).toFloat(),
                    ((stroke[at + 1] + stroke[next + 1]) / 2).toFloat(),
                )
            }
            if (count > 1) {
                val last = (count - 1) * 3
                path.lineTo(stroke[last].toFloat(), stroke[last + 1].toFloat())
            }
            canvas.drawPath(path, paint)
        }
        return bitmap
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
