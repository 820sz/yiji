import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_updater.dart';

/// 把下载好的 APK 交给系统安装。
///
/// 落盘位置选**应用自己的外部私有目录**:那里不需要任何存储权限,
/// 也不用担心用户清理相册时把安装包删掉。文件名固定,新版本直接覆盖旧的。
///
/// 安装这一步走自己的 MethodChannel(见 MainActivity.kt),不依赖第三方插件:
/// `install_plugin` 已停更且缺少 AGP 8 需要的 namespace,会把构建卡死。
class ApkInstaller {
  const ApkInstaller();

  static const _channel = MethodChannel('com.xi283.yiji/install');
  static const _fileName = 'yiji-update.apk';

  /// 下载并打开系统安装界面。
  ///
  /// [onProgress] 收到 0..1 的进度。
  Future<void> downloadAndInstall(
    AppUpdater updater,
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final directory = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, _fileName));

    // 上一次的残留先清掉:新包没下完时,不能让系统装到旧的那个。
    if (await file.exists()) await file.delete();

    onProgress?.call(0);
    final bytes = await updater.download(info);
    await file.writeAsBytes(bytes, flush: true);
    onProgress?.call(1);

    try {
      await _channel.invokeMethod<void>('installApk', {'path': file.path});
    } on PlatformException catch (error) {
      // 原生侧会把"需要先授权安装未知应用"翻成一句人话放在 message 里。
      throw UpdateException(error.message ?? '安装失败');
    } on MissingPluginException {
      throw UpdateException('这台设备不支持自动安装,请手动装下载好的包');
    }
  }
}
