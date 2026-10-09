import Foundation

#if os(Windows)
  import WinSDK
#endif

/// Environment snapshot used when discovering locally installed tools.
///
/// A background service keeps the environment captured when it was launched, so
/// `PATH` and tool roots written by an installation completed afterwards stay
/// invisible to it; on Windows the registry values are the current ones.
///
/// Portable mode (generic, no vendor binding):
/// when `CODEX_BRIDGE_ISOLATED=1`, host registry PATH merge is skipped and only
/// explicit `CODEX_BRIDGE_*` overrides plus agent home vars from the process
/// environment are honoured. The shim/GUI computes absolute paths (any portable
/// layout) and passes them via these generic variables.
public enum ToolDiscoveryEnvironment {
  /// Generic isolation switch, set by any portable shim.
  public static var isIsolated: Bool {
    let env = ProcessInfo.processInfo.environment
    return env.first(where: { $0.key.caseInsensitiveCompare("CODEX_BRIDGE_ISOLATED") == .orderedSame })?.value == "1"
  }

  public static func current() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    #if os(Windows)
      let machineKey = #"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"#
      if isIsolated {
        // Portable fenced mode: keep the shim's PATH as-is so host installs
        // cannot punch through. Explicit overrides below still apply.
      } else {
        let path = [
          registeredValue("Path", root: HKEY_LOCAL_MACHINE, subkey: machineKey),
          registeredValue("Path", root: HKEY_CURRENT_USER, subkey: "Environment"),
          environment.first(where: { $0.key.caseInsensitiveCompare("PATH") == .orderedSame })?.value,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        environment = environment.filter { $0.key.caseInsensitiveCompare("PATH") != .orderedSame }
        environment["PATH"] = path.joined(separator: ";")
      }
      for name in [
        "PNPM_HOME", "NPM_CONFIG_PREFIX", "YARN_GLOBAL_FOLDER", "BUN_INSTALL", "CARGO_HOME",
        "VOLTA_HOME",
        "NVM_HOME", "NVM_SYMLINK",
        // Generic explicit executable overrides (highest priority, shim/GUI set).
        "CODEX_BRIDGE_CODEX_EXECUTABLE",
        "CODEX_BRIDGE_OPENCODE_EXECUTABLE",
        "CODEX_BRIDGE_PI_EXECUTABLE",
        "CODEX_BRIDGE_QODER_EXECUTABLE",
        "CODEX_BRIDGE_AGY_EXECUTABLE",
        "CODEX_BRIDGE_ANTIGRAVITY_EXECUTABLE",
        "CODEX_BRIDGE_CLAUDE_EXECUTABLE",
        "CODEX_BRIDGE_DSH_EXECUTABLE",
        "CODEX_BRIDGE_DSH_HOME",
        "CODEX_BRIDGE_DSH_NODE",
        "CODEX_BRIDGE_DATA_ROOT",
        "CODEX_BRIDGE_ISOLATED",
        // Generic agent home overrides (data-isolation friendly, vendor docs).
        "CODEX_HOME", "CODEX_SQLITE_HOME",
        "CLAUDE_CONFIG_DIR",
        "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR",
        "OPENCODE_CONFIG_DIR", "OPENCODE_DATA_DIR", "OPENCODE_CACHE_DIR",
        "OPENCODE_LOG_DIR", "OPENCODE_STATE_DIR", "OPENCODE_APPNAME",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
        "DSH_HOME",
        "CODEX_BRIDGE_DEEPSEEK_HARNESS_ROOT", "DEEPSEEK_HARNESS_ROOT",
        "CODEX_BRIDGE_DEEPSEEK_HARNESS_EXECUTABLE", "DEEPSEEK_HARNESS_EXECUTABLE",
        "CODEX_BRIDGE_DEEPSEEK_HARNESS_CONFIGURATION", "DEEPSEEK_HARNESS_CONFIGURATION",
      ] {
        // Shim/GUI values always win: only fill from registry when the process
        // environment does not already carry the key.
        if environment.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) != nil {
          continue
        }
        // In isolated mode never let host registry reintroduce host paths,
        // except for explicit bridge overrides.
        if isIsolated, !name.hasPrefix("CODEX_BRIDGE_"), !name.hasPrefix("DEEPSEEK_HARNESS_") {
          continue
        }
        let value =
          registeredValue(name, root: HKEY_CURRENT_USER, subkey: "Environment")
          ?? registeredValue(
            name,
            root: HKEY_LOCAL_MACHINE,
            subkey: machineKey
          )
        guard let value, !value.isEmpty else { continue }
        environment = environment.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
        environment[name] = value
      }
    #endif
    return environment
  }

  #if os(Windows)
    private static func registeredValue(_ name: String, root: HKEY?, subkey: String) -> String? {
      var handle: HKEY?
      let status = subkey.withCString(encodedAs: UTF16.self) {
        RegOpenKeyExW(root, $0, 0, REGSAM(KEY_QUERY_VALUE), &handle)
      }
      guard status == ERROR_SUCCESS, let handle else { return nil }
      defer { RegCloseKey(handle) }
      var type: DWORD = 0
      var byteCount: DWORD = 0
      let measured = name.withCString(encodedAs: UTF16.self) {
        RegQueryValueExW(handle, $0, nil, &type, nil, &byteCount)
      }
      guard measured == ERROR_SUCCESS, byteCount > 0, byteCount <= 65_536,
        type == DWORD(REG_SZ) || type == DWORD(REG_EXPAND_SZ)
      else { return nil }
      var buffer = [WCHAR](repeating: 0, count: Int(byteCount) / 2 + 1)
      let read = name.withCString(encodedAs: UTF16.self) { valueName in
        buffer.withUnsafeMutableBytes {
          RegQueryValueExW(
            handle, valueName, nil, &type,
            $0.baseAddress?.assumingMemoryBound(to: BYTE.self), &byteCount
          )
        }
      }
      guard read == ERROR_SUCCESS else { return nil }
      let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
      guard type == DWORD(REG_EXPAND_SZ) else { return value }
      return value.withCString(encodedAs: UTF16.self) { source in
        let count = ExpandEnvironmentStringsW(source, nil, 0)
        guard count > 0, count <= 32_768 else { return nil }
        var expanded = [WCHAR](repeating: 0, count: Int(count))
        let written = ExpandEnvironmentStringsW(source, &expanded, count)
        guard written > 0, written <= count else { return nil }
        return String(decoding: expanded.prefix(while: { $0 != 0 }), as: UTF16.self)
      }
    }
  #endif
}
