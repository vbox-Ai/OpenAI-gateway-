# build31 —— iOS 插件 spawn EPERM 修复落地

> 归档时间：2026-10-31
> 提交：`80a5ea1`（已推 `vbox-Ai/OpenAI-gateway-` 的 `main`）
> 关联：`iOS插件spawn-根因与方案.md`（根因分析）、`iOS插件spawn-上下文总结.md`（时间线）

---

## 一、这次落了什么（三处改动）

根因文档里 build31 方案（给 Runner 主二进制补 platform entitlements）**已落到代码并提交**：

| # | 文件 | 改动 |
|---|---|---|
| 1 | `.github/workflows/ios-build.yml` | 新增「给 Runner 主二进制补 platform entitlements」步骤：xcodebuild 后、打 ipa 前，`ldid -S` 给 `Runner.app/Runner` 补 `platform-application` / `no-container` / `container-required=false` / `no-sandbox` / `skip-library-validation` / `get-task-allow` 六项。让 TrollStore 读主二进制 entitlements 并下发全 bundle，不再命中「兜底签名」分支。 |
| 2 | `.github/workflows/ios-build.yml` | 收敛插件 exe（子进程）的 entitlements：去掉 platform-application 等宽权限，只留 `get-task-allow`。避免子进程权限过宽触发 iOS 16+ 开发者模式检查。 |
| 3 | `desktop-tauri/src-tauri/server/src/server/core/plugin_host/lifecycle.rs` | `ios_spawn_diagnostics` 加 `spawn=bundle|data` 标记（按 exe 路径是否含 `Runner.app` / `/plugins/` 判定来源）；诊断文案从「缺 TrollStore 证书链」更新为「父进程缺 platform-application 权限（sandbox_check(exec) 拒绝 posix_spawn）」。 |

## 二、行尾规范化（顺带）

`ios-build.yml` 历史上是**混合行尾**（275 CRLF + 70 LF）。本次编辑时统一为**纯 LF**，与 `.gitattributes` 对 `.githooks/**` 的 `eol=lf` 规范意图一致，也符合 git `core.autocrlf=true` 期望 LF 入库的方向。之后不再有此问题。

> 实质改动（`git diff -w`）为 36 增 / 5 删；其余 diff 全是行尾规范化噪声。

## 三、下一步（未做，需人工）

1. **触发 iOS 构建**：GitHub 上手动 `workflow_dispatch` 跑 `iOS 构建与发布`，产出 build N 的 ipa。
2. **真机验证**：装机后看插件中心——
   - 「提供商增强」应显示 `已运行 / 已加载 30 家`；
   - 「网页提供商」应 `已运行 / 已加载 2 家`；
   - 若仍失败，错误尾部「诊断：」带 `spawn=bundle` 标记（= 路径选择正确但 platform 权限仍未生效），据此走备选路线。

## 四、备选路线（若 build31 仍 EPERM，按优先级）

| # | 路线 | 代价 |
|---|---|---|
| 1 | app 级 platform 权限仍不够 → TrollStore spawn-helper 配方（`libtrollstore` / `spawnRoot` / XPC） | 中 |
| 2 | 绕开 spawn：provider 增强编成静态库链进 Runner，plugin_host 走进程内 FFI 分支 | 大，Android 也能复用 |
| 3 | 降级：iOS 版把 provider 直接编进网关，放弃插件热插拔 | 最大，一劳永逸 |

## 五、工程侧提醒（本次踩坑记录）

- **推送凭据**：本机 git 默认凭据（`hf805864818`）无 `vbox-Ai` 写权限，推送被 403。已用 `vbox-Ai` 的 PAT 一次性 URL 推送成功。注意：该 PAT 曾出现在对话里，**需尽快轮换**。
- **`github.com:443` 直连仍 reset**：clone/push 走 `ghfast.top` 镜像前缀；`api.github.com` 正常。
- **本机无 cargo/gh**：无法本地 `cargo check` 或 `gh run list`，编译验证依赖 GitHub Actions。

---

## 六、build30 → 33 实证迭代链（entitlements 组合）

真机验证驱动，每轮一个结论：

| 版本 | 主二进制 entitlements | 结果 |
|---|---|---|
| build30 | 无签名 → TrollStore 兜底（普通沙箱） | App 正常启动，插件 spawn EPERM（缺 platform） |
| build31 | platform + **no-container** + no-sandbox + skip-library-validation + get-task-allow | ❌ Flutter `LaunchEngine.acquireEngine()` abort 闪退（no-container 让 App 失去容器，资源路径解析失败） |
| build32 | 仅 platform-application | App 正常启动，插件 spawn 仍 EPERM（`spawn=bundle` 路径正确，但 sandbox_check(exec) 仍拒 —— platform-application 不解除沙箱） |
| build33 | platform + **no-sandbox** + container-required=false（保留容器） | ✅ 编译通过（run #33，ipa 已出），待真机验证 spawn |

**核心结论**：`no-container` 是闪退凶手（去掉容器 → Flutter 崩），`platform-application` 单独不够（沙箱仍拦 exec）。正确组合是**保留容器 + 去沙箱强制**（no-sandbox + container-required=false），即 TrollStore RootHelper 的实际配方。子进程（插件 exe）同步恢复 platform-application（AMFI 要求 platform 父 spawn 的子进程本身也是 platform 二进制）。

## 七、上游 beta.6 同步（2026-10-31）

- 合并上游 `v3.3.0-beta.6` tag 进 fork main（`b9b8cd6`），**零冲突**。
- 网关版本 → 3.3.0-beta.6，协议 crate tag → v3.3.0-beta.6（上游 Agent2Providers 已有该 tag）。
- 合并后核验：iOS 专属补丁全部保留（`lib.rs` FFI 入口、`bootstrap.rs` bundled_plugin_exe、`lifecycle.rs` spawn=bundle 诊断、`crate-type=["staticlib","rlib"]`、mobile-app、ios-build.yml）。
- 插件克隆 ref 对齐 beta.6：providers 优先 vbox fork beta.6 tag → 回退上游 Agent2Providers v3.3.0-beta.6 → main 兜底。
- 注意：vbox 插件仓库（OpenAI-/OpenAI-web-）**尚未打 beta.6 tag**，CI 靠回退上游 tag 保证协议同版本。

## 八、build33 构建结果（2026-10-31）

- run #33 全绿（22 步 success），ipa `agent2api-mobile-3.3.0-beta.6-build33.ipa`（32,293,789 bytes）已发布，tag `mobile-3.3.0-beta.6-build33`。
- 关键闸门验证通过：beta.6 合并后的 Rust 代码在 iOS arm64 编译通过；协议 crate `v3.3.0-beta.6` 拉取成功且与 beta.5.1 **零接口变更**（上游 plugin_host 目录与 provider-protocol crate 均无改动）；插件 beta.6 克隆回退链（vbox fork → 上游 Agent2Providers）工作正常。
- **待办（硬依赖用户真机）**：装机验证 ① 能否启动 ② 插件 spawn 是否还 EPERM。这是判定「修复成功」的唯一依据，无法由构建结果代替。
