# 阶段 4 记忆点：.ipa 打包流水线（当前状态 + 未解决项）

## 已跑通
- `.github/workflows/ios-build.yml`：完整 .ipa 流水线已建立并可运行
  - cargo build .a → flutter create 平台壳 → 写 Podfile → pub get + pod install
    → Ruby 改 Runner.xcodeproj OTHER_LDFLAGS → flutter build ios --no-codesign
    → 打包 Payload → .ipa
- 产出：`agent2api-mobile-ios`（.ipa，可下载）
- 两次关键坑已修：
  - flutter create 不生成 Podfile → 改直接写完整 Podfile
  - platform :ios, '13.0' 太低 → Flutter 3.47 的 pod 要求更高 → 提到 '15.0'

## 未解决：Rust 静态库没被链接（dead-strip）
- 现象：Runner.app 一直 16.8MB（纯 Flutter，无 Rust 50MB），.ipa 6.4MB
- 根因：dart:ffi 在**运行时**才 `DynamicLibrary.process().lookup('agent2api_server_start')`，
  链接期没有任何代码引用 Rust 符号 → 链接器把整个 .a dead-strip 掉
- 尝试过但未生效：
  1. podspec `pod_target_xcconfig` 的 `-Wl,-force_load,$(PODS_TARGET_SRCROOT)/...` ✗
  2. Podfile post_install 改 aggregate_targets xcconfig ✗
  3. Ruby 直改 Runner.xcodeproj OTHER_LDFLAGS `-force_load <abs path>` ✗（脚本确实跑了）
- 附带警告：`CocoaPods did not set the base configuration ... custom config set`
  —— 这可能导致 Pods-Runner xcconfig 未被正确 include，CocoaPods 集成可能不完整

## 两个待验证的修复方向
1. **Swift @_silgen_name 引用**（最可靠，不依赖链接器 flag）：
   在 AppDelegate.swift 里声明 `@_silgen_name("agent2api_server_ping")` 并在启动时引用一次，
   强制链接器解析该符号 → 连带把 lib.rs 对象文件 + 其引用的整个 server 模块级联拉进来。
   前提：.a 必须在链接搜索路径里（vendored_libraries pod 或 -l 提供）。
2. **排查 CocoaPods 集成**：解决 "custom config set" 警告，确认 Pods-Runner xcconfig 被 include，
   再重新验证 force_load。

## 下一步建议
- 优先试方向 1（Swift 引用），它在 flutter_rust_bridge 生态里是成熟做法
- 验证方法：打包后 `nm Runner.app/Runner | grep agent2api_server_start` 应能命中；
  Runner.app 应从 16.8MB 涨到 ~60MB+
