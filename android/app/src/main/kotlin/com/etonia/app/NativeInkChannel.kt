package com.etonia.app

import android.app.Activity
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.ink.authoring.InProgressStrokeId
import androidx.ink.authoring.InProgressStrokesFinishedListener
import androidx.ink.authoring.InProgressStrokesView
import androidx.ink.brush.Brush
import androidx.ink.brush.BrushFamily
import androidx.ink.brush.StockBrushes
import androidx.ink.strokes.Stroke
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
        private const val PREVIEW_TIMEOUT_MS = 160L
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val surfaces = LinkedHashMap<Int, InkSurface>()
    private val handler = Handler(Looper.getMainLooper())
    private var flutterView: FlutterView? = null
    private var overlay: NativeInkOverlay? = null
    private var active: ActiveStroke? = null
    private var predictor: MotionEventPredictor? = null

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
                if (!surface.enabled || !surface.previewEnabled) {
                    active?.takeIf { it.surface.id == surface.id }?.let {
                        it.previewSuppressed = true
                    }
                    overlay?.clear()
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
                val pointer = argumentInt(call.arguments, "pointer")
                if (pointer != null) {
                    active?.takeIf { it.pointer == pointer }?.previewSuppressed = true
                    overlay?.finish(pointer)
                } else {
                    active = null
                    overlay?.clear()
                }
                result.success(null)
            }
            "clearAllPreviews" -> {
                active = null
                overlay?.clear()
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

    fun dispose() {
        cancelActive(sendPacket = false)
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
        active = ActiveStroke(surface, pointer, inverted)
        view.requestUnbufferedDispatch(event)
        val samples = samples(event, index, surface, includeHistory = false)
        if (surface.previewEnabled && !inverted) {
            overlay?.begin(pointer, event, surface, view)
        }
        emit(surface.id, pointer, "down", inverted, samples)
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
        if (stroke.surface.previewEnabled && !stroke.inverted && !stroke.previewSuppressed) {
            val predicted = predictor?.predict()
            try {
                overlay?.append(stroke.pointer, event, predicted)
            } finally {
                predicted?.recycle()
            }
        }
        emit(stroke.surface.id, stroke.pointer, "move", stroke.inverted, samples)
    }

    private fun end(event: MotionEvent, view: FlutterView) {
        val stroke = active ?: return
        val index = event.actionIndex
        if (event.getPointerId(index) != stroke.pointer) return
        val samples = samples(event, index, stroke.surface, includeHistory = true)
        var strokeId: InProgressStrokeId? = null
        if (stroke.surface.previewEnabled && !stroke.inverted && !stroke.previewSuppressed) {
            strokeId = overlay?.end(stroke.pointer, event)
        }
        emit(stroke.surface.id, stroke.pointer, "up", stroke.inverted, samples)
        active = null
        handler.postDelayed({ overlay?.finish(stroke.pointer, strokeId) }, PREVIEW_TIMEOUT_MS)
    }

    private fun cancelActive(sendPacket: Boolean) {
        val stroke = active ?: return
        active = null
        overlay?.finish(stroke.pointer)
        if (sendPacket) {
            emit(stroke.surface.id, stroke.pointer, "cancel", stroke.inverted, emptyList())
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

    private data class ActiveStroke(
        val surface: InkSurface,
        val pointer: Int,
        val inverted: Boolean,
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
        val stabilization: Double,
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
                    pressureSensitivity = number("pressureSensitivity") ?: 0.0,
                    stabilization = number("stabilization")?.coerceIn(0.0, 1.0) ?: 0.0,
                    writingStyle = arguments["writingStyle"] as? String ?: "pen",
                    exclusionRects = exclusion,
                )
            }
        }
    }

    /** Jetpack Ink's authoring view owns wet-ink modeling and low-latency rendering. */
    private class NativeInkOverlay(context: android.content.Context) : FrameLayout(context) {
        private val ink = InProgressStrokesView(context)
        private var pointer: Int? = null
        private var strokeId: InProgressStrokeId? = null
        private var strokeEnded = false
        private val removeWhenFinished = HashSet<InProgressStrokeId>()
        private val families = HashMap<FamilyKey, BrushFamily>()

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
                        val removable = strokes.keys.filterTo(HashSet()) {
                            removeWhenFinished.remove(it)
                        }
                        if (removable.isNotEmpty()) ink.removeFinishedStrokes(removable)
                    }
                },
            )
        }

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            // Avoid a visible first-stroke initialization hitch.
            ink.eagerInit()
        }

        fun begin(pointer: Int, event: MotionEvent, surface: InkSurface, source: View) {
            clear()
            this.pointer = pointer
            val location = IntArray(2)
            source.getLocationInWindow(location)
            val motionToWorld = Matrix().apply {
                setTranslate(-location[0].toFloat(), -location[1].toFloat())
            }
            strokeId = ink.startStroke(
                event,
                pointer,
                brushFor(surface),
                motionToWorld,
                Matrix(),
            )
        }

        fun append(pointer: Int, event: MotionEvent, prediction: MotionEvent?) {
            val id = strokeId ?: return
            if (this.pointer != pointer) return
            ink.addToStroke(event, pointer, id, prediction)
        }

        /** Returns the id of the stroke that was finished, for a targeted [finish]. */
        fun end(pointer: Int, event: MotionEvent): InProgressStrokeId? {
            val id = strokeId ?: return null
            if (this.pointer != pointer) return null
            ink.finishStroke(event, pointer, id)
            strokeEnded = true
            return id
        }

        /**
         * Hides the stroke. [only] pins the call to one stroke so a delayed
         * finish cannot hit a newer stroke that reuses the same pointer id.
         */
        fun finish(pointer: Int, only: InProgressStrokeId? = null) {
            if (only != null && only != strokeId) {
                release(only)
                return
            }
            if (only == null && this.pointer != null && this.pointer != pointer) return
            val id = strokeId
            if (id != null) {
                // A stroke that never got finishStroke would stay on screen
                // forever, so cancel it instead of waiting for a callback.
                if (strokeEnded) release(id) else ink.cancelUnfinishedStrokes()
            }
            this.pointer = null
            strokeId = null
            strokeEnded = false
        }

        private fun release(id: InProgressStrokeId) {
            if (ink.getFinishedStrokes().containsKey(id)) {
                ink.removeFinishedStrokes(setOf(id))
            } else {
                removeWhenFinished.add(id)
            }
        }

        fun clear() {
            ink.cancelUnfinishedStrokes()
            val finished = ink.getFinishedStrokes().keys.toSet()
            if (finished.isNotEmpty()) ink.removeFinishedStrokes(finished)
            removeWhenFinished.clear()
            pointer = null
            strokeId = null
            strokeEnded = false
        }

        private fun brushFor(surface: InkSurface): Brush {
            val windowMillis = if (surface.stabilization <= 0.001) {
                0
            } else {
                // 0-32 ms keeps the low end nearly raw while making the top
                // of the existing meter visibly steady. Prediction masks most
                // of the added visual lag.
                kotlin.math.ceil(surface.stabilization * 32.0).toInt()
            }
            val pressure = surface.pressureSensitivity > 0.001
            val key = FamilyKey(surface.writingStyle, pressure, windowMillis)
            val family = families.getOrPut(key) {
                val stock = when {
                    surface.writingStyle == "highlighter" -> StockBrushes.highlighter()
                    pressure -> StockBrushes.pressurePen()
                    else -> StockBrushes.marker()
                }
                val inputModel = if (windowMillis == 0) {
                    BrushFamily.InputModel.PASSTHROUGH_MODEL
                } else {
                    BrushFamily.InputModel.SlidingWindowModel(windowMillis.toLong(), 240)
                }
                stock.toBuilder().setInputModel(inputModel).build()
            }
            val physicalWidth = (
                surface.strokeWidth * surface.scale * resources.displayMetrics.density
            ).toFloat().coerceAtLeast(0.5f)
            return Brush.createWithColorIntArgb(
                family,
                surface.color,
                physicalWidth,
                0.1f,
            )
        }

        private data class FamilyKey(
            val writingStyle: String,
            val pressure: Boolean,
            val windowMillis: Int,
        )
    }
}
