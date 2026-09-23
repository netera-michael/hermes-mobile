import Foundation
import Testing
@testable import HermesKit

@Suite("Connection & Send trace")
struct ConnectionTraceTests {
  @Test func boundedOrderingAndSendCorrelation() {
    let trace = ConnectionTraceClient.ringBuffer(capacity: 2)
    let sendID = UUID()
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    trace.append(.init(timestamp: instant, generation: 1, kind: .slotOpened))
    trace.append(.init(timestamp: instant, generation: 1, sendID: sendID, kind: .sendStarted))
    trace.append(.init(timestamp: instant.addingTimeInterval(1), generation: 1,
                       sendID: sendID, kind: .sendTimedOut))
    let entries = trace.snapshot()
    #expect(entries.count == 2)
    #expect(entries.map(\.kind) == [.sendStarted, .sendTimedOut])
    #expect(entries.map(\.sendID) == [sendID, sendID])
    #expect(entries[0].timestamp < entries[1].timestamp)
  }

  @Test func exportedVocabularyCannotContainPayloads() {
    let trace = ConnectionTraceClient.ringBuffer()
    trace.append(.init(timestamp: Date(timeIntervalSince1970: 0), generation: 4,
                       kind: .hydrateSucceeded, rowCount: 7))
    for kind in ConnectionTraceKind.allCases {
      trace.append(.init(timestamp: Date(timeIntervalSince1970: 0), generation: 4,
                         sendID: UUID(), kind: kind))
    }
    let output = trace.snapshot().map(\.line).joined(separator: "\n")
    #expect(output.contains("slot=4"))
    #expect(output.contains("rows=7"))
    #expect(!output.contains("http"))
    #expect(!output.contains("/api/"))
    #expect(!output.contains("session_id"))
    #expect(!output.contains("profile"))
    #expect(!output.contains("text"))
    #expect(!output.contains("error="))
  }
}
