import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 下载 GitHub release 资产时可以借道的中转站。
///
/// **为什么需要它们**:用户在国内手机上点内置更新,报「下载不完整
/// (1418/65274459 字节)」——那是网络层塞回来的一张拦截页,直连 GitHub 的
/// 资产域名在这类网络下拿不到真文件。服务端本身完全正常(实测 302 到
/// Azure Blob、`Content-Length: 65274459`),问题只在"从这台设备够不着"。
///
/// 这些站点把 `github.com/...` 原样透传,实测返回的字节与直连**逐字节一致**
/// (前 16 字节三方相同:`50 4B 03 04 ...`)。
///
/// **顺序有讲究,而且是实测出来的**:`ghfast.top` 一开始能用,几十分钟后
/// 就连不上了(连接被重置)。这类免费中转随时会倒或限流,所以:
/// - 实测可用的排前面(当前 `gh-proxy.com` 连测 4 次全通);
/// - 直连永远排第一 —— 网络正常的人不该被中转拖慢;
/// - 失败就换下一个,全部试完才报错。
/// 它们是**尽力而为的退路**,不是保证。真下不动时还有系统下载器那条路。
const kGithubMirrors = <String>[
  'https://gh-proxy.com/',
  'https://ghfast.top/',
  'https://gh.llkk.cc/',
  'https://gh.zwy.one/',
  'https://ghproxy.cxkpro.top/',
];

