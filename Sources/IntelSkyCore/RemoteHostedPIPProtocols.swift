import Foundation
import XPC

typealias RemoteHostedPIPReply = @convention(block) (NSError?) -> Void

@objc(SAIRemoteHostedPIPContentHostXPCProtocol)
protocol RemoteHostedPIPContentHostXPCProtocol: NSObjectProtocol {
  @objc(publishPresentationWithID:threadID:turnID:contextID:width:height:withReply:)
  func publishPresentation(
    id presentationID: String,
    threadID: String,
    turnID: String,
    contextID: UInt32,
    width: Double,
    height: Double,
    reply: @escaping RemoteHostedPIPReply
  )

  @objc(setSourceProcessIdentifier:forPresentationWithID:withReply:)
  func setSourceProcessIdentifier(
    _ processIdentifier: Int32,
    presentationID: String,
    reply: @escaping RemoteHostedPIPReply
  )

  @objc(prepareOperationWithPresentationID:operationID:kind:contextID:width:height:fencePayload:withReply:)
  func prepareOperation(
    presentationID: String,
    operationID: UInt64,
    kind: String,
    contextID: UInt32,
    width: Double,
    height: Double,
    fencePayload: xpc_object_t,
    reply: @escaping RemoteHostedPIPReply
  )

  @objc(completeOperationWithPresentationID:operationID:withReply:)
  func completeOperation(
    presentationID: String,
    operationID: UInt64,
    reply: @escaping RemoteHostedPIPReply
  )

  @objc(willEndStreamWithPresentationID:withReply:)
  func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply)

  @objc(invalidatePresentationWithID:withReply:)
  func invalidatePresentation(id presentationID: String, reply: @escaping RemoteHostedPIPReply)

  @objc(noteInteractionWithPresentationID:withReply:)
  func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply)

  @objc(setComputerUseCursorLocationWithX:y:isActive:withReply:)
  func setComputerUseCursorLocation(
    x: Double,
    y: Double,
    isActive: ObjCBool,
    reply: @escaping RemoteHostedPIPReply
  )
}

@objc(SAIRemoteHostedPIPContentProducerXPCProtocol)
protocol RemoteHostedPIPContentProducerXPCProtocol: NSObjectProtocol {
  @objc(connectWithReply:)
  func connect(reply: @escaping RemoteHostedPIPReply)

  @objc(setMaxDisplaySize:withReply:)
  func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply)

  @objc(performActionWithPresentationID:kind:withReply:)
  func performAction(
    presentationID: String,
    kind: String,
    reply: @escaping RemoteHostedPIPReply
  )

  @objc(didEndStreamWithPresentationID:withReply:)
  func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply)
}

enum RemoteHostedPIPProtocolABI {
  static let hostProtocolName = "SAIRemoteHostedPIPContentHostXPCProtocol"
  static let producerProtocolName = "SAIRemoteHostedPIPContentProducerXPCProtocol"

  static let hostMethodTypes = [
    "publishPresentationWithID:threadID:turnID:contextID:width:height:withReply:":
      "v68@0:8@16@24@32I40d44d52@?60",
    "setSourceProcessIdentifier:forPresentationWithID:withReply:":
      "v36@0:8i16@20@?28",
    "prepareOperationWithPresentationID:operationID:kind:contextID:width:height:fencePayload:withReply:":
      "v76@0:8@16Q24@32I40d44d52@60@?68",
    "completeOperationWithPresentationID:operationID:withReply:":
      "v40@0:8@16Q24@?32",
    "willEndStreamWithPresentationID:withReply:": "v32@0:8@16@?24",
    "invalidatePresentationWithID:withReply:": "v32@0:8@16@?24",
    "noteInteractionWithPresentationID:withReply:": "v32@0:8@16@?24",
    "setComputerUseCursorLocationWithX:y:isActive:withReply:":
      "v44@0:8d16d24c32@?36",
  ]

  static let producerMethodTypes = [
    "connectWithReply:": "v24@0:8@?16",
    "setMaxDisplaySize:withReply:": "v32@0:8d16@?24",
    "performActionWithPresentationID:kind:withReply:": "v40@0:8@16@24@?32",
    "didEndStreamWithPresentationID:withReply:": "v32@0:8@16@?24",
  ]
}
