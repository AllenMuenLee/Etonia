package com.etonia.app

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.SurfaceView
import android.widget.FrameLayout
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
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
            overlay?.begin(pointer, previewPoints(event, index, view, includeHistory = false), surface)
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
            overlay?.append(
                stroke.pointer,
                previewPoints(event, index, view, includeHistory = true),
                predictedPreviewPoints(stroke.pointer, view),
                stroke.surface,
            )
        }
        emit(stroke.surface.id, stroke.pointer, "move", stroke.inverted, samples)
    }

    private fun end(event: MotionEvent, view: FlutterView) {
        val stroke = active ?: return
        val index = event.actionIndex
        if (event.getPointerId(index) != stroke.pointer) return
        val samples = samples(event, index, stroke.surface, includeHistory = true)
        if (stroke.surface.previewEnabled && !stroke.inverted && !stroke.previewSuppressed) {
            overlay?.append(
                stroke.pointer,
                previewPoints(event, index, view, includeHistory = true),
                emptyList(),
                stroke.surface,
            )
        }
        emit(stroke.surface.id, stroke.pointer, "up", stroke.inverted, samples)
        active = null
        handler.postDelayed({ overlay?.finish(stroke.pointer) }, PREVIEW_TIMEOUT_MS)
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

    private fun previewPoints(
        event: MotionEvent,
        pointerIndex: Int,
        view: FlutterView,
        includeHistory: Boolean,
    ): List<PreviewPoint> {
        val output = ArrayList<PreviewPoint>(event.historySize + 1)
        val location = IntArray(2)
        view.getLocationInWindow(location)
        if (includeHistory) {
            for (history in 0 until event.historySize) {
                output.add(
                    PreviewPoint(
                        event.getHistoricalX(pointerIndex, history) - location[0],
                        event.getHistoricalY(pointerIndex, history) - location[1],
                        event.getHistoricalPressure(pointerIndex, history).coerceIn(0f, 1f),
                    ),
                )
            }
        }
        output.add(
            PreviewPoint(
                event.getX(pointerIndex) - location[0],
                event.getY(pointerIndex) - location[1],
                event.getPressure(pointerIndex).coerceIn(0f, 1f),
            ),
        )
        return output
    }

    /** Prediction is native-preview-only and is never emitted to Dart. */
    private fun predictedPreviewPoints(pointer: Int, view: FlutterView): List<PreviewPoint> {
        val predicted = predictor?.predict() ?: return emptyList()
        return try {
            val index = predicted.findPointerIndex(pointer)
            if (index < 0) emptyList()
            else previewPoints(predicted, index, view, includeHistory = true)
        } finally {
            predicted.recycle()
        }
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
                    exclusionRects = exclusion,
                )
            }
        }
    }

    private data class PreviewPoint(val x: Float, val y: Float, val pressure: Float)

    private class NativeInkOverlay(context: android.content.Context) : FrameLayout(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        private val actual = ArrayList<PreviewPoint>()
        private val predicted = ArrayList<PreviewPoint>()
        private var pointer: Int? = null
        private var surface: InkSurface? = null
        private var frontRenderer: CanvasFrontBufferedRenderer<PreviewSegment>? = null
        private val frontSurface: SurfaceView? = if (Build.VERSION.SDK_INT >= 29) {
            SurfaceView(context).also { view ->
                view.setZOrderOnTop(true)
                view.holder.setFormat(PixelFormat.TRANSLUCENT)
                view.setBackgroundColor(Color.TRANSPARENT)
                addView(
                    view,
                    LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
                )
            }
        } else null

        init {
            isClickable = false
            isFocusable = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            setWillNotDraw(false)
        }

        override fun onAttachedToWindow() {
            super.onAttachedToWindow()
            if (Build.VERSION.SDK_INT >= 29 && frontRenderer == null) {
                val target = frontSurface ?: return
                frontRenderer = CanvasFrontBufferedRenderer(
                    target,
                    object : CanvasFrontBufferedRenderer.Callback<PreviewSegment> {
                        override fun onDrawFrontBufferedLayer(
                            canvas: Canvas,
                            bufferWidth: Int,
                            bufferHeight: Int,
                            param: PreviewSegment,
                        ) {
                            drawSegment(canvas, param)
                        }

                        override fun onDrawMultiBufferedLayer(
                            canvas: Canvas,
                            bufferWidth: Int,
                            bufferHeight: Int,
                            params: Collection<PreviewSegment>,
                        ) {
                            for (segment in params) drawSegment(canvas, segment)
                        }
                    },
                )
            }
        }

        override fun onDetachedFromWindow() {
            frontRenderer?.release(cancelPending = true, onReleaseComplete = null)
            frontRenderer = null
            super.onDetachedFromWindow()
        }

        fun begin(pointer: Int, incoming: List<PreviewPoint>, surface: InkSurface) {
            this.pointer = pointer
            this.surface = surface
            val dirty = dirtyBounds(actual + predicted, this.surface)
            actual.clear()
            actual.addAll(incoming)
            predicted.clear()
            frontRenderer?.clear()
            renderActual(incoming, surface)
            invalidateDirty(union(dirty, dirtyBounds(actual, surface)))
        }

        fun append(
            pointer: Int,
            incoming: List<PreviewPoint>,
            prediction: List<PreviewPoint>,
            surface: InkSurface,
        ) {
            if (this.pointer != pointer) begin(pointer, incoming, surface)
            else {
                val oldPrediction = dirtyBounds(predicted, this.surface)
                val previous = actual.lastOrNull()
                val added: List<PreviewPoint>
                if (incoming.isNotEmpty() && actual.isNotEmpty() && incoming.first() == actual.last()) {
                    added = incoming.drop(1)
                    actual.addAll(added)
                } else {
                    added = incoming
                    actual.addAll(incoming)
                }
                predicted.clear()
                predicted.addAll(prediction)
                this.surface = surface
                renderActual(
                    if (previous == null) added else listOf(previous) + added,
                    surface,
                )
                val changed = if (previous == null) incoming else listOf(previous) + incoming
                invalidateDirty(
                    union(
                        oldPrediction,
                        union(dirtyBounds(changed, surface), dirtyBounds(predicted, surface)),
                    ),
                )
            }
        }

        fun clear() {
            val dirty = dirtyBounds(actual + predicted, surface)
            this.pointer = null
            surface = null
            actual.clear()
            predicted.clear()
            frontRenderer?.clear()
            invalidateDirty(dirty)
        }

        fun finish(pointer: Int) {
            if (this.pointer == null || this.pointer == pointer) {
                clear()
            }
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val config = surface ?: return
            val points = if (frontRenderer == null) actual + predicted else predicted
            if (points.isEmpty()) return
            paint.color = config.color
            if (points.size == 1) {
                paint.style = Paint.Style.FILL
                val width = widthFor(points[0].pressure, config).toFloat()
                canvas.drawCircle(points[0].x, points[0].y, width / 2f, paint)
                paint.style = Paint.Style.STROKE
                return
            }
            for (index in 1 until points.size) {
                val before = points[index - 1]
                val current = points[index]
                paint.strokeWidth = widthFor((before.pressure + current.pressure) / 2f, config).toFloat()
                val clip = canvas.clipBounds
                val padding = paint.strokeWidth
                if (maxOf(before.x, current.x) + padding < clip.left ||
                    minOf(before.x, current.x) - padding > clip.right ||
                    maxOf(before.y, current.y) + padding < clip.top ||
                    minOf(before.y, current.y) - padding > clip.bottom
                ) continue
                canvas.drawLine(before.x, before.y, current.x, current.y, paint)
            }
        }

        private fun renderActual(points: List<PreviewPoint>, surface: InkSurface) {
            val renderer = frontRenderer ?: return
            if (points.size == 1) {
                renderer.renderFrontBufferedLayer(PreviewSegment(points[0], points[0], surface))
                return
            }
            for (index in 1 until points.size) {
                renderer.renderFrontBufferedLayer(
                    PreviewSegment(points[index - 1], points[index], surface),
                )
            }
        }

        private fun drawSegment(canvas: Canvas, segment: PreviewSegment) {
            val before = segment.before
            val current = segment.current
            paint.color = segment.surface.color
            if (before == current) {
                paint.style = Paint.Style.FILL
                val width = widthFor(current.pressure, segment.surface).toFloat()
                canvas.drawCircle(current.x, current.y, width / 2f, paint)
                paint.style = Paint.Style.STROKE
            } else {
                paint.strokeWidth = widthFor(
                    (before.pressure + current.pressure) / 2f,
                    segment.surface,
                ).toFloat()
                canvas.drawLine(before.x, before.y, current.x, current.y, paint)
            }
        }

        private fun dirtyBounds(points: List<PreviewPoint>, surface: InkSurface?): RectF? {
            if (points.isEmpty() || surface == null) return null
            var left = points.first().x
            var top = points.first().y
            var right = left
            var bottom = top
            var widest = 0f
            for (point in points) {
                left = minOf(left, point.x)
                top = minOf(top, point.y)
                right = maxOf(right, point.x)
                bottom = maxOf(bottom, point.y)
                widest = maxOf(widest, widthFor(point.pressure, surface).toFloat())
            }
            return RectF(left - widest, top - widest, right + widest, bottom + widest)
        }

        private fun union(a: RectF?, b: RectF?): RectF? = when {
            a == null -> b
            b == null -> a
            else -> RectF(a).apply { union(b) }
        }

        private fun invalidateDirty(rect: RectF?) {
            if (rect == null) return
            invalidate(
                kotlin.math.floor(rect.left.toDouble()).toInt(),
                kotlin.math.floor(rect.top.toDouble()).toInt(),
                kotlin.math.ceil(rect.right.toDouble()).toInt(),
                kotlin.math.ceil(rect.bottom.toDouble()).toInt(),
            )
        }

        private fun widthFor(pressure: Float, surface: InkSurface): Double {
            val pressureFactor = 1.0 + surface.pressureSensitivity * 0.75 * (2.0 * pressure - 1.0)
            return (surface.strokeWidth * surface.scale * resources.displayMetrics.density * pressureFactor)
                .coerceAtLeast(0.5)
        }

        private data class PreviewSegment(
            val before: PreviewPoint,
            val current: PreviewPoint,
            val surface: InkSurface,
        )
    }
}
