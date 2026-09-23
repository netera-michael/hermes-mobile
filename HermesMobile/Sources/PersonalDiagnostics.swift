import Foundation
import HermesKit
import Sentry

/// Personal build only. No DSN means the SDK is never started.
enum PersonalDiagnostics {
  static func start(bundle: Bundle = .main) -> DiagnosticsClient {
    guard let dsn = bundle.object(forInfoDictionaryKey: "HermesSentryDSN") as? String,
      let url = URLComponents(string: dsn), url.scheme == "https",
      url.host != nil, url.user?.isEmpty == false
    else { return .testValue }

    SentrySDK.start { options in
      options.dsn = dsn
      options.environment = "personal"
      options.debug = false
      options.sendDefaultPii = false
      options.enableSwizzling = false
      options.enableAutoBreadcrumbTracking = false
      options.enableNetworkBreadcrumbs = false
      options.enableCaptureFailedRequests = false
      options.enableAutoSessionTracking = false
      options.enableWatchdogTerminationTracking = false
      options.enableAppHangTracking = false
      options.enableAutoPerformanceTracing = false
      options.enableNetworkTracking = false
      options.enableFileIOTracing = false
      options.enableCoreDataTracing = false
      options.tracesSampleRate = 0
      options.tracePropagationTargets = []
      options.attachScreenshot = false
      options.attachViewHierarchy = false
      options.attachStacktrace = false
      options.enableMetricKit = false
      options.sessionReplay.sessionSampleRate = 0
      options.sessionReplay.onErrorSampleRate = 0
      options.sendClientReports = false
      options.maxBreadcrumbs = 20
      options.maxCacheItems = 10
      options.maxAttachmentSize = 0
      options.beforeBreadcrumb = { crumb in
        guard crumb.category == "hermes", let message = crumb.message,
          DiagnosticSignal(rawValue: message) != nil else { return nil }
        crumb.data = nil
        return crumb
      }
      options.beforeSend = { event in sanitize(event) }
    }
    let sink = Sink()
    var client = DiagnosticsClient()
    client.record = { sink.record($0) }
    #if DEBUG && targetEnvironment(simulator)
    // Explicit non-crashing, app-originated verification; unavailable on a phone.
    if ProcessInfo.processInfo.arguments.contains("--sentry-smoke-test") {
      client.record(.smokeTest)
    }
    #endif
    return client
  }

  /// Strip dynamic crash reasons and metadata; retain native addresses/UUIDs for
  /// server-side symbolication. Never serialize an NSError or a captured scope.
  static func sanitize(_ event: Event) -> Event? {
    guard event.type == nil || event.type == "default" else { return nil }
    let signal = event.message.flatMap { DiagnosticSignal(rawValue: $0.formatted) }
    guard signal != nil || event.exceptions?.isEmpty == false else { return nil }
    event.message = SentryMessage(formatted: signal?.rawValue ?? "nativeCrash")
    event.user = nil
    event.request = nil
    event.extra = nil
    event.context = nil
    event.tags = nil
    event.serverName = nil
    event.transaction = nil
    event.logger = nil
    event.error = nil
    event.fingerprint = nil
    for exception in event.exceptions ?? [] {
      exception.value = "Native exception (reason removed)"
      exception.type = "NativeCrash"
      exception.module = nil
      exception.mechanism = nil
      scrub(exception.stacktrace)
    }
    for thread in event.threads ?? [] {
      thread.name = nil
      scrub(thread.stacktrace)
    }
    scrub(event.stacktrace)
    for image in event.debugMeta ?? [] {
      image.name = image.name.map { ($0 as NSString).lastPathComponent }
      image.codeFile = image.codeFile.map { ($0 as NSString).lastPathComponent }
    }
    event.breadcrumbs = event.breadcrumbs?.filter {
      $0.category == "hermes" && DiagnosticSignal(rawValue: $0.message ?? "") != nil
    }
    event.breadcrumbs?.forEach { $0.data = nil }
    return event
  }

  private static func scrub(_ stack: SentryStacktrace?) {
    stack?.registers = [:]
    for frame in stack?.frames ?? [] {
      frame.vars = nil
      frame.contextLine = nil
      frame.preContext = nil
      frame.postContext = nil
      frame.fileName = nil
      frame.package = nil
      frame.function = nil
      frame.module = nil
    }
  }

  private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var budget = DiagnosticBudget()
    func record(_ signal: DiagnosticSignal) {
      let accepted = lock.withLock {
        budget.accept(signal, uptime: ProcessInfo.processInfo.systemUptime)
      }
      guard accepted else { return }
      let crumb = Breadcrumb(level: .info, category: "hermes")
      crumb.message = signal.rawValue
      SentrySDK.addBreadcrumb(crumb)
      if signal.isFailure {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: signal.rawValue)
        SentrySDK.capture(event: event)
      }
    }
  }
}
