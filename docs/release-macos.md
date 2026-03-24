# macOS 发布流程

这套流程默认面向站外分发，也就是：

- 使用 `Developer ID Application` 签名
- 使用 Apple notarization 公证
- 产出可直接分发的 `.zip`

整个仓库不会保存你的 Apple ID、Team ID、证书名或密码。发布用的本地配置放在 `.release.env`，这个文件已经被 Git 忽略。

## 前提

- 已加入 Apple Developer Program
- 本机 Xcode 已登录你的开发者账号
- 钥匙串里已有可用的 `Developer ID Application` 证书
- 当前工程可以在 Xcode 中正常 Archive

## 1. 创建本地发布配置

复制模板：

```bash
cp .release.env.example .release.env
```

然后填入你自己的值：

- `DEVELOPMENT_TEAM`
- `PRODUCT_BUNDLE_IDENTIFIER`
- `NOTARY_PROFILE`

建议不要把 Apple ID、app-specific password 或 API key 直接写进 `.release.env`。

## 2. 把 notarization 凭据存到钥匙串

推荐先把凭据保存成一个 Keychain profile，脚本只引用 profile 名，不直接接触密码。

示例：

```bash
xcrun notarytool store-credentials "codexsilo-notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOUR_TEAM_ID"
```

如果没有显式传 `--password`，命令会在终端里安全提示你输入 app-specific password。

你也可以改用 App Store Connect API key 方式保存 profile，`notarytool store-credentials` 同样支持。

## 3. 更新版本号

发布前先在 Xcode 里更新：

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`

当前工程的版本信息会进入 App bundle，并被应用内版本展示读取。

## 4. 执行打包

```bash
./scripts/release_macos.sh
```

脚本会完成这些事情：

- `xcodebuild archive`
- `xcodebuild -exportArchive` 导出 `Developer ID` 版本
- 验证签名结果
- 生成提交公证用的 zip
- 用 `notarytool` 等待公证完成
- `stapler staple` 回写公证票据
- 生成最终可分发 zip 和 `sha256`

默认输出目录是：

```text
build/release/
```

常见产物：

- `CodexSilo-1.0.0-macOS-notarized.zip`
- `CodexSilo-1.0.0-macOS-notarized.zip.sha256`

## 5. 只做本地签名验证

如果你只是想先验证 Archive 和导出流程，可以跳过公证：

```bash
NOTARIZE=0 ./scripts/release_macos.sh
```

这时输出会是已签名但未公证的 zip。

## 6. 发布到 GitHub Release

推荐使用 GitHub CLI 本地完成发布，这样 token 也不需要写进仓库。

首次使用前：

```bash
brew install gh
gh auth login
```

完成登录后可以直接执行：

```bash
./scripts/publish_release.sh
```

这个脚本会：

- 调用 `./scripts/release_macos.sh`
- 读取当前版本号
- 创建并推送对应 tag
- 创建 GitHub Release
- 上传 zip 和 `.sha256`

如果对应 release 已存在，脚本会改成覆盖上传附件。

建议上传：

- notarized zip
- `.sha256` 校验文件
- 对应版本说明

## 故障排查

- 如果 Archive 阶段签名失败，先在 Xcode 里手动跑一次 `Product > Archive`，确认当前账号、证书和 Bundle ID 已匹配。
- 如果导出阶段提示找不到 Team 或证书，检查 `.release.env` 里的 `DEVELOPMENT_TEAM` 是否正确。
- 如果 notarization 失败，先确认 `NOTARY_PROFILE` 可用：

```bash
xcrun notarytool history --keychain-profile "codexsilo-notary"
```

- 如果你需要保留中间产物排查问题，可以临时设置：

```bash
KEEP_WORK_ROOT=1 ./scripts/release_macos.sh
```

## 官方参考

- [Apple Developer: Developer ID](https://developer.apple.com/support/developer-id/)
- [Apple Developer: Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Apple Developer: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
