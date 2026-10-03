import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/update/app_updater.dart';

/// 真实下载 **v1.1.0 的 APK**,并且把服务端到底回了什么打印出来。
///
/// 起因:用户在手机上点内置更新,报「下载不完整(1418/65274459 字节)」。
/// 1418 字节不像"网络不稳",像**收到了一张 HTML 拦截页却当成 APK 存下来**。
/// 这一条要回答的是:同一个地址在一条正常的网络上,客户端到底能不能下完。
///
/// 它默认跳过(65MB + 真实网络,不该混进常规测试);手动开:
/// ```
/// $env:UPDATE_LIVE="1"; flutter test test/update_live_test.dart
/// ```
void main() {
  final enabled = Platform.environment['UPDATE_LIVE'] == '1';

  if (!enabled) {
    test('跳过真实下载探针', () {
      expect(enabled, isFalse);
    }, skip: '需要 UPDATE_LIVE=1(会下载 65MB)');
    return;
  }

  test('真实下载能拿到完整的 65274459 字节', () async {
    final updater = AppUpdater();
    addTearDown(updater.dispose);

    // 直接构造,不走 GitHub API:这里要验的是**下载**这一段。
    final info = UpdateInfo(
      versionName: '1.1.0',
      versionCode: 12,
      downloadUrl:
          'https://github.com/820sz/yiji/releases/download/v12/yiji-1.1.0.apk',
      sizeBytes: 65274459,
      notes: '',
    );

    final progress = <double>[];
    final bytes = await updater.download(
      info,
      onProgress: progress.add,
    );

    // ignore: avoid_print
    print('=== 收到 ${bytes.length} 字节,进度回调 ${progress.length} 次');

    // APK 是 zip:开头必须是 PK\x03\x04。
    // 这一条比"字节数对不对"更根本——**内容是不是 APK**。
    expect(
      bytes.length >= 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04,
      isTrue,
      reason: '拿到的不是 zip/APK,头 4 字节是 ${bytes.take(4).toList()}'
          '(0x50 0x4B 才是 PK)。前 200 字节照抄:${
          String.fromCharCodes(bytes.take(200).where((b) => b >= 32 && b < 127))
      }',
    );
    expect(bytes.length, 65274459, reason: '长度对不上');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
