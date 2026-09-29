import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yiji/update/app_updater.dart';

/// 下载安装包这件事。
///
/// 用户实际遇到的是 `Connection closed before full header was received`:
/// GitHub 的下载会 302 到 release-assets.githubusercontent.com,这条连接在
/// 部分网络下会被中途掐断。原来是一次性 `await get()`,于是:看不到任何进度、
/// 断了就彻底失败、失败后界面只弹一句英文异常。
///
/// 这里锁住三件事:**边下边报进度**、**断了自动重试**、**两个地址互为退路**。
class _ScriptedHttp extends http.BaseClient {
  _ScriptedHttp({
    required this.chunks,
    this.contentLength,
    this.failAtChunk,
    this.failTimes = 0,
  });

  /// 每次响应依次吐出的块。
  final List<List<int>> chunks;
  final int? contentLength;

  /// 吐到第几块时抛异常(模拟连接被掐断);null 表示不失败。
  final int? failAtChunk;

  /// 前几次请求失败。用来验证重试确实换了一次机会。
  final int failTimes;

  /// 每块之间等多久。真实下载是慢的,块与块之间隔着几十毫秒;
  /// 测试要复现"边下边报进度",就得让每块真的落在不同的时间点上。
  static const chunkDelay = Duration(milliseconds: 30);

  final List<String> urls = [];
  var _calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    urls.add(request.url.toString());
    final call = _calls++;

    // 重试用尽前先失败。第一次就抛,模拟"连都连不上"。
    if (call < failTimes) {
      throw http.ClientException('Connection closed before full header was received');
    }

    // 只有第一次请求会中途断。第二次(重试)必须成功,否则测不出重试生效。
    final shouldFail = failAtChunk != null && call == 0;
    final controller = StreamController<List<int>>();

    () async {
      for (var i = 0; i < chunks.length; i++) {
        // 出错后要停下:不检查的话后台还在往已关闭的流里塞数据,
        // 下一次请求会被上一轮的失败连累(测试里就踩到了这个坑)。
        if (controller.isClosed) return;
        if (shouldFail && i == failAtChunk) {
          controller.addError(
            http.ClientException('Connection closed before full header was received'),
          );
          await controller.close();
          return;
        }
        controller.add(chunks[i]);
        // 让出事件循环并走上一点时间,保证是"流式"到达而不是被同步塞完。
        await Future<void>.delayed(chunkDelay);
      }
      if (!controller.isClosed) await controller.close();
    }();

    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: contentLength,
    );
  }
}

UpdateInfo infoOf({int size = 0, String url = 'https://example.com/a.apk', String api = ''}) {
  return UpdateInfo(
    versionName: '0.6.0',
    versionCode: 6,
    downloadUrl: url,
    apiDownloadUrl: api,
    notes: '',
    sizeBytes: size,
  );
}

/// 把 4 块 1KB 的数据当成一个 4KB 的包。
List<List<int>> fourChunks() => List.generate(4, (i) => List.filled(1024, i));

