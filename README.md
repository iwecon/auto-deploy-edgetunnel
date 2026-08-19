# EdgeTunnel Swift 自动部署工具

这是一个无第三方依赖的 Swift 命令行工具。输入 Cloudflare API Token 和 Account ID 后，它会自动创建或复用 KV、配置 Cloudflare Pages、上传固定版本的 [`cmliu/edgetunnel`](https://github.com/cmliu/edgetunnel) `_worker.js`、初始化推荐节点地址，并在订阅验证成功后输出完整部署参数。

默认只需要两个输入：

- Cloudflare API Token
- Cloudflare Account ID（32 位十六进制）

工具会自动生成固定 UUID 和高强度管理密码，并把恢复部署所需的状态写到权限为 `0600` 的 `.edgetunnel-state.json`。API Token 不会写入状态文件，也不会出现在成功输出中。

## Cloudflare Token 权限

创建一个仅限目标 Account 的 API Token，并赋予：

- `Cloudflare Pages: Edit`（Cloudflare API 文档称 `Pages Write`）
- `Workers KV Storage: Edit`（Cloudflare API 文档称 `Workers KV Storage Write`）

不需要 Zone、DNS、Workers Routes 或全局 API Key 权限。相关官方 API：

- [Verify Token](https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/verify/)
- [Create KV Namespace](https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/methods/create/)
- [Read KV Value](https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/subresources/values/methods/get/)
- [Write KV Value](https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/subresources/values/methods/update/)
- [Create Pages Project](https://developers.cloudflare.com/api/resources/pages/subresources/projects/methods/create/)
- [Create Pages Deployment](https://developers.cloudflare.com/api/resources/pages/subresources/projects/subresources/deployments/methods/create/)

## 安装

### Homebrew

项目提供 HEAD Formula，会从 `main` 构建当前版本：

```bash
brew install --HEAD \
  https://raw.githubusercontent.com/iwecon/auto-deploy-edgetunnel/main/Formula/edgetunnel.rb
```

### 安装脚本

脚本只通过 HTTPS 下载本仓库源码，在本机使用 Swift 构建，并默认安装到
`$HOME/.local/bin/edgetunnel`：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/iwecon/auto-deploy-edgetunnel/main/install.sh | sh
```

可以用 `EDGETUNNEL_INSTALL_DIR` 指定安装目录，或用 `EDGETUNNEL_REF` 固定 tag / commit：

```bash
EDGETUNNEL_INSTALL_DIR=/usr/local/bin EDGETUNNEL_REF=main \
  sh install.sh
```

建议在执行远端脚本前先下载并审查内容。安装脚本不会读取 Cloudflare 凭据；凭据只会在运行
`edgetunnel` 部署时使用。

### 源码运行

macOS 13+，安装带 Swift 5.9+ 的 Xcode/Swift toolchain 后：

```bash
swift run edgetunnel
```

使用上述安装方式后，也可以直接运行：

```bash
edgetunnel
```

程序会先询问 Account ID，再以关闭终端回显的方式读取 API Token。

也可以用环境变量：

```bash
export CLOUDFLARE_ACCOUNT_ID="你的 Account ID"
export CLOUDFLARE_API_TOKEN="你的 API Token"
swift run edgetunnel
```

自动化场景可以从标准输入读取一行 Token：

```bash
printenv CLOUDFLARE_API_TOKEN | swift run edgetunnel \
  --account-id "你的 Account ID" \
  --api-token-stdin \
  --json
```

不提供 `--api-token <value>`，避免 Token 出现在 shell history 或进程参数中。

## 成功输出

部署通过真实订阅响应验证后，输出：

- Pages 项目名与 `pages.dev` 主机名
- Pages 项目 ID
- Account ID
- 站点和管理后台 URL
- 订阅 URL
- UUID
- 管理密码
- KV namespace 标题与 ID
- Pages deployment ID
- 固定上游 commit
- 本地状态文件路径
- 本次是否直接复用了已验证部署
- 推荐节点地址是否已经初始化或确认

订阅 URL、UUID、管理密码和状态文件都属于敏感信息。`--json` 同样会包含这些字段，请勿把输出上传到 CI 日志或公开位置。

## 参数

```text
edgetunnel [deploy] [选项]

--account-id <32hex>   Cloudflare Account ID
--api-token-stdin      从标准输入读取一行 API Token
--state-file <path>    状态文件；默认 .edgetunnel-state.json
--worker-file <path>   使用本地 _worker.js；仍校验固定 SHA-256
--project-name <name>  覆盖默认 in-iiiam-<account-id>
--kv-title <title>     覆盖默认 in.iiiam-edgetunnel
--adopt-existing       显式接管并覆盖身份不明或已变化的同名资源
--json                 JSON 输出（包含敏感字段）
--help                 帮助
```

输入优先级：命令行非敏感参数高于环境变量，环境变量高于交互输入。显式使用 `--api-token-stdin` 时，它高于 Token 环境变量。

## 部署与重跑行为

默认资源名：

- Pages project：`in-iiiam-<lowercase-account-id>`
- KV namespace title：`in.iiiam-edgetunnel`

品牌前缀统一配置为 `in.iiiam`。Cloudflare Pages 项目名不允许使用点号，因此新项目的实际名称会规范化为 `in-iiiam-<lowercase-account-id>`；新 KV namespace 使用 `in.iiiam-edgetunnel`。已有状态文件继续使用其中保存的 Pages 项目名和 KV namespace 标题，不会自动迁移或改名。

执行顺序：

1. 验证 Token。
2. 分页查找同名 KV，缺少时创建。
3. 获取同名 Pages project，缺少时创建。
4. 将 `UUID`、`ADMIN` 作为 `secret_text`，将 KV 绑定为 `KV`。
5. 通过 Pages Direct Upload multipart API 上传 `_worker.js`；不指定 branch，让 Cloudflare 使用项目当前 production branch。
6. 轮询新 deployment 至 `success`，并确认它已经成为 canonical deployment。
7. 首次验证订阅地址，要求返回标准 Base64、至少包含一个 VLESS + TLS + WebSocket URL，并且节点 UUID 与本地状态完全一致。
8. 合并 `config.json` 并将推荐节点地址写入 KV 的 `ADD.txt`，最后写 `in.iiiam-defaults.json` 标记。
9. 再次验证订阅，确认默认值写入后仍可生成匹配 UUID 的有效节点。
10. 原子写入完整状态并保持 `0600` 权限。

状态文件与当前 Account、项目名或 KV 标题不一致时会停止，而不是覆盖。状态还会保存 Pages project ID 和 KV namespace ID；远端资源缺失、同名替换或本地状态缺少对应 ID 时默认停止。只有状态已在远端创建前记录了对应 creation intent，才会自动按名称恢复 POST 成功但 ID 尚未来得及落盘的资源。其他替代资源必须显式使用 `--adopt-existing` 才能接管；该选项会替换 Pages 生产配置和代码。发现多个同名 KV 时仍会停止。若 Cloudflare 已创建部分资源而后续失败，工具会保留资源和本地状态供重跑，不会自动删除可能仍有价值的数据。

工具按 Cloudflare Account ID 在带当前 UID、权限为 `0700` 的运行时临时目录持有跨进程独占锁。即使进程使用不同状态文件、Pages 项目或共享 KV 标题，也不能同时修改同一账户；不要求写入用户 home/Application Support。加载已有状态时会拒绝符号链接、非当前用户所有、带额外硬链接或允许 group/other 访问的文件。

当状态记录的 deployment ID 与 Cloudflare canonical deployment 一致、固定上游版本一致，并且订阅仍能验证时，重跑会直接复用。否则使用原 UUID/管理密码修复部署，避免已有客户端凭据变化。

## 推荐节点地址初始化

首次成功部署时，Worker 先通过订阅请求生成 KV `config.json`，工具再执行与旧 Local Live 实现相同的幂等初始化：

- 保留未知配置；将缺失或关闭的 `启用0RTT`、`ECH` 打开。
- 仅在 `SUBCONFIG` 缺失或仍为上游默认值时，切换到完整规则；自定义地址保持不变。
- 仅在优选模式仍为上游默认时关闭随机 IP；自定义数量、端口和模式保持不变。
- 保留并去重现有 `ADD.txt` 内容，再按固定顺序补齐 12 条推荐地址链接。
- `config.json`、`ADD.txt` 成功后最后写入版本为 `1` 的 `in.iiiam-defaults.json`。标记已存在时不会再次覆盖用户后续修改；标记损坏或版本异常时会停止。

这些节点地址是第三方动态资源，并不受 `_worker.js` SHA-256 固定保护；其内容、可用性和运营方可能变化，请按自身信任边界使用。

## 固定上游与完整性

当前固定：

- commit：`92fc6cc4a4cbfdf536394bc9b0397e5948b039f8`
- `_worker.js` SHA-256：`01e932b492aad13bedb742d9d9b87923062f4bb5a973fda5bb7c78b53181e55a`
- compatibility date：`2025-11-04`

工具只从该 commit 的 raw URL 下载，限制为 1 MiB，并在向 Cloudflare 发送前校验 SHA-256。`--worker-file` 也不能绕过校验。

固定 `_worker.js` 不等于固定全部管理界面：上游 Worker 会从 `https://edt-pages.github.io/login` 和 `/admin` 动态取得 HTML，再通过你的 Pages 域名返回。该远端页面未来变化时不受上述 SHA-256 保护，并会处在可接触管理密码的同源页面中。若不能接受这条上游信任边界，请不要登录管理界面，或自行审计并固定管理 UI 资产后再部署。

## 构建与测试

```bash
swift build
swift test
```

单元测试不访问真实网络，覆盖首次部署、幂等复用、推荐配置合并、KV value 读写与 marker-last、同名资源收养保护、失败 deployment 不得伪装成功、multipart 内容、Cloudflare 错误脱敏、状态权限与锁、固定源码校验、MD5/SHA-256 与 UUID 一致的订阅解析。没有 Cloudflare 凭据时，构建和测试不能证明真实账户权限、Pages/KV propagation、第三方节点地址可用性、WebSocket 数据面或代理可用性；这些必须由一次真实部署和客户端连接另行验证。

请遵守所在地法律法规及上游项目的使用说明。
