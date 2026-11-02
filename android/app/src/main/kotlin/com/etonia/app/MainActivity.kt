package com.etonia.app

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var handwritingRecognizer: HandwritingRecognizerChannel? = null
    private var nativeInk: NativeInkChannel? = null
    private var sharedDocuments: SharedDocumentChannel? = null
    private var recordingTranscriber: RecordingTranscriberChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Flutter hides the status bar through the legacy visibility flags,
        // which leave the bars' behavior at "default", and Android fades bars
        // with that behavior in place. With transient behavior it slides them
        // off the edge instead, as when a note opens. Setting it explicitly
        // marks it as app-controlled, so later legacy flags don't reset it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        handwritingRecognizer =
            HandwritingRecognizerChannel(flutterEngine.dartExecutor.binaryMessenger)
        nativeInk = NativeInkChannel(flutterEngine.dartExecutor.binaryMessenger, this)
        recordingTranscriber = RecordingTranscriberChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
        sharedDocuments = SharedDocumentChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        ).also { it.handleIntent(intent) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sharedDocuments?.handleIntent(intent)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // Observe first, but never consume: Flutter still owns fingers and all
        // non-writing UI gestures.
        nativeInk?.observeStylusButtons(event)
        nativeInk?.observe(event)
        return super.dispatchTouchEvent(event)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (nativeInk?.observeStylusKey(event) == true) return true
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        nativeInk?.observeStylusButtons(event)
        if (event.actionMasked == MotionEvent.ACTION_HOVER_EXIT && isPen(event)) {
            parkPenHover(event)
        }
        return super.dispatchGenericMotionEvent(event)
    }

    // Flutter's embedding drops ACTION_HOVER_EXIT, so a pen lifted out of
    // range straight up from a button stays "hovering" it, and its tooltip
    // and hover highlight never go away. Move the hover far off the view
    // instead: Flutter then sends the exits it would have sent.
    private fun parkPenHover(event: MotionEvent) {
        val flutterView = findViewById<View>(FLUTTER_VIEW_ID) ?: return
        val parked = MotionEvent.obtain(event)
        parked.action = MotionEvent.ACTION_HOVER_MOVE
        parked.setLocation(-100_000f, -100_000f)
        flutterView.onGenericMotionEvent(parked)
        parked.recycle()
    }

    private fun isPen(event: MotionEvent): Boolean {
        val tool = event.getToolType(event.actionIndex)
        return tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        handwritingRecognizer?.dispose()
        handwritingRecognizer = null
        nativeInk?.dispose()
        nativeInk = null
        sharedDocuments?.dispose()
        sharedDocuments = null
        recordingTranscriber?.dispose()
        recordingTranscriber = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
