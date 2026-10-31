//! Agent2API 移动端入口。
//!
//! 架构：Flutter 壳（webview）→ 本地 headless 服务器（进程内 Rust 静态库）
//!       → 网关 Web UI（web_shim 形态，UI 零改）。
//!
//! 启动时序：
//!   1. 取沙盒 Documents 目录作为 data_dir
//!   2. 把打包好的 assets/ui.zip 解压到 {Documents}/ui/（缺 index.html 才解压）
//!   3. agent2api_server_start(Documents, 3065) 在进程内跑起网关服务器
//!   4. 轮询 /health 直到服务真正应答（start 返回 0 只代表 bind 成功）
//!   5. webview 加载 http://127.0.0.1:3065
//!
//! ── 为什么必须等 /health ──────────────────────────────────────
//! `server::start` 只同步 bind，监听任务是在后台运行时里起的；立刻让 webview
//! 去请求会拿到 connection refused，WKWebView 就停在白屏且不再重试。

import 'dart:convert' show base64Decode, jsonDecode, jsonEncode;
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'ffi.dart';

/// 网关监听端口（回环，仅本机可达）
const int kPort = 3065;

/// 面板地址
const String kUiUrl = 'http://127.0.0.1:$kPort/';

/// 探活地址（/health 返回裸 JSON，200 即服务已就绪）
const String kHealthUrl = 'http://127.0.0.1:$kPort/health';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Agent2App());
}

class Agent2App extends StatelessWidget {
  const Agent2App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent2API',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const WebUiPage(),
    );
  }
}

class WebUiPage extends StatefulWidget {
  const WebUiPage({super.key});

  @override
  State<WebUiPage> createState() => _WebUiPageState();
}

class _WebUiPageState extends State<WebUiPage> {
  /// 当前阶段文案（显示在状态条 / 加载页）
  String _stage = '启动中…';

  /// 附加细节（错误码、路径、异常信息）
  String _detail = '';

  /// 服务已就绪，可以放 webview
  bool _ready = false;

  /// 启动失败，展示重试入口
  bool _failed = false;

  /// 页面加载成功后可收起状态条（失败时保持可见）
  bool _barVisible = true;

  bool _busy = false;

  /// 实际数据目录（解析结果，启动失败时打进报错便于定位）
  String _dataPath = '';

  /// 最近一条 JS 错误（页面脚本抛错时贴在底部，点一下消失）
  String _jsError = '';

  /// 导出完成提示（文件已写进 App 文档目录，文件 App 可见）
  String _exportNote = '';

  /// webview 句柄（弹窗兜底导航用）
  InAppWebViewController? _web;

  /// 注入到页面之前的弹窗桥：把 window.open / target=_blank 交给原生打开。
  ///
  /// WKWebView 只有在实现 `WKUIDelegate createWebViewWith` 时才支持新窗口，
  /// 没实现时 `window.open()` 直接返回 null —— web_shim 的登录流程拿不到
  /// 窗口句柄，授权页永远打不开（点「添加账号」就像点了块石头）。
  /// 这里返回一个假句柄：给它赋 `location.href` 就等于请原生开浏览器，
  /// 同时把点击 `target=_blank` 的链接也接管过来。
  static const String _popupBridgeJs = r'''
(function () {
  if (window.__a2aPopupBridge) return;
  window.__a2aPopupBridge = true;

  function open(url) {
    if (!url) return;
    var text = String(url);
    if (!text || text === 'about:blank') return;
    try { window.flutter_inappwebview.callHandler('a2aOpen', text); } catch (e) {}
  }

  window.open = function (url, name, features) {
    if (url && String(url) !== 'about:blank') open(url);
    return {
      closed: false,
      focus: function () {},
      blur: function () {},
      close: function () { this.closed = true; },
      postMessage: function () {},
      location: {
        get href() { return 'about:blank'; },
        set href(value) { open(value); },
        assign: function (value) { open(value); },
        replace: function (value) { open(value); }
      }
    };
  };

  document.addEventListener('click', function (event) {
    var node = event.target;
    while (node && node.tagName !== 'A') { node = node.parentNode; }
    if (!node) return;
    if (node.target !== '_blank') return;
    var href = node.getAttribute('href');
    if (!href) return;
    event.preventDefault();
    open(href);
  }, true);

  // 脚本异常回传：空白页最常见的成因是某个 island 初始化时抛错，
  // 把消息带回原生贴在底部，下一次就能直接对症。
  function report(message) {
    try { window.flutter_inappwebview.callHandler('a2aError', String(message)); } catch (e) {}
  }
  window.addEventListener('error', function (event) {
    var where = (event.filename || '') + (event.lineno ? ':' + event.lineno : '');
    report('error: ' + (event.message || '') + (where ? ' @ ' + where : ''));
  });
  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    var text = reason && (reason.stack || reason.message) ? (reason.stack || reason.message) : reason;
    report('rejection: ' + text);
  });
})();
''';

