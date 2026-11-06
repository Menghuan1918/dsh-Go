import Foundation
import UIKit
import Security
import Darwin

@MainActor
final class IOSPhoneBridge: NSObject, URLSessionTaskDelegate {
  private struct Endpoint: Decodable { let v: Int; let runId: String; let baseUrl: String }
  private struct Claimed: Decodable { let request: IOSPhoneRequest? }
  private typealias Arm = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
  private typealias Clear = @convention(c) (UnsafePointer<CChar>) -> Void
  private let nativeArm: Arm
  private let nativeClear: Clear
  private let actions: IOSPhoneActions
  private let browser: IOSBrowser
  private let runner: IOSPhoneRunner
  private let system: IOSSystemTools
  private let runtimeCurrent: () -> Bool
  private var directory: URL?
  private var runId: String?
  private var token: String?
  private var endpoint: URL?
  private var active: IOSPhoneRequest?
  private var poller: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var session: URLSession?
  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = 4
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
  // nativeLibrary is the already loaded DshNodeHost framework handle, retained
  // by NativeEngine for the lifetime of the runner and its linked modules.
  init(presenter: @escaping () -> UIViewController?, runtimeCurrent: @escaping () -> Bool,
       nativeLibrary: UnsafeMutableRawPointer) throws {
    guard let arm = dlsym(nativeLibrary, "dsh_ios_phone_arm"),
      let clear = dlsym(nativeLibrary, "dsh_ios_phone_clear") else { throw CocoaError(.executableNotLoadable) }
    nativeArm = unsafeBitCast(arm, to: Arm.self)
    nativeClear = unsafeBitCast(clear, to: Clear.self)
    self.actions = IOSPhoneActions(presenter: presenter)
    self.browser = IOSBrowser(actions: actions, presenter: presenter)
    self.runner = IOSPhoneRunner(actions: actions, selfRunner: .shared)
    self.system = IOSSystemTools(actions: actions, presenter: presenter)
    self.runtimeCurrent = runtimeCurrent
    super.init()
  }
  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

