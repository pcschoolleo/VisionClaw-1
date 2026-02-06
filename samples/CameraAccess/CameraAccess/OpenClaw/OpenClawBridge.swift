import Foundation

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle

  private let urlSession: URLSession
  private let longRunSession: URLSession

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: config)

    let longConfig = URLSessionConfiguration.default
    longConfig.timeoutIntervalForRequest = 120
    self.longRunSession = URLSession(configuration: longConfig)
  }

  // MARK: - Agent Chat (synchronous, waits for OpenClaw agent response)

  func delegateTask(
    task: String,
    toolName: String = "delegate_task"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": [
        ["role": "user", "content": task]
      ],
      "stream": false
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await longRunSession.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }

  // MARK: - Tool Invoke (synchronous, for web_search)

  func invokeTool(
    tool: String,
    action: String = "json",
    args: [String: Any]
  ) async -> ToolResult {
    lastToolCallStatus = .executing(tool)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/tools/invoke") else {
      lastToolCallStatus = .failed(tool, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
      "tool": tool,
      "action": action,
      "args": args,
      "sessionKey": "glass:default"
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await urlSession.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        NSLog("[OpenClaw] Tool invoke failed: HTTP %d", code)
        lastToolCallStatus = .failed(tool, "HTTP \(code)")
        return .failure("Tool invoke failed: HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let error = json["error"] as? String {
          lastToolCallStatus = .failed(tool, error)
          return .failure(error)
        }
        let resultObj = json["result"] ?? json
        let resultData = try JSONSerialization.data(withJSONObject: resultObj, options: [.sortedKeys])
        let resultStr = String(data: resultData, encoding: .utf8) ?? "OK"
        NSLog("[OpenClaw] Tool %@ result: %@", tool, String(resultStr.prefix(200)))
        lastToolCallStatus = .completed(tool)
        return .success(resultStr)
      }

      lastToolCallStatus = .completed(tool)
      return .success(String(data: data, encoding: .utf8) ?? "OK")
    } catch {
      NSLog("[OpenClaw] Tool invoke error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(tool, error.localizedDescription)
      return .failure("Tool invoke failed: \(error.localizedDescription)")
    }
  }
}
