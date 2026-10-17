#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsApplicationIdentity {
    static let mainWindowClassName = "CodexBridgeMainWindow"
    static let explicitCloseRequest = WPARAM(1)
    static let restoreRequest = UINT(WM_APP + 42)
    /// Win32 window property carrying the orchestrator instance scope this
    /// window belongs to (see `ownerInstanceScope()`), so windows of one
    /// portable copy hosting several instances can be told apart.
    static let instanceScopeProperty = "CodexBridgeInstanceScope"

    /// Explicit per-instance scope assigned by the orchestrator; nil for
    /// legacy direct launches (exe-directory scope baseline).
    static func environmentInstanceScope() -> String? {
      let env = ProcessInfo.processInfo.environment
      if let root = env["CODEX_BRIDGE_DATA_ROOT"], !root.isEmpty {
        return "dataroot:" + root
      }
      if let inst = env["CODEX_BRIDGE_INSTANCE"], !inst.isEmpty {
        return "instance:" + inst
      }
      return nil
    }

    /// Scope recorded on and matched against the main window: the explicit
    /// environment scope when present, the executable directory otherwise
    /// (mirrors the single-instance mutex scope).
    static func ownerInstanceScope() -> String? {
      if let scope = environmentInstanceScope() { return scope }
      guard let path = currentExecutablePath(), let separator = path.lastIndex(of: "\\") else {
        return nil
      }
      return String(path[..<separator])
    }

    static func currentExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    /// Records the window's instance scope as a Win32 window property. The
    /// backing storage intentionally lives for the process lifetime (one main
    /// window per process).
    static func attachInstanceScope(to window: HWND) {
      guard let scope = ownerInstanceScope() else { return }
      var units = Array(scope.utf16)
      units.append(0)
      let storage = UnsafeMutablePointer<UInt16>.allocate(capacity: units.count)
      storage.initialize(from: units, count: units.count)
      instanceScopeProperty.withCString(encodedAs: UTF16.self) { name in
        _ = SetPropW(window, name, UnsafeMutableRawPointer(storage))
      }
    }

    static func instanceScope(of window: HWND) -> String? {
      instanceScopeProperty.withCString(encodedAs: UTF16.self) { name in
        guard let raw = GetPropW(window, name) else { return nil }
        let pointer = UnsafePointer<UInt16>(raw.assumingMemoryBound(to: UInt16.self))
        return String(decodingCString: pointer, as: UTF16.self)
      }
    }
  }

  public enum WindowsApplicationControl {
    public static func ensureServiceRunning() -> Bool {
      WindowsServiceLauncher.ensureServiceRunning().isReady
    }

    /// Returns false when another copy already owns the session; that copy is restored.
    /// Portable fix: scope the single-instance mutex to the executable directory
    /// (same FNV-1a hashing as WindowsPipeIdentity) so two portable copies can
    /// run side by side without stealing each other's window.
    public static func claimInstanceOrActivateExisting() -> Bool {
      let mutexName = singleInstanceMutexName()
      SetLastError(0)
      let created = mutexName.withCString(encodedAs: UTF16.self) {
        CreateMutexW(nil, true, $0)
      }
      guard let created else { return true }
      if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(created)
        activateExistingMainWindow()
        return false
      }
      instanceMutex = created
      return true
    }

    public static func shutdownRunningApplication() -> Bool {
      guard let expectedPath = WindowsApplicationIdentity.currentExecutablePath() else {
        return false
      }
      var closedCount = 0
      while let window = findMainWindow(for: expectedPath) {
        guard closedCount < 16, close(window: window, expectedPath: expectedPath) else {
          return false
        }
        closedCount += 1
      }
      return true
    }

    private static func close(window: HWND, expectedPath: String) -> Bool {
      var processID: DWORD = 0
      guard GetWindowThreadProcessId(window, &processID) != 0, processID > 0 else { return false }
      let access = DWORD(PROCESS_QUERY_LIMITED_INFORMATION) | DWORD(SYNCHRONIZE)
      guard let process = OpenProcess(access, false, processID) else { return false }
      defer { _ = CloseHandle(process) }
      guard processImagePath(process)?.caseInsensitiveCompare(expectedPath) == .orderedSame else {
        return false
      }
      if !PostMessageW(window, UINT(WM_CLOSE), WindowsApplicationIdentity.explicitCloseRequest, 0),
        WaitForSingleObject(process, 0) != WAIT_OBJECT_0
      {
        return false
      }
      return WaitForSingleObject(process, 30_000) == WAIT_OBJECT_0
    }

    private static func findMainWindow(
      for expectedPath: String? = nil,
      instanceScope: String? = nil
    ) -> HWND? {
      WindowsApplicationIdentity.mainWindowClassName.withCString(encodedAs: UTF16.self) { name in
        var previous: HWND?
        while let window = FindWindowExW(nil, previous, name, nil) {
          var processID: DWORD = 0
          if GetWindowThreadProcessId(window, &processID) != 0,
            matchesExecutable(processID, expectedPath: expectedPath),
            matchesInstanceScope(window, instanceScope: instanceScope)
          {
            return window
          }
          previous = window
        }
        return nil
      }
    }

    private static func matchesExecutable(_ processID: DWORD, expectedPath: String?) -> Bool {
      guard let expectedPath else { return true }
      return processImagePath(processID)?.caseInsensitiveCompare(expectedPath) == .orderedSame
    }

    private static func matchesInstanceScope(_ window: HWND, instanceScope: String?) -> Bool {
      guard let instanceScope else { return true }
      return WindowsApplicationIdentity.instanceScope(of: window) == instanceScope
    }

    nonisolated(unsafe) private static var instanceMutex: HANDLE?

    private static func activateExistingMainWindow() {
      let expected = WindowsApplicationIdentity.currentExecutablePath()
      let scope = WindowsApplicationIdentity.environmentInstanceScope()
      if activateWindow(matching: expected, instanceScope: scope) { return }
      // Legacy windows created before the scope property existed stay
      // reachable through plain exe-path matching.
      if scope != nil, activateWindow(matching: expected, instanceScope: nil) { return }
    }

    /// Waits briefly for a matching window and asks it to restore itself.
    private static func activateWindow(matching expected: String?, instanceScope: String?) -> Bool {
      for _ in 0..<30 {
        if let window = findMainWindow(for: expected, instanceScope: instanceScope) {
          var processID: DWORD = 0
          _ = GetWindowThreadProcessId(window, &processID)
          if processID > 0 {
            _ = AllowSetForegroundWindow(processID)
          }
          _ = PostMessageW(window, WindowsApplicationIdentity.restoreRequest, 0, 0)
          return true
        }
        Sleep(100)
      }
      return false
    }

    /// Instance-scoped single-instance name. Prefers the orchestrator-assigned
    /// data-root (one per profile) so a single binary directory can host N
    /// isolated Apps; falls back to the exe directory (legacy single copy).
    private static func singleInstanceMutexName() -> String {
      let env = ProcessInfo.processInfo.environment
      let scope: String
      if let root = env["CODEX_BRIDGE_DATA_ROOT"], !root.isEmpty {
        scope = "dataroot:" + root
      } else if let inst = env["CODEX_BRIDGE_INSTANCE"], !inst.isEmpty {
        scope = "instance:" + inst
      } else if let path = WindowsApplicationIdentity.currentExecutablePath(),
        let sep = path.lastIndex(of: "\\")
      {
        scope = String(path[..<sep])
      } else {
        return "Local\\CodexBridge.WindowsApp.SingleInstance"
      }
      let directory = scope.lowercased().replacingOccurrences(
        of: "/", with: "\\")
      var hash: UInt64 = 14_695_981_039_346_656_037
      for byte in directory.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
      }
      let suffix = String(hash, radix: 16).lowercased()
      let padded = String(repeating: "0", count: max(0, 16 - suffix.count)) + suffix
      return "Local\\CodexBridge.WindowsApp.SingleInstance.\(padded)"
    }

    private static func processImagePath(_ process: HANDLE) -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      var length = DWORD(buffer.count)
      guard QueryFullProcessImageNameW(process, 0, &buffer, &length), length > 0 else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    private static func processImagePath(_ processID: DWORD) -> String? {
      guard
        let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, processID)
      else { return nil }
      defer { _ = CloseHandle(process) }
      return processImagePath(process)
    }
  }
#endif
