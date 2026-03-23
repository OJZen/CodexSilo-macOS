# CodexSilo

<p align="center">
  <img src="./Sources/CodexSilo/Resources/app_icon.png" alt="CodexSilo App Icon" width="160" />
</p>

<p align="center">
  一个为 macOS 打造的原生 SwiftUI 工作台，用来集中管理 Codex / ChatGPT 账号、查看配额、智能切换账号，并提供本地 OpenAI 兼容 API 代理。
</p>

## 为什么会有这个项目

如果你同时维护多个 Codex / ChatGPT 账号，通常会遇到这些问题：

- 当前 `auth.json` 只能代表一个账号，切换成本高
- 不清楚哪个账号还有更多可用额度
- 想在切换账号后顺手拉起 Codex，而不是手动重开
- 需要把账号能力以本地 API 的形式提供给其他工具或脚本

CodexSilo 的目标，就是把这些工作流收进一个原生 macOS 应用里。

## 核心能力

### 账号管理

- 导入当前 `~/.codex/auth.json`
- 通过内置 ChatGPT OAuth 登录新增账号
- 导入外部账号文件，或直接以 JSON 形式自定义导入
- 编辑账号标签、团队别名、认证 JSON
- 删除本地账号配置，并维护当前选中账号

### 配额感知与智能切换

- 拉取并展示 5 小时窗口与 7 天窗口的用量
- 根据剩余额度计算排序分数
- 支持按剩余额度、账号名、邮箱、团队名排序
- 支持手动 Smart Switch
- 支持当前账号额度耗尽时的 Auto Smart Switch

### 本地 API 代理

- 内置 Swift 原生本地代理运行时，无需额外 Node/Tauri 运行时
- 提供 OpenAI 兼容接口：
  - `GET /v1/models`
  - `POST /v1/responses`
  - `POST /v1/chat/completions`
- 为常见 `gpt-5` / `gpt-5.x` / `gpt-5-codex` 系列模型做兼容映射
- 自动生成并持久化本地代理 API Key
- 支持代理状态查看、端口配置、复制 Base URL / API Key

### 桌面体验

- `MenuBarExtra` 常驻菜单栏
- 从菜单栏打开完整主窗口
- 后台刷新账号快照与用量
- 可选在切换账号后自动拉起 Codex
- 可选开机启动、自动刷新账号、自动启动本地代理

### 数据迁移与本地化

- 支持密码保护的账号数据导出 / 导入
- 导出格式为 `*.codexsiloexport`
- 支持自动跟随系统语言，以及英文、简体中文、繁体中文、日文、韩文、法文、德文、意大利文、西班牙文、俄文、荷兰文

## 适合谁

- 需要在多个 Codex / ChatGPT 账号之间频繁切换的个人用户
- 想把账号切换、额度查看和桌面工作流整合到一起的重度使用者
- 需要一个本地 OpenAI 兼容代理给脚本、工具或客户端复用的开发者

## 当前边界

- 当前应用只面向 macOS
- 主界面目前聚焦本地账号管理与本地代理工作流
- 代码里已经包含远程代理部署/管理基础设施，但当前产品路径是本地优先，不建议把它理解成现成的多机控制台

## 系统要求

- macOS 14+
- 支持 Swift 6 的 Xcode

## 快速开始

### 1. 打开工程

```bash
open CodexSilo.xcodeproj
```

推荐直接使用 Xcode 运行 `CodexSilo` scheme。

### 2. 命令行构建

```bash
xcodebuild -project CodexSilo.xcodeproj -scheme CodexSilo -configuration Debug -destination 'platform=macOS' build
```

### 3. 运行测试

```bash
swift test
```

如果你更习惯 Xcode：

```bash
xcodebuild test -project CodexSilo.xcodeproj -scheme CodexSilo -destination 'platform=macOS'
```

## 建议的使用流程

### 账号场景

1. 首次启动后，先导入当前账号，或通过 ChatGPT OAuth 新增账号
2. 点击刷新用量，让每个账号都拿到最新配额窗口
3. 按剩余额度排序，选择最合适的账号
4. 如果你希望切换后立即进入工作，可开启“切换后启动 Codex”
5. 如果你有多个轮换账号，可开启 Auto Smart Switch

### 代理场景

1. 进入 Proxy 页面启动本地代理
2. 复制 `Base URL` 与 `API Key`
3. 把你的客户端指向本地代理地址
4. 让外部工具通过 CodexSilo 统一复用当前账号能力

## 数据与安全

CodexSilo 主要读写这些本地文件：

- `~/Library/Application Support/CodexToolsSwift/accounts.json`
- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.codex-tools-proxyd/api-proxy.key`

补充说明：

- 账号总表会保存在 `accounts.json`
- 当前生效账号会同步回 `~/.codex/auth.json`
- 导出档案使用口令派生密钥 + `AES-256-GCM` 加密
- 仓库里并不包含你的真实凭据，但导出的数据包和本地存储都可能含有敏感 token，请不要上传或提交到公开仓库

## 开发说明

### 项目结构

```text
Sources/CodexSilo
├── App              # 应用入口、主窗口、菜单栏
├── Features         # Accounts / Proxy / Settings 页面
├── UI               # 可复用 UI 组件
├── Behavior         # 协调器、排序与切换策略
├── Infrastructure   # 文件、网络、进程、OAuth、代理运行时
├── Domain           # 模型与协议
├── Layout           # 布局常量
└── Resources        # 本地化、图标、代理资源
```

### 测试关注点

仓库已经为这些关键行为提供了单元测试：

- 账号导入、切换、去重与持久化
- 配额刷新与自动切换策略
- 本地代理运行时与接口兼容性
- 本地化键一致性
- 数据导入导出与异常恢复

## 发布

- 发布脚本：`./scripts/release_macos.sh`
- 发布说明：[`docs/release-macos.md`](./docs/release-macos.md)

该脚本覆盖了 Developer ID 签名、可选公证、zip 打包、校验和生成，以及可选的 GitHub Release 发布流程。

## 项目背景

这个仓库不是对旧实现的简单搬运，而是一次更偏原生化的重做：

- 以 SwiftUI + Swift 并发为主
- 采用明确分层的架构组织代码
- 目标是把原先分散的账号管理与代理工作流收敛成一个 macOS 原生体验

## 参考项目

本项目在设计思路与实现演进过程中参考了以下项目：

- [AlickH/Copool](https://github.com/AlickH/Copool)
- [170-carry/codex-tools](https://github.com/170-carry/codex-tools)

在此基础上，CodexSilo 选择了更偏 Swift 原生、macOS 原生工作流的实现路径。

## 许可证说明

本项目采用 [MIT License](./LICENSE) 开源。

如果你计划复用本项目中参考项目的代码、资源或实现思路，也请分别确认对应上游项目的许可证与合规要求。
