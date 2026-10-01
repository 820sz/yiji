import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一次可安装的更新。
class UpdateInfo {
  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.downloadUrl,
    required this.notes,
    required this.sizeBytes,
    this.apiDownloadUrl = '',
  });

  final String versionName;
  final int versionCode;

  /// APK 直链(浏览器下载地址)。
  final String downloadUrl;

  /// API 的 asset 地址,备用下载入口。
  ///
  /// 两条路都指向同一个文件,但走的是不同的域名。用户网络把其中一个
  /// 拦掉或掐断时,另一个往往能过——这也是重试能奏效的原因之一。
  final String apiDownloadUrl;

  /// 更新说明(release 正文)。
  final String notes;

  final int sizeBytes;
}

/// 从 GitHub Releases 检查更新。
///
/// 用公开仓库的 release,所以不需要 token——这个 app 没有服务端,
/// 让用户为了更新去配一个 GitHub token 是不合理的负担。
///
/// [httpClient] 可注入,测试用假客户端喂固定的 release JSON。
class AppUpdater {
  AppUpdater({
    http.Client? httpClient,
    this.owner = defaultOwner,
    this.repo = defaultRepo,
  }) : _http = httpClient ?? http.Client();

  /// 发布这个 app 的仓库。
  static const defaultOwner = '820sz';
  static const defaultRepo = 'yiji';

  final http.Client _http;
  final String owner;
  final String repo;

  /// 连接建好之后,多久没有新数据就判定这次下载已经卡死。
  ///
  /// 取值比"连接超时"(30 秒)宽松:大文件在弱网下块与块之间本来就会有间隔。
  static const _stallTimeout = Duration(seconds: 30);

  /// 查最新 release。
  ///
  /// 返回 null 表示"没有比当前更新的版本"(含仓库还没有任何 release 的情况)。
  /// 网络失败抛 [UpdateException];调用方决定是静默忽略还是提示——
  /// 检查更新失败不该打断用户手头的事。
  Future<UpdateInfo?> checkForUpdate({required int currentVersionCode}) async {
    final uri = Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

    final http.Response response;
    try {
      response = await _http.get(uri, headers: {
        'Accept': 'application/vnd.github+json',
      });
    } on Exception catch (error) {
      throw UpdateException('连不上 GitHub:$error');
    }

    // 仓库还没有 release 时 GitHub 返回 404——这不是错误,只是没得更新。
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw UpdateException('检查更新失败(${response.statusCode})');
    }

    final Map<String, Object?> release;
    try {
      // 自己按 UTF-8 解 bodyBytes,而不是用 response.body:
      // GitHub 的 Content-Type 不带 charset,http 包会退回 Latin-1,中文更新说明会变乱码。
      release = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
    } on FormatException {
      throw UpdateException('GitHub 返回了无法解析的内容');
    }

    // 只看 APK:仓库里可能还有源码压缩包,那两个装了没用。
    final assets = release['assets'];
    if (assets is! List) return null;
    final apk = assets.cast<Map<String, Object?>?>().firstWhere(
          (asset) => (asset?['name'] as String?)?.endsWith('.apk') ?? false,
          orElse: () => null,
        );
    if (apk == null) return null;

    final tag = (release['tag_name'] as String?) ?? '';
    final code = _parseVersionCode(tag);
    if (code == null) return null;
    // 只有比当前新才提示。用 versionCode 而不是字符串比较:
    // "0.10.0" 和 "0.9.0" 按字符串比会判反,而整数不会。
    if (code <= currentVersionCode) return null;

    // 版本名优先取 release 名字(写成"忆记 v0.4.0"这类),取不到就用 tag 本身。
    final title = (release['name'] as String?)?.trim() ?? '';
    final versionName = _versionNameFrom(title) ?? tag.replaceFirst(RegExp(r'^v'), '');

