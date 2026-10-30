# iOS 插件 spawn 失败 —— 根因、证据与修复方案

> 归档时间：2026-10-30
> 涉及仓库：`vbox-Ai/OpenAI-gateway-`（网关 + iOS 壳）、`vbox-Ai/OpenAI-`（提供商增强）、
> `vbox-Ai/OpenAI-web-`（网页提供商）、`vbox-Ai/Agent2plugin`（自建插件索引）

---

## 一、当前状态（一句话）

iOS 端网关、Web UI、导出、账号全部正常；**只剩插件进程拉不起来**：
两个插件都报 `Operation not permitted (os error 1)`，且设备侧自诊断显示
「入口存在、可执行、带代码签名」。**根因已定位：不是签名缺失，是 App 自身没有
`platform-application` 权限 —— 沙箱禁止 exec 任意二进制。**

---

## 二、走过的弯路（别再重复）

| 轮次 | 假说 | 结论 |
|---|---|---|
| build 24 | 插件 exe 没签名 | 错。解包验尸：`LC_CODE_SIGNATURE` 已存在（裸 `ldid -S` 生效了） |
| build 25 | 缺 entitlements，补 platform-application 等 4 项 | 不够。签名带 entitlements 了，仍然 EPERM |
| build 26 | entitlements 写入时有 bug？ | 错。解包确认 slot 5 (`0xfade7171`) 里 4 个 key 齐全 |
| build 27–30 | exe 没随 App bundle 分发，缺 TrollStore 证书链 | 方向对了一半：bundle 分发生效了，但仍然 EPERM |

---

## 三、真正的根因链

### 3.1 事实一：build 30 的 `Runner` 主二进制**完全没有代码签名**

解包 build 30 的 ipa，解析 `Payload/Runner.app/Runner`：

```
magic = 0xfeedfacf（arm64 Mach-O）
LC_CODE_SIGNATURE: None        ← 一条都没有
```

原因：workflow 里 xcodebuild 用了
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`。
ipa 里只有两个插件 exe 被 `ldid -S` 过（我们手动签的），**App 本体是裸的**。

### 3.2 事实二：TrollStore 给无 entitlements 的 App 发「兜底权限」，里面没有 platform-application

读 `opa334/TrollStore` 源码 `RootHelper/main.m` 的 `signApp`：

```objc
NSMutableDictionary *entitlementsToUse =
    dumpEntitlementsFromBinaryAtPath(bundleMainExecutablePath).mutableCopy;
if (isSameFile(bundleMainExecutablePath, mainExecutablePath)) {
    if (!entitlementsToUse) {            // ← 主二进制没有任何 entitlements 时
        entitlementsToUse = @{
            @"application-identifier" : @"TROLLTROLL.*",
            @"com.apple.developer.team-identifier" : @"TROLLTROLL",
            @"get-task-allow" : @YES,
            @"keychain-access-groups" : @[@"TROLLTROLL.*", @"com.apple.token"],
        }.mutableCopy;                   // ← 兜底里没有 platform-application
    }
}
```

我们的 Runner 恰好命中 `!entitlementsToUse` 分支。于是 TrollStore 把 App
签成**普通沙箱应用**（能启动、能跑网关、能写自己的容器目录 —— 与用户看到的现象完全一致），
**但没有 platform 权限**。

### 3.3 事实三：沙箱禁止 exec 任意二进制 → `EPERM`

普通沙箱 App 执行 `posix_spawn` 去跑自己容器里的文件时，内核在
`sandbox_check(exec)` 这一步就拒绝，返回的正是 **`EPERM` (Operation not permitted)**。
不是 AMFI 拒绝（AMFI 拒的话是 `Killed: 9` / `EBADARCH` / 直接 SIGKILL），
也不是文件权限问题（错误码会变 `EACCES`）。

这解释了为什么「入口存在、可执行、带代码签名」全齐却仍然 EPERM。

### 3.4 为什么 bundle 分发也没救回来

`Runner.app/plugins/` 里的 exe 确实被 TrollStore 重签了（递归 `ldid` + CoreTrust
bypass 两步都跑），但**父进程没有 platform 权限**，子进程签名再合法也过不了沙箱。
权限是「父进程能不能 spawn」，不是「子进程像不像样」。

---

## 四、修复方案（build 31）

### 4.1 核心改动：打包前给 `Runner` 主二进制补 platform entitlements

TrollStore 的签名逻辑是「**读主二进制现有 entitlements → 保留并下发给全 bundle**」。
只要主二进制自带 `platform-application`，兜底分支就不会命中，整套权限都会跟过去。

workflow 在 xcodebuild 之后、打 ipa 之前加一步：

```bash
APP=mobile-app/build/Build/Products/Release-iphoneos/Runner.app
cat > "$RUNNER_TEMP/app.entitlements" <<'PLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
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
- **只签主二进制**，不需要递归签整个 bundle —— TrollStore 会补全其余。
- `no-container` + `container-required=false` + `no-sandbox` 三件套是 TrollStore
  `RootHelper` 的标准配方（`RootHelper/entitlements.plist` 原文），保证 sandbox 放行。
