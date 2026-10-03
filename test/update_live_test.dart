import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/update/app_updater.dart';

/// **自动更新端到端**:假装自己是一台装着 v1.1.0 的手机,去查有没有新版,
/// 再按生产代码真实下载一次。
///
/// 起因:用户点内置更新报「下载不完整(1418/65274459 字节)」。1418 字节不是
/// "断了",是网络层塞回来的一张 HTML 拦截页——而它带着自己的 Content-Length
/// 正常结束,所以旧代码里"字节数够不够"完全看不出问题,真因被一句
/// "下载不完整"盖住了。这一组要回答三件事:
///   1. 从 v1.1.0 能不能查到 v1.1.1(版本比较、资产大小都对);
///   2. 真实下载能不能拿到**完整且以 PK 开头**的包;
///   3. 一条路被挡时,中转源能不能补上。
///
/// 默认跳过(65MB + 真实网络,不该混进常规测试);手动开:
/// ```
/// $env:UPDATE_LIVE="1"; flutter test test/update_live_test.dart
/// ```
void main() {
  final enabled = Platform.environment['UPDATE_LIVE'] == '1';

  if (!enabled) {
    test('跳过自动更新端到端', () {
      expect(enabled, isFalse);
    }, skip: '需要 UPDATE_LIVE=1(会下载 65MB)');
    return;
  }

  /// 假装本机装的是这个版本。
  const installedVersionCode = 12; // v1.1.0

  test('v1.1.0 能查到 v1.1.1,且大小与直链都对', () async {
    final updater = AppUpdater();
    addTearDown(updater.dispose);

    final info = await updater.checkForUpdate(
      currentVersionCode: installedVersionCode,
    );

    expect(info, isNotNull, reason: '装了 v1.1.0 就该看到 v1.1.1');
    // ignore: avoid_print
    print('=== 查到:${info!.versionName}(code ${info.versionCode}) '
        '${info.sizeBytes} 字节');
    // ignore: avoid_print
    print('=== 直链:${info.downloadUrl}');
    // ignore: avoid_print
    print('=== 备用:${info.apiDownloadUrl}');

    expect(info.versionName, '1.1.1');
    expect(info.versionCode, greaterThan(installedVersionCode));
    // 大小必须和上传的资产一致,否则下载完会被"大小不符"拦下来。
    expect(info.sizeBytes, 65274459);
    expect(info.downloadUrl, contains('github.com'));
    expect(info.apiDownloadUrl, isNotEmpty, reason: '没有备用地址就少一条退路');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('按生产代码真实下载,拿到完整且以 PK 开头的包', () async {
    final updater = AppUpdater();
    addTearDown(updater.dispose);

    final info = await updater.checkForUpdate(
      currentVersionCode: installedVersionCode,
    );
    expect(info, isNotNull);

    final seen = <double>[];
    final watch = Stopwatch()..start();
    final bytes = await updater.download(info!, onProgress: seen.add);
    watch.stop();

    // ignore: avoid_print
    print('=== 下到 ${bytes.length} 字节,用时 ${watch.elapsed.inSeconds}s,'
        '进度回调 ${seen.length} 次,最后一档 ${seen.isEmpty ? "无" : seen.last}');

    expect(
      bytes.length,
      info.sizeBytes,
      reason: '下载结果必须和登记大小一致',
    );
    // APK 是 zip:开头必须是 PK\x03\x04。这一条比"字节数对不对"更根本
    // ——它同时证明收到的不是拦截页。
    expect(
      bytes.take(4).toList(),
      [0x50, 0x4B, 0x03, 0x04],
      reason: '拿到的不是 zip/APK,前 4 字节是 ${bytes.take(4).toList()}',
    );
    expect(seen.last, 1, reason: '下完要报 1');
  }, timeout: const Timeout(Duration(minutes: 20)));

  test('中转源能补上:直连地址被挡时照样能下完', () async {
    // 用户的实际处境:直连 GitHub 的资产域名拿不到真文件。
    // 把直连地址换成一个够不着的域名,逼下载器走中转。
    final updater = AppUpdater();
    addTearDown(updater.dispose);

    final real = await updater.checkForUpdate(
      currentVersionCode: installedVersionCode,
    );
    expect(real, isNotNull);

    final info = UpdateInfo(
      versionName: real!.versionName,
      versionCode: real.versionCode,
      // 一个必然连不上的地址:验证"退到下一个源"真的会发生。
      downloadUrl: 'https://127.0.0.1:1/yiji.apk',
      // 把真实直链放到第二顺位,等于验证"换源"这条路径能拿到真包。
      apiDownloadUrl: real.downloadUrl,
      sizeBytes: real.sizeBytes,
      notes: '',
    );

    final bytes = await updater.download(info);

    // ignore: avoid_print
    print('=== 直连失败后退到备用源,下到 ${bytes.length} 字节');
    expect(bytes.length, info.sizeBytes);
    expect(bytes.take(4).toList(), [0x50, 0x4B, 0x03, 0x04]);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
