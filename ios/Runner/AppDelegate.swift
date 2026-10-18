import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var handwritingRecognizer: HandwritingRecognizerChannel?
  private var nativeInk: NativeInkChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "EtoniaHandwritingRecognizer")
    {
      handwritingRecognizer = HandwritingRecognizerChannel(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EtoniaNativeInk") {
      nativeInk = NativeInkChannel(messenger: registrar.messenger()) { [weak self] in
        self?.flutterRootView()
      }
    }
  }

  private func flutterRootView() -> UIView? {
    if let view = window?.rootViewController?.view { return view }
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      if let view = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view {
        return view
      }
    }
    return nil
  }
}

/// Reads handwriting written on the page in AI mode with Apple's on-device
/// Vision text recognition.
///
/// Dart sends an offscreen PNG of Etonia's own strokes, dark on white.
/// Vision reads that bitmap, so no text input, Scribble, or
/// `UIIndirectScribbleInteraction` is involved and iPadOS never draws ink of
/// its own over the page. The image lives only for the request.
///
/// Results contain ranked candidates per line, in reading order, so Dart
/// can use the draft and conversation to resolve ambiguous handwriting.
/// Failures return no words.
final class HandwritingRecognizerChannel {
  static let name = "com.etonia.app/handwriting_recognizer"

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(
    label: "com.etonia.app.handwriting", qos: .userInitiated)

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
    let customWords = Array((arguments["customWords"] as? [String] ?? []).prefix(64))
    queue.async {
      let text = autoreleasepool { Self.recognize(png: bytes, customWords: customWords) }
      DispatchQueue.main.async { result(text) }
    }
  }

  private static func recognize(png: Data, customWords: [String]) -> [String: Any] {
    guard let image = UIImage(data: png)?.cgImage else {
      return ["segments": []]
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.customWords = customWords
    // Handwriting reads far better in the writer's own languages than in
    // Vision's default, English alone.
    let languages = preferredLanguages(for: request)
    if !languages.isEmpty {
      request.recognitionLanguages = languages
    }
    if #available(iOS 16.0, *) {
      request.automaticallyDetectsLanguage = languages.count > 1
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return ["segments": []]
    }
    let observations = request.results ?? []
    // Vision's origin is the bottom left: a greater y is higher up.
    let ordered = observations.sorted { a, b in
      let boxA = a.boundingBox
      let boxB = b.boundingBox
      let sameRow = abs(boxA.midY - boxB.midY) < min(boxA.height, boxB.height) / 2
      return sameRow ? boxA.minX < boxB.minX : boxA.midY > boxB.midY
    }
    let segments: [[[String: Any]]] = ordered.map { observation in
      observation.topCandidates(5).map { candidate in
        ["text": candidate.string, "confidence": Double(candidate.confidence)]
      }
    }
    return ["segments": segments]
  }

  /// The user's preferred languages that [request] can read, in order of
  /// preference, matched by language when the region differs.
  private static func preferredLanguages(for request: VNRecognizeTextRequest) -> [String] {
    let supported: [String]
    if #available(iOS 15.0, *) {
      supported = (try? request.supportedRecognitionLanguages()) ?? []
    } else {
      supported =
        (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
          for: .accurate, revision: VNRecognizeTextRequestRevision1)) ?? []
    }
    var chosen: [String] = []
    for preferred in Locale.preferredLanguages {
      let language = preferred.split(separator: "-").first.map(String.init) ?? preferred
      let match =
        supported.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
        ?? supported.first { $0.lowercased().hasPrefix(language.lowercased()) }
      if let match, !chosen.contains(match) {
        chosen.append(match)
      }
    }
    return chosen
  }
}
