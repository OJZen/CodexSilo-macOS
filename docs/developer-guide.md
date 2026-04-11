# CodexSilo Developer Guide

这份文档只面向开发者维护，不会在 `README.md` 里对外展示。

## 项目定位

CodexSilo 是一个 macOS 原生 SwiftUI 工具，目标是把 Codex / ChatGPT 账号管理、配额查看、账号切换和本地 OpenAI 兼容代理放到一个轻量的桌面应用里。

当前代码的设计倾向是：

- 保持原生、轻量、单机优先
- 账号状态以本地文件和本地存储为中心
- 代理能力尽量兼容，但不引入重型 provider 网关架构

## 当前功能总览

### 1. 账号管理

- 导入当前 `~/.codex/auth.json`
- 通过自定义编辑器粘贴 / 编辑原始 `auth.json`
- 通过 ChatGPT OAuth 登录新增账号
- 新建自定义账号配置
- 编辑已存账号：
  - 账户名称
  - 团队别名
  - 原始 `auth.json`
- 删除本地账号配置
- 支持“导入并设为当前账号”
- 支持手动刷新账号用量
- 支持取消进行中的 OAuth 登录流程

补充说明：

- `AccountsCoordinator` 底层仍然保留了“从外部 auth 文件 URL 导入”的能力
- 但当前主 UI 没有直接暴露文件选择入口，实际用户入口是“导入当前 live auth”或“自定义编辑器”

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Accounts/AccountsPageModel.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Accounts/AccountsPageModel.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/AccountsCoordinator.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/AccountsCoordinator.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/OpenAIChatGPTOAuthLoginService.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/OpenAIChatGPTOAuthLoginService.swift)

### 2. 用量与工作区信息

- 拉取并展示 5 小时窗口用量
- 拉取并展示 7 天窗口用量
- 拉取账号计划信息
- 远程补全 workspace / team 名称
- 在本地缓存最近一次用量快照

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/DefaultUsageService.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/DefaultUsageService.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/DefaultWorkspaceMetadataService.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/DefaultWorkspaceMetadataService.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Accounts/AccountCardPresentation.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Accounts/AccountCardPresentation.swift)

### 3. 切换与排序

- 切换当前账号，并把目标账号写回 live `~/.codex/auth.json`
- Smart Switch：手动切到剩余额度更合适的账号
- Auto Smart Switch：后台刷新时如果当前账号额度耗尽，可自动切换
- 排序方式：
  - 剩余额度
  - 账号名称
  - 邮箱
  - 团队名称
- 支持账户卡片折叠 / 全部折叠

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/AccountRanking.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/AccountRanking.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Accounts/AccountsPageControls.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Accounts/AccountsPageControls.swift)

### 4. 本地 OpenAI 兼容代理

当前代理是轻量设计，核心用途是给本地客户端提供统一入口，并按账号额度顺序尝试上游。

支持的入口：

- `GET /health`
- `GET /v1/models`
- `POST /responses`
- `POST /v1/responses`
- `POST /v1/v1/responses`
- `POST /codex/v1/responses`
- `POST /responses/compact`
- `POST /v1/responses/compact`
- `POST /v1/v1/responses/compact`
- `POST /codex/v1/responses/compact`
- `POST /chat/completions`
- `POST /v1/chat/completions`
- `POST /v1/v1/chat/completions`
- `POST /codex/v1/chat/completions`

代理页面支持：

- 启动 / 停止代理
- 自定义端口
- 自动启动代理
- 查看可用账号数
- 查看当前命中的账号
- 查看最近错误
- 复制 `Base URL`
- 复制 `API Key`
- 刷新 `API Key`

补充说明：

- 页面里展示的 `Base URL` 是 `http://127.0.0.1:<port>/v1`
- 但运行时额外兼容了不带 `/v1`、双 `/v1`、`/codex/v1/*` 这些别名路径

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/SwiftNativeProxyRuntimeService.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/SwiftNativeProxyRuntimeService.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/ProxyCoordinator.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/ProxyCoordinator.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Proxy/ProxyPageModel.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Proxy/ProxyPageModel.swift)

### 5. 菜单栏与后台行为

