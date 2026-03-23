# CodexSilo

<p align="center">
  <img src="./Sources/CodexSilo/Resources/app_icon.png" alt="CodexSilo App Icon" width="160" />
</p>

<p align="center">
  一个面向 macOS 的原生 SwiftUI 工具，用来管理 Codex / ChatGPT 账号、查看配额、智能切换账号，并提供本地 OpenAI 兼容 API 代理。
</p>

## 功能

- 导入当前 `~/.codex/auth.json`
- 通过 ChatGPT OAuth 新增账号
- 导入外部账号文件，支持直接编辑认证 JSON
- 展示 5 小时和 7 天窗口用量
- 按剩余额度、账号名、邮箱、团队名排序
- 支持 Smart Switch 和 Auto Smart Switch
- 内置本地 OpenAI 兼容代理：
  - `GET /v1/models`
  - `POST /v1/responses`
  - `POST /v1/chat/completions`
- 支持复制 `Base URL` 与 `API Key`
- 支持菜单栏常驻、开机启动、自动刷新、切换后拉起 Codex、自动启动代理
- 支持密码保护的账号数据导入 / 导出，导出格式为 `*.codexsiloexport`

## 系统要求

- macOS 14+
- 支持 Swift 6 的 Xcode

## 运行

直接用 Xcode 打开 `CodexSilo.xcodeproj`，选择 `CodexSilo` scheme 运行即可。

首次运行前，请先在 Xcode 的 Signing 设置里把 `Development Team` 改成你自己的开发者账号。

如需跑测试：

```bash
swift test
```

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

## 数据文件

主要读写以下路径：

- `~/Library/Application Support/CodexToolsSwift/accounts.json`
- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.codex-tools-proxyd/api-proxy.key`

说明：

- 当前选中账号会同步回 `~/.codex/auth.json`
- 导出数据使用口令派生密钥和 `AES-256-GCM` 加密
- 本地存储可能包含敏感 token，请不要上传到公开仓库

## 发布

- 发布脚本：`./scripts/release_macos.sh`
- 发布说明：[`docs/release-macos.md`](./docs/release-macos.md)

## 参考项目

- [AlickH/Copool](https://github.com/AlickH/Copool)
- [170-carry/codex-tools](https://github.com/170-carry/codex-tools)

## License

本项目采用 [MIT License](./LICENSE)。
