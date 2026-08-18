import Foundation

public struct WorkerSourceLoader {
  private let transport: HTTPTransport
  private let upstream: UpstreamDescriptor

  public init(transport: HTTPTransport, upstream: UpstreamDescriptor = .pinned) {
    self.transport = transport
    self.upstream = upstream
  }

  public func load(file: URL?) async throws -> Data {
    let data: Data
    if let file {
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        if let size = attributes[.size] as? NSNumber,
          size.intValue > upstream.maximumSize
        {
          throw EdgeTunnelError.workerTooLarge(limit: upstream.maximumSize)
        }
        data = try Data(contentsOf: file, options: .mappedIfSafe)
      } catch let error as EdgeTunnelError {
        throw error
      } catch {
        throw EdgeTunnelError.state("无法读取指定的 _worker.js。")
      }
    } else {
      let response = try await transport.send(
        HTTPRequest(
          method: "GET",
          url: upstream.url,
          headers: ["Accept": "application/javascript, text/javascript;q=0.9"],
          timeout: 30,
          maximumResponseSize: upstream.maximumSize
        )
      )
      guard response.statusCode == 200 else {
        throw EdgeTunnelError.upstreamDownloadStatus(response.statusCode)
      }
      data = response.body
    }

    guard !data.isEmpty, data.count <= upstream.maximumSize else {
      throw EdgeTunnelError.workerTooLarge(limit: upstream.maximumSize)
    }
    let actualHash = Digest.sha256Hex(data)
    guard actualHash == upstream.sha256.lowercased() else {
      throw EdgeTunnelError.workerIntegrity(
        expected: upstream.sha256.lowercased(), actual: actualHash)
    }
    return data
  }
}
