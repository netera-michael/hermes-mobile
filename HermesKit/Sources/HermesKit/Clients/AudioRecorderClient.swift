import ComposableArchitecture
import DependenciesMacros
import Foundation

/// Recorded audio ready to upload to the transcription endpoint (#7). `mimeType` starts
/// with `audio/` so the agent's `/api/audio/transcribe` accepts it.
public struct RecordedAudio: Equatable, Sendable {
  public let data: Data
  public let mimeType: String

  public init(data: Data, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }

  /// `data:<mime>;base64,<…>` URL for upload to `/api/audio/transcribe` (#7).
  public var dataURL: String {
    "data:\(mimeType);base64,\(data.base64EncodedString())"
  }
}

public enum AudioRecorderError: Error, Equatable, Sendable {
  case permissionDenied
  case notRecording
  case unavailable
}

/// Records microphone audio for voice input and streams live amplitude so the composer
/// can draw a recording waveform (#7). Wraps `AVAudioSession`/`AVAudioRecorder` behind a
/// dependency so reducers stay testable and never touch AVFoundation directly.
@DependencyClient
public struct AudioRecorderClient: Sendable {
  /// Prompt for (or read) microphone permission. `false` ⇒ denied.
  public var requestPermission: @Sendable () async -> Bool = { false }
  /// Begin recording to a temp file with metering enabled.
  public var startRecording: @Sendable (UUID) async throws -> Void
  /// Stop and return the recorded audio bytes.
  public var stopRecording: @Sendable (UUID) async throws -> RecordedAudio
  /// Abort recording and discard the file (no audio returned).
  public var cancel: @Sendable (UUID) async -> Void
  /// A stream of normalized (0...1) amplitude samples while recording, for the waveform.
  /// Finishes when recording stops.
  public var levels: @Sendable (UUID) -> AsyncStream<Float> = { _ in AsyncStream { $0.finish() } }

  /// Map a metering power reading (dBFS, ~-160…0) to a 0...1 amplitude for the waveform.
  /// `-50 dB` is treated as the silence floor — pure so it's unit-testable on any platform.
  public static func normalizeLevel(dBFS: Float) -> Float {
    let floor: Float = -50
    if dBFS <= floor { return 0 }
    if dBFS >= 0 { return 1 }
    return (dBFS - floor) / -floor
  }
}

extension AudioRecorderClient: DependencyKey {
  /// A usable test double: permission granted, canned audio, and a short finite levels
  /// stream. Override individual closures in tests to exercise specific paths.
  public static var testValue: AudioRecorderClient {
    AudioRecorderClient(
      requestPermission: { true },
      startRecording: { _ in },
      stopRecording: { _ in RecordedAudio(data: Data([0x00, 0x01]), mimeType: "audio/m4a") },
      cancel: { _ in },
      levels: { _ in
        AsyncStream { continuation in
          for level: Float in [0.2, 0.6, 0.4] { continuation.yield(level) }
          continuation.finish()
        }
      }
    )
  }
}

public extension DependencyValues {
  var audioRecorder: AudioRecorderClient {
    get { self[AudioRecorderClient.self] }
    set { self[AudioRecorderClient.self] = newValue }
  }
}

/// Resource authority used inside the serial recorder engine. A late release cannot
/// deactivate, delete the file, or stop the microphone owned by another operation.
struct AudioRecorderOwnership: Sendable {
  private(set) var owner: UUID?
  mutating func claim(_ id: UUID) { owner = id }
  mutating func release(_ id: UUID) -> Bool {
    guard owner == id else { return false }
    owner = nil
    return true
  }
}

// MARK: - Live (iOS only)

// AVAudioSession/AVAudioApplication are iOS-only; the package is also built/tested on
// macOS via `swift test`, so the live recorder is compiled in only where UIKit exists.
// Elsewhere `liveValue` falls back to the no-op test double (no microphone).
#if canImport(UIKit)
  import AVFoundation

  /// Serializes access to the non-Sendable `AVAudioRecorder` and owns the temp file.
  private actor AudioRecorderEngine {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var ownership = AudioRecorderOwnership()

    func start(_ id: UUID) throws {
      try Task.checkCancellation()
      guard ownership.owner == nil else { throw AudioRecorderError.unavailable }
      ownership.claim(id)
      do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
      try session.setActive(true)

      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hermes-voice-\(UUID().uuidString).m4a")
      self.fileURL = url
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
      ]
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.isMeteringEnabled = true
      guard recorder.record() else { throw AudioRecorderError.unavailable }
      self.recorder = recorder
      self.fileURL = url
      } catch {
        cancel(id)
        throw error
      }
    }

    /// Current normalized amplitude, or `nil` once recording has stopped.
    func sample(_ id: UUID) -> Float? {
      guard ownership.owner == id else { return nil }
      guard let recorder, recorder.isRecording else { return nil }
      recorder.updateMeters()
      return AudioRecorderClient.normalizeLevel(dBFS: recorder.averagePower(forChannel: 0))
    }

    func stop(_ id: UUID) throws -> RecordedAudio {
      guard ownership.owner == id else { throw AudioRecorderError.notRecording }
      defer { cancel(id) }
      guard let recorder, let url = fileURL else { throw AudioRecorderError.notRecording }
      recorder.stop()
      self.recorder = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      let data = try Data(contentsOf: url)
      try? FileManager.default.removeItem(at: url)
      return RecordedAudio(data: data, mimeType: "audio/m4a")
    }

    func cancel(_ id: UUID) {
      guard ownership.release(id) else { return }
      recorder?.stop()
      recorder = nil
      if let url = fileURL { try? FileManager.default.removeItem(at: url) }
      fileURL = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  extension AudioRecorderClient {
    public static var liveValue: AudioRecorderClient {
      let engine = AudioRecorderEngine()
      return AudioRecorderClient(
        requestPermission: {
          await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
              continuation.resume(returning: granted)
            }
          }
        },
        startRecording: { try await engine.start($0) },
        stopRecording: { try await engine.stop($0) },
        cancel: { await engine.cancel($0) },
        levels: { id in
          AsyncStream { continuation in
            let task = Task {
              // Poll metering at ~15 Hz until the engine reports recording stopped.
              while !Task.isCancelled {
                guard let level = await engine.sample(id) else { break }
                continuation.yield(level)
                try? await Task.sleep(for: .milliseconds(66))
              }
              continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
          }
        }
      )
    }
  }
#else
  extension AudioRecorderClient {
    /// No microphone off-device (macOS `swift test`): fall back to the no-op double.
    public static var liveValue: AudioRecorderClient { testValue }
  }
#endif