- **不要**在插件 exe 上保留 `get-task-allow` 之外的多余权限（子进程权限过宽会触发
  iOS 16+ 的开发者模式检查，反而不让起）。

### 4.2 配套：诊断信息带上「spawn 的是哪一份」

之前诊断只报「入口存在、可执行、带代码签名」，无法区分实际 spawn 的是
`Runner.app/plugins/` 的 bundle 副本还是数据目录副本。build 31 起诊断会带
`spawn=bundle` / `spawn=data` 标记，下一轮真机报错即可直接确认路径是否正确。

### 4.3 如果还不行 —— 备选路线（按优先级）

1. **app 级 platform 权限仍然不够**：改用 `Runner.app` 内嵌 XPC / 直接
   `posix_spawn` 走 `posix_spawnattr_setflags(POSIX_SPAWN_START_SUSPENDED)` 等标准
   TrollStore spawn-helper 配方（需引入 `libtrollstore` 或 `spawnRoot` 通道）。
2. **彻底绕开 spawn**：把 `agent2api-providers` 编成**静态库**链进 Runner，插件宿主
   走「进程内 FFI」分支（网关 plugin_host 已有 `--in-process` 语义的雏形）。
   代价最大但一劳永逸，且 Android 端也能复用（`DynamicLibrary.open` 同样受限）。
3. **降级为内置 provider**：iOS 版把 21 家 provider 直接编进网关（放弃插件架构的
   热插拔），桌面端继续走插件。

---

## 五、验证清单（build 31 装机后）

1. 插件中心 → 「提供商增强」状态应为 `已运行 / 已加载 30 家`。
2. 「网页提供商」状态应为 `已运行 / 已加载 2 家`，且不再出现
   「未通过官方签名校验」（因为它随 ipa 预装，不走下载）。
3. 若仍失败，错误尾部的「诊断：」会给出 `spawn=bundle|data` +
   机器可判的成因分类，直接据此定位，不用再猜。

---

## 六、工程侧注意事项（重要）

- **本机 `github.com:443` 被重置**（`git push` 全失败），`api.github.com` 正常。
  提交改动走 contents API（`PUT /repos/{owner}/{repo}/contents/{path}`，先 `GET` 拿 `sha`）。
  因此**本地 `main` 与远端会有分叉**，网络恢复后执行：
  `git fetch vbox && git reset --hard vbox/main`。
- **`ldid` 的 entitlements 必须用绝对路径**：`cd` 进插件仓库后再用相对路径，
  ldid 找不到文件会 `_assert(): errno=2` → `Abort trap: 6`（exit 134）。
- **`pack.json` 不要裁字段**：`provider_category` 丢了，网页提供商会被网关当成
  Agent 类，`ownership::category` 判断错误。
- **CI 里插件仓库要显式 checkout tag**：`--branch v3.3.0-beta.5.1` 失败时退回
  `main`，版本号可能和 pack.json 对不上。

---

## 七、后续排期

| 项 | 状态 |
|---|---|
| iOS 插件 spawn（provider 增强 + 网页提供商） | 修复中，build 31 |
| iOS 系统事件导出 | 已完成 |
| Android 端（cargo-ndk + `DynamicLibrary.open`） | 待开始 |
| 网页端 Docker 部署 | 待开始（仓库现成 Dockerfile / compose） |
