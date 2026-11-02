package com.etonia.app

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/*
 * A line-for-line port of the Flutter pen model, so the native wet ink has
 * the very geometry of the stroke Flutter commits when the pen lifts:
 *
 *  - InkSmoothing      <- lib/features/editor/ink/smoothing_config.dart
 *  - InkSmoother       <- lib/features/editor/ink/one_euro_smoother.dart
 *  - InkStrokeModel    <- ActiveStroke and StrokeDynamics in stroke.dart
 *  - InkFlattener      <- _smoothInkSamples and _flattenInkQuadratic there
 *
 * Arithmetic is kept in the same order as the Dart so results agree to the
 * last bit or so. Change both together; test/fixtures/native_ink_parity.txt
 * is checked by Dart and by NativeInkModelTest.
 *
 * Plain Kotlin with no Android types, so it runs in JVM unit tests.
 */

/** The One Euro tuning for one stroke, stabilization already applied. */
data class InkSmoothing(
    val minCutoff: Double = 1.0,
    val beta: Double = 0.02,
    val derivativeCutoff: Double = 1.0,
    val minDtSeconds: Double = 0.001,
    val maxDtSeconds: Double = 0.1,
    val maxFinalizationPoints: Int = 8,
    val finalizationSpacing: Double = 2.0,
    val endpointTolerance: Double = 0.01,
    val slowSpeed: Double = 120.0,
    val fastSpeed: Double = 400.0,
    val slowCutoffScale: Double = 1.0,
) {
    fun cutoffScaleAt(speed: Double): Double {
        if (slowCutoffScale == 1.0 || speed >= fastSpeed) return 1.0
        if (speed <= slowSpeed) return slowCutoffScale
        val t = (speed - slowSpeed) / (fastSpeed - slowSpeed)
        return slowCutoffScale + (1 - slowCutoffScale) * t * t * (3 - 2 * t)
    }

    companion object {
        fun from(value: Any?): InkSmoothing {
            val map = value as? Map<*, *> ?: return InkSmoothing()
            fun number(key: String) = (map[key] as? Number)?.toDouble()
            val d = InkSmoothing()
            return InkSmoothing(
                minCutoff = number("minCutoff") ?: d.minCutoff,
                beta = number("beta") ?: d.beta,
                derivativeCutoff = number("derivativeCutoff") ?: d.derivativeCutoff,
                minDtSeconds = number("minDtSeconds") ?: d.minDtSeconds,
                maxDtSeconds = number("maxDtSeconds") ?: d.maxDtSeconds,
                maxFinalizationPoints = number("maxFinalizationPoints")?.toInt()
                    ?: d.maxFinalizationPoints,
                finalizationSpacing = number("finalizationSpacing") ?: d.finalizationSpacing,
                endpointTolerance = number("endpointTolerance") ?: d.endpointTolerance,
                slowSpeed = number("slowSpeed") ?: d.slowSpeed,
                fastSpeed = number("fastSpeed") ?: d.fastSpeed,
                slowCutoffScale = number("slowCutoffScale") ?: d.slowCutoffScale,
            )
        }
    }
}

/** The One Euro filter, as OneEuroSmoother. */
class InkSmoother(private val config: InkSmoothing) {
    private var started = false
    private var lastRawX = 0.0
    private var lastRawY = 0.0
    private var lastTimestamp = 0L
    private var derivX = 0.0
    private var derivY = 0.0

    /** The latest filtered point. */
    var outX = 0.0
        private set
    var outY = 0.0
        private set

    /** An independent smoother in this one's state, for trying out guesses. */
    fun copy() = InkSmoother(config).also {
        it.started = started
        it.lastRawX = lastRawX
        it.lastRawY = lastRawY
        it.lastTimestamp = lastTimestamp
        it.outX = outX
        it.outY = outY
        it.derivX = derivX
        it.derivY = derivY
    }

    fun start(x: Double, y: Double, micros: Long) {
        started = true
        lastRawX = x
        lastRawY = y
        lastTimestamp = micros
        outX = x
        outY = y
        derivX = 0.0
        derivY = 0.0
    }

