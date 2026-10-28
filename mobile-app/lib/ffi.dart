import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 网关静态库（libagent2api_server.a）的 dart:ffi 绑定。
///
/// 符号：
///   agent2api_server_start(const char* data_dir, uint16_t port) -> int32
///   agent2api_server_ping() -> int32
class Agent2ApiServer {
  Agent2ApiServer._();

  static final DynamicLibrary _lib = _load();

  static DynamicLibrary _load() {
    if (Platform.isIOS) {
      // iOS：静态库已链接进主二进制，符号直接可解析
      return DynamicLibrary.process();
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.process();
    }
    throw UnsupportedError('当前平台不支持：${Platform.operatingSystem}');
  }

  static final int Function(Pointer<Utf8>, int) _start = _lib
      .lookup<NativeFunction<Int32 Function(Pointer<Utf8>, Uint16)>>(
          'agent2api_server_start')
      .asFunction();

  static final int Function() _ping = _lib
      .lookup<NativeFunction<Int32 Function()>>('agent2api_server_ping')
      .asFunction();

  /// 探活：返回 42 表示静态库链接成功
  static int ping() => _ping();

  /// 启动网关 headless 服务器，返回 0 = 成功。
  /// [dataDir] 为配置目录（等价 AGENT2API_PROXY_HOME），UI 在 {dataDir}/ui/。
  static int start(String dataDir, int port) {
    final ptr = dataDir.toNativeUtf8();
    try {
      return _start(ptr, port);
    } finally {
      malloc.free(ptr);
    }
  }
}