- 菜单栏常驻
- 菜单栏里显示当前账号与剩余额度
- 从菜单栏快速切换账号
- 应用启动后自动开始后台刷新
- 定时刷新账号与用量
- 监听本地 `auth.json` 变化
- 监听本地 `config.toml` 变化

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/CodexSiloApp.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/CodexSiloApp.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/TrayMenuModel.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/TrayMenuModel.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/AuthFileRepository.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/AuthFileRepository.swift)

### 6. 设置与数据迁移

- 开机启动
- 自动刷新账号
- Auto Smart Switch
- 自动启动代理
- 应用语言切换
- 导出本地 store
- 导入本地 store
- 导入导出格式为 `*.codexsiloexport`
- 导出使用口令加密
- 设置页提供独立文件日志页面
- 设置页展示项目仓库链接
- 设置页展示当前应用版本号

这里的 store 不只是 accounts，还包括：

- settings
- currentSelection
- accounts

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Settings/SettingsPageView.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Settings/SettingsPageView.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/SettingsCoordinator.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/SettingsCoordinator.swift)

### 7. 本地文件日志

- 应用会把运行日志写入 `~/Library/Application Support/CodexToolsSwift/Logs/`
- 当前活跃日志文件是 `app.log`
- 日志采用纯文本单行格式，包含时间、级别、分类、事件和脱敏后的上下文摘要
- 默认按大小或日期轮转，并保留最近 7 天的日志文件
- 设置页里的 Logs 入口读取的是这套文件日志，不是代理 live test 历史

相关入口：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Domain/AppLogging.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Domain/AppLogging.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/FileAppLogger.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/FileAppLogger.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Settings/SettingsPageModel.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Features/Settings/SettingsPageModel.swift)

## 运行时结构

### 应用装配

`AppContainer.liveOrCrash()` 负责装配主要依赖：

- 本地路径与仓库
- auth 文件读写
- 本地文件监听
- 用量服务
- workspace 元数据服务
- OAuth 登录服务
- 本地代理服务
- 设置协调器
- 账户协调器
- 代理协调器
- 三个页面模型和菜单栏模型

参考：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/AppContainer.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/AppContainer.swift)

### 页面结构

主窗口只有三个 Tab：

- Accounts
- Proxy
- Settings

根视图会把 `trayModel` 的后台刷新结果同步回页面模型。

参考：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/RootScene.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/RootScene.swift)

## 关键数据文件

应用会直接读写这些文件：

