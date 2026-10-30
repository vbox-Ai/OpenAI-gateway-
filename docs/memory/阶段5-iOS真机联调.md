# 阶段 5 — iOS 真机联调（插件 spawn + 导出 + 基线重建）

> 本记忆点覆盖「重新基线到 beta.5.1 之后」到「iOS ipa 稳定出包」的全部工作。
> 清空上下文后据此恢复。

## 当前状态（结论）

- **三仓库全部对齐 v3.3.0-beta.5.1**：
  - 网关 `vbox-Ai/OpenAI-gateway-` main = beta.5.1 + iOS 补丁（ipa 从这个仓库出）
  - 原生插件 `vbox-Ai/OpenAI-` main = beta.5.1 + docs（旧 iOS FFI 线在 `legacy-ios-ffi`）
  - 网页插件 `vbox-Ai/OpenAI-web-` main = beta.5.1
- **iOS ipa 能稳定编译**：单一 workflow `iOS 构建与发布`（`workflow_dispatch`），
  产出裸 ipa + 自动发布 Releases，**每次 build 号递增**（GITHUB_RUN_NUMBER）。
- 最新构建 build 24 成功。

## 架构（核心理解，别忘）

手机 ipa = **Flutter 壳（webview）+ 进程内 headless 网关**，不是重写 UI：

```
Flutter App（mobile-app/）
  └─ webview 加载 http://127.0.0.1:3065（复用网关 Web UI，零改）
  └─ dart:ffi 调 libagent2api_server.a（静态库链进主二进制）
        └─ agent2api_server_start(Documents, 3065) → 进程内跑 headless 网关
```

- 核心 crate `desktop-tauri/src-tauri/server/`（`agent2api-server`）是**纯 Rust
  跨平台 headless**（axum+tokio+rustls+SQLite），一次写成三端复用（iOS 静态库 /
  Android so / 网页 Docker）。
- 网页端**现成**：仓库有 Dockerfile + docker-compose.yml，`docker compose up` 即用。
- Android 端 = iOS 翻版，但 FFI 用 `DynamicLibrary.open('libxxx.so')`，插件 spawn
  天生支持（无 iOS 沙盒限制）。

## 关键文件（改动点）

- `mobile-app/lib/main.dart` — Flutter 入口，启动时序 + 解压 ui/插件 + FFI + 导出
- `mobile-app/lib/ffi.dart` — dart:ffi 绑定（start/stop/ping）
- `desktop-tauri/src-tauri/server/src/lib.rs` — FFI 入口（run_headless + SHUTDOWN 句柄）
- `desktop-tauri/src-tauri/server/Cargo.toml` — `crate-type = ["staticlib", "rlib"]`
- `.github/workflows/ios-build.yml` — 单工作流出 ipa + Releases（build 号递增）
- `desktop-tauri/src-tauri/server/src/server/core/plugin_host/rpc.rs` — target_triple

## 踩过的坑（按重要性）

1. **插件 spawn EPERM（Operation not permitted）** —— 两个根因叠加：
   - 插件 exe **无代码签名**：iOS AMFI 要求被 posix_spawn 的二进制带有效签名，
     TrollStore 只重签 bundle 内 Mach-O，运行时解压到 Documents 的裸二进制不管。
     修：CI 打包前 `brew install ldid && ldid -S` 给 agent2api-providers 打 ad-hoc 签名。
   - `target_triple()` 只有 windows/macos 分支，iOS 落到 `_ =>` 变
     `aarch64-unknown-linux-gnu`，插件中心按 linux-gnu 下载 ELF 包。修：补 `"ios"` 分支。
2. **Directory 对象字符串插值 bug**：`'$pluginsDir/...'` 会把 Directory 对象
   插值成 `Directory: '/path'`（toString 格式），拼出 `/Directory: ...` 非法路径。
   必须显式 `'${pluginsDir.path}/...'`。
3. **TrollStore no-container 下 getApplicationDocumentsDirectory 可能异常**：
   加 `_resolveDataDir()` 防御（Application Support → Documents → Library 依次试，
   验证非空非根能 mkdir，最后兜底 systemTemp）。
4. **导出文件在「文件」App 看不到**：`UIFileSharingEnabled` 只对 Documents 生效。
   数据目录用 Application Support，但**导出目录必须单独用 Documents/Exports**
   （`_resolveExportDir()`，带 no-container 兜底）。
5. **白屏（服务起来就停）**：`server::start` 返回的 oneshot Sender **drop 即停机**，
   必须存 `static SHUTDOWN`；且 start 返回 0 只代表 bind 成功，要轮询 /health 再放 webview。
6. **iOS dead-strip**：静态库链接必须 `-Wl,-force_load,<.a> -Wl,-u,_agent2api_server_start
   -u,_agent2api_server_stop -u,_agent2api_server_ping`。
7. **Release 同名 tag 冲突**：同版本重复构建会撞 tag。改用 build 号
   （GITHUB_RUN_NUMBER）做 tag 后缀，每次唯一、历史全保留。
8. **PowerShell commit -m 含 `$`/反引号会炸**：commit message 用 `-F` 文件方式。

## 插件目录布局（越狱 spawn 路线）

```
{Documents 或 Application Support}/plugins/
  plugins.json                                 注册表
  agent2api-providers/{version}/
    pack.json                                  manifest（entry 含 aarch64-apple-ios）
    bin/agent2api-providers                    iOS 可执行文件（ldid 签名过）
```

- 网关 bootstrap 直接 `plugins/{id}/{version}` 拼路径（**不读 current 指针**）。
- `ensure_entry_executable` 会自动 chmod +x（Flutter 侧不用管权限）。
- plugins.json 的 `manifest_providers` 必填（否则 provider_enabled 全判未启用）。
- 插件是**单个 exe 承载 21+ 家 provider**（`agent2api-providers`），不是每家长一个。

## 下一步

1. iOS 真机验证：装 build 24+，看「提供商增强」30 家 provider 是否 spawn 成功；
   「网页提供商」是之前装坏的 Linux 包，用户需在插件中心卸载，后续单独出 iOS 版。
2. Android 端：新开流水线（cargo-ndk 交叉编译 + DynamicLibrary.open so + APK）。
3. 网页端：docker 部署（现成，半天事）。
4. 网页插件 iOS 版：`vbox-Ai/OpenAI-web-` 也编 aarch64-apple-ios + ldid 签名。
