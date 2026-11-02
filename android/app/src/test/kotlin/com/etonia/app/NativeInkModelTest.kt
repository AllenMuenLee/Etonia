package com.etonia.app

import java.io.File
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wet ink must be the stroke Flutter commits. Flutter's pen model wrote
 * test/fixtures/native_ink_parity.txt (see native_ink_parity_test.dart);
 * this runs the same samples through the Kotlin port.
 */
class NativeInkModelTest {
    private class Case(
        val name: String,
        val smoothing: InkSmoothing,
        val width: Double,
        val taper: Double,
        val pressure: Double,
        val samples: List<DoubleArray>,
        val live: List<DoubleArray>,
        val final: List<DoubleArray>,
        val dot: Boolean,
    )

    @Test
    fun matchesFlutterAcrossThePenSettings() {
        val cases = load()
        assertTrue("fixture has no cases", cases.size >= 8)
        for (case in cases) {
            val model = InkStrokeModel(case.width, case.taper, case.pressure, case.smoothing)
            val first = case.samples.first()
            model.start(first[0], first[1], first[2].toLong(), first[3])
            for (sample in case.samples.drop(1)) {
                model.add(sample[0], sample[1], sample[2].toLong(), sample[3])
            }

            val live = ArrayList<DoubleArray>()
            collect(model.stable, live)
            collect(model.liveTail(), live)
            expectPoints("${case.name} while drawing", case.live, live)

            val final = ArrayList<DoubleArray>()
            collect(model.finish(), final)
            expectPoints("${case.name} once lifted", case.final, final)
            assertEquals("${case.name} dot", case.dot, model.isDot)
        }
    }

    @Test
    fun aStrokeFinishedInPlaceIsTheCommittedStroke() {
        var inPlace = 0
        for (case in load()) {
            val model = InkStrokeModel(case.width, case.taper, case.pressure, case.smoothing)
            val first = case.samples.first()
            model.start(first[0], first[1], first[2].toLong(), first[3])
            for (sample in case.samples.drop(1)) {
                model.add(sample[0], sample[1], sample[2].toLong(), sample[3])
            }
            model.finish()
            if (model.finishReshapes) continue
            inPlace++
            // What the overlay draws when it finishes the stroke in place.
            val drawn = ArrayList<DoubleArray>()
            collect(model.stable, drawn)
            collect(model.liveTail(), drawn)
            expectPoints("${case.name} finished in place", case.final, drawn)
        }
        assertTrue("some cases finish in place", inPlace >= 3)
    }

    @Test
    fun predictionContinuesTheCurveWithoutDisturbingIt() {
        val case = load().first { it.name == "full-everything" }
        val model = InkStrokeModel(case.width, case.taper, case.pressure, case.smoothing)
        val half = case.samples.size / 2
        val first = case.samples.first()
        model.start(first[0], first[1], first[2].toLong(), first[3])
        for (sample in case.samples.subList(1, half)) {
            model.add(sample[0], sample[1], sample[2].toLong(), sample[3])
        }
        val before = model.stable.size
        val guessed = model.liveTail(case.samples.subList(half, half + 6))
        assertTrue("prediction adds points", guessed.size > 1)
        assertEquals("prediction leaves the model alone", before, model.stable.size)
        // The real samples arrive afterwards and still match Flutter.
        for (sample in case.samples.subList(half, case.samples.size)) {
            model.add(sample[0], sample[1], sample[2].toLong(), sample[3])
        }
        val final = ArrayList<DoubleArray>()
        collect(model.finish(), final)
        expectPoints("after prediction", case.final, final)
    }

    private fun collect(points: InkPoints, into: MutableList<DoubleArray>) {
        for (i in 0 until points.size) {
            into.add(doubleArrayOf(points.xs[i], points.ys[i], points.widths[i]))
        }
    }

    private fun expectPoints(label: String, expected: List<DoubleArray>, actual: List<DoubleArray>) {
        assertEquals("$label: point count", expected.size, actual.size)
        for (i in expected.indices) {
            for (axis in 0 until 3) {
                val e = expected[i][axis]
                val a = actual[i][axis]
                assertTrue(
                    "$label: point $i axis $axis is $a, Flutter has $e",
                    abs(e - a) <= 1e-9 * maxOf(1.0, abs(e)),
                )
            }
        }
    }

    private fun load(): List<Case> {
        val file = listOf(
            File("../../test/fixtures/native_ink_parity.txt"),
            File("test/fixtures/native_ink_parity.txt"),
        ).first { it.exists() }
        val lines = file.readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
        val cases = ArrayList<Case>()
        var i = 0
        fun numbers(line: String) = line.split(' ').drop(1).map { it.toDouble() }
        fun block(header: String): List<DoubleArray> {
            val parts = lines[i].split(' ')
            check(parts[0] == header) { "expected $header at ${lines[i]}" }
            val count = parts[1].toInt()
            i++
            val rows = (0 until count).map { k ->
                lines[i + k].split(' ').map { it.toDouble() }.toDoubleArray()
            }
            i += count
            return rows
        }
        while (i < lines.size) {
            val name = lines[i++].removePrefix("case ")
            val s = numbers(lines[i++])
            val smoothing = InkSmoothing(
                minCutoff = s[0],
                beta = s[1],
                derivativeCutoff = s[2],
                minDtSeconds = s[3],
                maxDtSeconds = s[4],
                maxFinalizationPoints = s[5].toInt(),
                finalizationSpacing = s[6],
                endpointTolerance = s[7],
                slowSpeed = s[8],
                fastSpeed = s[9],
                slowCutoffScale = s[10],
            )
            val pen = numbers(lines[i++])
            val samples = block("samples")
            val live = block("live")
            val final = block("final")
            val dot = lines[i++] == "dot 1"
            cases.add(Case(name, smoothing, pen[0], pen[1], pen[2], samples, live, final, dot))
        }
        return cases
    }
}
