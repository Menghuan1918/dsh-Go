import Foundation
import UIKit
import EventKit
import EventKitUI
import MessageUI
import UserNotifications

struct IOSPhoneRequest: Decodable {
  struct Owner: Decodable { let sessionId: String; let callId: String }
  struct Action: Decodable {
    let kind: String
    let url: String?
    let title: String?
    let text: String?
    let begin: String?
    let end: String?
    let allDay: Bool?
    let location: String?
    let description: String?
    let number: String?
    let destination: String?
    let mode: String?
    // The browser tools.
    let ref: String?
    let epoch: Int?
    let key: String?
    let direction: String?
    let maxBytes: Int?
    // The phone runner's tools.
    let method: String?
    let params: String?
  }
  let v: Int
  let runId: String
  let id: String
  let owner: Owner
  let action: Action
  let expiresAt: Double
}
struct IOSPhoneOutcome {
  let text: String
  let isError: Bool
  /// A JPEG, for a tool whose answer is a picture.
  var image: Data?
  static func failure(_ text: String) -> Self { Self(text: text, isError: true) }
  static func success(_ text: String) -> Self { Self(text: text, isError: false) }
}

@MainActor
final class IOSPhoneApproval: UIViewController {
  private let heading: String
  private let detail: String
  private let allowTitle: String
  private let denyTitle: String
  private let answer: (Bool) -> Void
  init(heading: String = "允许这一次手机动作？", detail: String, allow: String = "允许一次", deny: String = "拒绝",
       answer: @escaping (Bool) -> Void) {
    self.heading = heading; self.detail = detail; self.allowTitle = allow; self.denyTitle = deny; self.answer = answer
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    isModalInPresentation = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = heading
    title.font = .preferredFont(forTextStyle: .headline)
    let text = UITextView()
    text.isEditable = false
    text.isSelectable = true
    text.text = detail
    text.font = .preferredFont(forTextStyle: .body)
    let deny = UIButton(type: .system)
    deny.setTitle(denyTitle, for: .normal)
    deny.addAction(UIAction { [weak self] _ in self?.answer(false) }, for: .touchUpInside)
    let allow = UIButton(type: .system)
    allow.setTitle(allowTitle, for: .normal)
    allow.addAction(UIAction { [weak self] _ in self?.answer(true) }, for: .touchUpInside)
    let buttons = UIStackView(arrangedSubviews: [deny, allow])
    buttons.distribution = .fillEqually
    let stack = UIStackView(arrangedSubviews: [title, text, buttons])
    stack.axis = .vertical; stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      buttons.heightAnchor.constraint(equalToConstant: 48),
    ])
  }
}

@MainActor
final class IOSPhoneActions: NSObject, EKEventEditViewDelegate, MFMessageComposeViewControllerDelegate {
  private let presenter: () -> UIViewController?
  private var requestId: String?
  private var modal: UIViewController?
  private var answer: ((IOSPhoneOutcome) -> Void)?
  private var calendarStore: EKEventStore?
  init(presenter: @escaping () -> UIViewController?) { self.presenter = presenter }

