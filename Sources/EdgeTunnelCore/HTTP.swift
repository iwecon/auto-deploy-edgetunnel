import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct HTTPRequest: Equatable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data?
  public var timeout: TimeInterval
  public var maximumResponseSize: Int

  public init(
    method: String,
    url: URL,
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 30,
    maximumResponseSize: Int = EdgeTunnelConstants.maximumResponseSize
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
    self.maximumResponseSize = maximumResponseSize
  }
}

public struct HTTPResponse: Equatable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public protocol HTTPTransport {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class URLSessionTransport: HTTPTransport {
  private let session: URLSession

  public init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 45
      self.session = URLSession(configuration: configuration)
    }
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = request.timeout
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    do {
      let (data, response) = try await session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse else {
        throw EdgeTunnelError.invalidResponse(status: nil)
      }
      if let declaredLength = http.value(forHTTPHeaderField: "Content-Length"),
        let length = Int(declaredLength),
        length > request.maximumResponseSize
      {
        throw EdgeTunnelError.responseTooLarge(limit: request.maximumResponseSize)
      }
      guard data.count <= request.maximumResponseSize else {
        throw EdgeTunnelError.responseTooLarge(limit: request.maximumResponseSize)
      }
      var headers: [String: String] = [:]
      for (key, value) in http.allHeaderFields {
        headers[String(describing: key).lowercased()] = String(describing: value)
      }
      return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    } catch let error as EdgeTunnelError {
      throw error
    } catch let error as URLError {
      throw EdgeTunnelError.transport(code: error.errorCode)
    } catch {
      throw EdgeTunnelError.transport(code: -1)
    }
  }
}
