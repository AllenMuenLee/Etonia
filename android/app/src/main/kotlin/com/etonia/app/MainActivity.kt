package com.etonia.app

import android.content.Intent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var handwritingRecognizer: HandwritingRecognizerChannel? = null
    private var nativeInk: NativeInkChannel? = null
    private var sharedDocuments: SharedDocumentChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        handwritingRecognizer =
            HandwritingRecognizerChannel(flutterEngine.dartExecutor.binaryMessenger)
        nativeInk = NativeInkChannel(flutterEngine.dartExecutor.binaryMessenger, this)
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
        nativeInk?.observe(event)
        return super.dispatchTouchEvent(event)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        handwritingRecognizer?.dispose()
        handwritingRecognizer = null
        nativeInk?.dispose()
        nativeInk = null
        sharedDocuments?.dispose()
        sharedDocuments = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
