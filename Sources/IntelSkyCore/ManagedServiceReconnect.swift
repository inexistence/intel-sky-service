import Darwin
import Foundation

public enum ManagedServiceReconnectNotification {
  public static let name = Notification.Name(
    "com.openai.codex.computer-use.status-item-state-changed"
  )

  public static func userInfo(processIdentifier: pid_t) -> [AnyHashable: Any] {
    [
      "processIdentifier": NSNumber(value: processIdentifier),
      "computerUseActive": NSNumber(value: false),
      "computerHistoryState": "stopped",
    ]
  }

  public static func post(processIdentifier: pid_t) {
    DistributedNotificationCenter.default().postNotificationName(
      name,
      object: nil,
      userInfo: userInfo(processIdentifier: processIdentifier),
      deliverImmediately: true
    )
  }
}

public enum ManagedServiceReconnectWatchdogMode {
  public static let argument = "--notify-managed-service-exit"

  public static func parse(arguments: [String]) -> (servicePID: pid_t, hostPID: pid_t)? {
    guard arguments.count == 3, arguments[0] == argument,
      let servicePID = Int32(arguments[1]), servicePID > 1,
      let hostPID = Int32(arguments[2]), hostPID > 1,
      servicePID != hostPID
    else { return nil }
    return (servicePID, hostPID)
  }

  public static func arguments(servicePID: pid_t, hostPID: pid_t) -> [String] {
    [argument, String(servicePID), String(hostPID)]
  }

  public static func run(servicePID: pid_t, hostPID: pid_t) -> Int32 {
    guard getppid() == servicePID else { return 64 }

    let outcome = ManagedServiceExitWatchdogOutcome()
    let queue = DispatchQueue(
      label: "dev.huangjianbin.intel-sky-service.reconnect-watchdog"
    )
    let serviceExitSource = DispatchSource.makeProcessSource(
      identifier: servicePID,
      eventMask: .exit,
      queue: queue
    )
    let hostExitSource = DispatchSource.makeProcessSource(
      identifier: hostPID,
      eventMask: .exit,
      queue: queue
    )
    serviceExitSource.setEventHandler { outcome.finish(.serviceExited) }
    hostExitSource.setEventHandler { outcome.finish(.hostExited) }
    serviceExitSource.resume()
    hostExitSource.resume()

    let result = outcome.wait()
    serviceExitSource.cancel()
    hostExitSource.cancel()
    guard result == .serviceExited else { return 0 }

    // Give simultaneous ChatGPT shutdown a short chance to win without approaching the
    // official client's 250 ms fallback-to-LaunchServices threshold.
    Thread.sleep(forTimeInterval: 0.05)
    guard processHasExecutable(hostPID) else { return 0 }
    ManagedServiceReconnectNotification.post(processIdentifier: servicePID)
    return 0
  }

  private static func processHasExecutable(_ processIdentifier: pid_t) -> Bool {
    // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift cannot import. The documented
    // maximum is four times MAXPATHLEN (1024 on macOS).
    var bytes = [CChar](repeating: 0, count: 4_096)
    return proc_pidpath(processIdentifier, &bytes, UInt32(bytes.count)) > 0
  }
}

public final class ManagedServiceReconnectWatchdogLauncher: @unchecked Sendable {
  public typealias ProcessStarter = @Sendable (URL, [String]) throws -> Void

  private let lock = NSLock()
  private let executableURL: URL
  private let processStarter: ProcessStarter
  private var launchedHostProcessIdentifiers: Set<pid_t> = []

  public init(executableURL: URL) {
    self.executableURL = executableURL
    processStarter = Self.startProcess
  }

  init(executableURL: URL, processStarter: @escaping ProcessStarter) {
    self.executableURL = executableURL
    self.processStarter = processStarter
  }

  @discardableResult
  public func start(servicePID: pid_t, hostPID: pid_t) -> Bool {
    lock.withLock {
      guard !launchedHostProcessIdentifiers.contains(hostPID) else { return true }
      do {
        try processStarter(
          executableURL,
          ManagedServiceReconnectWatchdogMode.arguments(
            servicePID: servicePID,
            hostPID: hostPID
          )
        )
        launchedHostProcessIdentifiers.insert(hostPID)
        return true
      } catch {
        return false
      }
    }
  }

  private static func startProcess(executableURL: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }
}

public enum ManagedServiceLaunchPolicy {
  public static let launchServicesSocketBindDelay: TimeInterval = 1

  public static func socketBindDelay(arguments: [String], parentProcessIdentifier: pid_t)
    -> TimeInterval
  {
    arguments.isEmpty && parentProcessIdentifier == 1 ? launchServicesSocketBindDelay : 0
  }
}

private final class ManagedServiceExitWatchdogOutcome: @unchecked Sendable {
  enum Result: Equatable {
    case serviceExited
    case hostExited
  }

  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var result: Result?

  func finish(_ result: Result) {
    let didFinish = lock.withLock { () -> Bool in
      guard self.result == nil else { return false }
      self.result = result
      return true
    }
    if didFinish { semaphore.signal() }
  }

  func wait() -> Result {
    semaphore.wait()
    return lock.withLock { result! }
  }
}
