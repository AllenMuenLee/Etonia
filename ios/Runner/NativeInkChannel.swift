import Flutter
import PencilKit
import UIKit

/// Captures Apple Pencil input directly from UIKit. Coalesced samples are
/// persisted through Dart while PencilKit owns the latency-critical wet ink,
/// including its native prediction and smoothing.
final class NativeInkChannel: NSObject {
  static let name = "com.etonia.app/native_ink"

  private let channel: FlutterMethodChannel
  private let rootView: () -> UIView?
  private var surfaces: [Int: InkSurface] = [:]
  private var active: ActiveStroke?
  private weak var attachedRoot: UIView?
  private var recognizer: NativeInkRecognizer?
  private var overlay: NativeInkOverlay?
  private let gestureDelegate = NativeInkGestureDelegate()

  init(messenger: FlutterBinaryMessenger, rootView: @escaping () -> UIView?) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    self.rootView = rootView
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    if let recognizer, let view = recognizer.view {
      view.removeGestureRecognizer(recognizer)
    }
    overlay?.removeFromSuperview()
    channel.setMethodCallHandler(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "registerSurface", "updateSurface":
      guard let values = call.arguments as? [String: Any],
        let surface = InkSurface(values)
      else {
        result(FlutterError(code: "bad_surface", message: "Invalid native ink surface", details: nil))
        return
      }
      surfaces[surface.id] = surface
      attachIfNeeded()
      // Leaving the pen hides a stroke still in progress at once; the rest of
      // its gesture is swallowed rather than starting a new one.
      if !surface.enabled || !surface.previewEnabled {
        if let stroke = active, stroke.surface.id == surface.id {
          stroke.previewSuppressed = true
        }
        overlay?.clear()
      }
      result(true)
    case "unregisterSurface":
      if let values = call.arguments as? [String: Any],
        let id = (values["surfaceId"] as? NSNumber)?.intValue
      {
        surfaces.removeValue(forKey: id)
        if active?.surface.id == id { cancelActive(sendPacket: false) }
      }
      result(nil)
    case "finishPreview":
      if let values = call.arguments as? [String: Any] {
        let pointer = (values["pointer"] as? NSNumber)?.intValue ?? values["pointer"] as? Int
        if let pointer, active?.pointer == pointer { active?.previewSuppressed = true }
        if let pointer {
          overlay?.finish(pointer: pointer)
        } else {
          overlay?.clear()
        }
      } else {
        overlay?.clear()
      }
      result(nil)
    case "clearAllPreviews":
      active = nil
      overlay?.clear()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func attachIfNeeded() {
    guard let root = rootView() else { return }
    if attachedRoot === root { return }
    if let recognizer, let view = recognizer.view {
      view.removeGestureRecognizer(recognizer)
    }
    overlay?.removeFromSuperview()

    let inkOverlay = NativeInkOverlay(frame: root.bounds)
    inkOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    inkOverlay.surfaceAtPoint = { [weak self] point in
      self?.previewSurface(at: point)
    }
    root.addSubview(inkOverlay)

    let inkRecognizer = NativeInkRecognizer { [weak self] phase, touch, event in
      self?.observe(phase: phase, touch: touch, event: event)
    }
    inkRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    inkRecognizer.cancelsTouchesInView = false
    inkRecognizer.delaysTouchesBegan = false
    inkRecognizer.delaysTouchesEnded = false
    inkRecognizer.delegate = gestureDelegate
    root.addGestureRecognizer(inkRecognizer)

    attachedRoot = root
    overlay = inkOverlay
    recognizer = inkRecognizer
  }

  private func observe(phase: NativeInkPhase, touch: UITouch, event: UIEvent?) {
    guard let root = attachedRoot else { return }
    switch phase {
    case .down:
      guard active == nil else { return }
      let global = touch.location(in: root)
      guard let surface = surfaces.values
        .filter({ $0.enabled && $0.contains(global) })
        .max(by: { $0.id < $1.id })
      else { return }
      let pointer = touch.hash & 0x7FFF_FFFF
      active = ActiveStroke(surface: surface, pointer: pointer)
      let actual = actualTouches(touch, event: event, coalesced: false)
      if surface.previewEnabled {
        overlay?.begin(pointer: pointer, surface: surface)
      }
      emit(surface: surface, pointer: pointer, phase: "down", touches: actual, root: root)

    case .move:
      guard let stroke = active else { return }
      let actual = actualTouches(touch, event: event, coalesced: true)
      emit(
        surface: stroke.surface, pointer: stroke.pointer, phase: "move",
        touches: actual, root: root)

    case .up:
      guard let stroke = active else { return }
      let actual = actualTouches(touch, event: event, coalesced: true)
      emit(
        surface: stroke.surface, pointer: stroke.pointer, phase: "up",
        touches: actual, root: root)
      active = nil
      let pointer = stroke.pointer
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
        self?.overlay?.finish(pointer: pointer)
      }

    case .cancel:
      cancelActive(sendPacket: true)
    }
  }

