import Foundation
import IntelSkyCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "--socket" else {
  fputs("usage: intel-sky-service --socket /absolute/path/computeruse.sock\n", stderr)
  exit(64)
}

let socketPath = NSString(string: arguments[1]).expandingTildeInPath
guard socketPath.hasPrefix("/") else {
  fputs("socket path must be absolute\n", stderr)
  exit(64)
}

let server = SkyUnixServer(
  socketPath: socketPath,
  router: SkyRequestRouter(
    appCatalog: WorkspaceAppCatalog(),
    appStateProvider: MacAppStateProvider()
  )
)

fputs("intel-sky-service starting at \(socketPath)\n", stderr)
do {
  try server.run()
} catch {
  fputs("fatal: \(error)\n", stderr)
  exit(1)
}
