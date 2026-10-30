# iOS 插件 spawn EPERM —— 上下文总结

> 总结时间：2026-10-30
> 所属阶段：阶段 5（iOS 真机联调）未完成项
> 关联文档：`项目总览.md`、`iOS插件spawn-根因与方案.md`、`阶段5-iOS真机联调.md`

---

## 一、用户原始问题（时间线）

1. **3 阶段前置**：iOS ipa 已经跑起来，内置 provider 9 家 + 自定义 OK，
   系统事件导出 OK（Documents/Exports + UIFileSharingEnabled），Web UI OK。
2. **第一波报错（build 24）**：插件中心两个插件（提供商增强、网页提供商）
   都报 `Operation not permitted (os error 1)`。设备侧没有「诊断：」后缀，
   说明是老版本（build 24 及以前没诊断）。
3. **build 25 → 26**：加 ad-hoc + entitlements 签名、iOS 设备侧自诊断、
   自建插件索引（让网页提供商 iOS 版可下载）。用户装 build 26 后：
   - 提供商增强：EPERM，错误尾巴带「诊断：入口存在、可执行、带代码签名 —— EPERM 来自系统 AMFI 层，需要安装带最新插件签名修复的 ipa」
   - 网页提供商：先显示「当前平台暂无包」 → 自建索引生效后变成
     「加速下载的插件未通过官方签名校验：自动安装只接受通过官方签名校验的插件包」
4. **build 27 → 30**：把插件 exe **从数据目录下载路线改成随 ipa bundle 分发**
   （塞进 `Runner.app/plugins/`，TrollStore 安装时递归重签）。build 29
   左右发现 CI 里 ldid entitlements 用相对路径 `cd` 进插件仓库后
   `errno=2` abort 134，改成绝对路径；顺带修 plugins.zip 丢
   `provider_category` 导致网页提供商被当成 Agent 类。用户装 build 30 后：
   - 提供商增强：EPERM，错误尾巴跟 build 26 几乎一样
   - 网页提供商：EPERM，同样尾巴，并且已经不是「未通过官方签名校验」
     （因为它随 ipa 预装，不走下载）

**核心矛盾**：build 30 的 exe **确实**带签名 + entitlements + 已经随 bundle
分发（理论上 TrollStore 会重签），但仍然 EPERM。诊断说 AMFI，AMFI 又不杀
这个进程（杀的话是 SIGKILL，不是 EPERM）。

---

## 二、走过的弯路（按版本）

