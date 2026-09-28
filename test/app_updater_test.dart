import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yiji/update/app_updater.dart';

/// 更新检查的逻辑。
///
/// 两个容易出错的地方:
/// 1. **版本比较**必须走 versionCode,字符串比大小会把 "0.10.0" 判成比 "0.9.0" 旧;
/// 2. tag 只放 versionCode(`v4`),版本名放 release 标题——`v0.4.0+4` 里的 `+`
///    在下载链接里会被编码成 `%2B`,不值得冒这个险。
class _FakeHttp extends http.BaseClient {
  _FakeHttp({required this.status, required this.body});

  final int status;
  final String body;
  String? lastUrl;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUrl = request.url.toString();
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(body)]),
      status,
    );
  }
}

String releaseJson({
  required String tag,
  String name = '忆记 v0.4.0',
  String apkName = 'yiji.apk',
  String url = 'https://example.com/yiji.apk',
  int size = 12345678,
  String body = '修了几个 bug',
}) {
  return jsonEncode({
    'tag_name': tag,
    'name': name,
    'body': body,
    'assets': [
      {'name': 'source.zip', 'browser_download_url': 'https://example.com/src.zip', 'size': 1},
      {'name': apkName, 'browser_download_url': url, 'size': size},
    ],
  });
}

void main() {
  AppUpdater updaterWith(_FakeHttp http) =>
      AppUpdater(httpClient: http, owner: 'o', repo: 'r');

  group('有新版本时', () {
    test('返回版本号、下载地址与说明', () async {
      final http = _FakeHttp(status: 200, body: releaseJson(tag: 'v4'));
      final info = await updaterWith(http).checkForUpdate(currentVersionCode: 3);

      expect(info, isNotNull);
      // 版本名从 release 标题里取,而不是从 tag。
      expect(info!.versionName, '0.4.0');
      expect(info.versionCode, 4);
      expect(info.notes, '修了几个 bug');
      expect(info.sizeBytes, 12345678);
      // 只认 APK,不能把源码压缩包当安装包。
      expect(info.downloadUrl, 'https://example.com/yiji.apk');
    });

    test('tag 不带 v 前缀也认', () async {
      final http = _FakeHttp(
        status: 200,
        body: releaseJson(tag: '5', name: '忆记 v0.5.0'),
      );
      final info = await updaterWith(http).checkForUpdate(currentVersionCode: 3);
      expect(info!.versionCode, 5);
      expect(info.versionName, '0.5.0');
    });

    test('标题里抠不出版本号时退回用 tag', () async {
      final http = _FakeHttp(status: 200, body: releaseJson(tag: 'v7', name: '更新'));
      final info = await updaterWith(http).checkForUpdate(currentVersionCode: 3);
      expect(info!.versionName, '7');
    });
  });

  group('不该提示更新时', () {
    test('版本一样 → null', () async {
      final http = _FakeHttp(status: 200, body: releaseJson(tag: 'v4'));
      expect(await updaterWith(http).checkForUpdate(currentVersionCode: 4), isNull);
    });

    test('比当前旧 → null', () async {
      final http = _FakeHttp(status: 200, body: releaseJson(tag: 'v3'));
      expect(await updaterWith(http).checkForUpdate(currentVersionCode: 4), isNull);
    });

    test('跨位数比较按数字而不是字符串', () async {
      // 字符串比大小会认为 "0.10.0" < "0.9.0",从而漏掉更新。
      final http = _FakeHttp(
        status: 200,
        body: releaseJson(tag: 'v10', name: '忆记 v0.10.0'),
      );
      final info = await updaterWith(http).checkForUpdate(currentVersionCode: 9);
      expect(info, isNotNull, reason: 'versionCode 10 比 9 新');
      expect(info!.versionCode, 10);
      expect(info.versionName, '0.10.0');
    });

    test('仓库还没有 release(404)→ null,不是错误', () async {
      final http = _FakeHttp(status: 404, body: '{"message":"Not Found"}');
      expect(await updaterWith(http).checkForUpdate(currentVersionCode: 3), isNull);
    });

    test('release 里没有 apk → null', () async {
      final http = _FakeHttp(
        status: 200,
        body: jsonEncode({
          'tag_name': 'v9',
          'name': '忆记 v0.9.0',
          'assets': [
            {'name': 'source.zip', 'browser_download_url': 'https://x/s.zip', 'size': 1},
          ],
        }),
      );
      expect(await updaterWith(http).checkForUpdate(currentVersionCode: 3), isNull);
    });

    test('tag 不是数字 → null(无法判断新旧)', () async {
      final http = _FakeHttp(status: 200, body: releaseJson(tag: 'release-2026-09'));
      expect(await updaterWith(http).checkForUpdate(currentVersionCode: 3), isNull);
    });
  });

  group('出错时', () {
    test('非 200 抛 UpdateException', () async {
      final http = _FakeHttp(status: 500, body: 'boom');
      expect(
        () => updaterWith(http).checkForUpdate(currentVersionCode: 3),
        throwsA(isA<UpdateException>()),
      );
    });

    test('返回的不是 JSON 也抛 UpdateException', () async {
      final http = _FakeHttp(status: 200, body: '<html>nope</html>');
      expect(
        () => updaterWith(http).checkForUpdate(currentVersionCode: 3),
        throwsA(isA<UpdateException>()),
      );
    });
  });

  group('请求本身', () {
    test('打的是公开仓库的 latest release,不需要 token', () async {
      final http = _FakeHttp(status: 200, body: releaseJson(tag: 'v4'));
      await AppUpdater(httpClient: http, owner: '820sz', repo: 'yiji')
          .checkForUpdate(currentVersionCode: 3);

      expect(http.lastUrl, 'https://api.github.com/repos/820sz/yiji/releases/latest');
    });

    test('中文更新说明不会变乱码', () async {
      // Content-Type 不带 charset 时,http 包的 response.body 会退回 Latin-1,
      // 所以这里验证的是"按 UTF-8 自己解字节"这件事确实生效。
      final http = _FakeHttp(
        status: 200,
        body: releaseJson(tag: 'v4', body: '修了头像闪烁 · 支持传图'),
      );
      final info = await updaterWith(http).checkForUpdate(currentVersionCode: 3);
      expect(info!.notes, '修了头像闪烁 · 支持传图');
    });
  });
}
