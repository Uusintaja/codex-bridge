#if os(Windows)
  import Foundation
  import WinSDK

  /// Derives a stable endpoint. Multi-instance rule (generic, no vendor
  /// binding): when `CODEX_BRIDGE_DATA_ROOT` is set (one per orchestrator
  /// profile), identity hashes the data-root so a single binary directory can
  /// host N isolated instances. Otherwise falls back to the executable
  /// directory (legacy single-copy behaviour, unchanged).
  public enum WindowsPipeIdentity {
    public static func currentPipeName() -> String {
      if let root = instanceScope() {
        return pipeName(forScope: root)
      }
      guard let directory = currentExecutableDirectory() else {
        fatalError("The current Windows executable directory is unavailable.")
      }
      return pipeName(forExecutableDirectory: directory)
    }

    public static func currentMutexName() -> String {
      if let root = instanceScope() {
        return mutexName(forScope: root)
      }
      guard let directory = currentExecutableDirectory() else {
        fatalError("The current Windows executable directory is unavailable.")
      }
      return mutexName(forExecutableDirectory: directory)
    }

    public static func pipeName(forExecutableDirectory directory: String) -> String {
      "\\\\.\\pipe\\org.codexbridge.service.\(identifier(forExecutableDirectory: directory))"
    }

    public static func mutexName(forExecutableDirectory directory: String) -> String {
      "Global\\org.codexbridge.service.\(identifier(forExecutableDirectory: directory))"
    }

    public static func pipeName(forScope scope: String) -> String {
      "\\\\.\\pipe\\org.codexbridge.service.\(identifier(forScope: scope))"
    }

    public static func mutexName(forScope scope: String) -> String {
      "Global\\org.codexbridge.service.\(identifier(forScope: scope))"
    }

    /// Per-instance scope: explicit data-root wins (shim sets one per
    /// profile); CODEX_BRIDGE_INSTANCE alone also scopes when set.
    private static func instanceScope() -> String? {
      let env = ProcessInfo.processInfo.environment
      if let root = env["CODEX_BRIDGE_DATA_ROOT"], !root.isEmpty {
        return "dataroot:" + root
      }
      if let inst = env["CODEX_BRIDGE_INSTANCE"], !inst.isEmpty {
        return "instance:" + inst
      }
      return nil
    }

    private static func currentExecutableDirectory() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = buffer.withUnsafeMutableBufferPointer { raw in
        GetModuleFileNameW(nil, raw.baseAddress, DWORD(raw.count))
      }
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      let executable = String(decoding: buffer[..<Int(length)], as: UTF16.self)
      guard let separator = executable.lastIndex(of: "\\") else { return nil }
      return String(executable[..<separator])
    }

    private static func normalize(_ directory: String) -> String {
      var value = directory.replacingOccurrences(of: "/", with: "\\").lowercased()
      while value.count > 3, value.hasSuffix("\\") {
        value.removeLast()
      }
      return value
    }

    private static func identifier(forExecutableDirectory directory: String) -> String {
      identifier(forScope: directory)
    }

    private static func identifier(forScope scope: String) -> String {
      let normalized = normalize(scope)
      precondition(!normalized.isEmpty)
      let hash = fnv1a64(normalized.utf8)
      let suffix = String(hash, radix: 16).lowercased()
      return String(repeating: "0", count: max(0, 16 - suffix.count)) + suffix
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
      }
      return hash
    }
  }

  extension BridgeServiceIPC {
    public static var windowsPipeName: String {
      WindowsPipeIdentity.currentPipeName()
    }
  }
#endif