  func cancel(_ id: String) {
    guard requestId == id else { return }
    requestId = nil
    calendarStore = nil
    finish(.failure("原任务已取消或引擎已更换，旧确认不能再执行。"))
  }
  private func finish(_ value: IOSPhoneOutcome) {
    let callback = answer
    answer = nil
    let old = modal; modal = nil
    if let old, old.presentingViewController != nil {
      old.dismiss(animated: true) { callback?(value) }
    } else { callback?(value) }
  }
  private func present(_ controller: UIViewController) async -> IOSPhoneOutcome {
    guard let host = presenter(), host.viewIfLoaded?.window != nil, host.presentedViewController == nil else {
      return .failure("确认界面当前不可用，请回到 DSH Go 后由用户重新发起。")
    }
    return await withCheckedContinuation { continuation in
      modal = controller
      answer = { continuation.resume(returning: $0) }
      host.present(controller, animated: true)
    }
  }
  private var foreground: Bool {
    UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
  }
  func run(_ request: IOSPhoneRequest, current: @escaping () -> Bool,
           authorize: @escaping () async -> Bool, validate: @escaping () async -> Bool) async -> IOSPhoneOutcome {
    guard foreground, current(), request.expiresAt > Date().timeIntervalSince1970 * 1000 else {
      return .failure("请先解锁并打开 DSH Go；后台或已过期的动作不执行。")
    }
    requestId = request.id
    defer { if requestId == request.id { requestId = nil; calendarStore = nil } }
    let detail: String
    do { detail = try describe(request.action) } catch { return .failure("手机动作参数无效或 iOS 不支持。") }
    let controller = IOSPhoneApproval(detail: detail) { [weak self] allowed in
      guard let self, self.requestId == request.id else { return }
      self.finish(allowed ? .success("allowed-once") : .failure("用户拒绝了这一步；不要自动重试同一个动作。"))
    }
    let expiry = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled, let self, self.requestId == request.id, self.modal === controller else { return }
      self.finish(.failure("用户未在确认时间内选择；未执行动作。"))
    }
    let choice = await present(controller)
    expiry.cancel()
    guard !choice.isError else { return choice }
    // The Node-side invocation must still own this exact request AFTER the real tap.
    guard requestId == request.id, current(), foreground, await authorize(),
      requestId == request.id, current(), foreground else {
      return .failure("确认对应的原任务已经结束，未执行动作。")
    }
    return await perform(request.action, id: request.id, validate: validate)
  }
  /// The same real sheet, for a tool that decides what happens after the answer itself.
  func confirm(
    _ request: IOSPhoneRequest, title: String, detail: String, allow: String = "允许一次", deny: String = "拒绝",
    waitsForever: Bool = false
  ) async -> Bool {
    // A sheet cannot appear over another app. When DSH Go is in the background, ask through a
    // notification action instead: the action is guarded by Face ID/passcode, and NotifyTaps
    // resumes this continuation. The notification body is only a short summary.
    if !foreground {
      return await PhoneApprovalCenter.shared.request(
        id: request.id, title: title, detail: detail,
        timeout: waitsForever ? 600 : 30)
    }
    requestId = request.id
    defer { if requestId == request.id { requestId = nil } }
    let controller = IOSPhoneApproval(heading: title, detail: detail, allow: allow, deny: deny) { [weak self] allowed in
      guard let self, self.requestId == request.id else { return }
      self.finish(allowed ? .success("allowed-once") : .failure("declined"))
    }
    let expiry = Task { [weak self] in
      if waitsForever { return }
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !Task.isCancelled, let self, self.requestId == request.id, self.modal === controller else { return }
      self.finish(.failure("timed-out"))
    }
    let choice = await present(controller)
    expiry.cancel()
    return !choice.isError && requestId == request.id && foreground
  }
  private func required(_ value: String?, max: Int = 8192) throws -> String {
    guard let value, !value.isEmpty, value.utf8.count <= max, !value.contains("\0") else { throw CocoaError(.coderInvalidValue) }
    return value
  }
  private func safeURL(_ value: String?) throws -> URL {
    guard let url = URL(string: try required(value, max: 2048)),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
      url.user == nil, url.password == nil else { throw CocoaError(.coderInvalidValue) }
    return url
  }
  private func phoneNumber(_ value: String?) throws -> String {
    let value = try required(value, max: 100)
    guard value.range(of: #"^[+0-9 ()-]+$"#, options: .regularExpression) != nil,
      value.range(of: "[0-9]", options: .regularExpression) != nil else { throw CocoaError(.coderInvalidValue) }
    return value
  }
  private func date(_ value: String) -> Date? {
    let value = value.replacingOccurrences(of: " ", with: "T")
    if let instant = ISO8601DateFormatter().date(from: value) { return instant }
    for format in ["yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mmXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = .current
      formatter.dateFormat = format
      formatter.isLenient = false
      if let result = formatter.date(from: value) { return result }
    }
    return nil
  }
  private func calendarDates(_ a: IOSPhoneRequest.Action) throws -> (Date, Date, Bool) {
    let beginText = try required(a.begin, max: 100)
    guard let begin = date(beginText) else { throw CocoaError(.coderInvalidValue) }
    let allDay = a.allDay ?? (beginText.count == 10)
    let end: Date
    if let endText = a.end {
      guard let parsed = date(endText) else { throw CocoaError(.coderInvalidValue) }; end = parsed
    } else { end = begin.addingTimeInterval(allDay ? 86400 : 3600) }
    guard end >= begin else { throw CocoaError(.coderInvalidValue) }
    return (begin, end, allDay)
  }
  private func describe(_ a: IOSPhoneRequest.Action) throws -> String {
    switch a.kind {
    case "open": return "打开网址（只请求系统打开，不代表已完成网页中的操作）：\n\(try safeURL(a.url).absoluteString)"
    case "clipboard-get": return "读取当前剪贴板文字并发送给本次模型会话。剪贴板可能含私人信息；系统还可能询问粘贴权限。"
    case "clipboard-set":
      guard let value = a.text, value.utf8.count <= 8192, !value.contains("\0") else { throw CocoaError(.coderInvalidValue) }
      return "用以下全文替换剪贴板：\n\(value)"
    case "notify": return "发布本 App 的本地通知：\n标题：\(try required(a.title, max: 256))\n正文：\(try required(a.text))\n点通知只打开 App，不批准其他操作。"
    case "dial": return "打开系统拨号确认：\(try phoneNumber(a.number))\n系统可能再要求确认呼叫，不自动确认。"
    case "sms-draft":
      let recipient = try a.number.map { try phoneNumber($0) } ?? "由用户选择"
      return "打开短信草稿，最终由用户点发送：\n收件人：\(recipient)\n全文：\(try required(a.text))"
    case "share": return "打开系统分享面板，由用户选择目标并完成分享：\n\(try required(a.text))"
    case "settings": return "打开 DSH Go 本 App 的系统设置页；不会更改任何设置。"
    case "navigate":
      guard ["drive", "walk", "transit"].contains(a.mode ?? "") else { throw CocoaError(.coderInvalidValue) }
      return "在 Apple Maps 打开路线请求，由用户核对目的地并开始导航：\n目的地：\(try required(a.destination, max: 1024))\n方式：\(a.mode!)"
    case "calendar":
      let (begin, end, allDay) = try calendarDates(a)
      if let location = a.location { _ = try required(location, max: 1024) }
      if let description = a.description { _ = try required(description) }
      return "打开系统日程编辑器，由用户检查并保存：\n标题：\(try required(a.title, max: 256))\n开始：\(begin)\n结束：\(end)\n全天：\(allDay)\n地点：\(a.location ?? "")\n备注：\(a.description ?? "")"
    default: throw CocoaError(.coderInvalidValue)
    }
  }
  private func open(_ url: URL) async -> IOSPhoneOutcome {
    let accepted = await withCheckedContinuation { continuation in
      UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
    }
    return accepted ? .success("系统已接受打开请求；不表示已完成目标 App 中的操作。") : .failure("系统无法打开该目标。")
  }
  private func perform(_ a: IOSPhoneRequest.Action, id: String, validate: () async -> Bool) async -> IOSPhoneOutcome {
    do {
      switch a.kind {
      case "open": return await open(try safeURL(a.url))
      case "settings": return await open(URL(string: UIApplication.openSettingsURLString)!)
      case "dial":
        let value = try phoneNumber(a.number).replacingOccurrences(of: "[ ()-]", with: "", options: .regularExpression)
        return await open(URL(string: "tel:" + value)!)
      case "clipboard-set": UIPasteboard.general.string = a.text!; return .success("已写入剪贴板。")
      case "clipboard-get":
        let value = UIPasteboard.general.string ?? ""
        guard value.utf8.count <= 8192 else { return .failure("剪贴板超过 8192 UTF-8 字节，本次未发送给模型。") }
        return .success(value)
      case "notify":
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return .failure("用户未授予通知权限。") }
        guard requestId == id, foreground, await validate(), requestId == id, foreground else {
          return .failure("原任务已取消、已过期或 App 已进入后台。")
        }
        let content = UNMutableNotificationContent(); content.title = a.title!; content.body = a.text!
        // No category/action identifiers: a notification tap is navigation, never authority.
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        return .success("已提交本地通知；是否显示由系统通知设置决定。")
      case "navigate":
        var components = URLComponents(string: "https://maps.apple.com/")!
        let flag = ["drive": "d", "walk": "w", "transit": "r"][a.mode!]!
        components.queryItems = [URLQueryItem(name: "daddr", value: a.destination!), URLQueryItem(name: "dirflg", value: flag)]
        return await open(components.url!)
      case "share":
        let controller = UIActivityViewController(activityItems: [a.text!], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = presenter()?.view
        controller.completionWithItemsHandler = { [weak self, weak controller] _, completed, _, _ in
          guard let self, let controller, self.modal === controller, self.requestId == id else { return }
          self.finish(completed ? .success("用户已完成系统分享操作。") : .failure("用户取消了分享。"))
        }
        return await present(controller)
      case "sms-draft":
        guard MFMessageComposeViewController.canSendText() else { return .failure("此设备当前不能发送短信。") }
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = self; controller.body = a.text!
        controller.recipients = a.number.map { [$0] }
        return await present(controller)
      case "calendar":
        let store = EKEventStore(); calendarStore = store
        if #available(iOS 17.0, *) {
          // iOS 17+ EventKitUI's editor requires no broad calendar access.
        } else {
          let granted = await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { allowed, _ in continuation.resume(returning: allowed) }
          }
          guard granted else { return .failure("用户未授予旧版 iOS 所需的日历权限。") }
        }
        guard requestId == id, foreground, await validate(), requestId == id, foreground else {
          return .failure("原任务已取消、已过期或 App 已进入后台。")
        }
        let (begin, end, allDay) = try calendarDates(a)
        let event = EKEvent(eventStore: store)
        event.title = a.title!; event.startDate = begin; event.endDate = end; event.isAllDay = allDay
        event.location = a.location; event.notes = a.description
        let controller = EKEventEditViewController()
        controller.eventStore = store; controller.event = event; controller.editViewDelegate = self
        return await present(controller)
      default: return .failure("iOS 不支持该手机动作。")
      }
    } catch { return .failure("系统未完成手机动作；请用户检查，不要自动重试。") }
  }
  func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
    guard modal === controller else { return }
    finish(action == .saved ? .success("用户已在系统编辑器保存日程。") : .failure("用户取消了日程编辑。"))
  }
  func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
    guard modal === controller else { return }
    finish(result == .sent ? .success("系统报告短信已发送；不保证已送达。") : .failure("短信草稿已取消或发送失败。"))
  }
}