  private func actualTouches(_ touch: UITouch, event: UIEvent?, coalesced: Bool) -> [UITouch] {
    guard coalesced, let event else { return [touch] }
    return event.coalescedTouches(for: touch) ?? [touch]
  }

  private func previewSurface(at point: CGPoint) -> InkSurface? {
    surfaces.values
      .filter { $0.enabled && $0.previewEnabled && $0.contains(point) }
      .max(by: { $0.id < $1.id })
  }

  private func emit(
    surface: InkSurface,
    pointer: Int,
    phase: String,
    touches: [UITouch],
    root: UIView
  ) {
    var samples: [Any] = []
    samples.reserveCapacity(touches.count * 4)
    for touch in touches {
      guard let local = surface.local(touch.location(in: root)) else { continue }
      samples.append(Double(local.x))
      samples.append(Double(local.y))
      samples.append(Int64(touch.timestamp * 1_000_000))
      samples.append(normalizedPressure(touch))
    }
    channel.invokeMethod(
      "inkPacket",
      arguments: [
        "surfaceId": surface.id,
        "pointer": pointer,
        "phase": phase,
        "kind": "stylus",
        "samples": samples,
      ])
  }

  private func normalizedPressure(_ touch: UITouch) -> Double {
    guard touch.maximumPossibleForce > 0 else { return 0.5 }
    return min(1, max(0, Double(touch.force / touch.maximumPossibleForce)))
  }

  private func cancelActive(sendPacket: Bool) {
    guard let stroke = active else { return }
    active = nil
    overlay?.finish(pointer: stroke.pointer)
    if sendPacket {
      channel.invokeMethod(
        "inkPacket",
        arguments: [
          "surfaceId": stroke.surface.id,
          "pointer": stroke.pointer,
          "phase": "cancel",
          "kind": "stylus",
          "samples": [],
        ])
    }
  }
}

private enum NativeInkPhase { case down, move, up, cancel }

private final class NativeInkRecognizer: UIGestureRecognizer {
  typealias Observer = (NativeInkPhase, UITouch, UIEvent?) -> Void
  private let observer: Observer

  init(observer: @escaping Observer) {
    self.observer = observer
    super.init(target: nil, action: nil)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first else { return }
    observer(.down, touch, event)
    state = .began
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first else { return }
    observer(.move, touch, event)
    state = .changed
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first else { return }
    observer(.up, touch, event)
    state = .ended
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { observer(.cancel, touch, event) }
    state = .cancelled
  }
}

private final class NativeInkGestureDelegate: NSObject, UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }
}

private final class ActiveStroke {
  let surface: InkSurface
  let pointer: Int
  var previewSuppressed = false

  init(surface: InkSurface, pointer: Int) {
    self.surface = surface
    self.pointer = pointer
  }
}

private struct InkSurface {
  let id: Int
  let size: CGSize
  let origin: CGPoint
  let xBasis: CGPoint
  let yBasis: CGPoint
  let enabled: Bool
  let previewEnabled: Bool
  let color: UIColor
  let strokeWidth: CGFloat
  let pressureSensitivity: CGFloat
  let stabilization: CGFloat
  let writingStyle: String
  let exclusionRects: [CGRect]

  var scale: CGFloat {
    (hypot(xBasis.x, xBasis.y) + hypot(yBasis.x, yBasis.y)) / 2
  }