    /** Filters one sample; false, and nothing changes, for a non-finite one. */
    fun add(x: Double, y: Double, micros: Long): Boolean {
        if (!x.isFinite() || !y.isFinite()) return false
        val dt = ((micros - lastTimestamp).toDouble() / 1_000_000.0)
            .coerceIn(config.minDtSeconds, config.maxDtSeconds)
        lastRawX = x
        lastRawY = y
        if (micros > lastTimestamp) lastTimestamp = micros

        val deltaX = x - outX
        val deltaY = y - outY
        if (!deltaX.isFinite() || !deltaY.isFinite()) {
            outX = x
            outY = y
            derivX = 0.0
            derivY = 0.0
            return true
        }
        val inverse = 1 / dt
        val derivativeX = deltaX * inverse
        val derivativeY = deltaY * inverse
        val derivativeAlpha = alpha(dt, config.derivativeCutoff)
        derivX += (derivativeX - derivX) * derivativeAlpha
        derivY += (derivativeY - derivY) * derivativeAlpha

        val speed = magnitude(derivX, derivY)
        val cutoff = (
            if (config.beta == 0.0) config.minCutoff else config.minCutoff + config.beta * speed
            ) * config.cutoffScaleAt(speed)
        val positionAlpha = alpha(dt, cutoff)
        val nextX = outX + deltaX * positionAlpha
        val nextY = outY + deltaY * positionAlpha
        if (nextX.isFinite() && nextY.isFinite()) {
            outX = nextX
            outY = nextY
        }
        return true
    }

    /** The eased tail ending at the last raw sample, as x0, y0, x1, y1, ... */
    fun finish(): DoubleArray {
        if (!started) return DoubleArray(0)
        val fromX = outX
        val fromY = outY
        val residualX = lastRawX - fromX
        val residualY = lastRawY - fromY
        val distance = magnitude(residualX, residualY)
        if (distance <= config.endpointTolerance) return DoubleArray(0)
        if (!distance.isFinite()) {
            outX = lastRawX
            outY = lastRawY
            derivX = 0.0
            derivY = 0.0
            return doubleArrayOf(lastRawX, lastRawY)
        }
        val count = ceil(distance / config.finalizationSpacing).toInt()
            .coerceIn(1, config.maxFinalizationPoints)
        val tail = DoubleArray(count * 2)
        for (i in 1 until count) {
            val t = i.toDouble() / count
            val eased = 1 - (1 - t) * (1 - t)
            tail[(i - 1) * 2] = fromX + residualX * eased
            tail[(i - 1) * 2 + 1] = fromY + residualY * eased
        }
        tail[(count - 1) * 2] = lastRawX
        tail[(count - 1) * 2 + 1] = lastRawY
        outX = lastRawX
        outY = lastRawY
        derivX = 0.0
        derivY = 0.0
        return tail
    }

    private companion object {
        fun alpha(dt: Double, cutoff: Double): Double {
            val scaled = 2 * Math.PI * cutoff * dt
            if (scaled.isInfinite()) return 1.0
            return scaled / (1 + scaled)
        }

        fun magnitude(x0: Double, y0: Double): Double {
            val x = abs(x0)
            val y = abs(y0)
            val scale = max(x, y)
            if (scale == 0.0 || scale.isInfinite()) return scale
            val sx = x / scale
            val sy = y / scale
            return scale * sqrt(sx * sx + sy * sy)
        }
    }
}

/** A growable run of points, each with a width factor and a time. */
class InkPoints(capacity: Int = 64) {
    var xs = DoubleArray(capacity)
        private set
    var ys = DoubleArray(capacity)
        private set
    var widths = DoubleArray(capacity)
        private set
    var micros = LongArray(capacity)
        private set
    var size = 0
        private set

    fun add(x: Double, y: Double, width: Double, time: Long) {
        if (size == xs.size) {
            val grown = size * 2
            xs = xs.copyOf(grown)
            ys = ys.copyOf(grown)
            widths = widths.copyOf(grown)
            micros = micros.copyOf(grown)
        }
        xs[size] = x
        ys[size] = y
        widths[size] = width
        micros[size] = time
        size++
    }

    fun clear() {
        size = 0
    }
}

/**
 * Turns the stroke's points into the flattened curve Flutter paints: quadratic
 * Beziers between midpoints, cut until the centerline is within 1/8 px and
 * the width factor within 0.005. Points are pushed one at a time; each push
 * emits only the part of the curve that later points can no longer change.
 */
