import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/update/app_updater.dart';

/// **真实网络下跑一遍现在这套下载**(并发竞速 + 边收边写盘 + 120s 总预算)。
///
/// 这一条是照着用户的投诉补的:他说「研究下 AI上外语 的更新是怎么做的不就解决了吗」,
/// 而那边能用的做法就是这三件事。之前忆记一条都没做——所以下载会停在 0%。
///
/// 手动开:
/// ```
/// $env:UPDATE_LIVE="1"; flutter test test/update_live_test.dart
/// ```
void main() {
  final enabled = Platform.environment['UPDATE_LIVE'] == '1';

  if (!enabled) {
    test('跳过真实下载', () {
      expect(enabled, isFalse);
    }, skip: '需要 UPDATE_LIVE=1(会下载 62MB)');
    return;
  }

  test('真实下载 1.1.2:竞速 + 写盘 + 校验,拿到完整 APK', () async {
    final updater = AppUpdater();
    addTearDown(updater.dispose);

    final info = await updater.checkForUpdate(currentVersionCode: 13);
    expect(info, isNotNull, reason: '装着 1.1.1 就该看到 1.1.2');
    // ignore: avoid_print
    print('=== 查到 ${info!.versionName} ${info.sizeBytes} 字节');
    // ignore: avoid_print
    print('=== 候选源:${info.downloadUrl}');

    final dir = Directory.systemTemp.createTempSync('yiji_update_live');
    addTearDown(() {
      // 清理是测试的事,不该把一次成功的下载判成失败。
      // (之前这里会因为"目录不是空的/找不到"把通过的用例拖成红的。)
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final target = File('${dir.path}/update.apk');

    final bytes = <(int, int)>[];
    final progress = <double>[];
    final watch = Stopwatch()..start();
    final file = await updater.downloadToFile(
      info,
      target,
      onProgress: progress.add,
      onBytes: (received, total) => bytes.add((received, total)),
    );
    watch.stop();

    final length = await file.length();
    // ignore: avoid_print
    print('=== 落盘 $length 字节,用时 ${watch.elapsed.inSeconds}s,'
        '进度回调 ${progress.length} 次');

    expect(length, info.sizeBytes, reason: '字节数必须和登记一致');
    // 内容也要验:这是"不是拦截页"的硬证据。
    final head = await file.openRead(0, 4).fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
    expect(head, [0x50, 0x4B, 0x03, 0x04], reason: 'APK 是 zip,必须以 PK 开头');
    expect(progress.isNotEmpty && progress.last == 1, isTrue);
    // 过程中必须真的动过:停在 0% 正是用户投诉的现象。
    expect(
      bytes.any((e) => e.$1 > 0),
      isTrue,
      reason: '整个过程一次都没报过"收到字节",那就是卡住了',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