- `~/Library/Application Support/CodexToolsSwift/accounts.json`
- `~/Library/Application Support/CodexToolsSwift/Logs/app.log`
- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.codex-tools-proxyd/api-proxy.key`

说明：

- `accounts.json` 是应用自己的持久化 store，不只是账号列表
- `Logs/` 目录保存应用自己的文件日志，不进 `accounts.json`
- `accounts.json` 里还包含 settings 和 `currentSelection`
- `~/.codex/auth.json` 是 live 当前账号文件
- `~/.codex/config.toml` 会影响上游 base URL 和部分请求行为
- `api-proxy.key` 是本地代理访问密钥

## 开发注意事项

### 1. `auth.json` 不是普通缓存，它是 live 状态

这部分最容易改坏。

- 账户库里保存的是每个账号的 auth 快照
- live `~/.codex/auth.json` 代表当前正在使用的账号
- 当前实现既有“显式切换时把快照写回 live”，也有“监听 live 文件变化再回填到账户库”

改动这里时要特别注意：

- 不要把 live auth 当成只读缓存
- 不要在无用户意图的情况下频繁回写 live auth
- 不要破坏“显式切换”和“监听回填”之间的平衡
- 不要忽略 `currentSelection` 和 live auth 之间的联动

当前账号识别不是只看 `accountID`，而是优先基于：

- `variantKey`
- `accountKey`
- 必要时才回退到 `accountID`

如果你改了匹配或去重逻辑，请连带检查：

- 当前账号高亮
- 导入覆盖判定
- 当前账号恢复
- 设置导入后的 live auth 恢复

重点文件：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/AccountsCoordinator.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/AccountsCoordinator.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/AuthFileRepository.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/AuthFileRepository.swift)

### 2. 代理是轻量兼容层，不是重型网关

这是本项目的核心设计约束。

- `/responses` 和 `/responses/compact` 尽量保持透明
- `/chat/completions` 是兼容入口，内部会适配到上游 `responses`
- 当前上游本质是 ChatGPT / Codex backend，而不是完整 OpenAI 平台

开发时请保持这些原则：

- 优先保留 query、header、状态码和响应头
- 不要随意增加静默字段改写
- 对无法无损兼容的参数，优先显式报错，而不是悄悄吞掉
- 如果只是为了支持更多客户端别名路径，优先加 alias，不要把代理结构做重

重点文件：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/SwiftNativeProxyRuntimeService.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/SwiftNativeProxyRuntimeService.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Tests/CodexSiloTests/SwiftNativeProxyRuntimeServiceTests.swift](/Volumes/Ju/Projects/github/CodexSilo/Tests/CodexSiloTests/SwiftNativeProxyRuntimeServiceTests.swift)

### 3. 菜单栏模型承载了大量后台行为

`TrayMenuModel` 不只是 UI 模型，它还负责：

- 周期性刷新
- 本地文件监听后的同步
- Auto Smart Switch
- 页面模型需要的手动刷新服务

如果你要调整后台行为，优先从这里看，不要只盯页面层。

重点文件：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/TrayMenuModel.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/TrayMenuModel.swift)

### 4. 设置导入不仅仅是“读个文件”

设置导入会有额外副作用：

- 覆盖账户库
- 尝试恢复当前选中账号到 live `auth.json`
- 同步开机启动开关

如果改了导入逻辑，请连带检查这些副作用是否仍然成立。

重点文件：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/SettingsCoordinator.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/SettingsCoordinator.swift)

### 5. 本地化是强约束

项目已经有本地化一致性测试。

- 新增字符串后，需要补齐所有 locale key
- 不要只改 `en.lproj`
- 提交前最好跑本地化测试

重点文件：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Resources/en.lproj/Localizable.strings](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Resources/en.lproj/Localizable.strings)
- [/Volumes/Ju/Projects/github/CodexSilo/Tests/CodexSiloTests/LocalizationConsistencyTests.swift](/Volumes/Ju/Projects/github/CodexSilo/Tests/CodexSiloTests/LocalizationConsistencyTests.swift)

### 6. 有些能力已经有代码，但当前没有真正接到产品流里

这类代码改动前先确认，不要误以为它已经上线使用。

- 更新检查服务存在：
  - `GitHubUpdateService`
  - `UpdateCoordinator`
- 但当前主流程没有把它接进 UI
- cloud sync 相关协议和通知位也存在
- 但 `AppContainer` 当前注入的是 `nil`，默认后台策略也是 `disabled`

参考：

- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/GitHubUpdateService.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Infrastructure/GitHubUpdateService.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/UpdateCoordinator.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/Behavior/UpdateCoordinator.swift)
- [/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/AppContainer.swift](/Volumes/Ju/Projects/github/CodexSilo/Sources/CodexSilo/App/AppContainer.swift)

## 建议测试清单

改动后至少按影响范围运行这些测试：

- 全量测试：
  - `swift test`
- 代理相关：
  - `swift test --filter SwiftNativeProxyRuntimeServiceTests`
- 账户 / 当前选择 / 文件监听相关：
  - `swift test --filter AccountsCoordinatorTests`
- 本地化相关：
  - `swift test --filter LocalizationConsistencyTests`

## 常见修改建议

### 如果你要改账号导入或切换

- 先看 `AccountsCoordinator`
- 再看 `AuthFileRepository`
- 最后看 `AccountsCoordinatorTests`

### 如果你要改代理兼容行为

- 先看 `SwiftNativeProxyRuntimeService`
- 明确这是“透明透传”还是“兼容适配”
- 先补测试，再改运行时

### 如果你要改设置或导入导出

- 先看 `SettingsCoordinator`
- 留意是否影响 live auth 和开机启动
- 留意导入导出处理的是整个 `AccountsStore`

### 如果你要改后台刷新

- 优先从 `TrayMenuModel` 入手
- 检查页面层是否只是消费后台状态，而不是自己做重复刷新

## 维护建议

- 尽量把“业务规则”留在 `Behavior`
- 把“文件 / 网络 / 系统调用”留在 `Infrastructure`
- 页面模型只负责组装交互，不要把底层副作用直接写进 View
- 代理新增兼容时，优先最小改动，不要为了对齐外部项目把本项目架构做重
- 账号导入导出涉及加密格式时，尽量保持向后兼容；当前实现使用 `PBKDF2-HMAC-SHA256` + `AES-256-GCM`
