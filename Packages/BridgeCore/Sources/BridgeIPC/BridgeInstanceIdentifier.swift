import Foundation

/// Cross-platform instance scope identity: FNV-1a 64 over a normalized scope
/// string (per-instance data root or explicit instance token), rendered as 16
/// lowercase hex digits. Shared by the Windows pipe/mutex names and any
/// subsystem that needs a stable per-instance identifier, such as
/// per-instance secret references.
public enum BridgeInstanceIdentifier {
  public static func identifier(forScope scope: String) -> String {
    let normalized = normalize(scope)
    precondition(!normalized.isEmpty)
    let hash = fnv1a64(normalized.utf8)
    let suffix = String(hash, radix: 16).lowercased()
    return String(repeating: "0", count: max(0, 16 - suffix.count)) + suffix
  }

  public static func normalize(_ value: String) -> String {
    var normalized = value.replacingOccurrences(of: "/", with: "\\").lowercased()
    while normalized.count > 3, normalized.hasSuffix("\\") {
      normalized.removeLast()
    }
    return normalized
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