  // Only public generation and endpoint directory go in the Cordis overlay.
  // Secret exists only in Swift, C memory and the consuming Node environment.
  func prepare(in cache: URL) throws -> (directory: URL, runId: String) {
    retire()
    runner.warmUp()
    let generation = UUID().uuidString.lowercased()
    var random = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
      throw CocoaError(.fileWriteUnknown)
    }
    let credential = random.map { String(format: "%02x", $0) }.joined()
    let parent = cache.appendingPathComponent("ios-phone", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = parent.appendingPathComponent(generation, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard nativeArm(generation, credential) == 0 else {
      try? FileManager.default.removeItem(at: directory)
      throw CocoaError(.executableRuntimeMismatch)
    }
    self.directory = directory; runId = generation; token = credential
    session = makeSession()
    return (directory, generation)
  }
  // Start once the host has accepted startup. runtimeCurrent must additionally
  // bind the EngineChannel generation and running token captured for this launch.
  func startPolling() {
    guard poller == nil, let generation = runId else { return }
    poller = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.runId == generation else { return }
        await self.poll(generation)
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }
  }
  func retire() {
    poller?.cancel(); poller = nil
    session?.invalidateAndCancel(); session = nil
    browser.retire()
    runner.retire()
    system.retire()
    if let active { actions.cancel(active.id) }
    operation?.cancel(); operation = nil
    if let runId { nativeClear(runId) }
    active = nil; endpoint = nil; runId = nil; token = nil
    if let directory { try? FileManager.default.removeItem(at: directory) }
    directory = nil
  }
  // Called directly from didEnterBackground. No pending consent crosses a background hop.
  func enteredBackground() {
    browser.enteredBackground()
    guard let request = active else { return }
    actions.cancel(request.id)
  }
  private func current(_ request: IOSPhoneRequest) -> Bool {
    runId == request.runId && active?.id == request.id && runtimeCurrent()
  }
  private func readEndpoint() throws -> URL? {
    guard let directory, let runId else { return nil }
    let path = directory.appendingPathComponent("endpoint.json")
    guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
    defer { try? handle.close() }
    guard let bytes = try handle.read(upToCount: 4097), bytes.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
    let value = try JSONDecoder().decode(Endpoint.self, from: bytes)
    guard value.v == 1, value.runId == runId,
      value.baseUrl.range(of: #"^http://127\.0\.0\.1:[0-9]+$"#, options: .regularExpression) != nil,
      let url = URL(string: value.baseUrl), let port = url.port, (1...65535).contains(port) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return url
  }
  private func post(_ route: String, _ values: [String: Any] = [:]) async throws -> (Int, Data) {
    guard let endpoint, let runId, let token, let session else { throw URLError(.cancelled) }
    var body = values; body["runId"] = runId
    var request = URLRequest(url: endpoint.appendingPathComponent(route))
    request.httpMethod = "POST"
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (bytes, response) = try await session.data(for: request)
    guard bytes.count <= 32768, let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (http.statusCode, bytes)
  }
  private func poll(_ generation: String) async {
    guard runtimeCurrent(), runId == generation else { return }
    do {
      if endpoint == nil { endpoint = try readEndpoint() }
      guard endpoint != nil else { return }
      if let request = active {
        let (status, _) = try await post("status", ["id": request.id])
        guard runId == generation, active?.id == request.id else { return }
        if status == 410 || request.expiresAt <= Date().timeIntervalSince1970 * 1000 {
          active = nil
          operation?.cancel(); operation = nil
          actions.cancel(request.id)
          browser.enteredBackground()
          system.stopAsking()
        }
        return
      }
      // With the app away, only what needs nobody on screen: a turn the system is letting go on
      // can keep browsing a site already approved. The rest waits for the app to come back.
      let inFront = UIApplication.shared.applicationState == .active
      let (status, bytes) = try await post("claim", ["background": !inFront])
      guard runId == generation, runtimeCurrent(), status == 200,
        let request = try JSONDecoder().decode(Claimed.self, from: bytes).request else { return }
      guard request.v == 1, request.runId == generation, UUID(uuidString: request.id) != nil,
        !request.owner.sessionId.isEmpty, !request.owner.callId.isEmpty else { return }
      active = request
      operation = Task { [weak self] in
        guard let self else { return }
        let kind = request.action.kind
        if kind.hasPrefix("system-") {
          let current = { [weak self] in
            self?.current(request) == true && request.expiresAt > Date().timeIntervalSince1970 * 1000
          }
          let result = await self.system.run(request, authorize: { [weak self] in
            guard let self else { return false }
            return (try? await self.post("begin", ["id": request.id]))?.0 == 200
          }, current: current)
          guard self.current(request) else { return }
          _ = try? await self.post("result", ["id": request.id, "text": result.text, "isError": result.isError])
          guard self.active?.id == request.id else { return }
          self.active = nil; self.operation = nil
          return
        }
        if kind.hasPrefix("browser-") || kind.hasPrefix("runner-") {
          // The tool call has to still be waiting for this, now and after any question to the user.
          let current = { [weak self] in
            self?.current(request) == true && request.expiresAt > Date().timeIntervalSince1970 * 1000
          }
          let begun = (try? await self.post("begin", ["id": request.id]))?.0 == 200
          guard begun, current() else {
            if self.current(request) {
              _ = try? await self.post("result", ["id": request.id, "text": "这个工具调用已经结束，没有执行。", "isError": true])
              guard self.active?.id == request.id else { return }
              self.active = nil; self.operation = nil
            }
            return
          }
          let result = kind.hasPrefix("browser-")
            ? await self.browser.run(request, current: current) : await self.runner.run(request, current: current)
          guard self.current(request) else { return }
          var values: [String: Any] = ["id": request.id, "text": result.text, "isError": result.isError]
          if let image = result.image { values["image"] = image.base64EncodedString() }
          _ = try? await self.post("result", values)
          guard self.active?.id == request.id else { return }
          self.active = nil; self.operation = nil
          return
        }
        let result = await self.actions.run(request, current: { [weak self] in self?.current(request) == true }, authorize: { [weak self] in
          guard let self, self.current(request) else { return false }
          do {
            let (status, _) = try await self.post("begin", ["id": request.id])
            return status == 200 && self.current(request)
          } catch { return false }
        }, validate: { [weak self] in
          guard let self, self.current(request) else { return false }
          do {
            let (status, bytes) = try await self.post("status", ["id": request.id])
            let state = try JSONDecoder().decode([String: String].self, from: bytes)
            return status == 200 && state["state"] == "executing" && self.current(request)
          } catch { return false }
        })
        guard self.current(request) else { return }
        // A failed result upload is never permission to repeat a system action.
        _ = try? await self.post("result", ["id": request.id, "text": result.text, "isError": result.isError])
        guard self.active?.id == request.id else { return }
        self.active = nil; self.operation = nil
      }
    } catch {
      // Socket loss cannot authorize or replay anything. The per-call deadline and
      // EngineChannel's runtime stop/restart retire the outstanding request.
      if let request = active, request.expiresAt <= Date().timeIntervalSince1970 * 1000 { actions.cancel(request.id) }
    }
  }
}