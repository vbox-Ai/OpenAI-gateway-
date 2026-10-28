//! Agent2API 网关本体（独立 crate）。
//!
//! ── 本 crate 服务两种形态 ────────────────────────────────────
//!   · Tauri 桌面端：壳进程把本 crate 当库链接，网关作为进程内 HTTP
//!     服务器跑在 tauri 的 Tokio 运行时上（`server::start`）；
//!   · headless 服务器 / Docker：`agent2api-server` 二进制（`src/bin/`）
//!     自建 Tokio 运行时、自己托管管理界面（`server::static_files`），
//!     不链接任何 GUI 依赖。
//!
//! 模块结构是**刻意保留的一层壳**：`server/`、`port_conflict.rs` 的目录
//! 与文件名与拆分前（桌面 crate 的 `src/server`）完全一致，内部所有
//! `crate::server::…` / `crate::port_conflict::…` 路径零改动 —— 桌面侧
//! 用 `use agent2api_server as server` 重导出后，两边的既有路径都继续成立。
//!
//! ── 为什么 spawn 必须经由 [`spawn_task`] ─────────────────────
//! 拆分前模块里用的是 `tauri::async_runtime::spawn`（壳提供全局运行时，
//! 任意线程可调）；本 crate 不依赖 tauri，headless 又自带 `#[tokio::main]`
//! 运行时。统一入口 [`spawn_task`] 兼容两种宿主：
//!   · 已在 Tokio 运行时上下文里（桌面：任务跑在 tauri 运行时的工作
//!     线程上；headless：`#[tokio::main]`）→ 直接 `Handle::spawn`，
//!     任务落在**宿主**的运行时上，与拆分前行为一致；
//!   · 不在运行时上下文（从任意同步线程起后台任务）→ 落到惰性创建的
//!     全局运行时，**不会 panic** —— release 档是 panic=abort，
//!     一次误用就会带走整个进程，这正是拆分前统一走
//!     `tauri::async_runtime::spawn` 的原因，本入口继承同一保证。

pub mod paths;
pub mod port_conflict;
pub mod server;
pub mod web_shim;

use std::future::Future;
use std::sync::OnceLock;

use tokio::runtime::{Handle, Runtime};

/// 惰性全局运行时：只承接「在非 Tokio 上下文里发起的后台任务」，
/// 正常路径（handler / 既有任务体内）不会碰到它。
static GLOBAL_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 项目统一的 spawn 入口：桌面与 headless 共用（原
/// `tauri::async_runtime::spawn` 的替身，见 crate 文档头）。
pub fn spawn_task<F>(future: F) -> tokio::task::JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    match Handle::try_current() {
        Ok(handle) => handle.spawn(future),
        Err(_) => global_runtime().spawn(future),
    }
}

fn global_runtime() -> &'static Runtime {
    GLOBAL_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("创建后台 Tokio 运行时失败")
    })
}

/// 移动端嵌入入口探活：仅证明静态库可链接、符号可被 FFI 调用。
#[no_mangle]
pub extern "C" fn agent2api_server_ping() -> i32 {
    42
}

/// 移动端嵌入的服务器启动入口：在**本进程内**把网关 headless 服务器跑起来。
///
/// 与 `src/bin/agent2api-server.rs` 的 main() 同一条时序，差别只有两处：
///   · 绑回环（127.0.0.1），语义与桌面壳一致 —— 不做网络部署那套
///     panel_gate / v1_fail_closed 闸门；
///   · 不 block_on 等停机信号 —— 服务器由惰性全局运行时承接，函数返回后
///     继续在后台跑；停机交给 FFI 侧显式 drop（后续步骤补 `stop`）。
///
/// `data_dir` 即配置目录（桌面等价物是 `AGENT2API_PROXY_HOME`，默认
/// `~/.agent2api`）；移动端传 App 的沙盒 Documents 目录。
/// UI 目录约定为 `{data_dir}/ui/`（由 Flutter 侧在启动前把网关 Web UI 拷进去）。
pub fn run_headless(data_dir: &str, port: u16) -> Result<(), String> {
    use std::net::{IpAddr, Ipv4Addr};

    // 让既有 env 读取路径（paths::config_dir 等）统一落到移动端数据目录
    std::env::set_var("AGENT2API_PROXY_HOME", data_dir);

    let host = IpAddr::V4(Ipv4Addr::LOCALHOST);
    let mut state = server::ServerState::bootstrap(port, host)?;
    state.set_ui_dir(std::path::PathBuf::from(data_dir).join("ui"));

    // 面板访问控制：回环形态不设闸门（与桌面一致），但库句柄与令牌载入照常
    server::access::attach_db(state.db().cloned());
    server::access::load_refresh_tokens();
    server::access::load_access_tokens();
    server::access::sync_env_admin_to_store();

    let _shutdown = server::start(&state).map_err(|conflict| conflict.message)?;
    Ok(())
}

/// FFI 包装：从 Flutter 调用，返回 0 表示启动成功，非 0 表示失败。
/// `data_dir` 为 C 字符串（UTF-8），`port` 为监听端口。
#[no_mangle]
pub extern "C" fn agent2api_server_start(
    data_dir: *const std::os::raw::c_char,
    port: u16,
) -> i32 {
    let dir = unsafe {
        if data_dir.is_null() {
            return 1;
        }
        match std::ffi::CStr::from_ptr(data_dir).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return 2,
        }
    };
    match run_headless(&dir, port) {
        Ok(()) => 0,
        Err(_) => 3,
    }
}