    return UpdateInfo(
      versionName: versionName,
      versionCode: code,
      downloadUrl: (apk['browser_download_url'] as String?) ?? '',
      apiDownloadUrl: (apk['url'] as String?) ?? '',
      notes: (release['body'] as String?)?.trim() ?? '',
      sizeBytes: (apk['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// 从 tag 里取 versionCode。
  ///
  /// tag 约定为 `v<versionCode>`,例如 versionCode 4 就是 `v4`。
  /// 不把版本名塞进 tag 是为了避开 URL 编码问题——`v0.4.0+4` 里的 `+`
  /// 在下载链接里会变成 `%2B`,虽然能用,但不值得冒这个险。
  static int? _parseVersionCode(String tag) {
    final cleaned = tag.startsWith('v') ? tag.substring(1) : tag;
    return int.tryParse(cleaned.trim());
  }

  /// 从 release 标题里抠出语义化版本号,如"忆记 v0.4.0" → "0.4.0"。
  static String? _versionNameFrom(String title) {
    final match = RegExp(r'v?(\d+\.\d+(?:\.\d+)?)').firstMatch(title);
    return match?.group(1);
  }

  /// 下载 APK。
  ///
  /// 做了三件事来对付真实网络:
  /// 1. **流式读**并回报进度——一次性 await 整个 body 时用户看不到任何变化,
  ///    失败时也分不清是卡住还是断了;
  /// 2. **断线重试**。GitHub 的下载会 302 到 release-assets.githubusercontent.com,
  ///    部分网络下这条连接会被中途掐断(报 Connection closed before full header),
  ///    重试通常就能过;
  /// 3. **多个候选地址**:主地址失败后退回 API 的 asset 地址。
  ///
  /// [onProgress] 收到 0..1;总长度拿不到时只在结束时回调 1。
  /// [onBytes] 收到 (已下载, 总大小),总大小未知时为 0——界面靠它显示
  /// "12.3 MB / 54.9 MB" 这种用户能判断"是不是在动"的数字。
  Future<List<int>> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytes,
    int maxAttempts = 3,
  }) async {
    final urls = <String>{
      if (info.downloadUrl.isNotEmpty) info.downloadUrl,
      if (info.apiDownloadUrl.isNotEmpty) info.apiDownloadUrl,
    }.toList();
    if (urls.isEmpty) throw UpdateException('这个版本没有可用的下载地址');

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final url = urls[attempt % urls.length];
      try {
        return await _downloadOnce(
          url,
          fallbackTotal: info.sizeBytes,
          onProgress: onProgress,
          onBytes: onBytes,
        );
      } on Exception catch (error) {
        lastError = error;
        // 退一步再试:立刻重连往往还是被同一个原因掐断。
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw UpdateException(
      '下载失败,试了 $maxAttempts 次。可以换 Wi-Fi 再试,'
      '或者到 GitHub 的 releases 页面手动下载。($lastError)',
    );
  }

  /// 单次流式下载。
  Future<List<int>> _downloadOnce(
    String url, {
    required int fallbackTotal,
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytes,
  }) async {
    final http.StreamedResponse response;
    try {
      response = await _http
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 30));
    } on Exception catch (error) {
      throw UpdateException('连不上下载服务器:$error');
    }
    if (response.statusCode != 200) {
      throw UpdateException('下载失败(${response.statusCode})');
    }

    // 服务端没给 Content-Length 时退回 release 里登记的大小,界面才有分母。
    final total = response.contentLength ?? fallbackTotal;
    final bytes = <int>[];
    onProgress?.call(0);
    onBytes?.call(0, total);

    // 回报节流:每收满总量的 2% 报一次,同时兜住"太频繁"和"太稀疏"两头。
    // 纯按字节数的话,慢网下每个 socket 块都不到阈值,全程可能只在结束时
    // 报一次;纯按时间的话,快网下又会漏掉整整一段进度(4KB 的小包就是这么
    // 撞上来的)。先攒够 128KB 再开始节流,是为了不让 54MB 的包刷出几千次
    // 界面重建。
    final minStep = 128 * 1024;
    final percentStep = total > 0 ? (total * 0.02).round() : minStep;
    final step = total > 0 && total < minStep
        ? (total / 4).ceil()
        : (percentStep > minStep ? percentStep : minStep);
    var lastReported = 0;

    void report(int received) {
      lastReported = received;
      onBytes?.call(received, total);
      if (total > 0) {
        onProgress?.call((received / total).clamp(0.0, 1.0));
      }
    }

    try {
      // 逐块加超时:连接建好之后对方一直不吐数据(网络假死、被中间设备静默
      // 丢弃)时不能无限等下去,否则用户看到的是一条永远停在原处的进度条。
      await for (final chunk in response.stream.timeout(
        _stallTimeout,
        onTimeout: (sink) => sink.addError(
          UpdateException('下载卡住了,对方不再发数据'),
        ),
      )) {
        bytes.addAll(chunk);
        if (bytes.length - lastReported < step) continue;
        report(bytes.length);
      }
    } on Exception catch (error) {
      // 读到一半断了:抛出去交给上层重试,这里不假装成功。
      // 先把已收到的字节报上去,界面上"下到一半断了"才看得出来。
      report(bytes.length);
      throw UpdateException('下载中断:$error');
    }

    if (total > 0 && bytes.length < total) {
      throw UpdateException('下载不完整(${bytes.length}/$total 字节)');
    }
    onBytes?.call(bytes.length, total);
    onProgress?.call(1);
    return bytes;
  }

  void dispose() => _http.close();
}

/// 检查或下载更新时出的错。
class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
