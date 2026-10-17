import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var handwritingRecognizer: HandwritingRecognizerChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "GreatnoteHandwritingRecognizer")
    {
      handwritingRecognizer = HandwritingRecognizerChannel(messenger: registrar.messenger())
    }
  }
}

/// Reads handwriting written on the page in AI mode with Apple's on-device
/// Vision text recognition.
///
/// Dart sends an offscreen PNG of Greatnote's own strokes, dark on white.
/// Vision reads that bitmap, so no text input, Scribble, or
/// `UIIndirectScribbleInteraction` is involved and iPadOS never draws ink of
/// its own over the page. The image lives only for the request.
///
/// Every failure answers with an empty string rather than an error: there
/// were simply no words.
final class HandwritingRecognizerChannel {
  static let name = "com.greatnote.app/handwriting_recognizer"

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(
    label: "com.greatnote.app.handwriting", qos: .userInitiated)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognize" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any],
      let png = arguments["png"] as? FlutterStandardTypedData
    else {
      result("")
      return
    }
    let bytes = png.data
    queue.async {
      let text = autoreleasepool { Self.recognize(png: bytes) }
      DispatchQueue.main.async { result(text) }
    }
  }

  private static func recognize(png: Data) -> String {
    guard let image = UIImage(data: png)?.cgImage else {
      return ""
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return ""
    }
    let observations = request.results ?? []
    // Vision's origin is the bottom left: a greater y is higher up.
    let ordered = observations.sorted { a, b in
      let boxA = a.boundingBox
      let boxB = b.boundingBox
      let sameRow = abs(boxA.midY - boxB.midY) < min(boxA.height, boxB.height) / 2
      return sameRow ? boxA.minX < boxB.minX : boxA.midY > boxB.midY
    }
    return ordered
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
