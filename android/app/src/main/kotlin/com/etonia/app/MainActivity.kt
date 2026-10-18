package com.etonia.app

import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var handwritingRecognizer: HandwritingRecognizerChannel? = null
    private var nativeInk: NativeInkChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        handwritingRecognizer =
            HandwritingRecognizerChannel(flutterEngine.dartExecutor.binaryMessenger)
        nativeInk = NativeInkChannel(flutterEngine.dartExecutor.binaryMessenger, this)
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
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