  init?(_ values: [String: Any]) {
    func number(_ key: String) -> CGFloat? {
      (values[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }
    guard let id = (values["surfaceId"] as? NSNumber)?.intValue,
      let width = number("width"), let height = number("height"),
      let originX = number("originX"), let originY = number("originY"),
      let xx = number("xx"), let xy = number("xy"),
      let yx = number("yx"), let yy = number("yy"),
      let colorValue = (values["color"] as? NSNumber)?.uint32Value,
      let strokeWidth = number("strokeWidth"),
      let pressureSensitivity = number("pressureSensitivity"),
      let stabilization = number("stabilization"),
      let writingStyle = values["writingStyle"] as? String
    else { return nil }
    self.id = id
    size = CGSize(width: width, height: height)
    origin = CGPoint(x: originX, y: originY)
    xBasis = CGPoint(x: xx, y: xy)
    yBasis = CGPoint(x: yx, y: yy)
    enabled = values["enabled"] as? Bool ?? false
    previewEnabled = values["previewEnabled"] as? Bool ?? false
    let alpha = CGFloat((colorValue >> 24) & 0xff) / 255
    let red = CGFloat((colorValue >> 16) & 0xff) / 255
    let green = CGFloat((colorValue >> 8) & 0xff) / 255
    let blue = CGFloat(colorValue & 0xff) / 255
    color = UIColor(red: red, green: green, blue: blue, alpha: alpha)
    self.strokeWidth = strokeWidth
    self.pressureSensitivity = pressureSensitivity
    self.stabilization = stabilization
    self.writingStyle = writingStyle

    if let rectsData = values["exclusionRects"] as? [NSNumber] {
      var rects: [CGRect] = []
      var i = 0
      while i + 3 < rectsData.count {
        let left = CGFloat(rectsData[i].doubleValue)
        let top = CGFloat(rectsData[i + 1].doubleValue)
        let right = CGFloat(rectsData[i + 2].doubleValue)
        let bottom = CGFloat(rectsData[i + 3].doubleValue)
        rects.append(CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top)))
        i += 4
      }
      self.exclusionRects = rects
    } else {
      self.exclusionRects = []
    }
  }

  func local(_ global: CGPoint) -> CGPoint? {
    let determinant = xBasis.x * yBasis.y - xBasis.y * yBasis.x
    guard abs(determinant) > 0.000_000_1 else { return nil }
    let dx = global.x - origin.x
    let dy = global.y - origin.y
    let point = CGPoint(
      x: (dx * yBasis.y - dy * yBasis.x) / determinant,
      y: (dy * xBasis.x - dx * xBasis.y) / determinant)
    return point
  }

  func contains(_ global: CGPoint) -> Bool {
    for rect in exclusionRects {
      if rect.contains(global) { return false }
    }
    guard let point = local(global) else { return false }
    return point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height
  }
}

private final class NativeInkOverlay: PKCanvasView {
  var surfaceAtPoint: ((CGPoint) -> InkSurface?)?

  private var pointer: Int?
  private var preparedSurfaceId: Int?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    accessibilityElementsHidden = true
    drawingPolicy = .pencilOnly
    isScrollEnabled = false
    alwaysBounceHorizontal = false
    alwaysBounceVertical = false
    showsHorizontalScrollIndicator = false
    showsVerticalScrollIndicator = false
    // PencilKit already draws at the display's full ProMotion rate; a frame
    // rate range belongs to a CADisplayLink or CAAnimation, not a CALayer.
    bounces = false
  }

  required init?(coder: NSCoder) { nil }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard
      event?.allTouches?.contains(where: { $0.type == .pencil }) == true,
      let surface = surfaceAtPoint?(point)
    else { return false }
    prepare(surface)
    return super.point(inside: point, with: event)
  }

  func begin(pointer: Int, surface: InkSurface) {
    prepare(surface)
    self.pointer = pointer
  }

  private func prepare(_ surface: InkSurface) {
    if pointer != nil || preparedSurfaceId != surface.id {
      drawing = PKDrawing()
      pointer = nil
      preparedSurfaceId = surface.id
    }
    let type: PKInkingTool.InkType
    switch surface.writingStyle {
    case "pencil": type = .pencil
    case "highlighter": type = .marker
    default: type = .pen
    }
    tool = PKInkingTool(
      type,
      color: surface.color,
      width: max(0.5, surface.strokeWidth * surface.scale))
  }

  func clear() {
    self.pointer = nil
    preparedSurfaceId = nil
    drawing = PKDrawing()
  }

  func finish(pointer: Int) {
    if self.pointer == nil || self.pointer == pointer {
      clear()
    }
  }
}
