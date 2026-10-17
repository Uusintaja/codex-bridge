import BridgeSecurity
import Crypto
import Foundation

actor ServiceDeepSeekDesktopIdentity {
  private let store: any SecretStore
  private let reference: SecretReference
  private let legacyReference: SecretReference?

  init(store: any SecretStore, dataRoot: URL) {
    self.store = store
    let path = dataRoot.standardizedFileURL.path
    reference = Self.reference(forScope: Self.canonicalScope(for: path))
    let legacy = Self.reference(forScope: path)
    legacyReference = legacy == reference ? nil : legacy
  }

  func privateKey() throws -> Data {
    if let bytes = try loadValidated(reference) {
      return bytes
    }
    if let legacyReference, let bytes = try loadValidated(legacyReference) {
      // One-time migration: copy into the canonical slot but keep the legacy
      // entry so a rollback to an older build still finds its identity.
      try? store.store(bytes, for: reference)
      return bytes
    }
    let key = Curve25519.Signing.PrivateKey()
    try store.store(key.rawRepresentation, for: reference)
    return key.rawRepresentation
  }

  private func loadValidated(_ reference: SecretReference) throws -> Data? {
    do {
      let bytes = try store.load(reference)
      _ = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
      return bytes
    } catch SecretStoreError.notFound {
      return nil
    }
  }

  private static func canonicalScope(for path: String) -> String {
    #if os(Windows)
      // The same directory can be spelled with different case or separators;
      // normalize so every spelling resolves to one desktop identity.
      return path.replacingOccurrences(of: "/", with: "\\").lowercased()
    #else
      return path
    #endif
  }

  private static func reference(forScope scope: String) -> SecretReference {
    let digest = SHA256.hash(data: Data(scope.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return SecretReference(rawValue: "dsh-desktop-identity." + digest)
  }
}
