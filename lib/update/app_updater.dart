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
  });

  final String versionName;
  final int versionCode;

  /// APK 直链。
  final String downloadUrl;

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
    final parsed = _parseTag(tag);
    if (parsed == null) return null;
    // 只有比当前新才提示。用 versionCode 而不是字符串比较:
    // "0.10.0" 和 "0.9.0" 按字符串比会判反。
    if (parsed.code <= currentVersionCode) return null;

    return UpdateInfo(
      versionName: parsed.name,
      versionCode: parsed.code,
      downloadUrl: (apk['browser_download_url'] as String?) ?? '',
      notes: (release['body'] as String?)?.trim() ?? '',
      sizeBytes: (apk['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// 解析形如 `v0.4.0+4` 的 tag。
  ///
  /// `+N` 是 Android 的 versionCode;缺了它就没法判断新旧,返回 null。
  static ({String name, int code})? _parseTag(String tag) {
    final cleaned = tag.startsWith('v') ? tag.substring(1) : tag;
    if (cleaned.isEmpty) return null;

    final plus = cleaned.indexOf('+');
    final name = plus >= 0 ? cleaned.substring(0, plus) : cleaned;
    final code = plus >= 0 ? int.tryParse(cleaned.substring(plus + 1)) : null;
    if (name.isEmpty || code == null) return null;
    return (name: name, code: code);
  }

  /// 下载 APK 字节。
  ///
  /// 走浏览器直链(`browser_download_url`)而不是 API 的 asset 接口,
  /// 这样公开仓库也不需要 token。
  Future<List<int>> download(UpdateInfo info) async {
    final http.Response response;
    try {
      response = await _http.get(Uri.parse(info.downloadUrl));
    } on Exception catch (error) {
      throw UpdateException('下载失败:$error');
    }
    if (response.statusCode != 200) {
      throw UpdateException('下载失败(${response.statusCode})');
    }
    return response.bodyBytes;
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
