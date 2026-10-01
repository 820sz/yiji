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
  static ChatImage? parse(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith(marker)) return null;
    final ref = trimmed.substring(marker.length).trim();
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
}

/// 把用户发的图片存到应用私有目录,并给出消息里引用的文件名。
///
/// 存文件而不是存 base64:同一条消息里的图可能几百 KB,
/// 进库之后回看历史、搜索消息都会变慢。
class ChatImages {
  static Directory? _dir;

  /// 图片目录(不存在则建)。
  static Future<Directory> dir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
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
}