/// 一次下载的总预算。
///
/// **必须有一个**。没有它,卡住就是永远卡住——用户看到的是一条停在 0% 的
/// 进度条,既不会失败也不会成功。有了它,最坏情况是几分钟后给一句能照做的提示。
///
/// 取 5 分钟:实测 62MB 的包在这条网络上跑完要 119 秒,120 秒的预算刚好卡在
/// 边界上、把一次成功的下载掐掉了(真踩到)。预算是"防死等"的兜底,不是速度
/// 指标,留够余量比掐得准重要。
const _totalBudget = Duration(minutes: 5);

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
    int maxAttempts = 6,
  }) async {
    final sink = BytesBuilder(copy: false);
    await _fetch(
      info,
      onProgress: onProgress,
      onBytes: onBytes,
      maxAttempts: maxAttempts,
      onChunk: sink.add,
    );
    return sink.takeBytes();
  }

  /// **并发竞速 + 边收边写盘**的下载。返回落盘后的文件。
  ///
  /// 这三件事都是从同一个人另一个跑得好好的项目(AI上外语)抄来的做法,
  /// 之前我一条都没做,所以更新一直下不动:
  ///
  /// 1. **边收边写盘**,不把整包读进内存。
  ///    62MB 的包读进 `List<int>` 是 6500 万个元素,反复扩容拷贝把堆压死——
  ///    表现是**不报错、不报进度、就停在 0%**。
  /// 2. **所有候选同时下**,谁先成谁算数,其余的立刻取消。
  ///    串行试错会卡死在"连上了但吐数据极慢"的那个源上——正是用户看到的画面。
  /// 3. **总预算硬超时**。没有它,卡住就是永远卡住;有了它,至少会报错让你重试。
  Future<File> downloadToFile(
    UpdateInfo info,
    File target, {
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytes,
  }) async {
    final candidates = _candidates(info);
    if (candidates.isEmpty) throw UpdateException('这个版本没有可用的下载地址');

    // 给内部闭包用的名字,免得和参数重名看不清。
    final onProgressCallback = onProgress;
    final onBytesCallback = onBytes;

    // 每个候选写自己的临时文件:并发时不能共用一个文件。
    final tmp = <int, File>{};
    final completed = Completer<File>();
    var settled = false;

    /// 已经收到的字节数(所有候选里的最大值)。界面直接用它显示
    /// "12.3 MB / 62.3 MB"——用户靠这两个数字判断"还在动没有"。
    var maxReceived = 0;

    /// 主动切断这个候选的下载。
    ///
    /// 不切断的话,输掉的那几个候选**会继续把 62MB 下完**——真机上就是
    /// 一次更新后目录里堆着几个 62MB 的残包,而且一直在偷占流量。
    /// 这里把消费端断掉(`await for` 退出即取消订阅),连接随之关闭。
    final cut = <int, Completer<void>>{};

    /// 清掉所有临时文件。收尾统一走这里,免得漏。
    Future<void> sweep() async {
      for (final part in tmp.values) {
        try {
          if (part.existsSync()) await part.delete();
        } catch (_) {
          // 还有句柄在写(刚被切断、尚未完全停下):留给下一次调用覆盖,
          // 不该因为清理失败就让整个更新失败。
        }
      }
    }

    Future<void> race(int index, String url) async {
      final part = File('${target.path}.$index.part');
      tmp[index] = part;
      final abort = cut[index] = Completer<void>();
      try {
        if (part.existsSync()) part.deleteSync();
        await _fetchOne(
          url,
          fallbackTotal: info.sizeBytes,
          abort: abort,
          onChunk: (chunk) {
            // 赢家已经出现:立刻停手,不要再往盘上写。
            if (settled) return;
            part.writeAsBytesSync(chunk, mode: FileMode.append);
          },
          onBegin: () async {
            if (part.existsSync()) part.deleteSync();
          },
          // **用真实字节数回报,不用比例。**
          //
          // 之前这里传的是 0..1 的比例,竞速层却当字节数收,两者量级差
          // 六个数量级——界面上那行"12.3 MB / 62.3 MB"因此几乎不动,
          // 看着就像卡死。走字节数这条最原始的信号,没有换算就没有差错。
          onBytes: (received) {
            if (settled) return;
            // 报所有候选里最大的那个:用户看到的是最快那条的进展。
            if (received > maxReceived) {
              maxReceived = received;
              onBytesCallback?.call(maxReceived, info.sizeBytes);
              if (info.sizeBytes > 0) {
                onProgressCallback?.call(
                  (maxReceived / info.sizeBytes).clamp(0.0, 1.0),
                );
              }
            }
          },
        );
        if (settled) return;
        // 竞速窗口内先校验,不合格的候选直接淘汰,让别的继续。
        final problem = await _verify(part, info.sizeBytes);
        if (problem != null) return;
        // **先落 settled,再改名。**
        // 顺序反了的话,别的候选会在改名这几毫秒里继续往同一个目录写,
        // 收尾时就会出现"目录不是空的"删不掉(测试里真踩到了)。
        settled = true;
        for (final entry in cut.entries) {
          if (entry.key != index && !entry.value.isCompleted) {
            entry.value.complete();
          }
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        if (!completed.isCompleted) completed.complete(target);
        await sweep();
      } catch (_) {
        // 单个候选失败或被切断:交给别的候选,总预算兜底。
        try {
          if (!settled && part.existsSync()) await part.delete();
        } catch (_) {
          // 句柄刚被切断时可能还删不掉,上面的 sweep 会再试。
        }
      }
    }

    for (var i = 0; i < candidates.length; i++) {
      unawaited(race(i, candidates[i]));
    }
    onProgress?.call(0);
    onBytes?.call(0, info.sizeBytes);

    final result = await completed.future.timeout(
      _totalBudget,
      onTimeout: () async {
        settled = true;
        for (final abort in cut.values) {
          if (!abort.isCompleted) abort.complete();
        }
        await sweep();
        throw UpdateException(
          '下载超时(${_totalBudget.inSeconds} 秒),直连和 ${kGithubMirrors.length} 个中转都试过了。'
          '换 Wi-Fi 或流量再试,也可以在更新弹窗里点「用系统下载器」,'
          '或者到 GitHub 的 releases 页面手动下载。',
        );
      },
    );
    onBytes?.call(info.sizeBytes, info.sizeBytes);
    onProgress?.call(1);
    return result;
  }

  /// 候选地址:直连在前(网络正常的人该走最快的那条),中转兜底,去重。
  static List<String> _candidates(UpdateInfo info) {
    final urls = <String>[
      if (info.downloadUrl.isNotEmpty) info.downloadUrl,
      if (info.apiDownloadUrl.isNotEmpty) info.apiDownloadUrl,
      for (final mirror in kGithubMirrors)
        if (info.downloadUrl.isNotEmpty) '$mirror${info.downloadUrl}',
    ];
    return <String>{
      for (final url in urls)
        if (url.isNotEmpty) url,
    }.toList();
  }

  /// 校验落盘的文件:大小 + zip 魔数。返回 null 表示通过。
  static Future<String?> _verify(File file, int expectedSize) async {
    if (!file.existsSync()) return '文件不存在';
    final length = await file.length();
    if (length <= 0) return '文件为空';
    if (expectedSize > 0 && length != expectedSize) {
      return '字节数不符(期望 $expectedSize,实际 $length)';
    }
    if (length < 100 * 1024) {
      return '只有 $length 字节,不像安装包(多半是网络的拦截页)';
    }
    final head = await file.openRead(0, 4).fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
    if (head.length < 4 ||
        head[0] != 0x50 ||
        head[1] != 0x4B ||
        head[2] != 0x03 ||
        head[3] != 0x04) {
      return '开头不是 zip 魔数(多半是网络的拦截页)';
    }
    return null;
  }

  /// 只做一次尝试的流式取包(竞速用,内部不再重试)。
  ///
  /// [abort] 完成时立刻退出读取:竞速里赢家已经出现,输掉的候选没必要把
  /// 剩下的几十兆下完。
  ///
  /// [onBytes] 收的是**真实字节数**(不是 0..1 的比例):竞速层要拿它比
  /// "谁下得多",比例没法比。
  Future<void> _fetchOne(
    String url, {
    required int fallbackTotal,
    required void Function(List<int> chunk) onChunk,
    Future<void> Function()? onBegin,
    void Function(int received)? onBytes,
    Completer<void>? abort,
  }) =>
      _downloadOnce(
        url,
        fallbackTotal: fallbackTotal,
        onChunk: onChunk,
        onBegin: onBegin,
        onBytes: (received, _) => onBytes?.call(received),
        abort: abort,
      );

  /// 公共的取包流程:按候选地址依次尝试,并把校验做全。
  ///
  /// 校验放在这里而不是各自的调用点:内容校验(大小、魔数)漏一处就等于没做。
  Future<void> _fetch(
    UpdateInfo info, {
    required void Function(List<int> chunk) onChunk,
    Future<void> Function()? onBegin,
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytes,
    int maxAttempts = 6,
  }) async {
    final urls = <String>{
      // 直连优先:网络通的人就该走最快的那条。
      if (info.downloadUrl.isNotEmpty) info.downloadUrl,
      if (info.apiDownloadUrl.isNotEmpty) info.apiDownloadUrl,
      // 直连够不着的时候,借道中转站。
      for (final mirror in kGithubMirrors)
        if (info.downloadUrl.isNotEmpty) '$mirror${info.downloadUrl}',
    }.toList();
    if (urls.isEmpty) throw UpdateException('这个版本没有可用的下载地址');

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final url = urls[attempt % urls.length];
      try {
        await _downloadOnce(
          url,
          fallbackTotal: info.sizeBytes,
          onProgress: onProgress,
          onBytes: onBytes,
          onChunk: onChunk,
          onBegin: onBegin,
        );
        return;
      } on Exception catch (error) {
        lastError = error;
        // 退一步再试:立刻重连往往还是被同一个原因掐断。
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw UpdateException(
      '下载失败,直连和几个中转都试过了。可以换 Wi-Fi 或流量再试,'
      '也可以到 GitHub 的 releases 页面手动下载。($lastError)',
    );
  }

  /// 单次流式下载。
  Future<void> _downloadOnce(
    String url, {
    required int fallbackTotal,
    required void Function(List<int> chunk) onChunk,
    Future<void> Function()? onBegin,
    void Function(double progress)? onProgress,
    void Function(int received, int total)? onBytes,
    Completer<void>? abort,
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
    await onBegin?.call();
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
    var received = 0;
    var lastReported = 0;

    // **只留开头这一小段**用于内容校验。
    //
    // 拿到前 4 字节就能判断是不是 zip;不保留整包,内存占用与包大小无关。
    final head = <int>[];

    void report() {
      lastReported = received;
      onBytes?.call(received, total);
      if (total > 0) {
        onProgress?.call((received / total).clamp(0.0, 1.0));
      }
    }

    // 被主动切断时从这里退出:`await for` 一退出就取消订阅、关掉连接,
    // 不会把剩下的几十兆下完。
    var aborted = false;
    if (abort != null) {
      unawaited(abort.future.then((_) => aborted = true));
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
        if (aborted) return;
        onChunk(chunk);
        if (head.length < 4) {
          head.addAll(chunk.take(4 - head.length));
        }
        received += chunk.length;
        if (received - lastReported < step) continue;
        report();
        // 报完再查一次:切断可能正好发生在这一块的处理过程中。
        if (aborted) return;
      }
    } on Exception catch (error) {
      // 读到一半断了:抛出去交给上层重试,这里不假装成功。
      // 先把已收到的字节报上去,界面上"下到一半断了"才看得出来。
      // 被切断不算"断了"——那是我们自己叫停的,不该报错吓人。
      if (aborted) return;
      report();
      throw UpdateException('下载中断:$error');
    }

    if (total > 0 && received < total) {
      throw UpdateException('下载不完整($received/$total 字节)');
    }
    // 明显太短的一定不对,直接当失败交给上层重试。
    //
    // 放在魔数检查之前:一张拦截页只有一两 KB,而真包装得下全世界也不会
    // 小于 100KB。先按大小挡一道,重试换地址往往就过去了。
    if (received < 100 * 1024) {
      throw UpdateException(
        '下载回来只有 $received 字节,不像安装包(多半是网络的拦截页)',
      );
    }
    // **内容也要验,不能只看字节数。**
    //
    // 用户报过「下载不完整(1418/65274459 字节)」。1418 字节根本不是"断了":
    // 那是网络层塞回来的一张 **HTML 拦截页**(运营商劫持、公司网关、DNS 劫持
    // 都会这么干),而它带着自己的 Content-Length 正常结束——于是"字节数够不够"
    // 这个检查完全看不出问题,一路走到落盘才因为大小不符报错。
    // 报出来的话还是"下载不完整",看不出真因,用户只会反复点重试。
    //
    // APK 就是个 zip,开头必须是 `PK\x03\x04`。这一步能把拦截页、301/302 的
    // 页面、以及各种"稍后再试"的提示页当场认出来,并给出能照做的提示。
    if (!_looksLikeApk(head)) {
      throw UpdateException(
        '下载到的不是安装包(收到 $received 字节,开头不是 zip 魔数)。'
        '多半是当前网络的拦截页,换 Wi-Fi 或流量再试,'
        '也可以到 GitHub 的 releases 页面手动下载。',
      );
    }
    onBytes?.call(received, total);
    onProgress?.call(1);
  }

  /// 头几个字节是不是 zip 的魔数。
  ///
  /// 用魔数而不是 Content-Type:拦截页也会自称 `application/vnd.android.package-archive`,
  /// 而魔数没法伪造——内容是 HTML 就是 HTML。
  static bool _looksLikeApk(List<int> bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x50 && // P
        bytes[1] == 0x4B && // K
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
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
