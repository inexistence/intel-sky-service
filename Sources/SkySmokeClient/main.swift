import Foundation
import IntelSkyCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
  fputs("usage: sky-smoke-client /absolute/path/computeruse.sock\n", stderr)
  exit(64)
}

let client = SkyUnixClient(socketPath: NSString(string: arguments[0]).expandingTildeInPath)
do {
  try client.connect()
  let ping = try client.request([
    "jsonrpc": "2.0",
    "id": 1,
    "method": "ping",
    "params": ["clientApiVersion": SkyProtocol.apiVersion],
  ])
  let data = try JSONSerialization.data(
    withJSONObject: ping, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  do {
    _ = try client.request([
      "jsonrpc": "2.0",
      "id": 2,
      "method": "request",
      "params": [
        "clientApiVersion": SkyProtocol.apiVersion,
        "requestType": "ComputerUseIPCListAppsRequest",
        "request": [:],
      ],
    ])
    fputs("security check failed: unsigned smoke client was unexpectedly authorized\n", stderr)
    exit(1)
  } catch {
    fputs("Unsigned client was rejected after ping as expected: \(error)\n", stderr)
  }
} catch {
  fputs("smoke test failed: \(error)\n", stderr)
  exit(1)
}
