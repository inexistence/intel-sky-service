import AppKit
import Foundation
import IntelSkyCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  print(
    "usage: intel-sky-service [--socket /absolute/path/computeruse.sock] [--experimental-pip] | --check-permissions"
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
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
ComputerUseVisualCoordinator.warmUp()
ServicePermissionRequester().requestMissingPermissions()
let pipBootstrapController: RemoteHostedPIPBootstrapController?
if configuration.experimentalPIPEnabled {
  let controller = RemoteHostedPIPBootstrapController()
  controller.start()
  pipBootstrapController = controller
  fputs("experimental remote-hosted PIP bootstrap enabled\n", stderr)
} else {
  pipBootstrapController = nil
}

let resolver = MacAppResolver()
let snapshotCache = ElementSnapshotCache()
let interactionTracker = AppInteractionTracker()
let server = SkyUnixServer(
  socketPath: socketPath,
  router: SkyRequestRouter(
    appCatalog: WorkspaceAppCatalog(),
    appStateProvider: MacAppStateProvider(
      resolver: resolver,
      snapshotCache: snapshotCache,
      interactionTracker: interactionTracker
    ),
    appActionPerformer: MacAppActionPerformer(
      resolver: resolver,
      snapshotCache: snapshotCache,
      interactionTracker: interactionTracker
    )
  )
)

fputs("intel-sky-service starting at \(socketPath)\n", stderr)
DispatchQueue.global(qos: .userInitiated).async {
  do {
    try server.run {
      let permissions = ServicePermissionDiagnostics().currentStatus()
      do {
        try ServiceRuntimeStatusWriter.write(
          ServiceRuntimeStatus(
            permissions: permissions,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            physicalInputMonitoring: PhysicalInputMonitor.shared.isAvailable,
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
  } catch {
    fputs("fatal: \(error)\n", stderr)
    exit(1)
  }
}
application.run()
