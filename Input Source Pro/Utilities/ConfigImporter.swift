import Cocoa
import Combine
import Foundation

/// ConfigImporter monitors a JSON configuration file and imports app rules into Core Data.
///
/// Configuration file location: `~/.config/inputsourcepro/config.json`
///
/// JSON format:
/// ```json
/// {
///   "appRules": {
///     "com.apple.finder": "com.apple.keylayout.ABC",
///     "com.tencent.xinWeChat": "im.rime.inputmethod.Squirrel.Hans"
///   }
/// }
/// ```
@MainActor
final class ConfigImporter {
  // MARK: - Types

  struct Config: Codable {
    let appRules: [String: String]?  // bundleId -> inputSourceId

    enum CodingKeys: String, CodingKey {
      case appRules
    }
  }

  // MARK: - Properties

  private let preferencesVM: PreferencesVM
  private let configURL: URL
  private var fileMonitorSource: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private var directoryMonitorSource: DispatchSourceFileSystemObject?
  private var directoryDescriptor: Int32 = -1

  private var lastImportedHash: Int?

  static let configPath = "~/.config/inputsourcepro/config.json"

  // MARK: - Initialization

  init(preferencesVM: PreferencesVM) {
    self.preferencesVM = preferencesVM
    self.configURL = URL(fileURLWithPath: NSString(string: Self.configPath).expandingTildeInPath)

    // Initial import on startup
    importConfigIfNeeded()

    // Start monitoring for changes
    startMonitoring()
  }

  deinit {
    // Cancel dispatch sources directly without calling actor-isolated methods
    fileMonitorSource?.cancel()
    directoryMonitorSource?.cancel()
  }

  // MARK: - Public Methods

  /// Manually trigger a config import
  func importConfigIfNeeded() {
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      print("[ConfigImporter] Config file not found at: \(configURL.path)")
      return
    }

    do {
      let data = try Data(contentsOf: configURL)

      // Check if content has changed using hash
      let newHash = data.hashValue
      if newHash == lastImportedHash {
        print("[ConfigImporter] Config unchanged, skipping import")
        return
      }

      let config = try JSONDecoder().decode(Config.self, from: data)
      importConfig(config)
      lastImportedHash = newHash

      print("[ConfigImporter] Config imported successfully")
    } catch {
      print("[ConfigImporter] Failed to import config: \(error.localizedDescription)")
    }
  }

  // MARK: - Private Methods

  private func importConfig(_ config: Config) {
    guard let appRules = config.appRules, !appRules.isEmpty else {
      print("[ConfigImporter] No app rules found in config")
      return
    }

    // Clear all existing app rules
    clearAllAppRules()

    // Import new rules
    for (bundleId, inputSourceId) in appRules {
      addAppRule(bundleId: bundleId, inputSourceId: inputSourceId)
    }

    preferencesVM.saveContext()
    print("[ConfigImporter] Imported \(appRules.count) app rules")
  }

  private func clearAllAppRules() {
    let request = AppRule.fetchRequest()

    do {
      let existingRules = try preferencesVM.container.viewContext.fetch(request)
      for rule in existingRules {
        preferencesVM.container.viewContext.delete(rule)
      }
      print("[ConfigImporter] Cleared \(existingRules.count) existing app rules")
    } catch {
      print("[ConfigImporter] Failed to clear app rules: \(error.localizedDescription)")
    }
  }

  private func addAppRule(bundleId: String, inputSourceId: String) {
    // Find the application URL for this bundle ID
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
      print("[ConfigImporter] Could not find application for bundle ID: \(bundleId)")
      return
    }

    // Create new AppRule
    let appRule = AppRule(context: preferencesVM.container.viewContext)
    appRule.createdAt = Date()
    appRule.url = appURL
    appRule.bundleId = bundleId
    appRule.bundleName = FileManager.default.displayName(atPath: appURL.path)
    appRule.inputSourceId = inputSourceId

    print("[ConfigImporter] Added rule: \(bundleId) -> \(inputSourceId)")
  }

  // MARK: - File Monitoring

  private func startMonitoring() {
    // Ensure the config directory exists
    let configDir = configURL.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: configDir.path) {
      do {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        print("[ConfigImporter] Created config directory: \(configDir.path)")
      } catch {
        print("[ConfigImporter] Failed to create config directory: \(error.localizedDescription)")
      }
    }

    // Start monitoring the file if it exists
    if FileManager.default.fileExists(atPath: configURL.path) {
      startFileMonitor()
    }

    // Also monitor the directory for file creation
    startDirectoryMonitor()
  }

  private func startFileMonitor() {
    stopFileMonitor()

    fileDescriptor = open(configURL.path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      print("[ConfigImporter] Could not open file for monitoring: \(configURL.path)")
      return
    }

    fileMonitorSource = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .delete, .rename],
      queue: .main
    )

    fileMonitorSource?.setEventHandler { [weak self] in
      guard let self = self else { return }

      let flags = self.fileMonitorSource?.data ?? []

      if flags.contains(.delete) || flags.contains(.rename) {
        // File was deleted or renamed, restart monitoring
        self.stopFileMonitor()
        // Re-check after a short delay (file might be recreated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          if FileManager.default.fileExists(atPath: self?.configURL.path ?? "") {
            self?.startFileMonitor()
            self?.importConfigIfNeeded()
          }
        }
      } else if flags.contains(.write) {
        // File was modified
        self.importConfigIfNeeded()
      }
    }

    fileMonitorSource?.setCancelHandler { [weak self] in
      if let fd = self?.fileDescriptor, fd >= 0 {
        close(fd)
      }
      self?.fileDescriptor = -1
    }

    fileMonitorSource?.resume()
    print("[ConfigImporter] Started file monitor for: \(configURL.path)")
  }

  private func startDirectoryMonitor() {
    let configDir = configURL.deletingLastPathComponent()

    directoryDescriptor = open(configDir.path, O_EVTONLY)
    guard directoryDescriptor >= 0 else {
      print("[ConfigImporter] Could not open directory for monitoring: \(configDir.path)")
      return
    }

    directoryMonitorSource = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: directoryDescriptor,
      eventMask: [.write],
      queue: .main
    )

    directoryMonitorSource?.setEventHandler { [weak self] in
      guard let self = self else { return }

      // Check if config file now exists
      if FileManager.default.fileExists(atPath: self.configURL.path) {
        if self.fileMonitorSource == nil {
          self.startFileMonitor()
        }
        self.importConfigIfNeeded()
      }
    }

    directoryMonitorSource?.setCancelHandler { [weak self] in
      if let fd = self?.directoryDescriptor, fd >= 0 {
        close(fd)
      }
      self?.directoryDescriptor = -1
    }

    directoryMonitorSource?.resume()
    print("[ConfigImporter] Started directory monitor for: \(configDir.path)")
  }

  private func stopFileMonitor() {
    fileMonitorSource?.cancel()
    fileMonitorSource = nil
  }

  private func stopDirectoryMonitor() {
    directoryMonitorSource?.cancel()
    directoryMonitorSource = nil
  }

  private func stopMonitoring() {
    stopFileMonitor()
    stopDirectoryMonitor()
    print("[ConfigImporter] Stopped monitoring")
  }
}
