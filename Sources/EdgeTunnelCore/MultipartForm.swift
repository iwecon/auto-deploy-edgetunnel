import Foundation

struct MultipartForm {
  let boundary: String
  private(set) var data = Data()

  init(boundary: String = "edgetunnel-\(UUID().uuidString)") {
    self.boundary = boundary
  }

  mutating func addField(name: String, value: String) {
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
    append(value)
    append("\r\n")
  }

  mutating func addFile(name: String, filename: String, contentType: String, contents: Data) {
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: \(contentType)\r\n\r\n")
    data.append(contents)
    append("\r\n")
  }

  mutating func finish() {
    append("--\(boundary)--\r\n")
  }

  private mutating func append(_ string: String) {
    data.append(contentsOf: string.utf8)
  }
}
