package com.greatnote.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var handwritingRecognizer: HandwritingRecognizerChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        handwritingRecognizer =
            HandwritingRecognizerChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        handwritingRecognizer?.dispose()
        handwritingRecognizer = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
