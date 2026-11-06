package com.etonia.app

import android.app.Activity
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewConfiguration
import android.widget.FrameLayout
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.brush.BrushBehavior
import androidx.ink.brush.BrushCoat
import androidx.ink.brush.BrushFamily
import androidx.ink.brush.BrushPaint
import androidx.ink.brush.BrushTip
import androidx.ink.brush.ExperimentalInkCustomBrushApi
import androidx.ink.brush.InputToolType
import androidx.ink.brush.behavior.OutOfRange
import androidx.ink.brush.behavior.SourceNode
import androidx.ink.brush.behavior.TargetNode
import androidx.ink.strokes.MutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import androidx.ink.strokes.StrokeInput
import androidx.input.motionprediction.MotionEventPredictor
import io.flutter.embedding.android.FlutterView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.hypot

/**
 * Observes stylus MotionEvents before Flutter's pointer pipeline, preserves
 * their historical samples, and paints a short-lived native live-ink layer.
 * Finger events are never consumed and continue to drive Flutter navigation.
 */
class NativeInkChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.etonia.app/native_ink"
        private val PEN_DEVICE_NAME = Regex("""\b(pen|stylus)\b""", RegexOption.IGNORE_CASE)
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val surfaces = LinkedHashMap<Int, InkSurface>()
    private val handler = Handler(Looper.getMainLooper())
    private var flutterView: FlutterView? = null
    private var overlay: NativeInkOverlay? = null
    private var active: ActiveStroke? = null

    /** MotionEvent ids repeat; Dart addresses each stroke by its own number. */
    private var nextStrokeNumber = 1
    private var predictor: MotionEventPredictor? = null
    private var primaryButtonDown = false
    private var secondaryButtonDown = false
    private var lastPrimaryPressTime = 0L
    private var pendingSinglePress: Runnable? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "registerSurface", "updateSurface" -> {
                val surface = InkSurface.from(call.arguments as? Map<*, *>)
                if (surface == null) {
                    result.error("bad_surface", "Native ink surface arguments are invalid", null)
                    return
                }
                surfaces[surface.id] = surface
                ensureOverlay()
                // Leaving the pen hides a stroke still in progress at once; the
                // rest of its gesture is swallowed rather than starting a new one.
                // Finished strokes stay until Dart says Flutter is drawing them.
                if (!surface.enabled || !surface.previewEnabled) {
                    active?.takeIf { it.surface.id == surface.id }?.let {
                        it.previewSuppressed = true
                        overlay?.cancelLive()
                    }
                }
                result.success(true)
            }
            "unregisterSurface" -> {
                val id = argumentInt(call.arguments, "surfaceId")
                if (id != null) {
                    surfaces.remove(id)
                    if (active?.surface?.id == id) cancelActive(sendPacket = false)
                }
                result.success(null)
            }
            "finishPreview" -> {
                val number = argumentInt(call.arguments, "pointer")
                if (number != null) {
                    active?.takeIf { it.number == number }?.previewSuppressed = true
                    overlay?.finish(number)
                }
                result.success(null)
            }
            "clearLivePreview" -> {
                active = null
                overlay?.cancelLive()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Called at the top of [Activity.dispatchTouchEvent]. Never consumes. */
    fun observe(event: MotionEvent) {
        val view = ensureOverlay() ?: return
        val actionIndex = event.actionIndex.coerceIn(0, event.pointerCount - 1)
        val tool = event.getToolType(actionIndex)
        if (active != null ||
            ((event.actionMasked == MotionEvent.ACTION_DOWN ||
                event.actionMasked == MotionEvent.ACTION_POINTER_DOWN) &&
                (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER))
        ) {
            try {
                predictor?.record(event)
            } catch (_: IllegalArgumentException) {
                predictor = MotionEventPredictor.newInstance(view).also { it.record(event) }
            }
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> begin(event, view)
            MotionEvent.ACTION_MOVE -> move(event, view)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> end(event, view)
            MotionEvent.ACTION_CANCEL -> cancelActive(sendPacket = true)
        }
    }

    /** Observes stylus barrel buttons from touch and generic-motion paths. */
    fun observeStylusButtons(event: MotionEvent) {
        if (event.pointerCount == 0) return
        val index = event.actionIndex.coerceIn(0, event.pointerCount - 1)
        val tool = event.getToolType(index)
        if (tool != MotionEvent.TOOL_TYPE_STYLUS && tool != MotionEvent.TOOL_TYPE_ERASER) {
            return
        }

        val primaryDown = event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0
        val secondaryDown = event.buttonState and MotionEvent.BUTTON_STYLUS_SECONDARY != 0
        val primaryPressed =
            (event.actionMasked == MotionEvent.ACTION_BUTTON_PRESS &&
                event.actionButton == MotionEvent.BUTTON_STYLUS_PRIMARY) ||
                (primaryDown && !primaryButtonDown)
        val secondaryPressed =
            (event.actionMasked == MotionEvent.ACTION_BUTTON_PRESS &&
                event.actionButton == MotionEvent.BUTTON_STYLUS_SECONDARY) ||
                (secondaryDown && !secondaryButtonDown)
        primaryButtonDown = primaryDown
        secondaryButtonDown = secondaryDown

        if (primaryPressed) handlePrimaryPress(event.eventTime)
        if (secondaryPressed) emitStylusGesture("secondaryPress")
    }

    /**
     * Observes pens that send their buttons over Bluetooth as key events, with
     * no button state on their MotionEvents: a Xiaomi Focus Pen sends
     * KEYCODE_BUTTON_7 to 10. Gamepads use these keycodes too, so only a pen's
     * count. Returns whether the key was a pen's, for the caller to consume.
     */
    fun observeStylusKey(event: KeyEvent): Boolean {
        if (event.keyCode !in KeyEvent.KEYCODE_BUTTON_7..KeyEvent.KEYCODE_BUTTON_10) return false
        val device = InputDevice.getDevice(event.deviceId)?.name ?: return false
        if (!PEN_DEVICE_NAME.containsMatchIn(device)) return false
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            if (event.keyCode == KeyEvent.KEYCODE_BUTTON_7) {
                handlePrimaryPress(event.eventTime)
            } else {
                emitStylusGesture("secondaryPress")
            }
        }
        return true
    }

    private fun handlePrimaryPress(eventTime: Long) {
        val timeout = ViewConfiguration.getDoubleTapTimeout().toLong()
        val pending = pendingSinglePress
        if (pending != null && eventTime - lastPrimaryPressTime <= timeout) {
            handler.removeCallbacks(pending)
            pendingSinglePress = null
            lastPrimaryPressTime = 0L
            emitStylusGesture("doubleTap")
            return
        }
        pending?.let(handler::removeCallbacks)
        lastPrimaryPressTime = eventTime
        val single = Runnable {
            pendingSinglePress = null
            lastPrimaryPressTime = 0L
            emitStylusGesture("singlePress")
        }
        pendingSinglePress = single
        handler.postDelayed(single, timeout)
    }

    private fun emitStylusGesture(gesture: String) {
        channel.invokeMethod("stylusGesture", mapOf("gesture" to gesture))
    }

    fun dispose() {
        cancelActive(sendPacket = false)
        pendingSinglePress?.let(handler::removeCallbacks)
        pendingSinglePress = null
        channel.setMethodCallHandler(null)
        overlay?.let { (it.parent as? ViewGroup)?.removeView(it) }
        overlay = null
        flutterView = null
        predictor = null
        surfaces.clear()
    }

    private fun begin(event: MotionEvent, view: FlutterView) {
        val index = event.actionIndex
        val tool = event.getToolType(index)
        if (tool != MotionEvent.TOOL_TYPE_STYLUS && tool != MotionEvent.TOOL_TYPE_ERASER) return
        if (active != null) return
        val global = logicalPoint(event.getX(index), event.getY(index), view)
        val surface = surfaces.values.lastOrNull {
            it.enabled && it.contains(global.first, global.second)
        }
            ?: return
        val pointer = event.getPointerId(index)
        val inverted = tool == MotionEvent.TOOL_TYPE_ERASER
        view.requestUnbufferedDispatch(event)
        val samples = samples(event, index, surface, includeHistory = false)
        // The preview follows the very samples Dart receives, through the
        // same pen model, so it draws the stroke Flutter will commit.
        val model = if (surface.previewEnabled && !inverted && samples.size >= 4) {
            InkStrokeModel(
                surface.strokeWidth,
                surface.taper,
                surface.pressureSensitivity,
                surface.smoothing,
            ).also { feed(it, samples, started = false) }
        } else {
            null
        }
        val number = nextStrokeNumber++
        active = ActiveStroke(surface, pointer, number, inverted, model)
        if (model != null) overlay?.begin(number, surface, model)
        emit(surface.id, number, "down", inverted, samples)
    }

    private fun move(event: MotionEvent, view: FlutterView) {
        val stroke = active ?: return
        val index = event.findPointerIndex(stroke.pointer)
        if (index < 0) {
            cancelActive(sendPacket = true)
            return
        }
        view.requestUnbufferedDispatch(event)
        val samples = samples(event, index, stroke.surface, includeHistory = true)
        if (samples.isEmpty()) return
        val model = stroke.model
        if (model != null) {
            feed(model, samples, started = true)
            if (!stroke.previewSuppressed) {
                val predicted = predictor?.predict()
                try {
                    overlay?.append(stroke.number, model, predictedSamples(predicted, stroke, view))
                } finally {
                    predicted?.recycle()
                }
            }
        }
        emit(stroke.surface.id, stroke.number, "move", stroke.inverted, samples)
    }

    private fun end(event: MotionEvent, view: FlutterView) {
        val stroke = active ?: return
        val index = event.actionIndex
        if (event.getPointerId(index) != stroke.pointer) return
        val samples = samples(event, index, stroke.surface, includeHistory = true)
        val model = stroke.model
        if (model != null) {
            feed(model, samples, started = true)
            val final = model.finish()
            if (!stroke.previewSuppressed) overlay?.end(stroke.number, model, final)
        }
        emit(stroke.surface.id, stroke.number, "up", stroke.inverted, samples)
        active = null
        // Jetpack Ink keeps the finished stroke until Dart says Flutter is
        // drawing it, however many strokes come after it.
    }

    private fun cancelActive(sendPacket: Boolean) {
        val stroke = active ?: return
        active = null
        overlay?.finish(stroke.number)
        if (sendPacket) {
            emit(stroke.surface.id, stroke.number, "cancel", stroke.inverted, emptyList())
        }
    }

    /** Flat x,y,time-us,pressure tuples minimize StandardMessageCodec churn. */
    private fun samples(
        event: MotionEvent,
        pointerIndex: Int,
        surface: InkSurface,
        includeHistory: Boolean,
    ): List<Any?> {
        val output = ArrayList<Any?>((event.historySize + 1) * 4)
        if (includeHistory) {
            for (history in 0 until event.historySize) {
                val point = surface.localFromEvent(
                    event.getHistoricalX(pointerIndex, history),
                    event.getHistoricalY(pointerIndex, history),
                    flutterView ?: return output,
                ) ?: continue
                output.add(point.first)
                output.add(point.second)
                output.add(event.getHistoricalEventTime(history) * 1000L)
                output.add(event.getHistoricalPressure(pointerIndex, history).toDouble().coerceIn(0.0, 1.0))
            }
        }
        val point = surface.localFromEvent(
            event.getX(pointerIndex),
            event.getY(pointerIndex),
            flutterView ?: return output,
        )
        if (point != null) {
            output.add(point.first)
            output.add(point.second)
            output.add(event.eventTime * 1000L)
            output.add(event.getPressure(pointerIndex).toDouble().coerceIn(0.0, 1.0))
        }
        return output
    }

    /** Runs flat x, y, time-us, pressure samples through [model]. */
    private fun feed(model: InkStrokeModel, samples: List<Any?>, started: Boolean) {
        var index = 0
        var first = !started
        while (index + 3 < samples.size) {
            val x = (samples[index] as Number).toDouble()
            val y = (samples[index + 1] as Number).toDouble()
            val micros = (samples[index + 2] as Number).toLong()
            val pressure = (samples[index + 3] as? Number)?.toDouble()
            if (first) {
                model.start(x, y, micros, pressure)
                first = false
            } else {
                model.add(x, y, micros, pressure)
            }
            index += 4
        }
    }

    /** The predictor's guesses for [stroke]'s pointer, in its page's canvas pixels. */
    private fun predictedSamples(
        predicted: MotionEvent?,
        stroke: ActiveStroke,
        view: FlutterView,
    ): List<DoubleArray> {
        if (predicted == null) return emptyList()
        val index = predicted.findPointerIndex(stroke.pointer)
        if (index < 0) return emptyList()
        val output = ArrayList<DoubleArray>(predicted.historySize + 1)
        fun add(x: Float, y: Float, millis: Long, pressure: Float) {
            val point = stroke.surface.localFromEvent(x, y, view) ?: return
            output.add(
                doubleArrayOf(
                    point.first,
                    point.second,
                    (millis * 1000L).toDouble(),
                    pressure.toDouble().coerceIn(0.0, 1.0),
                ),
            )
        }
        for (history in 0 until predicted.historySize) {
            add(
                predicted.getHistoricalX(index, history),
                predicted.getHistoricalY(index, history),
                predicted.getHistoricalEventTime(history),
                predicted.getHistoricalPressure(index, history),
            )
        }
        add(predicted.getX(index), predicted.getY(index), predicted.eventTime, predicted.getPressure(index))
        return output
    }

    private fun emit(
        surfaceId: Int,
        pointer: Int,
        phase: String,
        inverted: Boolean,
        samples: List<Any?>,
    ) {
        channel.invokeMethod(
            "inkPacket",
            mapOf(
                "surfaceId" to surfaceId,
                "pointer" to pointer,
                "phase" to phase,
                "kind" to if (inverted) "invertedStylus" else "stylus",
                "samples" to samples,
            ),
        )
    }

    private fun ensureOverlay(): FlutterView? {
        flutterView?.let { if (it.isAttachedToWindow) return it }
        val found = findFlutterView(activity.window?.decorView) ?: return null
        flutterView = found
        predictor = MotionEventPredictor.newInstance(found)
        if (overlay?.parent !== found) {
            overlay?.let { (it.parent as? ViewGroup)?.removeView(it) }
            overlay = NativeInkOverlay(activity).also {
                found.addView(
                    it,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
            }
        }
        return found
    }

    private fun findFlutterView(view: View?): FlutterView? {
        if (view is FlutterView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                findFlutterView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    private fun logicalPoint(x: Float, y: Float, view: FlutterView): Pair<Double, Double> {
        val location = IntArray(2)
        view.getLocationInWindow(location)
        val density = activity.resources.displayMetrics.density.toDouble()
        return Pair((x - location[0]) / density, (y - location[1]) / density)
    }

    private fun argumentInt(arguments: Any?, key: String): Int? =
        ((arguments as? Map<*, *>)?.get(key) as? Number)?.toInt()

    private class ActiveStroke(
        val surface: InkSurface,
        /** The MotionEvent pointer id, which later gestures will reuse. */
        val pointer: Int,
        /** This stroke's number, which Dart knows it by. */
        val number: Int,
        val inverted: Boolean,
        /** The pen model behind the wet ink; null when there is no preview. */
        val model: InkStrokeModel?,
        var previewSuppressed: Boolean = false,
    )

    private data class InkSurface(
        val id: Int,
        val width: Double,
        val height: Double,
        val originX: Double,
        val originY: Double,
        val xx: Double,
        val xy: Double,
        val yx: Double,
        val yy: Double,
        val enabled: Boolean,
        val previewEnabled: Boolean,
        val color: Int,
        val strokeWidth: Double,
        val pressureSensitivity: Double,
        val taper: Double,
        val stabilization: Double,
        /** The stroke's One Euro tuning, stabilization applied, from Dart. */
        val smoothing: InkSmoothing,
        val writingStyle: String,
        val exclusionRects: List<RectF> = emptyList(),
    ) {
        private val determinant = xx * yy - xy * yx
        val scale = (hypot(xx, xy) + hypot(yx, yy)) / 2.0

        fun local(globalX: Double, globalY: Double): Pair<Double, Double>? {
            if (kotlin.math.abs(determinant) < 1e-9) return null
            val dx = globalX - originX
            val dy = globalY - originY
            val x = (dx * yy - dy * yx) / determinant
            val y = (dy * xx - dx * xy) / determinant
            return Pair(x, y)
        }

        fun contains(globalX: Double, globalY: Double): Boolean {
            val gx = globalX.toFloat()
            val gy = globalY.toFloat()
            for (rect in exclusionRects) {
                if (rect.contains(gx, gy)) return false
            }
            val point = local(globalX, globalY) ?: return false
            return point.first >= 0 && point.second >= 0 && point.first <= width && point.second <= height
        }

        fun localFromEvent(x: Float, y: Float, view: FlutterView): Pair<Double, Double>? {
            val location = IntArray(2)
            view.getLocationInWindow(location)
            val density = view.resources.displayMetrics.density.toDouble()
            return local((x - location[0]) / density, (y - location[1]) / density)
        }

        companion object {
            fun from(arguments: Map<*, *>?): InkSurface? {
                if (arguments == null) return null
                fun number(key: String) = (arguments[key] as? Number)?.toDouble()
                val rectsRaw = arguments["exclusionRects"] as? List<*>
                val exclusion = ArrayList<RectF>()
                if (rectsRaw != null) {
                    var i = 0
                    while (i + 3 < rectsRaw.size) {
                        val l = (rectsRaw[i] as? Number)?.toFloat() ?: 0f
                        val t = (rectsRaw[i + 1] as? Number)?.toFloat() ?: 0f
                        val r = (rectsRaw[i + 2] as? Number)?.toFloat() ?: 0f
                        val b = (rectsRaw[i + 3] as? Number)?.toFloat() ?: 0f
                        exclusion.add(RectF(l, t, r, b))
                        i += 4
                    }
                }
                return InkSurface(
                    id = (arguments["surfaceId"] as? Number)?.toInt() ?: return null,
                    width = number("width") ?: return null,
                    height = number("height") ?: return null,
                    originX = number("originX") ?: return null,
                    originY = number("originY") ?: return null,
                    xx = number("xx") ?: return null,
                    xy = number("xy") ?: return null,
                    yx = number("yx") ?: return null,
                    yy = number("yy") ?: return null,
                    enabled = arguments["enabled"] as? Boolean ?: false,
                    previewEnabled = arguments["previewEnabled"] as? Boolean ?: false,
                    color = (arguments["color"] as? Number)?.toLong()?.toInt() ?: Color.BLACK,
                    strokeWidth = number("strokeWidth") ?: 1.0,
                    pressureSensitivity = number("pressureSensitivity")?.coerceIn(0.0, 1.0) ?: 0.0,
                    taper = number("taper")?.coerceIn(0.0, 1.0) ?: 0.0,
                    stabilization = number("stabilization")?.coerceIn(0.0, 1.0) ?: 0.0,
                    smoothing = InkSmoothing.from(arguments["smoothing"]),
                    writingStyle = arguments["writingStyle"] as? String ?: "pen",
                    exclusionRects = exclusion,
                )
            }
        }
    }

    /**
     * Jetpack Ink's authoring view owns the low-latency rendering. It is fed
     * the points of [InkStrokeModel], Flutter's own pen model, rather than
     * raw MotionEvents: the same smoothing, pressure and taper, and the same
     * flattened curve, so the wet ink is the stroke Flutter will commit.
     */
    private class NativeInkOverlay(context: android.content.Context) : FrameLayout(context) {
        private val ink = InProgressStrokesView(context)

        /** The number of the stroke being drawn, and its Jetpack Ink id. */
        private var number: Int? = null
        private var strokeId: InProgressStrokeId? = null

        /** Finished strokes on screen, by number, until [finish]. */
        private val retained = HashMap<Int, InProgressStrokeId>()
        private var brush: Brush? = null
        private val strokeToView = Matrix()
        private var startMicros = 0L
        private var sent = 0
        private var lastInput: StrokeInput? = null
        private var reportedFailure = false

        /**
         * Each point's width factor travels as its pressure, halved to fit
         * 0..1, and the brush maps pressure straight back to 0..2 times its
         * size, so the widths are exactly the model's.
         */
        @OptIn(ExperimentalInkCustomBrushApi::class)
        private val family: BrushFamily by lazy {
            val width = BrushBehavior(
                TargetNode(
                    TargetNode.Target.SIZE_MULTIPLIER,
                    0f,
                    2f,
                    SourceNode(
                        SourceNode.Source.NORMALIZED_PRESSURE,
                        0f,
                        1f,
                        OutOfRange.CLAMP,
                    ),
                ),
            )
            BrushFamily.Builder()
                .setCoat(BrushCoat(BrushTip.Builder().setBehaviors(listOf(width)).build(), BrushPaint()))
                .setInputModel(BrushFamily.InputModel.PASSTHROUGH_MODEL)
                .build()
        }

        init {
            isClickable = false
            isFocusable = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            addView(
                ink,
                LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
            )
            ink.addFinishedStrokesListener(
                object : InProgressStrokesFinishedListener {
                    override fun onStrokesFinished(
                        strokes: Map<InProgressStrokeId, Stroke>,
                    ) {
                        // Strokes are handed off in cohorts: a finished stroke
                        // waits while another is in progress, out of reach of
                        // cancelUnfinishedStrokes, and arrives here after the
                        // overlay has let go of it. Only strokes still
                        // waiting for Flutter's confirmation may stay.
                        val stale = strokes.keys.filterTo(HashSet()) { it !in retained.values }
                        if (stale.isNotEmpty()) ink.removeFinishedStrokes(stale)
                    }
                },
            )
        }

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            // Avoid a visible first-stroke initialization hitch.
            ink.eagerInit()
        }

        fun begin(number: Int, surface: InkSurface, model: InkStrokeModel) {
            cancelLive()
            val points = model.stable
            if (points.size == 0) return
            val density = resources.displayMetrics.density.toDouble()
            // Stroke coordinates are the page's canvas pixels, as in Dart;
            // the overlay fills the FlutterView, in physical pixels.
            strokeToView.setValues(
                floatArrayOf(
                    (surface.xx * density).toFloat(),
                    (surface.yx * density).toFloat(),
                    (surface.originX * density).toFloat(),
                    (surface.xy * density).toFloat(),
                    (surface.yy * density).toFloat(),
                    (surface.originY * density).toFloat(),
                    0f,
                    0f,
                    1f,
                ),
            )
            val physicalPerUnit = (surface.scale * density).coerceAtLeast(1e-3)
            val created = Brush.createWithColorIntArgb(
                family,
                surface.color,
                surface.strokeWidth.toFloat().coerceAtLeast(0.01f),
                (EPSILON_PX / physicalPerUnit).toFloat(),
            )
            brush = created
            this.number = number
            startMicros = points.micros[0]
            strokeId = guarded {
                val first = input(points, 0)
                lastInput = first
                ink.startStroke(first, created, strokeToView)
            }
            sent = 1
        }

        fun append(number: Int, model: InkStrokeModel, predicted: List<DoubleArray>) {
            val id = strokeId ?: return
            if (this.number != number) return
            guarded {
                val stable = model.stable
                val real = batch(stable, sent, stable.size, lastInput)
                sent = stable.size
                if (real.size > 0) lastInput = real.get(real.size - 1)
                val tail = model.liveTail(predicted)
                ink.addToStroke(real, id, batch(tail, 0, tail.size, lastInput))
            }
        }

        /**
         * Ends the wet stroke as [final], the stroke as Flutter commits it,
         * and keeps it until [finish]. Usually that only adds the last
         * stretch, so the stroke finishes in place; only a tapered stroke or
         * a pressure dot, whose drawn points change, is redrawn whole.
         */
        fun end(number: Int, model: InkStrokeModel, final: InkPoints) {
            val id = strokeId ?: return
            val brush = brush ?: return
            if (this.number != number || final.size == 0) return
            guarded {
                if (!model.finishReshapes) {
                    val stable = model.stable
                    val rest = batch(stable, sent, stable.size, lastInput)
                    val tail = model.liveTail()
                    batch(tail, 0, tail.size, lastInput, rest)
                    sent = stable.size
                    retained[number] = id
                    finishWith(rest, input(stable, stable.size - 1, 1), id)
                    return@guarded
                }
                ink.cancelStroke(id)
                val first = input(final, 0)
                val next = ink.startStroke(first, brush, strokeToView)
                retained[number] = next
                finishWith(batch(final, 1, final.size, first), input(final, 0, 1), next)
            }
            this.number = null
            strokeId = null
        }

        /** Adds [rest] and ends on its last input; with nothing new, ends on [still]. */
        private fun finishWith(
            rest: MutableStrokeInputBatch,
            still: StrokeInput,
            id: InProgressStrokeId,
        ) {
            if (rest.size == 0) {
                ink.finishStroke(still, id)
                return
            }
            val leading = MutableStrokeInputBatch()
            for (index in 0 until rest.size - 1) leading.add(rest.get(index))
            if (leading.size > 0) ink.addToStroke(leading, id)
            ink.finishStroke(rest.get(rest.size - 1), id)
        }

        /** Hides the stroke numbered [number], and no other. */
        fun finish(number: Int) {
            if (this.number == number) {
                cancelLive()
                return
            }
            val id = retained.remove(number) ?: return
            // Not handed off yet, the finished listener removes it.
            if (ink.getFinishedStrokes().containsKey(id)) {
                ink.removeFinishedStrokes(setOf(id))
            }
        }

        /** Hides the stroke being drawn, leaving the finished ones. */
        fun cancelLive() {
            // A stroke that never got finishStroke would stay on screen
            // forever, so cancel it instead of waiting for a callback.
            if (number != null) ink.cancelUnfinishedStrokes()
            number = null
            strokeId = null
        }

        private fun input(points: InkPoints, index: Int, extraMillis: Long = 0): StrokeInput =
            StrokeInput.create(
                points.xs[index].toFloat(),
                points.ys[index].toFloat(),
                elapsedMillis(points.micros[index]) + extraMillis,
                InputToolType.STYLUS,
                StrokeInput.NO_STROKE_UNIT_LENGTH,
                pressureOf(points.widths[index]),
                StrokeInput.NO_TILT,
                StrokeInput.NO_ORIENTATION,
            )

        /**
         * Adds the points to [into], continuing from its last input or else
         * [after]. Jetpack Ink throws on an input that repeats the one before
         * it, and it sees float positions and whole milliseconds: a resting
         * pen's smoothed points differ by less than that, so those are skipped.
         */
        private fun batch(
            points: InkPoints,
            from: Int,
            until: Int,
            after: StrokeInput?,
            into: MutableStrokeInputBatch = MutableStrokeInputBatch(),
        ): MutableStrokeInputBatch {
            var previous = if (into.size > 0) into.get(into.size - 1) else after
            for (index in from until until) {
                val next = input(points, index)
                if (previous != null &&
                    next.x == previous.x &&
                    next.y == previous.y &&
                    next.elapsedTimeMillis == previous.elapsedTimeMillis
                ) {
                    continue
                }
                into.add(next)
                previous = next
            }
            return into
        }

        private fun elapsedMillis(micros: Long) = ((micros - startMicros) / 1000L).coerceAtLeast(0L)

        private fun pressureOf(widthFactor: Double) = (widthFactor / 2).toFloat().coerceIn(0f, 1f)

        /**
         * The wet ink is only a preview, so a rejected input must not take
         * down the app: the stroke is dropped, and Flutter still draws it.
         */
        private inline fun <T> guarded(block: () -> T): T? = try {
            block()
        } catch (error: RuntimeException) {
            if (!reportedFailure) {
                reportedFailure = true
                android.util.Log.w("NativeInk", "Wet ink preview failed", error)
            }
            ink.cancelUnfinishedStrokes()
            strokeId = null
            null
        }

        private companion object {
            /** Mesh tolerance in physical pixels: finer than the eye can see. */
            const val EPSILON_PX = 0.1
        }
    }
}
