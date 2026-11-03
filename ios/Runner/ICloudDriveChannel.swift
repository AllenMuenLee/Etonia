import Flutter
import Foundation

/// The file operations the library's iCloud backup needs, in the app's
/// iCloud container. Paths come from Dart, relative to a `Backups` folder that
/// stays out of the Files app, since the backup is not meant to be browsed.
///
/// Everything runs off the main thread: finding the container and coordinating
/// a file can each take a while. Reads wait for iCloud to bring the file down,
/// and give up with `offline` rather than wait for ever.
final class ICloudDriveChannel {
  static let name = "com.etonia.app/icloud_drive"
  private static let containerIdentifier = "iCloud.com.etonia.app"
  private static let backupsFolder = "Backups"

  /// How long a read waits for a file not on this device yet.
  private static let downloadLimit: TimeInterval = 120
  /// How long a read waits to learn of a newer version of a file it has.
  private static let freshenLimit: TimeInterval = 5

  private struct Failure: Error {
    let code: String
    let message: String?

    static let unavailable = Failure(code: "unavailable", message: nil)
    static let notFound = Failure(code: "notFound", message: nil)
    static let offline = Failure(code: "offline", message: nil)
    static let badArguments = Failure(code: "badArguments", message: "Bad arguments")
  }

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(
    label: "com.etonia.app.icloud", qos: .utility, attributes: .concurrent)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    let method = call.method
    queue.async { [weak self] in
      guard let self else { return }
      let answer: Any?
      do {
        answer = try self.perform(method, arguments: arguments)
      } catch let failure as Failure {
        answer = FlutterError(code: failure.code, message: failure.message, details: nil)
      } catch {
        answer = FlutterError(
          code: "failed", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  private func perform(_ method: String, arguments: [String: Any]) throws -> Any? {
    if method == "isAvailable" {
      return FileManager.default.ubiquityIdentityToken != nil && container() != nil
    }
    guard let path = arguments["path"] as? String else { throw Failure.badArguments }
    let url = try location(of: path)
    switch method {
    case "list":
      return try list(url)
    case "createFolder":
      try createFolder(url)
      return nil
    case "read":
      return FlutterStandardTypedData(bytes: try read(url))
    case "write":
      guard let bytes = arguments["bytes"] as? FlutterStandardTypedData else {
        throw Failure.badArguments
      }
      try write(bytes.data, to: url)
      return nil
    case "delete":
      try delete(url)
      return nil
    default:
      return FlutterMethodNotImplemented
    }
  }

  private func container() -> URL? {
    FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
  }

  /// Where `path` is, refusing anything that would climb out of the backups.
  private func location(of path: String) throws -> URL {
    guard FileManager.default.ubiquityIdentityToken != nil, let container = container() else {
      throw Failure.unavailable
    }
    var url = container.appendingPathComponent(Self.backupsFolder, isDirectory: true)
    for component in path.split(separator: "/") {
      guard component != "..", component != "." else { throw Failure.badArguments }
      url.appendPathComponent(String(component))
    }
    return url
  }

  /// The stand-in for a file iCloud has not brought down yet, on systems
  /// that make one: `.name.icloud` beside where the file will be.
  private func placeholder(of url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).icloud")
  }

  private func list(_ folder: URL) throws -> [[String: Any]] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys, options: [])
    } catch CocoaError.fileReadNoSuchFile {
      // The backups folder itself is only made by the first backup.
      if folder.lastPathComponent == Self.backupsFolder { return [] }
      throw Failure.notFound
    }
    var items: [[String: Any]] = []
    for url in contents {
      var name = url.lastPathComponent
      var isPlaceholder = false
      if name.hasPrefix(".") {
        // Other hidden files, such as .DS_Store, are not ours.
        guard name.hasSuffix(".icloud") else { continue }
        name = String(name.dropFirst().dropLast(".icloud".count))
        isPlaceholder = true
      }
      let values = try? url.resourceValues(forKeys: Set(keys))
      var item: [String: Any] = [
        "name": name,
        "isFolder": values?.isDirectory ?? false,
      ]
      if let modified = values?.contentModificationDate {
        item["modifiedMillis"] = Int(modified.timeIntervalSince1970 * 1000)
      }
      if !isPlaceholder, let size = values?.fileSize {
        item["size"] = size
      }
      items.append(item)
    }
    return items
  }

  private func createFolder(_ url: URL) throws {
    try coordinate(writing: url, options: []) { target in
      try FileManager.default.createDirectory(
        at: target, withIntermediateDirectories: true)
    }
  }

  private func read(_ url: URL) throws -> Data {
    try waitForDownload(url)
    var data: Data?
    var failure: Error?
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: [], error: &coordinationError
    ) { target in
      do {
        data = try Data(contentsOf: target)
      } catch {
        failure = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let failure { throw failure }
    guard let data else { throw Failure.notFound }
    return data
  }

  private func waitForDownload(_ url: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path)
      || manager.fileExists(atPath: placeholder(of: url).path)
    else { throw Failure.notFound }
    try? manager.startDownloadingUbiquitousItem(at: url)
    let started = Date()
    while true {
      var fresh = url
      fresh.removeAllCachedResourceValues()
      let values = try? fresh.resourceValues(forKeys: [
        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
      ])
      let status = values?.ubiquitousItemDownloadingStatus
      let waited = Date().timeIntervalSince(started)
      if status == .current { return }
      if status == .downloaded {
        // A copy is here. A newer one may be on its way, but offline there
        // never will be, and this copy is good to read.
        if waited >= Self.freshenLimit { return }
      } else {
        if status == nil && manager.fileExists(atPath: url.path)
          && !manager.fileExists(atPath: placeholder(of: url).path)
        {
          // Not an iCloud item yet: a file this device has just written.
          return
        }
        if values?.ubiquitousItemDownloadingError != nil || waited >= Self.downloadLimit {
          throw Failure.offline
        }
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
  }

  private func write(_ data: Data, to url: URL) throws {
    try coordinate(writing: url, options: .forReplacing) { target in
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target, options: .atomic)
    }
  }

  private func delete(_ url: URL) throws {
    try coordinate(writing: url, options: .forDeleting) { target in
      do {
        try FileManager.default.removeItem(at: target)
      } catch CocoaError.fileNoSuchFile {
        // Already gone.
      }
    }
  }

  private func coordinate(
    writing url: URL,
    options: NSFileCoordinator.WritingOptions,
    _ work: (URL) throws -> Void
  ) throws {
    var failure: Error?
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: options, error: &coordinationError
    ) { target in
      do {
        try work(target)
      } catch {
        failure = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let failure { throw failure }
  }
}
