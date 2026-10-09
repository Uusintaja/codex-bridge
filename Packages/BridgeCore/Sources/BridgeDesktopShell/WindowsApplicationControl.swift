#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowsApplicationIdentity {
    static let mainWindowClassName = "CodexBridgeMainWindow"
    static let explicitCloseRequest = WPARAM(1)
    static let restoreRequest = UINT(WM_APP + 42)
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
      guard let expectedPath = currentExecutablePath() else { return false }
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

    private static func findMainWindow(for expectedPath: String? = nil) -> HWND? {
      WindowsApplicationIdentity.mainWindowClassName.withCString(encodedAs: UTF16.self) { name in
        var previous: HWND?
        while let window = FindWindowExW(nil, previous, name, nil) {
          var processID: DWORD = 0
          if GetWindowThreadProcessId(window, &processID) != 0,
            matchesExecutable(processID, expectedPath: expectedPath)
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

    nonisolated(unsafe) private static var instanceMutex: HANDLE?

    private static func activateExistingMainWindow() {
      // Only activate a window owned by this portable copy.
      let expected = currentExecutablePath()
      for _ in 0..<30 {
        if let window = findMainWindow(for: expected) {
          var processID: DWORD = 0
          _ = GetWindowThreadProcessId(window, &processID)
          if processID > 0 {
            _ = AllowSetForegroundWindow(processID)
          }
          _ = PostMessageW(window, WindowsApplicationIdentity.restoreRequest, 0, 0)
          return
        }
        Sleep(100)
      }
    }

    private static func currentExecutablePath() -> String? {
      var buffer = [WCHAR](repeating: 0, count: 32_768)
      let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
      guard length > 0, length < DWORD(buffer.count) else { return nil }
      return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
    }

    /// Portable-scoped single-instance name (FNV-1a of exe directory).
    private static func singleInstanceMutexName() -> String {
      guard let path = currentExecutablePath(),
        let sep = path.lastIndex(of: "\\")
      else {
        return "Local\\CodexBridge.WindowsApp.SingleInstance"
      }
      let directory = String(path[..<sep]).lowercased().replacingOccurrences(
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
