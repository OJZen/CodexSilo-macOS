# CodexSilo Refactor Checklist

## Scope

- [x] 审计当前分层实现，确认页面层职责泄漏点与重复规则源
- [x] 将 Accounts 页面拆分为页面组合壳、账户卡片视觉 primitive、卡片呈现规则
- [x] 将 Proxy 页面拆分为页面组合壳、代理区块 primitive、远程节点卡片 primitive
- [x] 收敛重复规则源，统一远程节点默认值、复制到剪贴板行为和页面布局常量入口
- [x] 为抽出的纯规则补充测试，确保关键展示/默认值契约可验证
- [x] 同步 Xcode 工程并运行测试，确认重构后可编译且行为未回退

## Refactor Targets

- `Sources/CodexSilo/Features/Accounts/AccountsPageView.swift`
- `Sources/CodexSilo/Features/Proxy/ProxyPageView.swift`
- `Sources/CodexSilo/Features/Proxy/ProxyPageModel.swift`
- `Sources/CodexSilo/Behavior/ProxyControlBridge.swift`
- `Sources/CodexSilo/Layout/LayoutRules.swift`
- `Tests/CodexSiloTests`
