import AppKit
import Darwin
import Foundation
import IntelSkyCore

let arguments = Array(CommandLine.arguments.dropFirst())
if let watchdog = ManagedServiceReconnectWatchdogMode.parse(arguments: arguments) {
  exit(
    ManagedServiceReconnectWatchdogMode.run(
      servicePID: watchdog.servicePID,
      hostPID: watchdog.hostPID
    )
  )
}
if arguments == ["--help"] || arguments == ["-h"] {
  print(
    "usage: intel-sky-service [--socket /absolute/path/computeruse.sock] [--disable-pip] | --check-permissions | --prepare-capability | --register-capability"
  )
  exit(0)
}
if arguments == ["--prepare-capability"] {
  let registration = ComputerUseCapabilityRegistrar().prepareRuntime()
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  do {
    FileHandle.standardOutput.write(try encoder.encode(registration))
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fputs("could not encode capability preparation: \(error)\n", stderr)
    exit(1)
  }
  exit(registration.registered ? 0 : 78)
}
if arguments == ["--register-capability"] {
  let registration = ComputerUseCapabilityRegistrar().register()
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  do {
    FileHandle.standardOutput.write(try encoder.encode(registration))
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fputs("could not encode capability registration: \(error)\n", stderr)
    exit(1)
  }
  exit(registration.registered ? 0 : 78)
}
if arguments == ["--check-permissions"] {
  let status = ServicePermissionDiagnostics().currentStatus()
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  do {
    FileHandle.standardOutput.write(try encoder.encode(status))
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fputs("could not encode permission status: \(error)\n", stderr)
    exit(1)
  }
  exit(status.allGranted ? 0 : 77)
}
let configuration: SkyServiceConfiguration
do {
  configuration = try SkyServiceConfiguration(arguments: arguments)
} catch {
  fputs("\(error)\n", stderr)
  exit(64)
}
let socketPath = configuration.socketPath
let processIdentifier = ProcessInfo.processInfo.processIdentifier
let launchParentProcessIdentifier = getppid()
let socketBindDelay = ManagedServiceLaunchPolicy.socketBindDelay(
  arguments: arguments,
  parentProcessIdentifier: launchParentProcessIdentifier
)
let reconnectWatchdogLauncher = Bundle.main.executableURL.map {
  ManagedServiceReconnectWatchdogLauncher(executableURL: $0)
}

