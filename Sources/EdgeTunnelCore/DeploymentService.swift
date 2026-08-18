import Foundation

public final class DeploymentService {
  private let transport: HTTPTransport
  private let verifierSleep: SubscriptionVerifier.Sleep
  private let upstream: UpstreamDescriptor

  public init(
    transport: HTTPTransport,
    upstream: UpstreamDescriptor = .pinned,
    verifierSleep: @escaping SubscriptionVerifier.Sleep = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.transport = transport
    self.upstream = upstream
    self.verifierSleep = verifierSleep
  }

  public func deploy(
    token: String,
    options requestedOptions: DeploymentOptions
  ) async throws -> DeploymentResult {
    var options = requestedOptions
    let deploymentLock = try DeploymentStateLock(accountID: options.accountID)
    defer { deploymentLock.release() }
    let store = DeploymentStateStore(fileURL: options.stateFile)
    let existingState = try store.load()
    if let existingState,
      options.usesDefaultProjectName || options.usesDefaultKVNamespaceTitle
    {
      options = try DeploymentOptions(
        accountID: options.accountID,
        projectName: options.usesDefaultProjectName
          ? existingState.projectName : options.projectName,
        kvNamespaceTitle: options.usesDefaultKVNamespaceTitle
          ? existingState.kvNamespaceTitle : options.kvNamespaceTitle,
        stateFile: options.stateFile,
        workerFile: options.workerFile,
        adoptExisting: options.adoptExisting
      )
    }
    let hasTrustedState = existingState != nil
    var state: DeploymentState
    if let existing = existingState {
      try existing.validate(for: options)
      state = existing
    } else {
      state = DeploymentState(
        accountID: options.accountID,
        projectName: options.projectName,
        kvNamespaceTitle: options.kvNamespaceTitle,
        upstreamCommit: upstream.commit
      )
    }

    let cloudflare = try CloudflareClient(token: token, transport: transport)
    let subscriptionVerifier = SubscriptionVerifier(transport: transport, sleep: verifierSleep)
    let defaultsInitializer = RecommendedDefaultsInitializer(
      cloudflare: cloudflare,
      sleep: verifierSleep
    )
    try await cloudflare.verifyToken(accountID: options.accountID)

    let namespaces = try await cloudflare.listKVNamespaces(accountID: options.accountID)
    let matchingNamespaces = namespaces.filter { $0.title == options.kvNamespaceTitle }
    guard matchingNamespaces.count <= 1 else {
      throw EdgeTunnelError.stateConflict(
        "发现多个标题为 \(options.kvNamespaceTitle) 的 KV 命名空间，无法安全选择。"
      )
    }

    var namespace: KVNamespace?
    var remoteIdentityChanged = false
    if let savedID = state.kvNamespaceID {
      if let savedNamespace = namespaces.first(where: { $0.id == savedID }) {
        guard savedNamespace.title == options.kvNamespaceTitle else {
          throw EdgeTunnelError.stateConflict("状态中的 KV ID 指向了不同标题的命名空间。")
        }
        namespace = savedNamespace
        state.kvNamespaceCreationPending = false
      } else {
        guard options.adoptExisting else {
          throw EdgeTunnelError.stateConflict(
            "状态中的 KV 命名空间已不存在。若确认要创建或接管替代资源，请显式使用 --adopt-existing。"
          )
        }
        namespace = matchingNamespaces.first
        state.kvNamespaceID = namespace?.id
        state.kvNamespaceCreationPending = false
        remoteIdentityChanged = true
      }
    } else {
      namespace = matchingNamespaces.first
      if hasTrustedState, namespace != nil {
        guard state.kvNamespaceCreationPending == true || options.adoptExisting else {
          throw EdgeTunnelError.stateConflict(
            "Cloudflare 存在同名 KV，但状态文件没有其 ID。若确认要接管，请显式使用 --adopt-existing。"
          )
        }
        state.kvNamespaceID = namespace?.id
        state.kvNamespaceCreationPending = false
        remoteIdentityChanged = true
      }
    }

    var project = try await cloudflare.getPagesProject(
      accountID: options.accountID,
      name: options.projectName
    )
    if !hasTrustedState,
      !options.adoptExisting,
      matchingNamespaces.first != nil || project != nil
    {
      throw EdgeTunnelError.stateConflict(
        "Cloudflare 已存在同名 Pages 项目或 KV，但本地没有可信状态。若确认要覆盖并接管，请显式使用 --adopt-existing。"
      )
    }
    if let savedProjectID = state.pagesProjectID {
      if project?.id != savedProjectID {
        guard options.adoptExisting else {
          throw EdgeTunnelError.stateConflict(
            "状态中的 Pages 项目已不存在或已被同名资源替代。若确认要创建或接管替代资源，请显式使用 --adopt-existing。"
          )
        }
        state.pagesProjectID = project?.id
        state.pagesProjectCreationPending = false
        remoteIdentityChanged = true
      }
    } else if hasTrustedState, let project {
      guard state.pagesProjectCreationPending == true || options.adoptExisting else {
        throw EdgeTunnelError.stateConflict(
          "Cloudflare 存在同名 Pages 项目，但状态文件没有其 ID。若确认要接管，请显式使用 --adopt-existing。"
        )
      }
      state.pagesProjectID = project.id
      state.pagesProjectCreationPending = false
      remoteIdentityChanged = true
    }
    if let project {
      guard project.name == options.projectName else {
        throw EdgeTunnelError.stateConflict("Cloudflare 返回了不同的 Pages 项目。")
      }
      state.pagesProjectID = project.id
      state.pagesProjectCreationPending = false
      state.hostname = project.subdomain
    }

    if let namespace {
      state.kvNamespaceID = namespace.id
    }
    if remoteIdentityChanged {
      state.deploymentID = nil
      state.deploymentComplete = false
    }
    try store.save(state)

    if state.deploymentComplete,
      state.upstreamCommit == upstream.commit,
      let project,
      let namespace,
      let savedDeploymentID = state.deploymentID,
      savedDeploymentID == project.canonicalDeploymentID,
      state.kvNamespaceID == namespace.id
    {
      let subscriptionURL = try Subscription.makeURL(
        hostname: project.subdomain,
        uuid: state.uuid
      )
      var subscriptionIsReusable = false
      do {
        try await subscriptionVerifier.verify(
          subscriptionURL,
          expectedUUID: state.uuid,
          attempts: 2
        )
        subscriptionIsReusable = true
      } catch {
        if Task.isCancelled { throw error }
        // A stale canonical deployment is repaired below with the same credentials.
      }
      if subscriptionIsReusable {
        try await defaultsInitializer.ensure(
          accountID: options.accountID,
          namespaceID: namespace.id,
          upstreamCommit: upstream.commit
        )
        try await subscriptionVerifier.verify(
          subscriptionURL,
          expectedUUID: state.uuid,
          attempts: 4
        )
        return try DeploymentResult(state: state, stateFile: options.stateFile, reused: true)
      }
    }

    let worker = try await WorkerSourceLoader(transport: transport, upstream: upstream)
      .load(file: options.workerFile)

    if namespace == nil {
      state.kvNamespaceCreationPending = true
      try store.save(state)
      namespace = try await cloudflare.createKVNamespace(
        accountID: options.accountID,
        title: options.kvNamespaceTitle
      )
    }
    guard let namespace else {
      throw EdgeTunnelError.invalidResponse(status: 200)
    }
    state.kvNamespaceID = namespace.id
    state.kvNamespaceCreationPending = false
    try store.save(state)

    if project == nil {
      state.pagesProjectCreationPending = true
      try store.save(state)
      project = try await cloudflare.createPagesProject(
        accountID: options.accountID,
        name: options.projectName
      )
    }
    guard var project else {
      throw EdgeTunnelError.invalidResponse(status: 200)
    }
    state.pagesProjectID = project.id
    state.pagesProjectCreationPending = false
    state.hostname = project.subdomain
    state.upstreamCommit = upstream.commit
    state.deploymentComplete = false
    try store.save(state)

    project = try await cloudflare.configurePagesProject(
      accountID: options.accountID,
      name: options.projectName,
      namespaceID: namespace.id,
      uuid: state.uuid,
      adminPassword: state.adminPassword,
      upstreamCommit: upstream.commit
    )
    guard project.id == state.pagesProjectID else {
      throw EdgeTunnelError.stateConflict("Pages 项目 ID 在配置期间发生变化，已停止部署。")
    }
    state.hostname = project.subdomain
    try store.save(state)

    let deploymentID = try await cloudflare.createPagesDeployment(
      accountID: options.accountID,
      projectName: options.projectName,
      worker: worker,
      upstreamCommit: upstream.commit,
      redacting: [state.uuid, state.adminPassword]
    )
    state.deploymentID = deploymentID
    try store.save(state)

    project = try await waitForCanonicalDeployment(
      cloudflare: cloudflare,
      accountID: options.accountID,
      projectName: options.projectName,
      projectID: project.id,
      deploymentID: deploymentID
    )
    state.hostname = project.subdomain
    try store.save(state)

    let subscriptionURL = try Subscription.makeURL(
      hostname: project.subdomain,
      uuid: state.uuid
    )
    try await subscriptionVerifier.verify(
      subscriptionURL,
      expectedUUID: state.uuid,
      attempts: 8
    )
    try await defaultsInitializer.ensure(
      accountID: options.accountID,
      namespaceID: namespace.id,
      upstreamCommit: upstream.commit
    )
    try await subscriptionVerifier.verify(
      subscriptionURL,
      expectedUUID: state.uuid,
      attempts: 8
    )

    state.deploymentComplete = true
    try store.save(state)
    return try DeploymentResult(state: state, stateFile: options.stateFile, reused: false)
  }

  private func waitForCanonicalDeployment(
    cloudflare: CloudflareClient,
    accountID: String,
    projectName: String,
    projectID: String,
    deploymentID: String,
    attempts: Int = 45
  ) async throws -> PagesProject {
    for attempt in 0..<attempts {
      switch try await cloudflare.getPagesDeploymentStage(
        accountID: accountID,
        projectName: projectName,
        deploymentID: deploymentID
      ) {
      case .failed(let status):
        throw EdgeTunnelError.pagesDeploymentFailed(status: status)
      case .success:
        if let project = try await cloudflare.getPagesProject(
          accountID: accountID,
          name: projectName
        ), project.id == projectID,
          project.canonicalDeploymentID == deploymentID
        {
          return project
        }
      case .pending:
        break
      }
      if attempt + 1 < attempts {
        try await verifierSleep(2_000_000_000)
      }
    }
    throw EdgeTunnelError.pagesDeploymentTimedOut(attempts: attempts)
  }
}
