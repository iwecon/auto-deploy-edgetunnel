import Foundation
import WinSDK

public struct DeploymentStateStore {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func load() throws -> DeploymentState? {
    let attributes = windowsFileAttributes(at: fileURL)
    if attributes == INVALID_FILE_ATTRIBUTES {
      if GetLastError() == DWORD(ERROR_FILE_NOT_FOUND) { return nil }
      throw EdgeTunnelError.state("无法安全打开状态文件（Windows 错误 \(GetLastError())）。")
    }
    guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
      throw EdgeTunnelError.state("状态路径不能是符号链接或重解析点。")
    }
    guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else {
      throw EdgeTunnelError.state("状态路径不是普通文件。")
    }
    do {
      let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      guard data.count <= 65_536 else {
        throw EdgeTunnelError.state("状态文件大小异常。")
      }
      return try JSONDecoder().decode(DeploymentState.self, from: data)
    } catch let error as EdgeTunnelError {
      throw error
    } catch {
      throw EdgeTunnelError.state("无法读取或解析 \(fileURL.lastPathComponent)。")
    }
  }

  public func save(_ state: DeploymentState) throws {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try ensureWindowsDirectoryIsNotReparsePoint(directory)
      let existingAttributes = windowsFileAttributes(at: fileURL)
      if existingAttributes != INVALID_FILE_ATTRIBUTES,
        existingAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
      {
        throw EdgeTunnelError.state("状态路径不能是符号链接或重解析点。")
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(state)
      data.append(0x0a)
      try data.write(to: fileURL, options: [.atomic])
    } catch let error as EdgeTunnelError {
      throw error
    } catch {
      throw EdgeTunnelError.state("写入 \(fileURL.lastPathComponent) 失败。")
    }
  }
}

final class DeploymentStateLock {
  private var handle: HANDLE?

  init(
    accountID: String,
    lockDirectory: URL? = nil
  ) throws {
    let directory = lockDirectory ?? Self.defaultLockDirectory
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try ensureWindowsDirectoryIsNotReparsePoint(directory)
    } catch let error as EdgeTunnelError {
      throw error
    } catch {
      throw EdgeTunnelError.state("无法创建部署锁目录。")
    }

    let identity = Data(accountID.utf8)
    let lockFile = directory.appendingPathComponent("\(Digest.sha256Hex(identity)).lock")
    let opened = withWindowsPath(lockFile.path) { path in
      CreateFileW(
        path,
        DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
        0,
        nil,
        DWORD(OPEN_ALWAYS),
        DWORD(FILE_ATTRIBUTE_NORMAL),
        nil
      )
    }
    guard opened != windowsInvalidHandle else {
      if GetLastError() == DWORD(ERROR_SHARING_VIOLATION) {
        throw EdgeTunnelError.deploymentInProgress
      }
      throw EdgeTunnelError.state("无法创建部署锁（Windows 错误 \(GetLastError())）。")
    }
    handle = opened
  }

  private static var defaultLockDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "edgetunnel-swift-locks",
      isDirectory: true
    )
  }

  deinit {
    release()
  }

  func release() {
    if let handle {
      _ = CloseHandle(handle)
      self.handle = nil
    }
  }
}

private let windowsInvalidHandle = UnsafeMutableRawPointer(bitPattern: -1)

private func windowsFileAttributes(at url: URL) -> DWORD {
  withWindowsPath(url.path) { GetFileAttributesW($0) }
}

private func ensureWindowsDirectoryIsNotReparsePoint(_ directory: URL) throws {
  let attributes = windowsFileAttributes(at: directory)
  guard attributes != INVALID_FILE_ATTRIBUTES,
    attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
    attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
  else {
    throw EdgeTunnelError.state("状态或部署锁目录不能是符号链接或重解析点。")
  }
}

private func withWindowsPath<Result>(
  _ path: String,
  _ body: (UnsafePointer<WCHAR>) -> Result
) -> Result {
  var widePath = Array(path.utf16)
  widePath.append(0)
  return widePath.withUnsafeBufferPointer { buffer in
    body(buffer.baseAddress!)
  }
}
