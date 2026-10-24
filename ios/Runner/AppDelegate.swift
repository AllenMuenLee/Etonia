import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var handwritingRecognizer: HandwritingRecognizerChannel?
  private var nativeInk: NativeInkChannel?
  let sharedDocuments = SharedDocumentChannel()

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EtoniaSharedDocuments") {
      sharedDocuments.attach(messenger: registrar.messenger())
    }
  }

  func handleOpenURLContexts(_ urlContexts: Set<UIOpenURLContext>) {
    for context in urlContexts {
      _ = sharedDocuments.receive(url: context.url)
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if sharedDocuments.receive(url: url) {
      return true
    }
    return super.application(app, open: url, options: options)
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

/// Receives PDFs shared into Etonia from another app's share sheet or "Open
/// in" action and forwards their filename and bytes to Dart.
///
/// Files are read on a queue of their own, in the order they arrive: a large
/// PDF, or one in iCloud that must first download, would otherwise freeze
/// the app. Everything else here stays on the main thread.
final class SharedDocumentChannel {
  static let name = "com.etonia.app/shared_documents"

  private var channel: FlutterMethodChannel?
  private var pending: [[String: Any]] = []
  private var dartReady = false
  private var recentPaths: [String: TimeInterval] = [:]
  private let reader = DispatchQueue(
    label: "com.etonia.app.shared-documents", qos: .userInitiated)

  func attach(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = methodChannel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "takeInitialDocuments":
      dartReady = true
      let drained = pending
      pending.removeAll()
      result(drained)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @discardableResult
  func receive(url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let standardized = url.standardizedFileURL.path
    let now = ProcessInfo.processInfo.systemUptime
    if let last = recentPaths[standardized], now - last < 1.0 {
      return true
    }
    recentPaths[standardized] = now

    reader.async { [weak self] in
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }
      guard let data = try? Data(contentsOf: url), !data.isEmpty else {
        return
      }
      let name = url.lastPathComponent.isEmpty ? "Shared.pdf" : url.lastPathComponent
      if standardized.contains("/Documents/Inbox/") {
        try? FileManager.default.removeItem(at: url)
      }
      let payload: [String: Any] = [
        "name": name,
        "bytes": FlutterStandardTypedData(bytes: data),
      ]
      DispatchQueue.main.async { self?.deliver(payload) }
    }
    return true
  }

  private func deliver(_ payload: [String: Any]) {
    if dartReady, let channel {
      channel.invokeMethod("onDocumentShared", arguments: payload)
    } else {
      pending.append(payload)
    }
  }
}

/// Reads handwriting written on the page in AI mode with Apple's on-device
/// Vision text recognition.
///
/// Dart sends Etonia's own strokes as vectors, drawn dark on white on the
/// recognition queue (older callers send a PNG of them instead). Vision
/// reads that bitmap, so no text input, Scribble, or
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
    guard let arguments = call.arguments as? [String: Any] else {
      result("")
      return
    }
    let customWords = Array((arguments["customWords"] as? [String] ?? []).prefix(64))
    queue.async {
      let text = autoreleasepool { () -> [String: Any] in
        let image: CGImage?
        if let png = arguments["png"] as? FlutterStandardTypedData {
          image = UIImage(data: png.data)?.cgImage
        } else {
          image = Self.imageFromStrokes(arguments)
        }
        return Self.recognize(image: image, customWords: customWords)
      }
      DispatchQueue.main.async { result(text) }
    }
  }

  private static func recognize(image: CGImage?, customWords: [String]) -> [String: Any] {
    guard let image else {
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

  /// Rasterizes vector handwriting on the recognition queue, avoiding a
  /// Flutter GPU readback and PNG encode/decode for Vision requests.
  private static func imageFromStrokes(_ arguments: [String: Any]) -> CGImage? {
    guard let strokes = arguments["strokes"] as? [[NSNumber]],
      let width = arguments["width"] as? NSNumber,
      let height = arguments["height"] as? NSNumber,
      let logicalWidth = arguments["logicalWidth"] as? NSNumber,
      let logicalHeight = arguments["logicalHeight"] as? NSNumber
    else { return nil }
    let pixelWidth = min(max(1, width.intValue), 4096)
    let pixelHeight = min(max(1, height.intValue), 4096)
    let logical = CGSize(
      width: CGFloat(logicalWidth.doubleValue),
      height: CGFloat(logicalHeight.doubleValue))
    guard logical.width > 0, logical.height > 0 else { return nil }
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(
      data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
      bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(
      x: CGFloat(pixelWidth) / logical.width,
      y: -CGFloat(pixelHeight) / logical.height)
    context.setStrokeColor(gray: 0, alpha: 1)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for stroke in strokes {
      let count = stroke.count / 3
      guard count > 0 else { continue }
      func point(_ index: Int) -> CGPoint {
        let offset = index * 3
        return CGPoint(
          x: CGFloat(stroke[offset].doubleValue),
          y: CGFloat(stroke[offset + 1].doubleValue))
      }
      let first = point(0)
      context.beginPath()
      context.move(to: first)
      context.addLine(to: first)
      if count > 2 {
        for index in 1..<(count - 1) {
          let current = point(index)
          let next = point(index + 1)
          context.addQuadCurve(
            to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2),
            control: current)
        }
      }
      if count > 1 { context.addLine(to: point(count - 1)) }
      context.strokePath()
    }
    return context.makeImage()
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