  /// 用系统浏览器（SFSafariViewController）打开授权页。
  /// 授权页完成后的回调打回 127.0.0.1:3065，本机回环两边共用，
  /// 网关收到回调，shim 的轮询自然拿到结果。
  Future<void> _openExternal(String url) async {
    try {
      final browser = ChromeSafariBrowser();
      await browser.open(url: WebUri(url));
    } catch (_) {
      // 退路：实在开不了就在当前 webview 里导航（会丢 SPA 状态，但能看见页面）
      await _web?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  /// 把导出的文件写进 App 文档目录 Exports/ 下。
  /// Info.plist 已开 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace，
  /// 用户在系统「文件」App → 我的 iPhone → Agent2API 里即可看到并拷出。
  Future<void> _doExport({required String name, required String data}) async {
    try {
      final bytes = base64Decode(data);
      final base = await _resolveExportDir();
      final exports = Directory('${base.path}/Exports');
      await exports.create(recursive: true);
      // 文件名只取末尾一段，防路径注入
      final safe = name.replaceAll('\\', '/').split('/').last;
      final file = File('${exports.path}/$safe');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _jsError = '';
        _exportNote = '已导出：${exports.path}/$safe';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _exportNote = '导出失败：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    _setup();
  }

  /// 只在挂载时 setState（启动流程有多处 await，避免 dispose 后报错）
  void _set(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  Future<void> _setup() async {
    if (_busy) return;
    _busy = true;
    try {
      _set(() {
        _failed = false;
        _ready = false;
        _barVisible = true;
        _stage = '准备数据目录…';
        _detail = '';
      });

      final docs = await _resolveDataDir();
      _dataPath = docs.path;
      final uiPath = '${docs.path}/ui';

      // 解压判据用 index.html 而不是目录是否存在：上一次解压中途被杀会留下
      // 空目录，按目录判断会永远跳过解压，结果是永远白屏。
      if (!File('$uiPath/index.html').existsSync()) {
        _set(() => _stage = '解包管理界面…');
        await _extractUi(uiPath);
        if (!File('$uiPath/index.html').existsSync()) {
          throw StateError('解包后仍找不到 index.html（assets/ui.zip 可能没打进去）');
        }
      }

      // 解包插件（越狱 spawn 路线）：网关 bootstrap 时读 plugins.json 并 spawn
      // 插件进程（agent2api-providers，21+ 家 provider）。必须在 start 之前落盘。
      _set(() => _stage = '解包提供商插件…');
      await _extractPlugins(docs.path);

      _set(() {
        _stage = '启动网关服务…';
        _detail = '端口 $kPort　数据目录 ${docs.path}';
      });
      final code = Agent2ApiServer.start(docs.path, kPort);
      if (code != 0) {
        throw StateError('agent2api_server_start 返回 $code'
            '（1=参数非法 2=路径非 UTF-8 3=服务器内部错误，常见为端口被占用）');
      }

      _set(() => _stage = '等待服务应答…');
      final ok = await _waitHealthy();
      if (!ok) {
        throw StateError('服务启动后 20 秒内 /health 无 200 应答'
            '（静态库可能未被链接，或监听任务已退出）');
      }

      _set(() {
        _ready = true;
        _stage = '就绪';
        _detail = '';
      });
    } catch (e) {
      _set(() {
        _failed = true;
        _barVisible = true;
        _stage = '启动失败';
        _detail = '${e.toString()}\n数据目录=$_dataPath\nping=${_safePing()}';
      });
    } finally {
      _busy = false;
    }
  }

  /// 探活符号（42 = 静态库已链接）。失败时用于区分「库没链上」与「服务没起来」。
  String _safePing() {
    try {
      return Agent2ApiServer.ping().toString();
    } catch (e) {
      return 'symbol-missing';
    }
  }

  /// 解析一个「确实可写」的数据目录。
  ///
  /// TrollStore（no-container）环境下，`getApplicationDocumentsDirectory` 的
  /// NSDocumentDirectory 解析可能落到 `/`（根目录）或不可写路径，直接创建会
  /// EPERM。这里按「Application Support → Documents → Library」依次尝试，
  /// 逐个验证「非空、非根、能真正 mkdir」，全部失败才退回系统临时目录。
  Future<Directory> _resolveDataDir() async {
    final candidates = <Future<Directory> Function()>[
      getApplicationSupportDirectory,
      getApplicationDocumentsDirectory,
      getLibraryDirectory,
    ];
    for (final getter in candidates) {
      try {
        final dir = await getter();
        final path = dir.path;
        if (path.isEmpty || path == '/' || path == '//') continue;
        await Directory(path).create(recursive: true);
        return Directory(path);
      } catch (_) {
        // 这个候选不可用，试下一个
      }
    }
    final tmp = Directory.systemTemp;
    await tmp.create(recursive: true);
    return tmp;
  }

  /// 导出目录：优先 Documents（UIFileSharingEnabled 只对 Documents 生效，
  /// 用户才能在系统「文件」App 里看到并拷出）。TrollStore no-container 下
  /// Documents 解析异常时退回数据目录。
  Future<Directory> _resolveExportDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = dir.path;
      if (path.isNotEmpty && path != '/' && path != '//') {
        await Directory(path).create(recursive: true);
        return Directory(path);
      }
    } catch (_) {
      // 落到下面的数据目录兜底
    }
    return _resolveDataDir();
  }

  /// 轮询 /health：`server::start` 只保证 bind，监听任务异步起来。
  Future<bool> _waitHealthy() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      for (var i = 0; i < 80; i++) {
        try {
          final request = await client.getUrl(Uri.parse(kHealthUrl));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == 200) return true;
        } catch (_) {
          // 还没起来：connection refused，继续等
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 解压内置 Web UI。zip 内条目可能带 `./` 前缀，且必须防 zip-slip。
  Future<void> _extractUi(String uiPath) async {
    final data = await rootBundle.load('assets/ui.zip');
    final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List());
    final root = Directory(uiPath).absolute;
    final rootPrefix = '${root.path}${Platform.pathSeparator}';

    for (final file in archive) {
      if (!file.isFile) continue;
      // archive 3.x 的 zip 条目解码后 content 即完整字节（非流式）
      final content = file.content;
      if (content is! List<int>) continue;

      var name = file.name.replaceAll('\\', '/');
      while (name.startsWith('./')) {
        name = name.substring(2);
      }
      name = name.replaceFirst(RegExp(r'^/+'), '');
      if (name.isEmpty) continue;

      final out = File('${root.path}/$name');
      // 归一化后必须仍在 ui/ 之内，否则丢弃（zip-slip 防御）
      final normalized = out.absolute.path;
      if (!normalized.startsWith(rootPrefix)) continue;

      await out.parent.create(recursive: true);
      await out.writeAsBytes(content, flush: true);
    }
  }

  /// 解包插件包到 `{dataDir}/plugins/` 并写注册表 plugins.json。
  ///
  /// iOS 上两个插件（agent2api-providers + agent2api-web-providers）都随 App
  /// 打包分发，但**真正被 spawn 的可执行文件在 App bundle 里**
  /// （Runner.app/plugins/），由 TrollStore 安装时用 CoreTrust 证书重签；
  /// 数据目录里的副本只有 ldid ad-hoc 签名、没有证书，spawn 必然 EPERM。
  /// 所以这里的 zip 只提供 pack.json 清单与注册表落盘，让网关 bootstrap 知道
  /// 「装了哪些插件、是否启用」，实际 spawn 走 bundle 内副本。
  Future<void> _extractPlugins(String dataPath) async {
    // 版本号**不能写死**：workflow 打包 plugins.zip 时从插件仓库的 pack.json
    // 读版本（随上游 tag 变化）。写死 beta.5.1 而上游出 beta.6 后，解压目录
    // 对不上，报「缺少 pack.json」。改为：先解压，再扫描目录动态发现版本。
    final pluginsDir = Directory('$dataPath/plugins');
    final registry = File('${pluginsDir.path}/plugins.json');

    final data = await rootBundle.load('assets/plugins.zip');
    final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List());
    final root = pluginsDir.absolute;
    // 注意：不能写 `'$pluginsDir/…'` —— Directory 对象插值会变成
    // `Directory: '/path'` 这种带前缀的字符串，拼出非法路径。必须显式取 `.path`。
    final rootPrefix = '${root.path}${Platform.pathSeparator}';
    await root.create(recursive: true);

    for (final file in archive) {
      if (!file.isFile) continue;
      final content = file.content;
      if (content is! List<int>) continue;
      var name = file.name.replaceAll('\\', '/');
      while (name.startsWith('./')) {
        name = name.substring(2);
      }
      name = name.replaceFirst(RegExp(r'^/+'), '');
      if (name.isEmpty) continue;
      final out = File('${root.path}/$name');
      final normalized = out.absolute.path;
      if (!normalized.startsWith(rootPrefix)) continue;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(content, flush: true);
    }

    // 逐个包动态发现版本：扫 `plugins/<包id>/` 下的版本目录，取 pack.json
    // 存在的那个（zip 里每个包只有一个版本目录）。
    final packs = <Map<String, dynamic>>[];
    for (final id in ['agent2api-providers', 'agent2api-web-providers']) {
      final packRoot = Directory('${pluginsDir.path}/$id');
      String? version;
      if (packRoot.existsSync()) {
        for (final entry in packRoot.listSync()) {
          if (entry is! Directory) continue;
          if (File('${entry.path}/pack.json').existsSync()) {
            version = entry.path.split(Platform.pathSeparator).last;
            break;
          }
        }
      }
      if (version == null) {
        throw StateError('插件包解压后缺少 $id/<版本>/pack.json');
      }
      final packJson = File('${pluginsDir.path}/$id/$version/pack.json');
      final manifest =
          jsonDecode(await packJson.readAsString()) as Map<String, dynamic>;
      final providers = manifest['providers'] as List? ?? const [];
      packs.add({
        'id': id,
        'version': version,
        'enabled': true,
        'providers': <String, bool>{},
        'entry': 'bin/$id',
        'sha256': '',
        'signed': false,
        'installed_at': DateTime.now().millisecondsSinceEpoch,
        'manifest_providers': providers,
      });
    }
    await registry.parent.create(recursive: true);
    await registry.writeAsString(jsonEncode({'packs': packs}), flush: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      body: Stack(
        children: [
          // SafeArea 必须包住 webview：页面根布局是 `.shell { height: 100vh }`，
          // webview 若与屏幕等大（100vh 含状态栏），内容整体会被顶到状态栏
          // 底下去 —— 表现就是「整体上移」。收进安全区后 100vh 才等于可见高度。
          Positioned.fill(
            child: SafeArea(
              child: _ready
                  ? InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(kUiUrl)),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        allowsInlineMediaPlayback: true,
                        mediaPlaybackRequiresUserGesture: false,
                        supportZoom: false,
                        transparentBackground: false,
                      ),
                      onWebViewCreated: (controller) {
                        _web = controller;
                        // 弹窗通道：WKWebView 未实现 createWebViewWith 时
                        // window.open 返回 null，登录授权页根本打不开；
                        // 这里把 window.open / target=_blank 转成原生浏览器。
                        controller.addJavaScriptHandler(
                          handlerName: 'a2aOpen',
                          callback: (args) {
                            if (args.isNotEmpty) {
                              _openExternal(args.first.toString());
                            }
                            return null;
                          },
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'a2aError',
                          callback: (args) {
                            if (args.isEmpty) return null;
                            final text = args.first.toString();
                            if (!mounted) return null;
                            setState(() => _jsError = text.length > 300
                                ? text.substring(0, 300)
                                : text);
                            return null;
                          },
                        );
                        // 导出桥：web_shim 在 iOS 下把导出内容转 base64 传过来，
                        // 原生侧写进 App 文档目录（文件 App 可见）。
                        controller.addJavaScriptHandler(
                          handlerName: 'a2aExport',
                          callback: (args) {
                            if (args.isEmpty) return null;
                            final map = args.first;
                            if (map is! Map) return null;
                            _doExport(
                              name: (map['name'] ?? 'export.bin').toString(),
                              data: (map['data'] ?? '').toString(),
                            );
                            return null;
                          },
                        );
                        controller.addUserScript(
                          userScript: UserScript(
                            source: _popupBridgeJs,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                            forMainFrameOnly: true,
                          ),
                        );
                      },
                      onLoadStop: (controller, url) {
                        if (!mounted) return;
                        setState(() => _barVisible = false);
                      },
                      onConsoleMessage: (controller, message) {
                        // 不直接比枚举值：不同版本 ConsoleMessageLevel 的大小写
                        // 有过变化，按字符串判定更稳。
                        final level =
                            message.messageLevel.toString().toLowerCase();
                        if (!level.contains('error')) return;
                        if (!mounted) return;
                        final text = message.message.toString();
                        setState(() => _jsError =
                            text.length > 300 ? text.substring(0, 300) : text);
                      },
                      onReceivedError: (controller, request, error) {
                        if (!mounted) return;
                        setState(() {
                          _barVisible = true;
                          _failed = true;
                          _stage = '页面加载失败';
                          _detail = '${request.url}\n${error.description}';
                        });
                      },
                    )
                  : _loadingView(),
            ),
          ),
          if (_jsError.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: GestureDetector(
                  onTap: () => setState(() => _jsError = ''),
                  child: Container(
                    color: const Color(0xE6B3261E),
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'JS 错误（点掉）: $_jsError',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ),
            ),
          if (_exportNote.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: GestureDetector(
                  onTap: () => setState(() => _exportNote = ''),
                  child: Container(
                    color: const Color(0xE61F7A3D),
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      _exportNote,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_barVisible)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: IgnorePointer(
                  ignoring: !_failed,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE6101216),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x33FFFFFF)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!_failed)
                          const Padding(
                            padding: EdgeInsets.only(top: 1, right: 8),
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _stage,
                                style: TextStyle(
                                  color: _failed
                                      ? const Color(0xFFFF7A7A)
                                      : Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_detail.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    _detail,
                                    style: const TextStyle(
                                      color: Color(0xFFB9BEC7),
                                      fontSize: 11,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              if (_failed)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    children: [
                                      _barButton('重试', () {
                                        Agent2ApiServer.stop();
                                        _setup();
                                      }),
                                      const SizedBox(width: 8),
                                      _barButton('只看页面', () {
                                        setState(() {
                                          _barVisible = false;
                                          _ready = true;
                                        });
                                      }),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _barButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF2B6CF6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _loadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_failed)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            if (!_failed) const SizedBox(height: 16),
            Text(
              _stage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF9AA0AA),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