// MARK: - Background approval

/// Resolves a phone approval from a notification action when no sheet can be shown.
/// The action has authenticationRequired, so iOS asks for Face ID/passcode before it runs.
@MainActor
final class PhoneApprovalCenter {
  static let shared = PhoneApprovalCenter()
  static let categoryIdentifier = "dsh.phone.approval"
  static let allowAction = "dsh.phone.allow"
  static let denyAction = "dsh.phone.deny"

  static var category: UNNotificationCategory {
    let allow = UNNotificationAction(
      identifier: allowAction, title: "允许一次", options: [.authenticationRequired])
    let deny = UNNotificationAction(
      identifier: denyAction, title: "拒绝", options: [.authenticationRequired, .destructive])
    return UNNotificationCategory(
      identifier: categoryIdentifier, actions: [allow, deny],
      intentIdentifiers: [], options: [.customDismissAction])
  }

  private let center = UNUserNotificationCenter.current()
  private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
  private var timeouts: [String: Task<Void, Never>] = [:]

  func request(id: String, title: String, detail: String, timeout: TimeInterval) async -> Bool {
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
      return false
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = String(detail.prefix(300))
    content.categoryIdentifier = Self.categoryIdentifier
    content.userInfo = ["requestId": id]
    content.threadIdentifier = "dsh.phone.approval"
    content.sound = .default
    do {
      try await center.add(UNNotificationRequest(
        identifier: "phone-" + id, content: content, trigger: nil))
    } catch {
      return false
    }
    return await withCheckedContinuation { continuation in
      pending[id] = continuation
      timeouts[id] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.resolve(id: id, allowed: false)
      }
    }
  }

  func resolve(id: String, allowed: Bool) {
    timeouts[id]?.cancel()
    timeouts[id] = nil
    if let continuation = pending.removeValue(forKey: id) {
      continuation.resume(returning: allowed)
    }
    center.removeDeliveredNotifications(withIdentifiers: ["phone-" + id])
  }
}
