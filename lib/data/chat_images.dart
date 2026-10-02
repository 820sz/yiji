import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 聊天里出现的一份图片素材。
///
/// 两种来源:
/// - 用户自己发的图:字节落到应用私有目录里,消息里只记文件名;
/// - 内置表情包:打进 APK 的 assets,消息里记 `asset:...` 路径。
///
/// 之所以不把图片字节直接塞进消息文本,是因为聊天记录要能长期保存:
/// base64 进库会让每条消息膨胀几百 KB,回看历史和查库都会变慢。
class ChatImage {
  const ChatImage({required this.ref});

  /// `asset:<包内路径>` 或本地文件名(相对 [ChatImages.dir] )。
  final String ref;

  bool get isAsset => ref.startsWith('asset:');

  /// 包内路径(仅 [isAsset] 时有意义)。
  String get assetPath => ref.substring('asset:'.length);

  /// 本地文件(仅 [isAsset] 为假时有意义)。
  String get fileName => ref;

  /// 消息文本里的标记前缀。用 `![图]` 而不是自定义符号:一眼能看出是图片。
  static const marker = '![图]';

  /// 从消息文本里解析出这一行的图片标记;不是标记行返回 null。
  ///
  /// 行尾可以跟一段说明(`![图] asset:... | 被摸头眯眼冒爱心`),那是给 AI 看的:
  /// 它看不到图,但需要知道用户发的是哪张表情包、什么情绪,不然接不上梗。
  static ChatImage? parse(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(marker)) return null;
    final body = trimmed.substring(marker.length).trim();
    if (body.isEmpty) return null;
    // 竖线之后是说明,渲染时用不到,但它必须被容忍(不能当成引用的一部分)。
    final bar = body.indexOf('|');
    final ref = (bar < 0 ? body : body.substring(0, bar)).trim();
    return ref.isEmpty ? null : ChatImage(ref: ref);
  }
}

/// 表情包图库里的一条。
class Meme {
  const Meme({
    required this.file,
    required this.tag,
    required this.caption,
    required this.keywords,
  });

  /// 相对 `assets/memes/` 的路径,例如 `happy/123.webp`。
  final String file;

  /// 情绪分类:angry / confused / daily / happy / sad / shy / sleep / surprised / work。
  final String tag;

  /// 一句中文描述,用来展示和给模型参考。
  final String caption;

  /// 空格分隔的中文关键词。
  final String keywords;

  String get assetPath => 'memes/$file';

  /// 给模型看的那个短 id(不带目录和扩展名,省 token)。
  String get id => p.basenameWithoutExtension(file);

  static Meme fromJson(Map<String, Object?> json) => Meme(
        file: (json['file'] as String?) ?? '',
        tag: (json['tag'] as String?) ?? '',
        caption: (json['caption'] as String?) ?? '',
        keywords: (json['keywords'] as String?) ?? '',
      );

  /// 检索用的词袋:描述 + 关键词。
  List<String> get haystack => [
        ...keywords.split(RegExp(r'\s+')),
        caption,
      ].where((w) => w.isNotEmpty).toList();
}

/// 表情包图库。
///
/// 索引随 APK 打包(assets/memes/index.json),所以**离线也能发表情包**,
/// 不需要联网、不需要额外下载。图本身按需从 asset 取,不进内存。
class MemeLibrary {
  MemeLibrary._(this.memes);

  final List<Meme> memes;

  static const _indexPath = 'assets/memes/index.json';

  /// 中文情绪词 → 标签。模型回复里往往是"开心""无语"这类词,
  /// 而图库的标签是英文的,这里做一层对应。
  static const _emotionTags = <String, String>{
    '开心': 'happy', '高兴': 'happy', '笑': 'happy', '哈哈': 'happy',
    '喜欢': 'happy', '可爱': 'happy', '赞': 'happy', '好耶': 'happy',
    '生气': 'angry', '气': 'angry', '怒': 'angry', '火大': 'angry',
    '烦躁': 'angry', '催': 'angry',
    '难过': 'sad', '伤心': 'sad', '哭': 'sad', '累': 'sad', 'emo': 'sad',
    '沮丧': 'sad', '无语': 'sad', '求饶': 'sad', '可怜': 'sad',
    '害羞': 'shy', '羞': 'shy', '不好意思': 'shy', '脸红': 'shy',
    '困惑': 'confused', '不解': 'confused', '疑惑': 'confused', '问号': 'confused',
    '惊讶': 'surprised', '惊': 'surprised', '震惊': 'surprised', '没想到': 'surprised',
    '睡': 'sleep', '困': 'sleep', '晚安': 'sleep', '睡觉': 'sleep',
    '工作': 'work', '上班': 'work', '干活': 'work', '加班': 'work',
    '日常': 'daily', '摸鱼': 'daily', '吃饭': 'daily', '躺': 'daily',
  };