| 版本 | 做了啥 | 验证结论 |
|---|---|---|
| build 24 | ldid -S（纯 ad-hoc，无 entitlements） | EPERM 依旧；解包确认 LC_CODE_SIGNATURE 已有，但裸 ad-hoc 不够 |
| build 25 | ldid -S<ent.plist>（platform-application / no-container / get-task-allow / skip-library-validation 四件套） | EPERM 依旧；诊断信息上线 |
| build 26 | 同 build 25 + INDEX_REPO 改自建索引 | EPERM 依旧；网页提供商开始走自建索引，但自建包没官方签名 = 下载通不过校验 |
| build 27 | entitlements 改用绝对路径 | 修了 CI 崩（cd 后 ldid 找不到相对路径），但未实机验证 |
| build 29 → 30 | **插件 exe 打进 Runner.app/plugins/**，网关 plugin_host iOS 端 spawn 优先选 bundle 内副本 | 两个插件都 EPERM，诊断尾巴没变 |

---

## 三、根因链（当前最可信假说）

### 3.1 签名层面（解包 build 30 ipa 确认）

`Runner.app/Runner`（主二进制）**没有任何代码签名**：
- 工作流里 `xcodebuild` 用了 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
- 之后我们只对插件 exe 跑了 `ldid -S`，没碰主二进制
- 主二进制 Mach-O 里 `LC_CODE_SIGNATURE: None`（一条都没有）

### 3.2 TrollStore 签名逻辑（读源码）

TrollStore 的 `signApp` 里有个兜底分支：如果主二进制
`dumpEntitlementsFromBinaryAtPath` 返回空（也就是主二进制没 entitlements），
它会自己生成一套兜底权限：

```objc
// opa334/TrollStore RootHelper/main.m
if (!entitlementsToUse) {
    entitlementsToUse = @{
        @"application-identifier" : @"TROLLTROLL.*",
        @"com.apple.developer.team-identifier" : @"TROLLTROLL",
        @"get-task-allow" : @YES,
        @"keychain-access-groups" : @[@"TROLLTROLL.*", @"com.apple.token"],
    }.mutableCopy;   // ← 没有 platform-application
}
```

**所以我们的 App 被 TrollStore 签成了「普通沙箱应用」**（能启动、能跑网关、
能写自己的容器目录），但**没有 platform-application 权限**。

### 3.3 普通沙箱 App 不能 spawn 子进程

`sandbox_check(exec)` 这一步内核直接拒绝 `posix_spawn`，返回 `EPERM`。
不是 AMFI（AMFI 拒的话直接 SIGKILL，不会有 EPERM），也不是文件权限
（文件权限问题是 `EACCES`）。这解释了为什么「入口存在、可执行、带签名」
全齐却仍然 EPERM —— **父进程没有 spawn 权限，子进程再像模像样也白搭**。

### 3.4 为什么 bundle 分发也没救回来

`Runner.app/plugins/` 里的 exe 确实被 TrollStore 重签了（递归 `ldid` +
CoreTrust bypass），但**父进程没权限，子进程有签名也没用**。权限不在子进程，
在「父进程能不能 spawn」。

---

## 四、下一步（build 31）

### 4.1 必须做的

在 xcodebuild 之后、打 ipa 之前，**给 Runner 主二进制签名 + entitlements**：

```bash
APP=mobile-app/build/Build/Products/Release-iphoneos/Runner.app
cat > "$RUNNER_TEMP/app.entitlements" <<'PLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
  <key>platform-application</key><true/>
  <key>com.apple.private.security.no-container</key><true/>
  <key>com.apple.private.security.container-required</key><false/>
  <key>com.apple.private.security.no-sandbox</key><true/>
  <key>com.apple.private.skip-library-validation</key><true/>
  <key>get-task-allow</key><true/>
</dict>
</plist>
PLEOF
ldid -S"$RUNNER_TEMP/app.entitlements" "$APP/Runner"
```

要点：
- 只签主二进制，不用递归 bundle —— TrollStore 会读它的 entitlements
  并下发给全 bundle 其余 Mach-O；
- 三件套 `no-container` + `container-required=false` + `no-sandbox` 是
  TrollStore RootHelper 自己就用的配方；
- 插件 exe 自身也保留 entitlements（父有 platform 了，子权限过宽才会
  触发开发者模式检查，反而起不来），但去掉 get-task-allow 以外多余项。

### 4.2 配套

诊断信息里加 `spawn=bundle|data` 标记，下次真机报错直接确认路径。

### 4.3 如果还不行（备选路线，按优先级）

| # | 路线 | 代价 |
|---|---|---|
| 1 | app 级 platform 权限仍然不够？改用 TrollStore spawn-helper 配方（`libtrollstore` / `spawnRoot` / XPC） | 中 |
| 2 | 彻底绕开 spawn：把 provider 增强编成静态库链进 Runner，plugin_host 走「进程内 FFI」分支 | 大，但 Android 端也能复用 |
| 3 | 降级：iOS 版把 provider 直接编进网关，放弃插件架构热插拔 | 最大，但一劳永逸 |

---

## 五、已解决 / 未解决 速查

| 项 | 状态 | 备注 |
|---|---|---|
| iOS ipa 编译稳定 | ✅ | build 号递增，tag 冲突已修 |
| Flutter 壳 + webview | ✅ | http://127.0.0.1:3065 |
| Rust 静态库链接 + dead-strip | ✅ | force_load + -u 三符号 |
| ATS 放行本地回环 | ✅ | NSAllowsArbitraryLoads |
| 内置 provider 9 家 + 自定义 | ✅ | 直接编译进网关 |
| 系统事件导出 | ✅ | Documents/Exports + UIFileSharingEnabled |
| 数据目录防御解析 | ✅ | Application Support → Documents → Library → systemTemp 依次试 |
| 插件 INDEX_REPO 改自建 | ✅ | vbox-Ai/Agent2plugin |
| 网页提供商自建 iOS 包 | ✅ | OpenAI-web- ios-release.yml |
| **Provider 增强 30 家 spawn** | ❌ | **EPERM（父进程缺 platform-application）** |
| **网页提供商 2 家 spawn** | ❌ | 同上 |
| Android 端 | — | 未开始 |
| 网页端 Docker | — | 未开始 |

---

## 六、工程侧已踩过的坑（别再踩）

1. **`github.com:443` 本机直连 reset**：push 失败，走 contents API；
   本地 `main` 与远端分叉时，`git fetch vbox && git reset --hard vbox/main`。
2. **`ldid` entitlements 必须绝对路径**：`cd` 后进插件仓库，相对路径会
   `errno=2` → abort 134。
3. **`pack.json` 别裁字段**：`provider_category` 丢了，网页提供商会被
   网关当成 Agent 类，`ownership::category` 判错。
4. **插件仓库要显式 checkout tag**：`--branch v3.3.0-beta.5.1` 失败时退回
   `main`，版本号对不上。
5. **TrollStore 只重签 bundle 内 Mach-O**：解压到 Documents 的裸二进制
   永远只是 ad-hoc，spawn 必 EPERM。插件 exe 必须随 bundle 分发。
6. **裸 `ldid -S`（无 entitlements）不够**：AMFI / TrollStore 的组合不接受。
7. **xcodebuild `CODE_SIGNING_ALLOWED=NO` 后主二进制无任何签名**：
   这是 build 24→30 所有版本的共同问题，必须在打 ipa 前单独给主二进制签。
8. **PowerShell commit message 含 `$` / 反引号会炸**：用 `-F` 文件方式。

---

## 七、关键文件索引

| 文件 | 改动 |
|---|---|
| `.github/workflows/ios-build.yml` | 单工作流出 ipa；编译插件；ldid 签名；force_load + -u；build 号递增 |
| `mobile-app/lib/main.dart` | Flutter 壳，启动时序 + 解压 ui/plugins + FFI + 导出 |
| `mobile-app/lib/ffi.dart` | dart:ffi 绑定 start/stop/ping |
| `server/Cargo.toml` | `crate-type = ["staticlib", "rlib"]` |
| `server/src/lib.rs` | FFI 入口 run_headless + SHUTDOWN 句柄 + agent2api_server_start/stop/ping |
| `plugin_host/lifecycle.rs` | spawn + iOS 自诊断（`ios_spawn_diagnostics`） |
| `plugin_host/update.rs` | `INDEX_REPO = "vbox-Ai/Agent2plugin"` |
| `desktop-tauri/ui/` | 复用网关 Web UI，打进 ipa 的 ui.zip |

---

## 八、验证路径（build 31 装机后）

1. 插件中心 → 两个插件都应显示 `已运行 / 已加载 N 家`；
2. 若仍 EPERM，错误尾巴 `诊断：` 里现在会带 `spawn=bundle|data`，
   直接看 spawn 的是哪一份。
