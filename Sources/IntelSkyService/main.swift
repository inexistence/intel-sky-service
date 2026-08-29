import Foundation
import IntelSkyCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
  print("usage: intel-sky-service [--socket /absolute/path/computeruse.sock]")
  exit(0)
}
let configuration: SkyServiceConfiguration
do {
  configuration = try SkyServiceConfiguration(arguments: arguments)
} catch {
  fputs("\(error)\n", stderr)
  exit(64)
}
let socketPath = configuration.socketPath

let resolver = MacAppResolver()
let snapshotCache = ElementSnapshotCache()
let server = SkyUnixServer(
  socketPath: socketPath,
  router: SkyRequestRouter(
    appCatalog: WorkspaceAppCatalog(),
    appStateProvider: MacAppStateProvider(
      resolver: resolver,
      snapshotCache: snapshotCache
    ),
    appActionPerformer: MacAppActionPerformer(
      resolver: resolver,
      snapshotCache: snapshotCache
    )
  )
)

fputs("intel-sky-service starting at \(socketPath)\n", stderr)
do {
  try server.run()
} catch {
  fputs("fatal: \(error)\n", stderr)
  exit(1)
}
