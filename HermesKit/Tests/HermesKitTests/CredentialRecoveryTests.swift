import ComposableArchitecture
import CryptoKit
import Foundation
import Testing
@testable import HermesKit

extension RESTTransportSuite {
  @Suite(.serialized) struct CredentialRecoveryTests {
    @Test func corruptRecordRecoveryInvalidatesOldAndCompetingWriters() throws {
      let fixture = try RecoveryFixture()
      defer { fixture.cleanup() }
      let client = fixture.client()
      let old = client.persistence(freshLogin: false), oldLogin = client.persistence(freshLogin: true)
      try Data("corrupt".utf8).write(to: fixture.record)
      #expect(client.loadToken() == nil)
      let forbiddenRotation = client.persistence(freshLogin: false)
      let fresh = client.persistence(freshLogin: true), competitor = client.persistence(freshLogin: true)
      #expect(throws: KeychainError.retired) { try forbiddenRotation(.token("rotation")) }
      #expect(throws: KeychainError.retired) { try old(.token("old")) }
      #expect(throws: KeychainError.retired) { try oldLogin(.token("old-login")) }
      try fresh(.token("new"))
      #expect(fixture.client().loadToken() == "new")
      #expect(throws: KeychainError.retired) { try competitor(.token("competitor")) }
      try fresh(.token("new-rotation"))
      #expect(fixture.client().loadToken() == "new-rotation")
    }

    @Test func recoveredRecordWriteFailureRequiresNewLoginWriter() throws {
      let fixture = try RecoveryFixture()
      defer { fixture.cleanup() }
      let client = fixture.client()
      let old = client.persistence(freshLogin: false), oldLogin = client.persistence(freshLogin: true)
      // A directory at this unique record path makes atomic record publication fail.
      try FileManager.default.createDirectory(at: fixture.record, withIntermediateDirectories: false)
      #expect(throws: KeychainError.retirementStorageUnavailable) { try client.deleteSession() }
      #expect(client.loadToken() == nil)
      let failedLogin = client.persistence(freshLogin: true)
      #expect(throws: KeychainError.retirementStorageUnavailable) { try failedLogin(.token("failed")) }
      try FileManager.default.removeItem(at: fixture.record)
      #expect(client.loadToken() == nil, "Recovery of filesystem alone must not reopen old credentials")
      #expect(throws: KeychainError.retired) { try failedLogin(.token("late-failed")) }
      #expect(throws: KeychainError.retired) { try old(.token("late-old")) }
      #expect(throws: KeychainError.retired) { try oldLogin(.token("late-login")) }
      try fixture.client().saveSession(.token("replacement"))
      #expect(fixture.client().loadToken() == "replacement")
      #expect(throws: KeychainError.retired) { try old(.token("late-old")) }
    }

    @Test func canceledFreshLoginCannotRepairCorruption() async throws {
      let fixture = try RecoveryFixture()
      defer { fixture.cleanup() }
      try Data("corrupt".utf8).write(to: fixture.record)
      let client = fixture.client(), write = client.persistence(freshLogin: true)
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(throws: KeychainError.retired) { try write(.token("cancelled")) }
      }
      await task.value
      #expect(client.loadToken() == nil)
      #expect(fixture.writes.value == 0)
      try client.saveSession(.token("replacement"))
      #expect(client.loadToken() == "replacement")
    }
  }
}

private final class RecoveryFixture: @unchecked Sendable {
  let service = "test.recovery." + UUID().uuidString
  let record: URL
  let data = LockIsolated<Data?>(Data("old".utf8))
  let writes = LockIsolated(0)
  init() throws {
    let hash = SHA256.hash(data: try JSONEncoder().encode([service, "test"])).map { String(format: "%02x", $0) }.joined()
    record = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HermesCredentialRetirement").appendingPathComponent(hash + ".json")
    try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  func cleanup() { try? FileManager.default.removeItem(at: record) }
  func client() -> KeychainClient {
    KeychainClient.live(service: service, account: "test", operations: .init(read: { [self] in data.value }, write: { [self] value in writes.withValue { $0 += 1 }; data.setValue(value) }, delete: { [self] in data.setValue(nil) }))
  }
}
