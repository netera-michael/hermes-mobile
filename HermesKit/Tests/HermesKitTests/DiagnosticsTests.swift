import Testing
@testable import HermesKit

struct DiagnosticsTests {
  @Test func cooldownAndBudget() {
    var budget = DiagnosticBudget()
    let first = budget.accept(.sendFailed, uptime: 0)
    let cooldown = budget.accept(.sendFailed, uptime: 59)
    let afterCooldown = budget.accept(.sendFailed, uptime: 60)
    #expect(first)
    #expect(!cooldown)
    #expect(afterCooldown)
    for index in 2..<10 {
      let accepted = budget.accept(.sendFailed, uptime: Double(index) * 60)
      #expect(accepted)
    }
    let exhausted = budget.accept(.sessionFailed, uptime: 700)
    let breadcrumb = budget.accept(.sessionOpened, uptime: 700)
    let duplicateBreadcrumb = budget.accept(.sessionOpened, uptime: 701)
    #expect(!exhausted)
    #expect(breadcrumb)
    #expect(!duplicateBreadcrumb)
  }

  @Test func payloadsNeverBecomeDiagnostics() {
    #expect(ChatFeature.diagnosticSignal(for: .promptSubmitFailed(message: "secret https://private")) == .sendFailed)
    #expect(ChatFeature.diagnosticSignal(for: .modelSelected(model: "private model", provider: "secret")) == .modelChanged)
    #expect(ChatFeature.diagnosticSignal(for: .gatewayEvent(.messageDelta(text: "private chat"))) == nil)
    #expect(ChatFeature.diagnosticSignal(for: .gatewayEvent(.error(message: "token=secret"))) == .connectionFailed)
    #expect(DiagnosticSignal(rawValue: "private chat") == nil)
  }

  @Test func defaultsAreInert() {
    DiagnosticsClient.liveValue.record(.smokeTest)
    DiagnosticsClient.testValue.record(.smokeTest)
  }
}
