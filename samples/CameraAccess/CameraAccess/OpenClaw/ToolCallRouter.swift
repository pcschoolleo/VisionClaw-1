import Foundation

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  /// Route a tool call from Gemini to OpenClaw. Calls sendResponse with the
  /// JSON dictionary to send back as a toolResponse message.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    let task = Task { @MainActor in
      let result: ToolResult

      switch callName {
      case "delegate_task":
        let taskDesc = call.args["task"] as? String ?? ""
        result = await bridge.delegateTask(task: taskDesc, toolName: "delegate_task")

      case "send_message":
        let to = call.args["to"] as? String ?? ""
        let message = call.args["message"] as? String ?? ""
        let channel = call.args["channel"] as? String ?? "last"
        let taskDesc = "Send a \(channel) message to \(to) saying: \(message)"
        result = await bridge.delegateTask(task: taskDesc, toolName: "send_message")

      case "web_search":
        let query = call.args["query"] as? String ?? ""
        result = await bridge.invokeTool(
          tool: "web_search",
          action: "json",
          args: ["query": query]
        )

      default:
        NSLog("[ToolCall] Unknown tool '%@', delegating as generic task", callName)
        result = await bridge.delegateTask(
          task: "Execute tool '\(callName)' with args: \(call.args)",
          toolName: callName
        )
      }

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
  }

  // MARK: - Private

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