  static MemeLibrary? _cached;

  /// 读图库。读不到时返回空图库(没打包素材也不该让聊天崩掉)。
  static Future<MemeLibrary> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      final raw = await rootBundle.loadString(_indexPath);
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _cached = MemeLibrary._(const []);
      final memes = [
        for (final item in decoded)
          if (item is Map) Meme.fromJson(item.cast<String, Object?>()),
      ].where((m) => m.file.isNotEmpty).toList();
      return _cached = MemeLibrary._(memes);
    } catch (_) {
      // 素材没打进包(比如某些构建变体)时,表情包功能静默不可用,
      // 其余聊天功能照常。
      return _cached = MemeLibrary._(const []);
    }
  }

  bool get isEmpty => memes.isEmpty;

  /// 所有出现过的情绪标签,按字母序,供用户手动挑。
  List<String> get tags {
    final set = <String>{for (final meme in memes) meme.tag};
    return set.toList()..sort();
  }

  List<Meme> byTag(String tag) =>
      [for (final meme in memes) if (meme.tag == tag) meme];

  /// 把模型给的情绪词(往往是中文"开心""无语")映射到图库标签。
  ///
  /// 模型不一定知道我们有哪些标签,所以先做这层对应;认不出时返回 null,
  /// 调用方就在全部图里按关键词找。
  String? tagForEmotion(String emotion) {
    final text = emotion.trim().toLowerCase();
    if (text.isEmpty) return null;
    // 英文标签直接命中。
    for (final tag in tags) {
      if (tag.toLowerCase() == text) return tag;
    }
    for (final entry in _emotionTags.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// 在指定情绪里找带 [query] 的图;query 为空就随机抽一张。
  /// [seed] 用于让同样的问题得到同样的图(同一句话不该每次换一张)。
  Meme? pick({String? tag, String query = '', int seed = 0}) {
    if (memes.isEmpty) return null;
    var pool = tag == null || tag.isEmpty ? memes : byTag(tag);
    if (pool.isEmpty) pool = memes;

    if (query.trim().isNotEmpty) {
      final words = query
          .split(RegExp(r'[\s,、。!?;,]+'))
          .where((w) => w.trim().isNotEmpty)
          .toList();
      final scored = <(Meme, int)>[];
      for (final meme in pool) {
        var score = 0;
        for (final word in words) {
          for (final hay in meme.haystack) {
            if (hay.contains(word) || word.contains(hay)) score++;
          }
        }
        if (score > 0) scored.add((meme, score));
      }
      if (scored.isNotEmpty) {
        scored.sort((a, b) => b.$2.compareTo(a.$2));
        return scored.first.$1;
      }
    }
    return pool[seed.abs() % pool.length];
  }

  /// 按**模型抄回来的描述**挑图。
  ///
  /// 这是挑图的主路径,学的是 dsh-meme 的做法:提示词里把每张图的描述列给模型,
  /// 要求它**原样抄一条**回来,这里再拿抄回来的字符串去精确定位那张图。
  ///
  /// 为什么不继续用"模型自己编一个画面描述,再拿描述去搜":
  /// 模型的描述是自由发挥的,和库里预写的 caption 几乎不会逐字相同;
  /// 它写"超爽蹦起来",库里是"抱着抱枕打滚笑",搜索命中不了、只能退回随机抽,
  /// 于是用户看到的就是"AI 发的图跟说的话对不上"或者干脆发不出来。
  /// 抄描述这条路把"挑图"变成了**闭集选择**,选错也只会选到库里的另一张,
  /// 不会出现配不上图的情况。
  ///
  /// 匹配顺序:整条描述精确相等 → 描述互相包含 → 关键词打分。
  Meme? pickByCaption(String caption, {String? tag, int seed = 0}) {
    if (memes.isEmpty) return null;
    final wanted = _normalize(caption);
    if (wanted.isEmpty) return null;

    final pool = tag == null || tag.isEmpty ? memes : byTag(tag);
    final searchIn = pool.isEmpty ? memes : pool;

    for (final meme in searchIn) {
      if (_normalize(meme.caption) == wanted) return meme;
    }
    for (final meme in searchIn) {
      final shown = _normalize(meme.caption);
      if (shown.isEmpty) continue;
      if (shown.contains(wanted) || wanted.contains(shown)) return meme;
    }
    // 都没对上就按关键词打分,最后还是不行才随机——宁可给一张同情绪的,
    // 也不要什么都不发(用户已经看到 AI 说"这个给你")。
    final picked = pick(tag: tag, query: caption, seed: seed);
    return picked;
  }

  /// 比较用:去掉空白与标点、统一大小写。模型抄回来时可能少个逗号或加个句号。
  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[\s,、。.!?;:;:""''「」【】()()]'), '');

  /// 生成给模型看的"可选图片清单"。
  ///
  /// 每行是 `情绪 | 描述`,描述就是挑图时要**原样抄回来**的那串字。
  /// 只有把候选摆到模型面前,它才可能抄,而不是自己编一个画面描述。
  ///
  /// [perTag] 控制每个情绪最多列几张:全列出来要上千 token,而这个清单
  /// 每次请求都要带,长期下来不划算。每个情绪给几张足够它挑出贴题的。
  String catalogPrompt({int perTag = 6}) {
    if (memes.isEmpty) return '';
    final buffer = StringBuffer();
    for (final tag in tags) {
      final shown = byTag(tag).take(perTag).toList();
      buffer.writeln('【$tag】');
      for (final meme in shown) {
        buffer.writeln('  ${meme.caption}');
      }
    }
    return buffer.toString();
  }
}

/// 把用户发的图片存到应用私有目录,并给出消息里引用的文件名。
///
/// 存文件而不是存 base64:同一条消息里的图可能几百 KB,
/// 进库之后回看历史、搜索消息都会变慢。
class ChatImages {
  static Directory? _dir;

  /// 测试用的目录覆盖。同时作为图片目录和头像目录的根。
  ///
  /// 测试环境没有 path_provider 的平台通道,`getApplicationSupportDirectory()`
  /// 会抛 MissingPluginException;给测试一个明确的注入口,比到处兜 Error 干净。
  static set directoryOverride(Directory? value) {
    _dir = value;
    _override = value;
    _avatarDir = null;
  }

  static Directory? _override;
  static Directory? _avatarDir;

  /// 取根目录:优先测试覆盖,否则问系统。
  static Future<Directory> _base() async =>
      _override ?? await getApplicationSupportDirectory();

  /// 图片目录(不存在则建)。
  static Future<Directory> dir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await _base();
    final target = Directory(p.join(base.path, 'chat_images'));
    if (!await target.exists()) await target.create(recursive: true);
    return _dir = target;
  }

  /// 存一份图片,返回文件名。失败返回 null(调用方按"没带上"处理)。
  static Future<String?> save(Uint8List bytes, String originalName) async {
    try {
      final directory = await dir();
      // 文件名带时间戳,避免同名覆盖;保留扩展名,便于排查。
      final ext = p.extension(originalName).isEmpty ? '.img' : p.extension(originalName);
      final name = '${DateTime.now().microsecondsSinceEpoch}$ext';
      await File(p.join(directory.path, name)).writeAsBytes(bytes, flush: true);
      return name;
    } on Exception {
      return null;
    }
  }

  /// 取一张已保存的图。不存在返回 null。
  static Future<File?> file(String name) async {
    try {
      final directory = await dir();
      final file = File(p.join(directory.path, name));
      return await file.exists() ? file : null;
    } on Exception {
      return null;
    }
  }

  /// 头像目录。和聊天图片分开放,便于整目录清理。
  static Future<Directory> avatarDir() async {
    final cached = _avatarDir;
    if (cached != null) return cached;
    final base = await _base();
    final target = Directory(p.join(base.path, 'avatars'));
    if (!await target.exists()) await target.create(recursive: true);
    return _avatarDir = target;
  }

  /// 保存一张头像,返回**文件名**(不是完整路径)。
  ///
  /// 头像以前是 base64 直接写进数据库的一行。512×512 的 PNG 编码出来
  /// 几百 KB,base64 之后还要再涨三分之一,写起来又慢又容易失败——
  /// 用户报的"调完大小形状就保存不上"就是这个。改成写文件之后,
  /// 库里只留一个短文件名,读写都变成常量级的。
  ///
  /// [key] 用来区分不同的头像位(比如 `conversation_3`、`user`)。
  static Future<String?> saveAvatar(String key, Uint8List bytes) async {
    try {
      final directory = await avatarDir();
      // 同一 key 换图时旧文件要删掉,否则换十次头像就是十份垃圾。
      // 先写新文件再删旧的:万一写到一半失败,旧头像还在。
      final name = '${key}_${DateTime.now().microsecondsSinceEpoch}.png';
      final target = File(p.join(directory.path, name));
      await target.writeAsBytes(bytes, flush: true);
      await _removeOtherAvatars(directory, key, keep: name);
      return name;
    } on Exception {
      return null;
    }
  }

  /// 删掉同一个 key 下的旧头像文件。
  static Future<void> _removeOtherAvatars(
    Directory directory,
    String key, {
    required String keep,
  }) async {
    final prefix = '${key}_';
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix) || name == keep) continue;
      try {
        await entity.delete();
      } on Exception {
        // 删不掉就留着:多占一点空间而已,不该让换头像失败。
      }
    }
  }

  /// 读一张头像文件。不存在返回 null。
  static Future<Uint8List?> readAvatar(String name) async {
    try {
      final directory = await avatarDir();
      final file = File(p.join(directory.path, name));
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on Exception {
      return null;
    }
  }
}