// ChatGPT starts its PIP host and the managed service concurrently, then sends the bootstrap Apple
// Event on a short deadline. Register that handler before constructing NSApplication or warming any
// visual runtime so the service is eligible as soon as its process is discoverable.
let pipBootstrapController: RemoteHostedPIPBootstrapController?
if configuration.remoteHostedPIPEnabled {
  let controller = RemoteHostedPIPBootstrapController()
  controller.setAuthorizedHostHandler { hostProcessIdentifier in
    guard
      reconnectWatchdogLauncher?.start(
        servicePID: processIdentifier,
        hostPID: hostProcessIdentifier
      ) == true
    else {
      fputs("warning: could not start managed-service reconnect watchdog\n", stderr)
      return
    }
    fputs(
      "managed-service reconnect watchdog started for host pid=\(hostProcessIdentifier)\n",
      stderr
    )
  }
  controller.start()
  pipBootstrapController = controller
  fputs("remote-hosted PIP bootstrap enabled\n", stderr)
} else {
  pipBootstrapController = nil
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
ComputerUseVisualCoordinator.warmUp()
let focusStealProtectionAvailable = ComputerUseFocusProtection.warmUp()
ServicePermissionRequester().requestMissingPermissions()

let resolver = MacAppResolver()
let snapshotCache = ElementSnapshotCache()
let interactionTracker = AppInteractionTracker()
let appStateProvider = MacAppStateProvider(
  resolver: resolver,
  snapshotCache: snapshotCache,
  interactionTracker: interactionTracker
)
let appCaptureProvider = AppCaptureSessionManager(
  appStateProvider: appStateProvider,
  changeMonitorFactory: { processIdentifier, changeHandler in
    NativeAppCaptureChangeMonitor(
      processIdentifier: processIdentifier,
      changeHandler: changeHandler
    )
  }
)
appCaptureProvider.installSessionStopHandling { bundleIdentifier, threadID in
  appStateProvider.deactivate(bundleIdentifier: bundleIdentifier, threadID: threadID)
}
let eventStreamProvider = EventStreamSessionManager(
  rootDirectoryURL: URL(fileURLWithPath: socketPath)
    .deletingLastPathComponent()
    .appendingPathComponent("EventStreams", isDirectory: true)
)
let nativeBridgeController = ComputerUseNativeBridgeController(
  appStateProvider: appStateProvider,
  appCaptureProvider: appCaptureProvider
)
nativeBridgeController.start()
let router = SkyRequestRouter(
  appCatalog: WorkspaceAppCatalog(),
  appStateProvider: appStateProvider,
  appActionPerformer: MacAppActionPerformer(
    resolver: resolver,
    snapshotCache: snapshotCache,
    interactionTracker: interactionTracker
  ),
  appCaptureProvider: appCaptureProvider,
  appLifecycleProvider: MacAppLifecycleProvider(resolver: resolver),
  eventStreamProvider: eventStreamProvider,
  requestObserver: pipBootstrapController
)
let appServerThreadEventObserver = CodexAppServerThreadEventObserver(
  turnEnded: { threadID in
    fputs("Codex turn completed for thread \(threadID); revoking Computer Use runtime\n", stderr)
    router.codexTurnDidEnd(threadID: threadID)
  },
  diagnostic: { message in fputs("warning: \(message)\n", stderr) }
)
appServerThreadEventObserver.start()
let screenLockMonitor = ComputerUseScreenLockMonitor {
  fputs("screen locked or console session changed; revoking Computer Use runtime\n", stderr)
  router.screenDidLock()
}
screenLockMonitor.start()
let server = SkyUnixServer(
  socketPath: socketPath,
  router: router,
  shutdownAfterLastAuthenticatedClientDelay: 1,
  shouldShutdownWhenIdle: {
    // A managed instance that never obtained the native PIP host must not outlive its last
    // ChatGPT client. Otherwise it blocks the replacement instance launched during the next
    // ChatGPT startup and consumes that process's one-shot bootstrap event.
    !(pipBootstrapController?.isHostConnected ?? false)
  }
)
pipBootstrapController?.setHostInvalidationHandler { [weak server] in
  fputs("native PIP host disconnected; shutting down managed service\n", stderr)
  server?.shutdown()
}
let cleanupRuntimeStatus: @Sendable () -> Void = {
  appServerThreadEventObserver.stop()
  screenLockMonitor.stop()
  do {
    try ServiceRuntimeStatusWriter.removeIfCurrent(
      processIdentifier: processIdentifier,
      nextToSocketAt: socketPath
    )
  } catch {
    fputs("warning: could not remove runtime status: \(error)\n", stderr)
  }
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSources = [SIGTERM, SIGINT].map { signalNumber in
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    server.shutdown()
  }
  source.resume()
  return source
}
let managedParentExitSource: DispatchSourceProcess? = {
  guard launchParentProcessIdentifier > 1 else { return nil }
  let source = DispatchSource.makeProcessSource(
    identifier: launchParentProcessIdentifier,
    eventMask: .exit,
    queue: .main
  )
  source.setEventHandler {
    fputs(
      "managed parent exited pid=\(launchParentProcessIdentifier); shutting down service\n",
      stderr
    )
    server.shutdown()
  }
  source.resume()
  return source
}()

fputs("intel-sky-service starting at \(socketPath)\n", stderr)
DispatchQueue.global(qos: .userInitiated).async {
  if socketBindDelay > 0 {
    fputs(
      "LaunchServices fallback delaying socket bind by \(socketBindDelay) seconds\n",
      stderr
    )
    Thread.sleep(forTimeInterval: socketBindDelay)
  }
  do {
    try server.run {
      let permissions = ServicePermissionDiagnostics().currentStatus()
      let capability = ComputerUseCapabilityRegistrar().register()
      do {
        try ServiceRuntimeStatusWriter.write(
          ServiceRuntimeStatus(
            permissions: permissions,
            processIdentifier: processIdentifier,
            physicalInputMonitoring: PhysicalInputMonitor.shared.isAvailable,
            focusStealProtection: focusStealProtectionAvailable,
            computerUseCapability: capability,
            updatedAt: Date()
          ),
          nextToSocketAt: socketPath
        )
      } catch {
        fputs("warning: could not write runtime status: \(error)\n", stderr)
      }
      fputs(
        "permissions: accessibility=\(permissions.accessibility) screenRecording=\(permissions.screenRecording)\n",
        stderr
      )
      if capability.registered {
        fputs("Computer Use capability registered for new Codex sessions\n", stderr)
      } else {
        fputs(
          "Computer Use capability unavailable: \(capability.diagnostic ?? "unknown error")\n",
          stderr
        )
      }
    }
    cleanupRuntimeStatus()
    DispatchQueue.main.async {
      application.terminate(nil)
    }
  } catch {
    cleanupRuntimeStatus()
    fputs("fatal: \(error)\n", stderr)
    exit(1)
  }
}
application.run()
managedParentExitSource?.cancel()
for source in terminationSources { source.cancel() }
server.shutdown()
cleanupRuntimeStatus()