class InkFlattener private constructor(
    private var count: Int,
    private var startX: Double,
    private var startY: Double,
    private var startW: Double,
    private var prevX: Double,
    private var prevY: Double,
    private var prevW: Double,
    private var prevT: Long,
    private var lastX: Double,
    private var lastY: Double,
) {
    constructor() : this(0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0L, Double.NaN, Double.NaN)

    fun copy() = InkFlattener(count, startX, startY, startW, prevX, prevY, prevW, prevT, lastX, lastY)

    fun push(x: Double, y: Double, w: Double, t: Long, out: InkPoints) {
        if (count == 0) {
            emit(x, y, w, t, out)
            startX = x
            startY = y
            startW = w
        } else if (count >= 2) {
            val endX = (prevX + x) * 0.5
            val endY = (prevY + y) * 0.5
            val endW = (prevW + w) * 0.5
            flatten(startX, startY, startW, prevX, prevY, prevW, endX, endY, endW, prevT, out, 0)
            startX = endX
            startY = endY
            startW = endW
        }
        prevX = x
        prevY = y
        prevW = w
        prevT = t
        count++
    }

    /** The straight run from the curve so far to the newest point. */
    fun tail(out: InkPoints) {
        if (count >= 2) emit(prevX, prevY, prevW, prevT, out)
    }

    private fun emit(x: Double, y: Double, w: Double, t: Long, out: InkPoints) {
        if (x == lastX && y == lastY) return
        lastX = x
        lastY = y
        out.add(x, y, w, t)
    }

    private fun flatten(
        sx: Double, sy: Double, sw: Double,
        cx: Double, cy: Double, cw: Double,
        ex: Double, ey: Double, ew: Double,
        t: Long, out: InkPoints, depth: Int,
    ) {
        val chordX = ex - sx
        val chordY = ey - sy
        val chordLength = sqrt(chordX * chordX + chordY * chordY)
        val centerlineError = if (chordLength == 0.0) {
            sqrt((cx - sx) * (cx - sx) + (cy - sy) * (cy - sy))
        } else {
            abs((cx - sx) * chordY - (cy - sy) * chordX) / chordLength
        }
        val widthError = abs(cw - (sw + ew) * 0.5)
        if (depth >= MAX_DEPTH ||
            (centerlineError <= MAX_CENTERLINE_ERROR && widthError <= MAX_WIDTH_ERROR)
        ) {
            emit(ex, ey, ew, t, out)
            return
        }
        val scX = (sx + cx) * 0.5
        val scY = (sy + cy) * 0.5
        val ceX = (cx + ex) * 0.5
        val ceY = (cy + ey) * 0.5
        val mX = (scX + ceX) * 0.5
        val mY = (scY + ceY) * 0.5
        val scW = (sw + cw) * 0.5
        val ceW = (cw + ew) * 0.5
        val mW = (scW + ceW) * 0.5
        flatten(sx, sy, sw, scX, scY, scW, mX, mY, mW, t, out, depth + 1)
        flatten(mX, mY, mW, ceX, ceY, ceW, ex, ey, ew, t, out, depth + 1)
    }

    private companion object {
        const val MAX_CENTERLINE_ERROR = 0.125
        const val MAX_WIDTH_ERROR = 0.005
        const val MAX_DEPTH = 7
    }
}

/**
 * The stroke being drawn, as Flutter's ActiveStroke: smoothed points, each
 * with the width factor of its eased pressure and the tapered start, and on
 * [finish] both ends tapered as the committed stroke is. [width] is in canvas
 * pixels; [taper] and [pressure] are StrokeDynamics, both 0 for an even line.
 */
