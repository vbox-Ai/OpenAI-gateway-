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

## build 24 真机验尸（2026-10-30，EPERM 未消）

- **现象**：「提供商增强」仍报 `启动插件进程失败（agent2api-providers）：Operation not permitted (os error 1)`。
- **验尸方法（本地可复用）**：下载 release ipa → Python 解 zip → 解析 exe Mach-O
  load commands 找 `LC_CODE_SIGNATURE`（cmd=0x1d）。**结论：exe 有签名**，ldid 生效了。
- **新结论：裸 `ldid -S`（无 entitlements 的纯 ad-hoc）不够**。iOS AMFI 对被
  posix_spawn 的二进制不只查签名，还查 entitlements 与 platformized 父进程的
  匹配 —— 这是 TrollStore 社区 spawn helper 的已知坑，标准配方是
  `ldid -S<ent.plist>`，entitlements 至少含：
  `platform-application`、`com.apple.private.security.no-container`、
  `get-task-allow`、`com.apple.private.skip-library-validation`。
  修复已进 workflow（build 25 起）。
- **「未签名」黄标 ≠ Mach-O 签名**：UI 的已签名/未签名指 **pack.json 的
  ed25519 包签名**（`official-2026` 公钥，验签在 install.rs）。自打包
  plugins.zip 没有私钥，永远显示未签名 —— 无害，别再往 Mach-O 上猜。
- **spawn 失败现在带设备侧自诊断**（`lifecycle.rs::ios_spawn_diagnostics`，
  iOS-only）：错误信息会附加「缺执行位 / 不是 Mach-O / 无代码签名 / AMFI 层」
  四选一结论，下次用户贴截图即得答案。
- **插件目录来源确认**：插件中心卡片数据来自**上游硬编码索引**
  `Agent2plugin/Agent2plugin`（`update.rs::INDEX_REPO`，raw.githubusercontent
  的 index.json + detail 文件）。`vbox-Ai/OpenAI-` releases 为空，用户设备上
  的 提供商增强 只能来自 ipa 自带解包 —— 不存在「channel 覆盖坏包」的可能。
- **网页提供商**：界面已正确显示「aarch64-apple-ios 当前平台暂无包」（平台
  识别修复生效）。要让它可装，需把 INDEX_REPO 指到自己的索引仓库（fork
  Agent2plugin + 改常量），并给 `OpenAI-web-` 出 aarch64-apple-ios 包。
- **下载墙坑**：release 资产（objects.githubusercontent.com）直连被 reset，
  `mirror.ghproxy.com` DNS 不通，**`https://ghfast.top/` 前缀可用**；gh CLI
  本机不存在，用 `curl.exe + PAT` 走 api.github.com（API 域没被墙）。

## 下一步

1. iOS 真机验证：装 build 25+（entitlements 签名版），看「提供商增强」是否
   spawn 成功；若仍 EPERM，错误信息里的「诊断：」后缀会直接指明成因。
2. 网页插件 iOS 版：fork `Agent2plugin/Agent2plugin` 到 vbox-Ai → `update.rs`
   的 `INDEX_REPO` 改指向（建议做成配置可覆盖）→ 给 `OpenAI-web-` 出
   aarch64-apple-ios 包 + ldid entitlements 签名 → 发布进自建索引。
3. Android 端：新开流水线（cargo-ndk 交叉编译 + DynamicLibrary.open so + APK）。
4. 网页端：docker 部署（现成，半天事）。


## build 25/26 + 自建插件索引（2026-10-30）

- **build 25 成功**（entitlements 签名版 ipa 已出包）：tag mobile-3.3.0-beta.5.1-build25，
  资产 agent2api-mobile-3.3.0-beta.5.1-build25.ipa。等真机验证「提供商增强」spawn；
  若再失败，错误信息末尾「诊断：」后缀直接给结论（缺执行位 / 非 Mach-O / 无签名 / AMFI 层）。
  用户截图的报错没有「诊断：」后缀 = 设备还在 build 24。
- **自建插件索引路线（网页提供商 iOS 化）已落地**：
  1. fork 上游索引 Agent2plugin/Agent2plugin 到 **vbox-Ai/Agent2plugin**（PAT 是 vbox-Ai 账号，
     fork 直接落在 vbox-Ai 名下）。
  2. fork 里 plugins/agent2api-web-providers.json：release.repo 改为 vbox-Ai/OpenAI-web-、
     platforms 加 aarch64-apple-ios、version 对齐 3.3.0-beta.5.1；index.json 的 source.repo 同步改。
     网关取 detail 的 release.repo 查 releases（走 api.github.com，不被墙），
     tag 模板 web-v{version}、资产模板 {id}-{version}-{target}.zip。
  3. vbox-Ai/OpenAI-web- 新增 .github/workflows/ios-release.yml（workflow_dispatch）：
     cargo build aarch64-apple-ios --bin agent2api-web-providers → ldid -S<ent> 签名 →
     zip（pack.json 动态补 aarch64-apple-ios entry + bin/ + assets 图标）→
     Release tag web-v3.3.0-beta.5.1。已 dispatch。
  4. 网关 update.rs 的 **INDEX_REPO 常量改为 vbox-Ai/Agent2plugin**（提交 43868e7，已 push vbox），
     触发 **build 26**（含 build 25 全部修复 + 自建索引）。
