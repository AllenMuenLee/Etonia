import Flutter
import UIKit

/// Captures Apple Pencil input directly from UIKit. Coalesced samples are
/// persisted through Dart, and the latency-critical wet ink is drawn here by
/// a port of Flutter's own pen model, so it is the stroke Flutter commits.
final class NativeInkChannel: NSObject, UIPencilInteractionDelegate {
  static let name = "com.etonia.app/native_ink"

  private let channel: FlutterMethodChannel
  private let rootView: () -> UIView?
  private var surfaces: [Int: InkSurface] = [:]
  private var active: ActiveStroke?
  /// UITouch hashes can repeat; Dart addresses each stroke by its own number.
  private var nextStrokeNumber = 1
  private weak var attachedRoot: UIView?
  private var recognizer: NativeInkRecognizer?
  private var overlay: NativeInkOverlay?
  private var pencilInteraction: UIPencilInteraction?
  private var lastPencilTapSentAt: TimeInterval = -.infinity
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
    if let pencilInteraction, let attachedRoot {
      attachedRoot.removeInteraction(pencilInteraction)
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
      // its gesture is swallowed rather than starting a new one. Finished
      // strokes stay until Dart says Flutter is drawing them.
      if !surface.enabled || !surface.previewEnabled {
        if let stroke = active, stroke.surface.id == surface.id {
          stroke.previewSuppressed = true
          overlay?.cancelLive()
        }
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
      if let values = call.arguments as? [String: Any],
        let pointer = (values["pointer"] as? NSNumber)?.intValue
      {
        if active?.pointer == pointer { active?.previewSuppressed = true }
        overlay?.finish(pointer: pointer)
      }
      result(nil)
    case "clearLivePreview":
      active = nil
      overlay?.cancelLive()
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
    if let pencilInteraction, let attachedRoot {
      attachedRoot.removeInteraction(pencilInteraction)
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

    let pencilInteraction: UIPencilInteraction
    if #available(iOS 17.5, *) {
      pencilInteraction = UIPencilInteraction(delegate: self)
    } else {
      pencilInteraction = UIPencilInteraction()
      pencilInteraction.delegate = self
    }
    root.addInteraction(pencilInteraction)

    attachedRoot = root
    overlay = inkOverlay
    recognizer = inkRecognizer
    self.pencilInteraction = pencilInteraction
  }

  private func emitStylusGesture(_ gesture: String) {
    channel.invokeMethod("stylusGesture", arguments: ["gesture": gesture])
  }

  private func emitPencilDoubleTap() {
    // Newer UIKit can invoke the replacement delegate method while an older
    // compatibility callback is also present. Keep one action per gesture.
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastPencilTapSentAt > 0.1 else { return }
    lastPencilTapSentAt = now
    emitStylusGesture("doubleTap")
  }

  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    emitPencilDoubleTap()
  }

  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction,
    didReceiveTap tap: UIPencilInteraction.Tap
  ) {
    emitPencilDoubleTap()
  }

  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction,
    didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    if squeeze.phase == .ended {
      emitStylusGesture("squeeze")
    }
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
      let pointer = nextStrokeNumber
      nextStrokeNumber += 1
      let actual = samples(
        actualTouches(touch, event: event, coalesced: false), surface: surface, root: root)
      // The preview follows the very samples Dart receives, through the same
      // pen model, so it draws the stroke Flutter will commit.
      var model: InkStrokeModel?
      if surface.previewEnabled, let first = actual.first {
        let created = InkStrokeModel(
          width: Double(surface.strokeWidth),
          taper: Double(surface.taper),
          pressure: Double(surface.pressureSensitivity),
          smoothing: surface.smoothing)
        created.start(first)
        for sample in actual.dropFirst() { created.add(sample) }
        model = created
      }
      active = ActiveStroke(surface: surface, pointer: pointer, model: model)
      if let model {
        overlay?.begin(pointer: pointer, surface: surface)
        overlay?.update(pointer: pointer, model: model, predicted: [])
      }
      emit(surface: surface, pointer: pointer, phase: "down", samples: actual)

    case .move:
      guard let stroke = active else { return }
      let actual = samples(
        actualTouches(touch, event: event, coalesced: true), surface: stroke.surface, root: root)
      if let model = stroke.model {
        for sample in actual { model.add(sample) }
        if !stroke.previewSuppressed {
          let predicted = samples(
            event?.predictedTouches(for: touch) ?? [], surface: stroke.surface, root: root)
          overlay?.update(pointer: stroke.pointer, model: model, predicted: predicted)
        }
      }
      emit(surface: stroke.surface, pointer: stroke.pointer, phase: "move", samples: actual)

    case .up:
      guard let stroke = active else { return }
      let actual = samples(
        actualTouches(touch, event: event, coalesced: true), surface: stroke.surface, root: root)
      if let model = stroke.model {
        for sample in actual { model.add(sample) }
        let committed = model.finish()
        if !stroke.previewSuppressed {
          overlay?.showFinal(pointer: stroke.pointer, points: committed)
        }
      }
      emit(surface: stroke.surface, pointer: stroke.pointer, phase: "up", samples: actual)
      active = nil
      // The finished wet stroke, both ends tapered as Flutter commits it,
      // stays visible until Dart says Flutter is drawing it, however many
      // strokes come after it.

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

  /// [touches] in [surface]'s canvas pixels; touches it cannot map are left out.
  private func samples(_ touches: [UITouch], surface: InkSurface, root: UIView) -> [InkSample] {
    var output: [InkSample] = []
    output.reserveCapacity(touches.count)
    for touch in touches {
      guard let local = surface.local(touch.location(in: root)) else { continue }
      output.append(
        InkSample(
          x: Double(local.x),
          y: Double(local.y),
          micros: Int64(touch.timestamp * 1_000_000),
          pressure: normalizedPressure(touch)))
    }
    return output
  }

  /// Flat x, y, time-us, pressure tuples keep the platform message small.
  private func emit(surface: InkSurface, pointer: Int, phase: String, samples: [InkSample]) {
    var flat: [Any] = []
    flat.reserveCapacity(samples.count * 4)
    for sample in samples {
      flat.append(sample.x)
      flat.append(sample.y)
      flat.append(sample.micros)
      flat.append(sample.pressure)
    }
    channel.invokeMethod(
      "inkPacket",
      arguments: [
        "surfaceId": surface.id,
        "pointer": pointer,
        "phase": phase,
        "kind": "stylus",
        "samples": flat,
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
  /// The pen model behind the wet ink; nil when there is no preview.
  let model: InkStrokeModel?
  var previewSuppressed = false

  init(surface: InkSurface, pointer: Int, model: InkStrokeModel?) {
    self.surface = surface
    self.pointer = pointer
    self.model = model
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
  let taper: CGFloat
  let stabilization: CGFloat
  /// The stroke's One Euro tuning, stabilization applied, from Dart.
  let smoothing: InkSmoothing
  let writingStyle: String
  let exclusionRects: [CGRect]

  /// Maps canvas pixels to the root view's points.
  var canvasToRoot: CGAffineTransform {
    CGAffineTransform(
      a: xBasis.x, b: xBasis.y, c: yBasis.x, d: yBasis.y, tx: origin.x, ty: origin.y)
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
    taper = number("taper") ?? 0
    self.stabilization = stabilization
    smoothing = InkSmoothing(values["smoothing"])
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

/// The wet ink: the curve of [InkStrokeModel] filled exactly as Flutter's
/// buildInkOutline fills a stroke, a disc at each end and at each sharp
/// turn, joined by a quadrilateral along each segment.
///
/// The settled part of a long stroke is frozen into fixed shape layers of
/// [chunkLength] points, so each touch only redraws the newest stretch.
/// Touches that land on a page are swallowed here, as PencilKit did, so
/// Flutter never scrolls under the pen; NativeInkRecognizer on the root view
/// still observes them.
private final class NativeInkOverlay: UIView {
  var surfaceAtPoint: ((CGPoint) -> InkSurface?)?

  private static let chunkLength = 64

  /// The stroke being drawn.
  private var pointer: Int?
  /// Finished strokes on screen, by pointer, until [finish].
  private var retained: [Int: CAShapeLayer] = [:]
  private var canvasToRoot = CGAffineTransform.identity
  private var radius = 0.5
  private var color = UIColor.black.cgColor
  private var chunks: [CAShapeLayer] = []
  private var chunkStart = 0
  private let live = CAShapeLayer()
  private var displayRateHint: CADisplayLink?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    accessibilityElementsHidden = true
    configure(live)
    layer.addSublayer(live)
  }

  required init?(coder: NSCoder) { nil }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard
      event?.allTouches?.contains(where: { $0.type == .pencil }) == true,
      surfaceAtPoint?(point) != nil
    else { return false }
    return super.point(inside: point, with: event)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

  func begin(pointer: Int, surface: InkSurface) {
    cancelLive()
    self.pointer = pointer
    canvasToRoot = surface.canvasToRoot
    radius = Double(surface.strokeWidth) / 2
    color = surface.color.cgColor
    configure(live)
    keepDisplayFast(true)
  }

  /// Asks a ProMotion display to stay at its fastest while a stroke is drawn.
  /// Flutter draws no frames then, so nothing else tells the system that the
  /// screen is busy, and it may let the rate fall. The link only has to exist.
  private func keepDisplayFast(_ fast: Bool) {
    guard fast else {
      displayRateHint?.invalidate()
      displayRateHint = nil
      return
    }
    guard displayRateHint == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(displayRateHintFired))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    displayRateHint = link
  }

  @objc private func displayRateHintFired() {}

  /// Draws the stroke so far, and on through [predicted] samples.
  func update(pointer: Int, model: InkStrokeModel, predicted: [InkSample]) {
    guard self.pointer == pointer else { return }
    let stable = model.stable
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    while stable.count - 1 - chunkStart >= Self.chunkLength {
      let end = chunkStart + Self.chunkLength
      let chunk = CAShapeLayer()
      configure(chunk)
      chunk.path = outline(stable, from: chunkStart, through: end, tail: nil)
      layer.insertSublayer(chunk, below: live)
      chunks.append(chunk)
      // The next stretch starts on this one's last point, so they overlap.
      chunkStart = end
    }
    live.path = outline(
      stable, from: chunkStart, through: stable.count - 1, tail: model.liveTail(predicted))
    CATransaction.commit()
  }

  /// Replaces the wet stroke with [points], the stroke as Flutter commits
  /// it, both ends tapered, and keeps it until [finish].
  func showFinal(pointer: Int, points: InkPoints) {
    guard self.pointer == pointer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let finished = CAShapeLayer()
    configure(finished)
    finished.path = outline(points, from: 0, through: points.count - 1, tail: nil)
    layer.insertSublayer(finished, below: live)
    retained[pointer] = finished
    removeChunks()
    live.path = nil
    CATransaction.commit()
    self.pointer = nil
    keepDisplayFast(false)
  }

  /// Hides the stroke being drawn, leaving the finished ones.
  func cancelLive() {
    pointer = nil
    keepDisplayFast(false)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    removeChunks()
    live.path = nil
    CATransaction.commit()
  }

  /// Hides the stroke of [pointer], and no other.
  func finish(pointer: Int) {
    if self.pointer == pointer {
      cancelLive()
      return
    }
    guard let finished = retained.removeValue(forKey: pointer) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    finished.removeFromSuperlayer()
    CATransaction.commit()
  }

  private func removeChunks() {
    for chunk in chunks { chunk.removeFromSuperlayer() }
    chunks.removeAll()
    chunkStart = 0
  }

  private func configure(_ shape: CAShapeLayer) {
    shape.frame = bounds
    shape.contentsScale = max(1, traitCollection.displayScale)
    shape.fillColor = color
    shape.fillRule = .nonZero
    shape.strokeColor = nil
    shape.lineWidth = 0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    live.frame = bounds
    for chunk in chunks { chunk.frame = bounds }
    for finished in retained.values { finished.frame = bounds }
    CATransaction.commit()
  }

  /// The filled outline of points [from] through [through] of [points], then
  /// [tail], in canvas pixels mapped to this view. Every part is wound the
  /// same way so the union fills without holes under the nonzero rule.
  private func outline(_ points: InkPoints, from: Int, through: Int, tail: InkPoints?) -> CGPath {
    var xs: [Double] = []
    var ys: [Double] = []
    var rs: [Double] = []
    let extra = tail?.count ?? 0
    xs.reserveCapacity(max(0, through - from + 1) + extra)
    ys.reserveCapacity(xs.capacity)
    rs.reserveCapacity(xs.capacity)
    if from <= through {
      for i in from...through {
        xs.append(points.xs[i])
        ys.append(points.ys[i])
        rs.append(radius * points.widths[i])
      }
    }
    if let tail {
      for i in 0..<tail.count {
        xs.append(tail.xs[i])
        ys.append(tail.ys[i])
        rs.append(radius * tail.widths[i])
      }
    }
    let path = CGMutablePath()
    let n = xs.count
    guard n > 0 else { return path }
    let t = canvasToRoot

    func disc(_ i: Int) {
      let r = rs[i]
      guard r > 0 else { return }
      // Counterclockwise in canvas space, angles increasing: the same
      // winding as polygon's.
      path.move(to: CGPoint(x: xs[i] + r, y: ys[i]), transform: t)
      path.addArc(
        center: CGPoint(x: xs[i], y: ys[i]), radius: CGFloat(r),
        startAngle: 0, endAngle: 2 * .pi, clockwise: false, transform: t)
      path.closeSubpath()
    }

    func polygon(_ corners: [CGPoint]) {
      var area: CGFloat = 0
      for i in corners.indices {
        let a = corners[i]
        let b = corners[(i + 1) % corners.count]
        area += a.x * b.y - b.x * a.y
      }
      if area == 0 { return }
      let ordered = area > 0 ? corners : Array(corners.reversed())
      path.move(to: ordered[0], transform: t)
      for corner in ordered.dropFirst() { path.addLine(to: corner, transform: t) }
      path.closeSubpath()
    }

    disc(0)
    // Turns sharper than this get a disc, so the outside of a corner stays
    // round; gentler ones get their wedge filled.
    let turnCosine = 0.985
    if n > 1 {
      for i in 0..<(n - 1) {
        let ax = xs[i]
        let ay = ys[i]
        let bx = xs[i + 1]
        let by = ys[i + 1]
        let dx = bx - ax
        let dy = by - ay
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 { continue }
        let nx = -dy / length
        let ny = dx / length
        let ra = rs[i]
        let rb = rs[i + 1]
        let b = CGPoint(x: bx, y: by)
        let p1 = CGPoint(x: bx - nx * rb, y: by - ny * rb)
        let p2 = CGPoint(x: bx + nx * rb, y: by + ny * rb)
        polygon([
          CGPoint(x: ax - nx * ra, y: ay - ny * ra), p1, p2,
          CGPoint(x: ax + nx * ra, y: ay + ny * ra),
        ])
        if i + 2 < n {
          let ex = xs[i + 2] - bx
          let ey = ys[i + 2] - by
          let nextLength = (ex * ex + ey * ey).squareRoot()
          if nextLength > 0 && (dx * ex + dy * ey) / (length * nextLength) < turnCosine {
            disc(i + 1)
          } else if nextLength > 0 {
            let mx = -ey / nextLength
            let my = ex / nextLength
            polygon([b, p1, CGPoint(x: bx - mx * rb, y: by - my * rb)])
            polygon([b, p2, CGPoint(x: bx + mx * rb, y: by + my * rb)])
          }
        }
      }
    }
    disc(n - 1)
    return path
  }
}

// MARK: - Flutter's pen model
//
// A line-for-line port, so the wet ink has the very geometry of the stroke
// Flutter commits when the pencil lifts:
//
//  - InkSmoothing    <- lib/features/editor/ink/smoothing_config.dart
//  - InkSmoother     <- lib/features/editor/ink/one_euro_smoother.dart
//  - InkStrokeModel  <- ActiveStroke and StrokeDynamics in stroke.dart
//  - InkFlattener    <- _smoothInkSamples and _flattenInkQuadratic there
//
// Arithmetic is kept in the same order as the Dart. Android has the same
// port in NativeInkModel.kt, checked against Flutter's output in
// test/fixtures/native_ink_parity.txt; change all three together.

/// One actual or predicted pencil sample in canvas pixels.
private struct InkSample {
  let x: Double
  let y: Double
  let micros: Int64
  let pressure: Double
}

/// The One Euro tuning for one stroke, stabilization already applied.
private struct InkSmoothing {
  var minCutoff = 1.0
  var beta = 0.02
  var derivativeCutoff = 1.0
  var minDtSeconds = 0.001
  var maxDtSeconds = 0.1
  var maxFinalizationPoints = 8
  var finalizationSpacing = 2.0
  var endpointTolerance = 0.01
  var slowSpeed = 120.0
  var fastSpeed = 400.0
  var slowCutoffScale = 1.0

  init(_ value: Any?) {
    guard let map = value as? [String: Any] else { return }
    func number(_ key: String) -> Double? { (map[key] as? NSNumber)?.doubleValue }
    if let v = number("minCutoff") { minCutoff = v }
    if let v = number("beta") { beta = v }
    if let v = number("derivativeCutoff") { derivativeCutoff = v }
    if let v = number("minDtSeconds") { minDtSeconds = v }
    if let v = number("maxDtSeconds") { maxDtSeconds = v }
    if let v = number("maxFinalizationPoints") { maxFinalizationPoints = Int(v) }
    if let v = number("finalizationSpacing") { finalizationSpacing = v }
    if let v = number("endpointTolerance") { endpointTolerance = v }
    if let v = number("slowSpeed") { slowSpeed = v }
    if let v = number("fastSpeed") { fastSpeed = v }
    if let v = number("slowCutoffScale") { slowCutoffScale = v }
  }

  func cutoffScale(at speed: Double) -> Double {
    if slowCutoffScale == 1 || speed >= fastSpeed { return 1 }
    if speed <= slowSpeed { return slowCutoffScale }
    let t = (speed - slowSpeed) / (fastSpeed - slowSpeed)
    return slowCutoffScale + (1 - slowCutoffScale) * t * t * (3 - 2 * t)
  }
}

/// The One Euro filter, as OneEuroSmoother. A value type: a copy tries out
/// predicted samples without disturbing the real filter.
private struct InkSmoother {
  let config: InkSmoothing
  private var started = false
  private var lastRawX = 0.0
  private var lastRawY = 0.0
  private var lastTimestamp: Int64 = 0
  private var derivX = 0.0
  private var derivY = 0.0
  private(set) var outX = 0.0
  private(set) var outY = 0.0

  init(config: InkSmoothing) {
    self.config = config
  }

  mutating func start(x: Double, y: Double, micros: Int64) {
    started = true
    lastRawX = x
    lastRawY = y
    lastTimestamp = micros
    outX = x
    outY = y
    derivX = 0
    derivY = 0
  }

  /// Filters one sample; false, and nothing changes, for a non-finite one.
  mutating func add(x: Double, y: Double, micros: Int64) -> Bool {
    guard x.isFinite, y.isFinite else { return false }
    let raw = Double(micros - lastTimestamp) / 1_000_000
    let dt = min(max(raw, config.minDtSeconds), config.maxDtSeconds)
    lastRawX = x
    lastRawY = y
    if micros > lastTimestamp { lastTimestamp = micros }

    let deltaX = x - outX
    let deltaY = y - outY
    if !deltaX.isFinite || !deltaY.isFinite {
      outX = x
      outY = y
      derivX = 0
      derivY = 0
      return true
    }
    let inverse = 1 / dt
    let derivativeX = deltaX * inverse
    let derivativeY = deltaY * inverse
    let derivativeAlpha = Self.alpha(dt, config.derivativeCutoff)
    derivX = derivX + (derivativeX - derivX) * derivativeAlpha
    derivY = derivY + (derivativeY - derivY) * derivativeAlpha

    let speed = Self.magnitude(derivX, derivY)
    let cutoff =
      (config.beta == 0 ? config.minCutoff : config.minCutoff + config.beta * speed)
      * config.cutoffScale(at: speed)
    let positionAlpha = Self.alpha(dt, cutoff)
    let nextX = outX + deltaX * positionAlpha
    let nextY = outY + deltaY * positionAlpha
    if nextX.isFinite && nextY.isFinite {
      outX = nextX
      outY = nextY
    }
    return true
  }

  /// The eased tail ending at the last raw sample, as x0, y0, x1, y1, ...
  mutating func finish() -> [Double] {
    guard started else { return [] }
    let fromX = outX
    let fromY = outY
    let residualX = lastRawX - fromX
    let residualY = lastRawY - fromY
    let distance = Self.magnitude(residualX, residualY)
    if distance <= config.endpointTolerance { return [] }
    if !distance.isFinite {
      outX = lastRawX
      outY = lastRawY
      derivX = 0
      derivY = 0
      return [lastRawX, lastRawY]
    }
    let count = min(
      max(Int((distance / config.finalizationSpacing).rounded(.up)), 1),
      config.maxFinalizationPoints)
    var tail: [Double] = []
    tail.reserveCapacity(count * 2)
    if count > 1 {
      for i in 1..<count {
        let t = Double(i) / Double(count)
        let eased = 1 - (1 - t) * (1 - t)
        tail.append(fromX + residualX * eased)
        tail.append(fromY + residualY * eased)
      }
    }
    tail.append(lastRawX)
    tail.append(lastRawY)
    outX = lastRawX
    outY = lastRawY
    derivX = 0
    derivY = 0
    return tail
  }

  private static func alpha(_ dt: Double, _ cutoff: Double) -> Double {
    let scaled = 2 * Double.pi * cutoff * dt
    if scaled.isInfinite { return 1 }
    return scaled / (1 + scaled)
  }

  private static func magnitude(_ x0: Double, _ y0: Double) -> Double {
    let x = abs(x0)
    let y = abs(y0)
    let scale = max(x, y)
    if scale == 0 || scale.isInfinite { return scale }
    let sx = x / scale
    let sy = y / scale
    return scale * (sx * sx + sy * sy).squareRoot()
  }
}

/// A run of points, each with a width factor and a time.
private struct InkPoints {
  var xs: [Double] = []
  var ys: [Double] = []
  var widths: [Double] = []
  var micros: [Int64] = []

  var count: Int { xs.count }

  mutating func append(x: Double, y: Double, width: Double, micros time: Int64) {
    xs.append(x)
    ys.append(y)
    widths.append(width)
    micros.append(time)
  }
}

/// Turns the stroke's points into the flattened curve Flutter paints:
/// quadratic Beziers between midpoints, cut until the centerline is within
/// 1/8 px and the width factor within 0.005. Points are pushed one at a time;
/// each push emits only the part of the curve later points cannot change.
private struct InkFlattener {
  private static let maxCenterlineError = 0.125
  private static let maxWidthError = 0.005
  private static let maxDepth = 7

  private var count = 0
  private var startX = 0.0
  private var startY = 0.0
  private var startW = 0.0
  private var prevX = 0.0
  private var prevY = 0.0
  private var prevW = 0.0
  private var prevT: Int64 = 0
  private var lastX = Double.nan
  private var lastY = Double.nan

  mutating func push(x: Double, y: Double, w: Double, t: Int64, into out: inout InkPoints) {
    if count == 0 {
      emit(x, y, w, t, &out)
      startX = x
      startY = y
      startW = w
    } else if count >= 2 {
      let endX = (prevX + x) * 0.5
      let endY = (prevY + y) * 0.5
      let endW = (prevW + w) * 0.5
      flatten(
        startX, startY, startW, prevX, prevY, prevW, endX, endY, endW, prevT, &out, 0)
      startX = endX
      startY = endY
      startW = endW
    }
    prevX = x
    prevY = y
    prevW = w
    prevT = t
    count += 1
  }

  /// The straight run from the curve so far to the newest point.
  mutating func tail(into out: inout InkPoints) {
    if count >= 2 { emit(prevX, prevY, prevW, prevT, &out) }
  }

  private mutating func emit(
    _ x: Double, _ y: Double, _ w: Double, _ t: Int64, _ out: inout InkPoints
  ) {
    if x == lastX && y == lastY { return }
    lastX = x
    lastY = y
    out.append(x: x, y: y, width: w, micros: t)
  }

  private mutating func flatten(
    _ sx: Double, _ sy: Double, _ sw: Double,
    _ cx: Double, _ cy: Double, _ cw: Double,
    _ ex: Double, _ ey: Double, _ ew: Double,
    _ t: Int64, _ out: inout InkPoints, _ depth: Int
  ) {
    let chordX = ex - sx
    let chordY = ey - sy
    let chordLength = (chordX * chordX + chordY * chordY).squareRoot()
    let centerlineError =
      chordLength == 0
      ? ((cx - sx) * (cx - sx) + (cy - sy) * (cy - sy)).squareRoot()
      : abs((cx - sx) * chordY - (cy - sy) * chordX) / chordLength
    let widthError = abs(cw - (sw + ew) * 0.5)
    if depth >= Self.maxDepth
      || (centerlineError <= Self.maxCenterlineError && widthError <= Self.maxWidthError)
    {
      emit(ex, ey, ew, t, &out)
      return
    }
    let scX = (sx + cx) * 0.5
    let scY = (sy + cy) * 0.5
    let ceX = (cx + ex) * 0.5
    let ceY = (cy + ey) * 0.5
    let mX = (scX + ceX) * 0.5
    let mY = (scY + ceY) * 0.5
    let scW = (sw + cw) * 0.5
    let ceW = (cw + ew) * 0.5
    let mW = (scW + ceW) * 0.5
    flatten(sx, sy, sw, scX, scY, scW, mX, mY, mW, t, &out, depth + 1)
    flatten(mX, mY, mW, ceX, ceY, ceW, ex, ey, ew, t, &out, depth + 1)
  }
}

/// The stroke being drawn, as Flutter's ActiveStroke: smoothed points, each
/// with the width factor of its eased pressure and the tapered start, and on
/// [finish] both ends tapered as the committed stroke is. [width] is in
/// canvas pixels; [taper] and [pressure] are StrokeDynamics, both 0 for an
/// even line.
private final class InkStrokeModel {
  private static let neutralPressure = 0.5
  private static let pressureSmoothing = 0.3
  private static let dotExtent = 0.01

  private var smoother: InkSmoother
  private let taper: Double
  private let pressure: Double
  private let dynamic: Bool
  private let taperLength: Double
  private let tipFraction: Double

  /// The smoothed points; widths hold the pressure factor alone.
  private var points = InkPoints()
  private var distances: [Double] = []
  private var length = 0.0
  private var pressureState = InkStrokeModel.neutralPressure
  private var lastTime: Int64 = 0
  private var maxDistanceFromOrigin = 0.0

  /// The flattened curve so far that later samples cannot change.
  private(set) var stable = InkPoints()
  private var flattener = InkFlattener()

  var isDot: Bool { maxDistanceFromOrigin < Self.dotExtent }

  init(width: Double, taper: Double, pressure: Double, smoothing: InkSmoothing) {
    smoother = InkSmoother(config: smoothing)
    self.taper = taper
    self.pressure = pressure
    dynamic = taper != 0 || pressure != 0
    taperLength = width * (1 + 7 * taper)
    tipFraction = 1 - 0.85 * taper
  }

  func start(_ sample: InkSample) {
    smoother.start(x: sample.x, y: sample.y, micros: sample.micros)
    lastTime = sample.micros
    pressureState = sample.pressure
    let factor = pressureFactor(pressureState)
    points.append(x: sample.x, y: sample.y, width: factor, micros: sample.micros)
    distances.append(0)
    flattener.push(
      x: sample.x, y: sample.y, w: factor * taperAt(0, taperLength), t: sample.micros,
      into: &stable)
  }

  func add(_ sample: InkSample) {
    guard smoother.add(x: sample.x, y: sample.y, micros: sample.micros) else { return }
    pressureState += (sample.pressure - pressureState) * Self.pressureSmoothing
    if sample.micros > lastTime { lastTime = sample.micros }
    append(smoother.outX, smoother.outY, lastTime)
  }

  private func append(_ x: Double, _ y: Double, _ time: Int64) {
    guard let lx = points.xs.last, let ly = points.ys.last else { return }
    if x == lx && y == ly { return }
    length += ((x - lx) * (x - lx) + (y - ly) * (y - ly)).squareRoot()
    let factor = pressureFactor(pressureState)
    points.append(x: x, y: y, width: factor, micros: time)
    distances.append(length)
    let ox = points.xs[0]
    let oy = points.ys[0]
    let fromOrigin = ((x - ox) * (x - ox) + (y - oy) * (y - oy)).squareRoot()
    if fromOrigin > maxDistanceFromOrigin { maxDistanceFromOrigin = fromOrigin }
    flattener.push(
      x: x, y: y, w: factor * taperAt(length, taperLength), t: time, into: &stable)
  }

  /// The curve past [stable]: up to the newest point, then on through
  /// [predicted] samples, filtered by a copy of the smoother so the guess
  /// bends as the real line will.
  func liveTail(_ predicted: [InkSample]) -> InkPoints {
    var out = InkPoints()
    var flat = flattener
    if !predicted.isEmpty, var lx = points.xs.last, var ly = points.ys.last {
      var guess = smoother
      var reading = pressureState
      var distance = length
      var time = lastTime
      for sample in predicted {
        guard guess.add(x: sample.x, y: sample.y, micros: sample.micros) else { continue }
        reading += (sample.pressure - reading) * Self.pressureSmoothing
        if sample.micros > time { time = sample.micros }
        let x = guess.outX
        let y = guess.outY
        if x == lx && y == ly { continue }
        distance += ((x - lx) * (x - lx) + (y - ly) * (y - ly)).squareRoot()
        lx = x
        ly = y
        flat.push(
          x: x, y: y, w: pressureFactor(reading) * taperAt(distance, taperLength), t: time,
          into: &out)
      }
    }
    flat.tail(into: &out)
    return out
  }

  /// Ends the stroke as Flutter's ActiveStroke.finish does and returns the
  /// whole flattened curve with its final widths. A dot is one point at full
  /// width, as Flutter paints it.
  func finish() -> InkPoints {
    let tail = smoother.finish()
    var i = 0
    while i + 1 < tail.count {
      append(tail[i], tail[i + 1], lastTime)
      i += 2
    }
    var out = InkPoints()
    guard points.count > 0 else { return out }
    if isDot {
      out.append(x: points.xs[0], y: points.ys[0], width: 1, micros: points.micros[0])
      return out
    }
    let ends = min(taperLength, length * 0.4)
    var flat = InkFlattener()
    for index in 0..<points.count {
      let d = distances[index]
      let w =
        dynamic ? points.widths[index] * taperAt(d, ends) * taperAt(length - d, ends) : 1
      flat.push(x: points.xs[index], y: points.ys[index], w: w, t: points.micros[index], into: &out)
    }
    flat.tail(into: &out)
    return out
  }

  private func pressureFactor(_ reading: Double) -> Double {
    if !dynamic { return 1 }
    return 1 + pressure * 0.75 * (2 * min(max(reading, 0), 1) - 1)
  }

  private func taperAt(_ distance: Double, _ length: Double) -> Double {
    if !dynamic || taper == 0 || length <= 0 || distance >= length { return 1 }
    let t = min(max(distance / length, 0), 1)
    let eased = t * (2 - t)
    return tipFraction + (1 - tipFraction) * eased
  }
}
