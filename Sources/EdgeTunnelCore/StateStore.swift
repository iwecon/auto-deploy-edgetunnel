import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct DeploymentStateStore {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func load() throws -> DeploymentState? {
    let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw EdgeTunnelError.state("无法安全打开状态文件（errno \(errno)）。")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0 else {
        throw EdgeTunnelError.state("无法检查状态文件元数据（errno \(errno)）。")
      }
      guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw EdgeTunnelError.state("状态路径不是普通文件。")
      }
      guard metadata.st_uid == geteuid() else {
        throw EdgeTunnelError.state("状态文件不属于当前用户。")
      }
      guard metadata.st_mode & mode_t(0o077) == 0 else {
        throw EdgeTunnelError.state("状态文件可被组或其他用户访问；请先将权限改为 0600。")
      }
      guard metadata.st_nlink == 1 else {
        throw EdgeTunnelError.state("状态文件存在额外硬链接，拒绝读取。")
      }
      guard metadata.st_size >= 0, metadata.st_size <= 65_536 else {
        throw EdgeTunnelError.state("状态文件大小异常。")
      }
      let data = try handle.readToEnd() ?? Data()
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
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(state)
      data.append(0x0a)

      let temporary = directory.appendingPathComponent(
        ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)"
      )
      guard
        FileManager.default.createFile(
          atPath: temporary.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        throw EdgeTunnelError.state("无法创建临时状态文件。")
      }
      do {
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()

        guard rename(temporary.path, fileURL.path) == 0 else {
          throw EdgeTunnelError.state("无法原子替换状态文件（errno \(errno)）。")
        }
        guard chmod(fileURL.path, mode_t(0o600)) == 0 else {
          throw EdgeTunnelError.state("无法将状态文件权限设为 0600（errno \(errno)）。")
        }
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
      }
    } catch let error as EdgeTunnelError {
      throw error
    } catch {
      throw EdgeTunnelError.state("写入 \(fileURL.lastPathComponent) 失败。")
    }
  }
}

final class DeploymentStateLock {
  private var descriptor: Int32 = -1

  init(
    accountID: String,
    lockDirectory: URL? = nil
  ) throws {
    let directory = lockDirectory ?? Self.defaultLockDirectory
    try Self.ensurePrivateDirectory(directory)
    let identity = Data(accountID.utf8)
    let lockFile = directory.appendingPathComponent("\(Digest.sha256Hex(identity)).lock")
    let descriptor = open(
      lockFile.path,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw EdgeTunnelError.state("无法创建部署锁（errno \(errno)）。")
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_uid == geteuid(),
      metadata.st_nlink == 1
    else {
      close(descriptor)
      throw EdgeTunnelError.state("部署锁文件不安全。")
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
      close(descriptor)
      throw EdgeTunnelError.state("无法设置部署锁权限（errno \(errno)）。")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw EdgeTunnelError.deploymentInProgress
    }
    self.descriptor = descriptor
  }

  private static var defaultLockDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "edgetunnel-swift-locks-\(geteuid())",
      isDirectory: true
    )
  }

  private static func ensurePrivateDirectory(_ directory: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw EdgeTunnelError.state("无法创建部署锁目录。")
    }
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(0o077) == 0
    else {
      throw EdgeTunnelError.state("部署锁目录不安全；必须属于当前用户且权限不宽于 0700。")
    }
  }

  deinit {
    release()
  }

  func release() {
    if descriptor >= 0 {
      _ = flock(descriptor, LOCK_UN)
      close(descriptor)
      descriptor = -1
    }
  }
}
