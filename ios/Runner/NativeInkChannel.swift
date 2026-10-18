import Flutter
import UIKit

/// Captures Apple Pencil input directly from UIKit. Coalesced samples are
/// persisted through Dart; predicted touches are rendered only in this
/// transient native overlay and are replaced by the next real event.
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
      if let values = call.arguments as? [String: Any],
        let pointer = (values["pointer"] as? NSNumber)?.intValue
      {
        if active?.pointer == pointer { active?.previewSuppressed = true }
        overlay?.finish(pointer: pointer)
      }
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
    inkOverlay.isUserInteractionEnabled = false
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
      let pointer = touch.hash
      active = ActiveStroke(surface: surface, pointer: pointer)
      let actual = actualTouches(touch, event: event, coalesced: false)
      if surface.previewEnabled {
        overlay?.begin(
          pointer: pointer,
          actual: previewPoints(actual, in: root),
          predicted: [],
          surface: surface)
      }
      emit(surface: surface, pointer: pointer, phase: "down", touches: actual, root: root)

    case .move:
      guard let stroke = active else { return }
      let actual = actualTouches(touch, event: event, coalesced: true)
      let predicted = event?.predictedTouches(for: touch) ?? []
      if stroke.surface.previewEnabled && !stroke.previewSuppressed {
        overlay?.append(
          pointer: stroke.pointer,
          actual: previewPoints(actual, in: root),
          predicted: previewPoints(predicted, in: root),
          surface: stroke.surface)
      }
      emit(
        surface: stroke.surface, pointer: stroke.pointer, phase: "move",
        touches: actual, root: root)

    case .up:
      guard let stroke = active else { return }
      let actual = actualTouches(touch, event: event, coalesced: true)
      if stroke.surface.previewEnabled && !stroke.previewSuppressed {
        overlay?.append(
          pointer: stroke.pointer,
          actual: previewPoints(actual, in: root),
          predicted: [],
          surface: stroke.surface)
      }
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

  private func previewPoints(_ touches: [UITouch], in root: UIView) -> [PreviewPoint] {
    touches.map {
      PreviewPoint(point: $0.location(in: root), pressure: normalizedPressure($0))
    }
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
      let pressureSensitivity = number("pressureSensitivity")
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
    guard let point = local(global) else { return false }
    return point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height
  }
}

private struct PreviewPoint: Equatable {
  let point: CGPoint
  let pressure: Double
}

private final class NativeInkOverlay: UIView {
  private var pointer: Int?
  private var actual: [PreviewPoint] = []
  private var predicted: [PreviewPoint] = []
  private var surface: InkSurface?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    contentMode = .redraw
    accessibilityElementsHidden = true
  }

  required init?(coder: NSCoder) { nil }

  func begin(
    pointer: Int, actual: [PreviewPoint], predicted: [PreviewPoint], surface: InkSurface
  ) {
    self.pointer = pointer
    self.actual = actual
    self.predicted = predicted
    self.surface = surface
    setNeedsDisplay()
  }

  func append(
    pointer: Int, actual incoming: [PreviewPoint], predicted: [PreviewPoint],
    surface: InkSurface
  ) {
    guard self.pointer == pointer else {
      begin(pointer: pointer, actual: incoming, predicted: predicted, surface: surface)
      return
    }
    if incoming.first == actual.last {
      actual.append(contentsOf: incoming.dropFirst())
    } else {
      actual.append(contentsOf: incoming)
    }
    self.predicted = predicted
    self.surface = surface
    setNeedsDisplay()
  }

  func finish(pointer: Int) {
    guard self.pointer == pointer else { return }
    self.pointer = nil
    actual.removeAll(keepingCapacity: true)
    predicted.removeAll(keepingCapacity: true)
    surface = nil
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext(), let surface, !actual.isEmpty else { return }
    let points = actual + predicted
    context.setStrokeColor(surface.color.cgColor)
    context.setFillColor(surface.color.cgColor)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    if points.count == 1 {
      let width = lineWidth(points[0].pressure, surface: surface)
      context.fillEllipse(
        in: CGRect(
          x: points[0].point.x - width / 2, y: points[0].point.y - width / 2,
          width: width, height: width))
      return
    }
    for index in 1..<points.count {
      let before = points[index - 1]
      let current = points[index]
      context.setLineWidth(lineWidth((before.pressure + current.pressure) / 2, surface: surface))
      context.move(to: before.point)
      context.addLine(to: current.point)
      context.strokePath()
    }
  }

  private func lineWidth(_ pressure: Double, surface: InkSurface) -> CGFloat {
    let factor = 1 + surface.pressureSensitivity * 0.75 * CGFloat(2 * pressure - 1)
    return max(0.5, surface.strokeWidth * surface.scale * factor)
  }
}
