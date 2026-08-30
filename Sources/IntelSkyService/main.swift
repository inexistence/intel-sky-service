import AppKit
import Darwin
import Foundation
import IntelSkyCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  print(
    "usage: intel-sky-service [--socket /absolute/path/computeruse.sock] [--disable-pip] | --check-permissions"
  )
  exit(0)
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

// ChatGPT starts its PIP host and the managed service concurrently, then sends the bootstrap Apple
// Event on a short deadline. Register that handler before constructing NSApplication or warming any
// visual runtime so the service is eligible as soon as its process is discoverable.
let pipBootstrapController: RemoteHostedPIPBootstrapController?
if configuration.remoteHostedPIPEnabled {
  let controller = RemoteHostedPIPBootstrapController()
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
let appCaptureProvider = AppCaptureSessionManager(appStateProvider: appStateProvider)
appCaptureProvider.installSessionStopHandling()
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
let server = SkyUnixServer(
  socketPath: socketPath,
  router: SkyRequestRouter(
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
)
let processIdentifier = ProcessInfo.processInfo.processIdentifier
let launchParentProcessIdentifier = getppid()
let cleanupRuntimeStatus: @Sendable () -> Void = {
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
  do {
    try server.run {
      let permissions = ServicePermissionDiagnostics().currentStatus()
      do {
        try ServiceRuntimeStatusWriter.write(
          ServiceRuntimeStatus(
            permissions: permissions,
            processIdentifier: processIdentifier,
            physicalInputMonitoring: PhysicalInputMonitor.shared.isAvailable,
            focusStealProtection: focusStealProtectionAvailable,
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
