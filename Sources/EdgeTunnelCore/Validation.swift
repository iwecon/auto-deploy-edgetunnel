import Foundation

public enum InputValidator {
  public static func accountID(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.utf8.count == 32,
      normalized.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      })
    else {
      throw EdgeTunnelError.invalidAccountID
    }
    return normalized
  }

  public static func projectName(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (1...58).contains(normalized.utf8.count),
      normalized.first != "-",
      normalized.last != "-",
      normalized.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
      })
    else {
      throw EdgeTunnelError.invalidProjectName(value)
    }
    return normalized
  }

  public static func kvTitle(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.utf8.count <= 128,
      normalized.unicodeScalars.allSatisfy({
        !CharacterSet.controlCharacters.contains($0)
      })
    else {
      throw EdgeTunnelError.invalidKVTitle
    }
    return normalized
  }
}