void main() {
  test('边下边报进度,不是下完了才告诉界面', () async {
    final http = _ScriptedHttp(chunks: fourChunks(), contentLength: 4096);
    final updater = AppUpdater(httpClient: http);
    final seen = <double>[];

    final bytes = await updater.download(
      infoOf(size: 4096),
      onProgress: seen.add,
    );

    expect(bytes.length, 4096);
    // 关键:中间必须报过 0 和 1 之间的值。原来是等整个 body 回来,
    // 界面在几十秒里一帧进度都拿不到,用户只能以为卡死了。
    expect(seen.first, 0);
    expect(seen.last, 1);
    expect(
      seen.any((v) => v > 0 && v < 1),
      isTrue,
      reason: '下载过程中要有中间进度,实际收到 $seen',
    );
    // 进度不能倒退。
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  test('字节数也报给界面,用户能看出还在动', () async {
    final http = _ScriptedHttp(chunks: fourChunks(), contentLength: 4096);
    final updater = AppUpdater(httpClient: http);
    final seen = <(int, int)>[];

    await updater.download(
      infoOf(size: 4096),
      onBytes: (received, total) => seen.add((received, total)),
    );

    expect(seen.last, (4096, 4096));
    expect(seen.any((e) => e.$1 > 0 && e.$1 < 4096), isTrue);
  });

  test('服务端没给 Content-Length 时,用 release 里登记的大小当分母', () async {
    // GitHub 走 CDN 时不一定带 Content-Length。没有分母的话界面只能转圈,
    // 所以退回 release 登记值。
    final http = _ScriptedHttp(chunks: fourChunks());
    final updater = AppUpdater(httpClient: http);
    final seen = <double>[];

    await updater.download(infoOf(size: 4096), onProgress: seen.add);

    expect(seen.last, 1);
    expect(seen.any((v) => v > 0 && v < 1), isTrue, reason: '有分母就该有中间进度');
  });

  test('读到一半断了会自动重试,并且最终拿到完整文件', () async {
    // 第一次在第 2 块断掉,第二次成功。
    final http = _ScriptedHttp(
      chunks: fourChunks(),
      contentLength: 4096,
      failAtChunk: 2,
      failTimes: 1,
    );
    final updater = AppUpdater(httpClient: http);

    final bytes = await updater.download(infoOf(size: 4096));

    expect(bytes.length, 4096, reason: '重试后要拿到完整包');
    expect(http.urls.length, 2, reason: '应该正好重试一次');
  });

  test('连不上时也重试,不是一次就放弃', () async {
    final http = _ScriptedHttp(
      chunks: fourChunks(),
      contentLength: 4096,
      failTimes: 2,
    );
    final updater = AppUpdater(httpClient: http);

    final bytes = await updater.download(infoOf(size: 4096));

    expect(bytes.length, 4096);
    expect(http.urls.length, 3);
  });

  test('一直失败时给一句人话,而不是把英文异常原样扔给用户', () async {
    final http = _ScriptedHttp(
      chunks: fourChunks(),
      contentLength: 4096,
      failTimes: 99,
    );
    final updater = AppUpdater(httpClient: http);

    await expectLater(
      updater.download(infoOf(size: 4096)),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          allOf(contains('下载失败'), contains('手动下载')),
        ),
      ),
    );
  });

  test('两个下载地址轮流试,换域名能绕开被掐的连接', () async {
    final http = _ScriptedHttp(
      chunks: fourChunks(),
      contentLength: 4096,
      failTimes: 1,
    );
    final updater = AppUpdater(httpClient: http);

    await updater.download(
      infoOf(size: 4096, url: 'https://github.com/x/a.apk', api: 'https://api.github.com/x/a'),
    );

    expect(http.urls.first, 'https://github.com/x/a.apk');
    expect(http.urls[1], 'https://api.github.com/x/a', reason: '第二次应该换地址');
  });

  test('包不完整时不假装成功', () async {
    // 流正常结束但字节数对不上:这种情况绝不能交给系统安装,
    // 否则用户看到的是安装器报的一句看不懂的错。
    final http = _ScriptedHttp(chunks: [List.filled(1024, 1)], contentLength: 4096);
    final updater = AppUpdater(httpClient: http);

    await expectLater(
      updater.download(infoOf(size: 4096)),
      throwsA(isA<UpdateException>()),
    );
  });

  test('release 里登记的大小和实际一致时不误判', () async {
    // 边界:大小完全一致必须通过,否则正常更新也会被拦下来。
    final http = _ScriptedHttp(chunks: fourChunks(), contentLength: 4096);
    final updater = AppUpdater(httpClient: http);

    final bytes = await updater.download(infoOf(size: 4096));
    expect(bytes.length, 4096);
  });

  test('没有下载地址时明确报错', () async {
    final http = _ScriptedHttp(chunks: fourChunks());
    final updater = AppUpdater(httpClient: http);

    await expectLater(
      updater.download(infoOf(url: '', api: '')),
      throwsA(isA<UpdateException>()),
    );
  });

  test('50MB 的包也不会刷出成千上万次界面重建', () async {
    // 反面教材:每收一块就 notifyListeners,54MB 的包会刷出几千次重建,
    // 下载界面自己先卡住。这里用一个接近真实的包量一下次数。
    const total = 50 * 1024 * 1024;
    const chunkSize = 256 * 1024;
    final chunks = List.generate(total ~/ chunkSize, (_) => List.filled(chunkSize, 7));
    final http = _ScriptedHttp(chunks: chunks, contentLength: total);
    final updater = AppUpdater(httpClient: http);
    var reports = 0;
    final seen = <double>[];

    final bytes = await updater.download(
      infoOf(size: total),
      onProgress: (v) {
        reports++;
        seen.add(v);
      },
    );

    expect(bytes.length, total);
    expect(seen.last, 1);
    // 50MB ÷ 2% ≈ 50 次,放宽到 120 次足够证明"不是每块都报"。
    expect(reports, lessThan(120), reason: '实际报了 $reports 次');
    // 但也不能太稀:中间得有足够多的点,进度条才是走的。
    expect(reports, greaterThan(10), reason: '实际报了 $reports 次');
  });

  test('检查更新时把 API 地址也带上,下载才有退路', () async {
    final release = AppUpdater(
      httpClient: _JsonHttp(
        jsonEncode({
          'tag_name': 'v6',
          'name': '忆记 v0.6.0',
          'assets': [
            {
              'name': 'yiji.apk',
              'browser_download_url':
                  'https://github.com/820sz/yiji/releases/download/v6/yiji.apk',
              'url': 'https://api.github.com/repos/820sz/yiji/releases/assets/1',
              'size': 100,
            },
          ],
        }),
      ),
    );

    final info = await release.checkForUpdate(currentVersionCode: 5);
    expect(info!.downloadUrl, contains('github.com/820sz/yiji/releases/download/v6'));
    expect(info.apiDownloadUrl, contains('api.github.com'));
  });
}

class _JsonHttp extends http.BaseClient {
  _JsonHttp(this.body);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }
}