class InkStrokeModel(
    private val width: Double,
    private val taper: Double,
    private val pressure: Double,
    smoothing: InkSmoothing,
) {
    private val smoother = InkSmoother(smoothing)
    private val dynamic = taper != 0.0 || pressure != 0.0
    private val taperLength = width * (1 + 7 * taper)
    private val tipFraction = 1 - 0.85 * taper

    /** The smoothed points; widths hold the pressure factor alone. */
    val points = InkPoints()
    private val distances = InkPoints()
    private var length = 0.0
    private var pressureState = NEUTRAL_PRESSURE
    private var lastTime = 0L
    private var maxDistanceFromOrigin = 0.0

    /** The flattened curve so far that later samples cannot change. */
    val stable = InkPoints()
    private val flattener = InkFlattener()

    val isDot get() = maxDistanceFromOrigin < DOT_EXTENT

    /**
     * Whether [finish] changes points already drawn: the ends taper only
     * once the stroke's length is known, and a dot is drawn at full width.
     * Otherwise the finished stroke is [stable] and [liveTail] after it.
     */
    val finishReshapes get() = dynamic && (taper != 0.0 || isDot)

    fun start(x: Double, y: Double, micros: Long, reading: Double?) {
        smoother.start(x, y, micros)
        lastTime = micros
        pressureState = reading ?: NEUTRAL_PRESSURE
        val factor = pressureFactor(pressureState)
        points.add(x, y, factor, micros)
        distances.add(0.0, 0.0, 0.0, micros)
        flattener.push(x, y, factor * taperAt(0.0, taperLength), micros, stable)
    }

    /** Returns whether the stroke changed. */
    fun add(x: Double, y: Double, micros: Long, reading: Double?): Boolean {
        if (!smoother.add(x, y, micros)) return false
        if (reading != null) pressureState += (reading - pressureState) * PRESSURE_SMOOTHING
        if (micros > lastTime) lastTime = micros
        return append(smoother.outX, smoother.outY, lastTime)
    }

    private fun append(x: Double, y: Double, time: Long): Boolean {
        val last = points.size - 1
        val lx = points.xs[last]
        val ly = points.ys[last]
        if (x == lx && y == ly) return false
        length += sqrt((x - lx) * (x - lx) + (y - ly) * (y - ly))
        val factor = pressureFactor(pressureState)
        points.add(x, y, factor, time)
        distances.add(length, 0.0, 0.0, time)
        val ox = points.xs[0]
        val oy = points.ys[0]
        val fromOrigin = sqrt((x - ox) * (x - ox) + (y - oy) * (y - oy))
        if (fromOrigin > maxDistanceFromOrigin) maxDistanceFromOrigin = fromOrigin
        flattener.push(x, y, factor * taperAt(length, taperLength), time, stable)
        return true
    }

    /**
     * The curve past [stable]: up to the newest point, then on through
     * [predicted] samples (x, y, time-us, pressure or NaN), filtered by a
     * copy of the smoother so the guess bends as the real line will.
     */
    fun liveTail(predicted: List<DoubleArray> = emptyList()): InkPoints {
        val out = InkPoints(8 + predicted.size * 4)
        val flat = flattener.copy()
        if (predicted.isNotEmpty() && points.size > 0) {
            val guess = smoother.copy()
            var reading = pressureState
            var distance = length
            var time = lastTime
            var lx = points.xs[points.size - 1]
            var ly = points.ys[points.size - 1]
            for (sample in predicted) {
                val micros = sample[2].toLong()
                if (!guess.add(sample[0], sample[1], micros)) continue
                if (!sample[3].isNaN()) reading += (sample[3] - reading) * PRESSURE_SMOOTHING
                if (micros > time) time = micros
                val x = guess.outX
                val y = guess.outY
                if (x == lx && y == ly) continue
                distance += sqrt((x - lx) * (x - lx) + (y - ly) * (y - ly))
                lx = x
                ly = y
                flat.push(x, y, pressureFactor(reading) * taperAt(distance, taperLength), time, out)
            }
        }
        flat.tail(out)
        return out
    }

    /**
     * Ends the stroke as Flutter's ActiveStroke.finish does and returns the
     * whole flattened curve with its final widths. A dot is one point at
     * full width, as Flutter paints it.
     */
    fun finish(): InkPoints {
        val tail = smoother.finish()
        var i = 0
        while (i < tail.size) {
            append(tail[i], tail[i + 1], lastTime)
            i += 2
        }
        val out = InkPoints(points.size * 2)
        if (isDot) {
            out.add(points.xs[0], points.ys[0], 1.0, points.micros[0])
            return out
        }
        val ends = min(taperLength, length * 0.4)
        val flat = InkFlattener()
        for (index in 0 until points.size) {
            val d = distances.xs[index]
            val w = if (dynamic) {
                points.widths[index] * taperAt(d, ends) * taperAt(length - d, ends)
            } else {
                1.0
            }
            flat.push(points.xs[index], points.ys[index], w, points.micros[index], out)
        }
        flat.tail(out)
        return out
    }

    private fun pressureFactor(reading: Double): Double {
        if (!dynamic) return 1.0
        return 1 + pressure * 0.75 * (2 * reading.coerceIn(0.0, 1.0) - 1)
    }

    private fun taperAt(distance: Double, length: Double): Double {
        if (!dynamic || taper == 0.0 || length <= 0 || distance >= length) return 1.0
        val t = (distance / length).coerceIn(0.0, 1.0)
        val eased = t * (2 - t)
        return tipFraction + (1 - tipFraction) * eased
    }

    private companion object {
        const val NEUTRAL_PRESSURE = 0.5
        const val PRESSURE_SMOOTHING = 0.3
        const val DOT_EXTENT = 0.01
    }
}
