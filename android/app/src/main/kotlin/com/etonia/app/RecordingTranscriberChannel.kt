package com.etonia.app

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.speech.RecognitionListener
import android.speech.RecognitionPart
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteOrder
import java.util.Locale
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Transcribes a saved recording with the device's own speech recognizer,
 * only when the user asks for it and never while recording.
 *
 * The finished M4A is decoded to 16 kHz mono PCM on a background thread and
 * piped into a segmented [SpeechRecognizer] session, Android 13's way to
 * recognize audio that is not the microphone. The on-device recognizer is
 * preferred; the device's default speech service is used when there is none.
 * The pipe's back-pressure paces decoding to the recognizer, so a long
 * lecture never holds more than a few seconds of audio in memory.
 *
 * One recording at a time. Recognizer calls and callbacks stay on the main
 * thread, as [SpeechRecognizer] requires.
 */
class RecordingTranscriberChannel(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "com.etonia.app/recording_transcriber"
        private const val RATE = 16000
    }

    private val channel = MethodChannel(messenger, NAME)
    private val main = Handler(Looper.getMainLooper())
    private var job: Job? = null

    init {
        channel.setMethodCallHandler(this)
    }

    private class Job(
        val id: String,
        val path: String,
        val durationMs: Int,
        val result: MethodChannel.Result,
    ) {
        var recognizer: SpeechRecognizer? = null
        var intent: Intent? = null
        var source: ParcelFileDescriptor? = null
        var formatting = true
        val lines = mutableListOf<Map<String, Any>>()

        @Volatile
        var stopped = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "transcribe" -> transcribe(call, result)
            "cancel" -> {
                job?.takeIf { it.id == call.argument<String>("id") }?.let {
                    finish(it, error = "cancelled")
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun transcribe(call: MethodCall, result: MethodChannel.Result) {
        if (job != null) {
            result.error("busy", null, null)
            return
        }
        val id = call.argument<String>("id")
        val path = call.argument<String>("path")
        if (id == null || path == null) {
            result.error("failed", null, null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.error("unavailable", null, null)
            return
        }
        val started = Job(id, path, call.argument<Int>("durationMs") ?: 0, result)
        job = started
        start(started)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun start(job: Job) {
        val onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        if (!onDevice && !SpeechRecognizer.isRecognitionAvailable(context)) {
            finish(job, error = "unavailable")
            return
        }
        val recognizer = try {
            if (onDevice) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            } else {
                SpeechRecognizer.createSpeechRecognizer(context)
            }
        } catch (_: Throwable) {
            finish(job, error = "unavailable")
            return
        }
        val pipe = try {
            ParcelFileDescriptor.createPipe()
        } catch (_: IOException) {
            recognizer.destroy()
            finish(job, error = "failed")
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(
                RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
            // One session for the whole file, not just its first utterance.
            putExtra(
                RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                RecognizerIntent.EXTRA_AUDIO_SOURCE,
            )
            if (job.formatting) {
                putExtra(
                    RecognizerIntent.EXTRA_ENABLE_FORMATTING,
                    RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_TIMING, true)
            }
        }
        job.recognizer = recognizer
        job.intent = intent
        job.source = pipe[0]
        recognizer.setRecognitionListener(Listener(job))
        try {
            recognizer.startListening(intent)
        } catch (_: Throwable) {
            pipe[1].close()
            finish(job, error = "failed")
            return
        }
        Thread({ feed(job, pipe[1]) }, "etonia-transcription").start()
    }

    private inner class Listener(private val job: Job) : RecognitionListener {
        override fun onSegmentResults(segmentResults: Bundle) {
            if (this@RecordingTranscriberChannel.job !== job) return
            val text = segmentResults
                .getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
            if (text.isNullOrEmpty()) return
            val line = mutableMapOf<String, Any>("text" to text)
            startMs(segmentResults)?.let { line["startMs"] = it }
            job.lines.add(line)
        }

        override fun onEndOfSegmentedSession() {
            if (this@RecordingTranscriberChannel.job !== job) return
            complete(job)
        }

        override fun onResults(results: Bundle) {
            // A recognizer that ignored the segmented session.
            onSegmentResults(results)
            onEndOfSegmentedSession()
        }

        override fun onError(error: Int) {
            if (this@RecordingTranscriberChannel.job !== job) return
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> complete(job)
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                    finish(job, error = "permission")
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        job.formatting &&
                        job.lines.isEmpty()
                    ) {
                        // Formatting is not offered in every language.
                        retryWithoutFormatting(job)
                    } else {
                        finish(job, error = "language")
                    }
                SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val intent = job.intent
                        if (intent != null) {
                            try {
                                job.recognizer?.triggerModelDownload(intent)
                            } catch (_: Throwable) {
                                // The download is a courtesy for next time.
                            }
                        }
                    }
                    finish(job, error = "language")
                }
                else ->
                    if (job.lines.isNotEmpty()) complete(job) else finish(job, error = "failed")
            }
        }

        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onPartialResults(partialResults: Bundle?) {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    /** Where in the audio a segment starts, when the recognizer timed it. */
    private fun startMs(results: Bundle): Long? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        return try {
            results.getParcelableArrayList(
                SpeechRecognizer.RECOGNITION_PARTS,
                RecognitionPart::class.java,
            )?.firstOrNull()?.timestampMillis?.takeIf { it >= 0 }
        } catch (_: Throwable) {
            null
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun retryWithoutFormatting(failed: Job) {
        release(failed)
        val retry = Job(failed.id, failed.path, failed.durationMs, failed.result).apply {
            formatting = false
        }
        job = retry
        start(retry)
    }

    private fun complete(job: Job) {
        // Times that are all zero were never measured.
        val lines = if (job.lines.size > 1 &&
            job.lines.all { (it["startMs"] as? Long ?: 0L) == 0L }
        ) {
            job.lines.map { it - "startMs" }
        } else {
            job.lines.toList()
        }
        if (lines.isEmpty()) {
            finish(job, error = "no_speech")
        } else {
            finish(job, value = mapOf("segments" to lines, "locale" to Locale.getDefault().toLanguageTag()))
        }
    }

    private fun finish(finished: Job, value: Any? = null, error: String? = null) {
        if (job !== finished) return
        job = null
        release(finished)
        if (error != null) {
            finished.result.error(error, null, null)
        } else {
            finished.result.success(value)
        }
    }

    /** Stops [job]'s recognizer and decoder. Main thread. */
    private fun release(job: Job) {
        job.stopped = true
        job.recognizer?.let {
            try {
                it.cancel()
                it.destroy()
            } catch (_: Throwable) {
                // Already gone with its service.
            }
        }
        job.recognizer = null
        try {
            job.source?.close()
        } catch (_: IOException) {
        }
        job.source = null
    }

    /**
     * Decodes [job]'s file into [sink] as 16 kHz mono 16-bit PCM, at
     * background priority, then closes it so the session ends.
     */
    private fun feed(job: Job, sink: ParcelFileDescriptor) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ParcelFileDescriptor.AutoCloseOutputStream(sink).use { out ->
                extractor.setDataSource(job.path)
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                        ?.startsWith("audio/") == true
                } ?: throw IOException("no audio track")
                extractor.selectTrack(track)
                val format = extractor.getTrackFormat(track)
                val decoder = MediaCodec.createDecoderByType(
                    format.getString(MediaFormat.KEY_MIME)!!,
                )
                codec = decoder
                decoder.configure(format, null, null, 0)
                decoder.start()
                val resampler = Resampler(out)
                resampler.configure(
                    format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                    format.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                    AudioFormat.ENCODING_PCM_16BIT,
                )
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var reportedMs = 0L
                while (!job.stopped) {
                    if (!inputDone) {
                        val index = decoder.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = decoder.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(
                                    index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = decoder.dequeueOutputBuffer(info, 10_000)
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val output = decoder.outputFormat
                        resampler.configure(
                            output.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                            output.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                            if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                                output.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            } else {
                                AudioFormat.ENCODING_PCM_16BIT
                            },
                        )
                    } else if (index >= 0) {
                        val buffer = decoder.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            resampler.push(buffer.slice().order(ByteOrder.nativeOrder()))
                        }
                        decoder.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                        val fedMs = resampler.written * 1000L / RATE
                        if (job.durationMs > 0 && fedMs - reportedMs >= 1000) {
                            reportedMs = fedMs
                            progress(job, fedMs.toDouble() / job.durationMs)
                        }
                    }
                }
                resampler.flush()
            }
        } catch (_: Throwable) {
            // The session ends when the pipe closes; whatever was heard by
            // then is the transcript, and none at all is reported as such.
        } finally {
            try {
                codec?.stop()
            } catch (_: Throwable) {
            }
            codec?.release()
            extractor.release()
            try {
                sink.close()
            } catch (_: IOException) {
            }
        }
    }

    private fun progress(job: Job, fraction: Double) {
        main.post {
            if (this.job !== job) return@post
            channel.invokeMethod(
                "onProgress",
                mapOf("id" to job.id, "fraction" to fraction.coerceIn(0.0, 1.0)),
            )
        }
    }

    fun dispose() {
        job?.let { finish(it, error = "cancelled") }
        channel.setMethodCallHandler(null)
    }

    /**
     * Mixes decoded PCM down to mono and resamples it to [RATE] by linear
     * interpolation, after a gentle low-pass so higher frequencies do not
     * fold into the speech band.
     */
    private class Resampler(private val out: OutputStream) {
        private var channels = 1
        private var encoding = AudioFormat.ENCODING_PCM_16BIT
        private var step = 1.0
        private var alpha = 1f
        private var filtered = 0f

        /** Index, in input frames, of the next output sample. */
        private var position = 0.0

        /** Index of the first frame of the next block. */
        private var base = 0L
        private var last = 0f
        private var mono = FloatArray(0)
        private val bytes = ByteArray(8192)
        private var pending = 0
        var written = 0L
            private set

        fun configure(rate: Int, channels: Int, encoding: Int) {
            this.channels = channels.coerceAtLeast(1)
            this.encoding = encoding
            step = rate.toDouble() / RATE
            val cutoff = 7000.0
            alpha = if (rate > 2 * cutoff) (1 - exp(-2 * PI * cutoff / rate)).toFloat() else 1f
        }

        fun push(buffer: java.nio.ByteBuffer) {
            val frames = when (encoding) {
                AudioFormat.ENCODING_PCM_FLOAT -> buffer.remaining() / 4 / channels
                else -> buffer.remaining() / 2 / channels
            }
            if (frames == 0) return
            if (mono.size < frames) mono = FloatArray(frames)
            if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                val floats = buffer.asFloatBuffer()
                for (frame in 0 until frames) {
                    var sum = 0f
                    for (c in 0 until channels) sum += floats.get()
                    mono[frame] = lowPass(sum / channels)
                }
            } else {
                val shorts = buffer.asShortBuffer()
                for (frame in 0 until frames) {
                    var sum = 0f
                    for (c in 0 until channels) sum += shorts.get() / 32768f
                    mono[frame] = lowPass(sum / channels)
                }
            }
            while (true) {
                val whole = floor(position).toLong()
                val index = (whole - base).toInt()
                if (index + 1 >= frames) break
                val a = if (index < 0) last else mono[index]
                val b = mono[index + 1]
                write(a + (b - a) * (position - whole).toFloat())
                position += step
            }
            last = mono[frames - 1]
            base += frames
        }

        private fun lowPass(sample: Float): Float {
            filtered += alpha * (sample - filtered)
            return filtered
        }

        private fun write(sample: Float) {
            val value = (sample.coerceIn(-1f, 1f) * 32767).roundToInt()
            bytes[pending++] = value.toByte()
            bytes[pending++] = (value shr 8).toByte()
            written++
            if (pending == bytes.size) flush()
        }

        fun flush() {
            if (pending == 0) return
            out.write(bytes, 0, pending)
            pending = 0
        }
    }
}