- **验证路径**：装 build 26 → 插件中心「网页提供商」应显示可下载（不再「当前平台暂无包」）→
  下载安装 → 启用 → 看 spawn 是否成功（网页提供商与提供商增强同受 AMFI 签名约束，
  插件包里的 exe 都必须 ldid entitlements 签名）。
- **API 写文件套路**：无 gh CLI 时用 curl/python + PAT 走 contents API（GET 拿 sha → PUT 改文件），
  fork 用 POST /repos/{owner}/{repo}/forks；workflow dispatch 用 POST .../dispatches。
  PowerShell 的 curl -d 单引号 JSON 会炸（Problems parsing JSON），用 python urllib。
- **Read 工具读中文文件名会挂死**（阶段5-iOS真机联调.md 两次 630s 超时），
  读/改记忆点用 Shell Get-Content / python 代替。

## build 26 出包确认（2026-10-30 12:45）

- 网关 build 26 成功：tag mobile-3.3.0-beta.5.1-build26，资产 agent2api-mobile-3.3.0-beta.5.1-build26.ipa。
- OpenAI-web- ios-release 成功：Release web-v3.3.0-beta.5.1 带
  agent2api-web-providers-3.3.0-beta.5.1-aarch64-apple-ios.zip。
- 用户 10:39（=02:39 UTC）装的是旧包（build 26 完成于 04:45 UTC），
  所以截图上「提供商增强」EPERM 无诊断后缀 + 「网页提供商暂无包」都是旧包表现。
- 判定真机版本的锚点：装了 build 26 后，网页提供商卡片应能下载安装；
  提供商增强若再 EPERM，错误尾部必有「诊断：」结论。

## build 27：插件 exe 随 bundle 分发（真根因 + 修法，2026-10-30）

- **真根因（推翻 build 24-26 的 entitlements 判断）**：下载 build 26 ipa 解包，
  解析 exe 的 Mach-O 签名 —— LC_CODE_SIGNATURE 在、entitlements 在
  （slot 5 = fade7171，platform-application/no-container/get-task-allow/
  skip-library-validation 全齐），但 **CodeDirectory flags = 0x0**，且 ldid
  2.1.5 的 -C 选项根本没有 platform/adhoc 组合（读源码确认）。但 flags=0
  不是致命点 —— **致命点是 ad-hoc（NoSigner）签名没有证书**。
- **TrollStore 签名机制（读 opa334/TrollStore 源码确认）**：TrollStore 安装时
  signApp 用 NSDirectoryEnumerator 递归扫 bundle、ldid -s 递归重签所有
  Mach-O，再对**每个**二进制 pply_coretrust_bypass（用内置 CA 证书重签 CMS
  签名 blob）。所以带 TrollStore 证书链的二进制 AMFI 才放行；数据目录里的
  ldid ad-hoc 副本无证书，spawn 必 EPERM。
- **修法**：两个插件 exe（agent2api-providers + agent2api-web-providers）打进
  Runner.app/plugins/（workflow 在 xcodebuild 后注入），TrollStore 安装时
  递归重签它们。网关 plugin_host 在 iOS 上 undled_plugin_exe()（用
  current_exe 反推 bundle 路径）优先 spawn bundle 内副本，数据目录副本只做
  清单/注册表落盘。网页提供商改为随 plugins.zip 预装（与提供商增强同路），
  不再走插件中心下载。
- 提交 986c702 已 push，**build 27 已 dispatch**（含双插件 bundle + 双包
  plugins.zip + iOS spawn 走 bundle + 诊断文案修正）。
- 网页提供商「未通过官方签名校验」是**加速下载（Mirror 源）强制验签**的
  网关安全特性（update.rs L516：candidate.source == Mirror 时 require_signed），
  自建包无官方 ed25519 私钥签不了。bundle 预装后不再走下载，自然绕开。

## build 30 出包：插件 exe 随 bundle 分发（2026-10-30）

- **build 30 成功**：tag mobile-3.3.0-beta.5.1-build30，ipa 31.9MB。
  解包验证：`Payload/Runner.app/plugins/agent2api-providers` +
  `agent2api-web-providers` 都在；entitlements = platform-application /
  no-container / container-required=false / skip-library-validation（已去掉
  get-task-allow —— iOS 16+ 无开发者模式时它会让二进制起不来，
  TrollStore RootHelper 就是不带它）；plugins.zip 含两个包、完整 pack.json、
  provider_category=web、各 30 / 2 家 provider。
- **build 27/28 失败教训**：
  1. build 27 exit 134 —— `ldid -Shelper.entitlements` 在 `cd` 进插件仓库后
     是相对路径 → 找不到文件 → ldid `_assert(): errno=2` abort。改成
     `ENT="$RUNNER_TEMP/helper.entitlements"` 绝对路径。
  2. build 28/29 是主动 cancel 的（补 pack.json 全字段 + 去 get-task-allow）。
- **本机 github.com:443 被墙（push/pull 全 reset）**，api.github.com 正常 →
  用 contents API PUT 单文件提交推送 workflow 改动。
  因此**本地 main 与远端可能分叉**，网络恢复后先
  `git fetch vbox && git reset --hard vbox/main`。
- **验证路径**：装 build 30 → 插件中心「提供商增强」「网页提供商」都显示已启用；
  提供商增强不再 EPERM（spawn 的是 bundle 内被 TrollStore 重签的副本）。
