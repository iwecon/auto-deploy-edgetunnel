import Foundation

public enum Digest {
  public static func md5Hex(_ string: String) -> String {
    md5(Data(string.utf8)).hexString
  }

  public static func sha256Hex(_ data: Data) -> String {
    sha256(data).hexString
  }

  static func md5(_ data: Data) -> Data {
    var message = Array(data)
    let bitLength = UInt64(message.count) &* 8
    message.append(0x80)
    while message.count % 64 != 56 {
      message.append(0)
    }
    for shift in stride(from: 0, through: 56, by: 8) {
      message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
    }

    var a0: UInt32 = 0x6745_2301
    var b0: UInt32 = 0xefcd_ab89
    var c0: UInt32 = 0x98ba_dcfe
    var d0: UInt32 = 0x1032_5476

    let shifts: [UInt32] = [
      7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    let constants: [UInt32] = (0..<64).map { index in
      UInt32(abs(sin(Double(index + 1))) * 4_294_967_296.0)
    }

    for offset in stride(from: 0, to: message.count, by: 64) {
      var words = [UInt32](repeating: 0, count: 16)
      for index in 0..<16 {
        let start = offset + index * 4
        words[index] =
          UInt32(message[start])
          | (UInt32(message[start + 1]) << 8)
          | (UInt32(message[start + 2]) << 16)
          | (UInt32(message[start + 3]) << 24)
      }

      var a = a0
      var b = b0
      var c = c0
      var d = d0

      for index in 0..<64 {
        let f: UInt32
        let wordIndex: Int
        switch index {
        case 0..<16:
          f = (b & c) | ((~b) & d)
          wordIndex = index
        case 16..<32:
          f = (d & b) | ((~d) & c)
          wordIndex = (5 * index + 1) % 16
        case 32..<48:
          f = b ^ c ^ d
          wordIndex = (3 * index + 5) % 16
        default:
          f = c ^ (b | (~d))
          wordIndex = (7 * index) % 16
        }

        let previousD = d
        d = c
        c = b
        let sum = a &+ f &+ constants[index] &+ words[wordIndex]
        b = b &+ rotateLeft(sum, by: shifts[index])
        a = previousD
      }

      a0 &+= a
      b0 &+= b
      c0 &+= c
      d0 &+= d
    }

    var digest = Data()
    for word in [a0, b0, c0, d0] {
      for shift in stride(from: 0, through: 24, by: 8) {
        digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
      }
    }
    return digest
  }

  static func sha256(_ data: Data) -> Data {
    let constants: [UInt32] = [
      0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
      0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
      0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
      0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
      0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
      0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
      0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
      0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
      0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
      0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
      0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
      0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
      0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
      0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
      0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
      0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    var message = Array(data)
    let bitLength = UInt64(message.count) &* 8
    message.append(0x80)
    while message.count % 64 != 56 {
      message.append(0)
    }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
    }

    var hash: [UInt32] = [
      0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
      0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]

    for offset in stride(from: 0, to: message.count, by: 64) {
      var words = [UInt32](repeating: 0, count: 64)
      for index in 0..<16 {
        let start = offset + index * 4
        words[index] =
          (UInt32(message[start]) << 24)
          | (UInt32(message[start + 1]) << 16)
          | (UInt32(message[start + 2]) << 8)
          | UInt32(message[start + 3])
      }
      for index in 16..<64 {
        let s0 =
          rotateRight(words[index - 15], by: 7)
          ^ rotateRight(words[index - 15], by: 18)
          ^ (words[index - 15] >> 3)
        let s1 =
          rotateRight(words[index - 2], by: 17)
          ^ rotateRight(words[index - 2], by: 19)
          ^ (words[index - 2] >> 10)
        words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
      }

      var a = hash[0]
      var b = hash[1]
      var c = hash[2]
      var d = hash[3]
      var e = hash[4]
      var f = hash[5]
      var g = hash[6]
      var h = hash[7]

      for index in 0..<64 {
        let bigS1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
        let choice = (e & f) ^ ((~e) & g)
        let temp1 = h &+ bigS1 &+ choice &+ constants[index] &+ words[index]
        let bigS0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = bigS0 &+ majority

        h = g
        g = f
        f = e
        e = d &+ temp1
        d = c
        c = b
        b = a
        a = temp1 &+ temp2
      }

      hash[0] &+= a
      hash[1] &+= b
      hash[2] &+= c
      hash[3] &+= d
      hash[4] &+= e
      hash[5] &+= f
      hash[6] &+= g
      hash[7] &+= h
    }

    var digest = Data()
    for word in hash {
      digest.append(UInt8(truncatingIfNeeded: word >> 24))
      digest.append(UInt8(truncatingIfNeeded: word >> 16))
      digest.append(UInt8(truncatingIfNeeded: word >> 8))
      digest.append(UInt8(truncatingIfNeeded: word))
    }
    return digest
  }

  private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value << amount) | (value >> (32 - amount))
  }

  private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
  }
}

extension Data {
  fileprivate var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
