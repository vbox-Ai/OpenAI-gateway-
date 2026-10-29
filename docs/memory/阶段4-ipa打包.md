# 阶段 4 记忆点：.ipa 打包流水线（已解决！）

## 最终解法（第 10 次迭代成功）
**根因**：`-dead_strip` 是 **section 级**死代码消除。`-force_load` 只保证整个 .a
进入链接，但 `run_headless`/整个 server 的 section 在链接期无人引用，仍被裁掉。
Swift `@_silgen_name` 引用 `agent2api_server_ping` 只保留了 ping 那一个 section
（ping 是 `return 42`，不引用 server，不会级联）。

**修复**：在 Runner 目标 OTHER_LDFLAGS 里加：
```
-Wl,-force_load,<libagent2api_server.a 绝对路径> \
-Wl,-u,_agent2api_server_start \
-Wl,-u,_agent2api_server_ping
```
`-u` 把符号标记为「未解析引用」，强制链接器保留该符号及其级联依赖
（start → run_headless → server::bootstrap/start → 18 家 provider + axum + tokio）。

## 结果
- Runner.app：18MB（纯 Flutter）→ **36MB**（Flutter 18MB + Rust server ~18MB）✓
- .ipa：6.4MB → **13.18MB** ✓
- 符号检查：`BIN_HAS_SYMBOL` ✓

## 流水线最终形态（ios-build.yml）
1. cargo build --release --target aarch64-apple-ios --lib → 177MB 的 .a
2. flutter create . --platforms ios
3. 写 Podfile（platform :ios 15.0 + flutter_install_all_ios_pods）
4. 写 AppDelegate.swift（@_silgen_name 引用 ping + start）
5. flutter pub get + pod install
6. Ruby 直改 Runner.xcodeproj 的 OTHER_LDFLAGS（force_load + -u）
7. **xcodebuild 直连**（不用 flutter build ios，避免 pod 重装重置 OTHER_LDFLAGS）
8. 打包 Payload → .ipa

## 关键坑记录
1. flutter create 不生成 Podfile → 自己写
2. platform :ios 13.0 太低 → Flutter 3.47 要求 ≥15.0
3. flutter build ios 会重跑 pod install 重置 OTHER_LDFLAGS → 改 xcodebuild 直连
4. force_load 不够（section 级 dead_strip）→ 必须加 -u 强制保留符号

## 下一步
- 真机验证：装 ipa → ldid -S 假签名 → 启动 → webview 加载 127.0.0.1:3065
- 打包网关 Web UI 到 Documents/ui/（run_headless 约定 {data_dir}/ui/）
