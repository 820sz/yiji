import 'dart:async';
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

  /// `asset:<包内路径>`、`data:image/...;base64,<字节>`,或本地文件名。
  final String ref;

  bool get isAsset => ref.startsWith('asset:');

  /// 图片字节直接写在消息里(自包含)。
  ///
  /// **这是"AI 发的图永远画得出来"的最后一道保险**:引用就是字节本身,
  /// 不需要去任何地方查文件,也就不存在"找不到"。
  /// 内置表情包普遍 30KB 上下,base64 之后约 46KB,一条消息完全承受得起。
  bool get isInline => ref.startsWith('data:image/');

  /// 内联字节(仅 [isInline] 时有意义)。
  Uint8List? get inlineBytes {
    if (!isInline) return null;
    final cached = _decoded[ref];
    if (cached != null) return cached;
    final comma = ref.indexOf(',');
    if (comma < 0) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(ref.substring(comma + 1));
    } catch (_) {
      return null;
    }
    if (_decoded.length >= decodedLimit) _decoded.remove(_decoded.keys.first);
    return _decoded[ref] = bytes;
  }

  /// 内联字节的解码缓存。
  ///
  /// **按引用串缓存,不是省 CPU 那么简单**:`Image.memory` 认图的键是字节对象的
  /// 身份,而每次 base64 解码都会造出一个新的 `Uint8List`。不缓存的话,气泡每重建
  /// 一次就等于换了一张新图——旧的缓存命中不了、要重新解码、重新走一遍加载态。
  /// 用户报的「聊天记录里有表情包时一划就卡帧闪烁」就是这条路径每帧解码一张图。
  static final Map<String, Uint8List> _decoded = <String, Uint8List>{};

  /// 缓存条数上限。一条消息一张图,60 张够覆盖几屏来回。
  static const decodedLimit = 60;

  /// 测试用:清掉解码缓存,免得住例之间互相影响。
  static void clearDecodedCache() => _decoded.clear();

  /// 测试用:当前缓存了多少条。
  static int get decodedCacheLength => _decoded.length;

  /// 包内路径(仅 [isAsset] 时有意义)。
  String get assetPath => ref.substring('asset:'.length);

  /// 文件名(不带目录、不带 `asset:` 前缀)。
  ///
  /// **内置引用也要靠它查磁盘**:以前这里直接返回整串 `ref`,于是拿它去查
  /// 文件时得到的是 `asset:memes/daily/x.webp` 这种"文件名",必然找不到。
  /// 用户报的"图不在了"里,那串诊断就写着这件事——
  /// `按文件名「asset:memes/daily/x.webp」…都没找到`。
  String get fileName => isInline
      ? ''
      : (isAsset
            ? assetPath.split('/').last
            : ref.split(RegExp(r'[/\\]')).last);

  /// 解析用:不是标记行返回 null。
  static ChatImage? parse(String line) {
    final trimmed = stripDecoration(line);
    if (!trimmed.startsWith(marker)) return null;
    final body = trimmed.substring(marker.length).trim();
    if (body.isEmpty) return null;
    // 竖线之后是说明,渲染时用不到,但它必须被容忍(不能当成引用的一部分)。
    final bar = body.indexOf('|');
    var ref = (bar < 0 ? body : body.substring(0, bar)).trim();
    // 路径里出现省略号说明是**模型自己打出来的**,不是真实路径。
    if (ref.isEmpty || ref.contains('...') || ref.contains('…')) return null;
    ref = _resolveCaptionRef(ref);
    return ChatImage(ref: ref);
  }

  /// 引用不像路径、却和某张图的描述对得上时,把它换回那张图的真实引用。
  ///
  /// 这是用户截图里那个 bug 的正面修法:模型偶尔会照着提示词里那个格式,
  /// 自己写一行 `![图] <清单里的描述>`。那一行里没有路径,渲染层只认引用,
  /// 于是显示成「图不在了」。**描述本身足够定位那张图**,所以在解析这一步
  /// 就认回去——渲染、给模型看的历史、落库前的归一化,全都跟着变对。
  ///
  /// 结果做缓存:`parse` 在渲染路径上每帧都会跑,而回查要遍历上百条描述。
  static String _resolveCaptionRef(String ref) {
    if (isInlineRef(ref) || _looksLikePath(ref)) return ref;
    final cached = _resolvedRefs[ref];
    if (cached != null) return cached.isEmpty ? ref : cached;
    final meme = MemeLibrary.cached?.matchByCaption(ref);
    _resolvedRefs[ref] = meme?.messageRef ?? '';
    return meme?.messageRef ?? ref;
  }

  /// 这串东西看起来像文件/路径吗。
  ///
  /// 像的话就按引用原样走(文件名、`asset:` 路径),不要拿它去匹配描述——
  /// 那既没意义,也会让"磁盘上有这个文件"的图被换成另一张。
  static bool _looksLikePath(String ref) {
    if (ref.contains('/') || ref.contains(r'\')) return true;
    return RegExp(
      r'\.(png|jpe?g|webp|gif|bmp|img)$',
      caseSensitive: false,
    ).hasMatch(ref);
  }

  /// `data:image/...` 开头。
  static bool isInlineRef(String ref) => ref.startsWith('data:image/');

  /// 描述回查的缓存:引用 → 认出来的真实引用(空串表示"查过,认不出来")。
  static final Map<String, String> _resolvedRefs = <String, String>{};

  /// 图库换了内容(用户加/删表情包)时清掉回查缓存。
  static void clearResolvedRefs() => _resolvedRefs.clear();

  /// 图片行里 `|` 之后那句说明(没有就返回空串)。
  ///
  /// 用户发图时会把表情包的描述挂在后面,模型靠它知道那张图是什么意思;
  /// 而**一句描述本身也应当能反过来定位到那张图**——见
  /// [MemeLibrary.matchByCaption]。
  static String captionOf(String line) {
    final body = stripDecoration(line);
    final bar = body.indexOf('|');
    return bar < 0 ? '' : body.substring(bar + 1).trim();
  }

  /// 去掉模型可能加上的装饰:反引号、列表符号、引用符号、加粗星号。
  ///
  /// 模型经常把这一行当代码写,输出 `` `![图] asset:...` `` 甚至
  /// `- \`![图] ...\``。带装饰的话解析直接落空,界面就把这一行原样显示成
  /// 文字——用户看到的是"图不在了"或者一串路径。
  static String stripDecoration(String line) {
    var text = line.trim();
    // 列表符号 / 引用符号
    text = text.replaceFirst(RegExp(r'^[-*>+]\s+'), '');
    // 反引号(整行包住的)
    text = text.replaceAll('`', '');
    // 加粗星号
    text = text.replaceAll('**', '');
    return text.trim();
  }

  /// 消息文本里的标记前缀。用 `![图]` 而不是自定义符号:一眼能看出是图片。
  static const marker = '![图]';
}

/// 表情包图库里的一条。
class Meme {
  const Meme({
    required this.file,
    required this.tag,
    required this.caption,
    required this.keywords,
    this.fromUser = false,
  });

  /// 相对 `assets/memes/` 的路径(内置),或相对用户图库目录的文件名(自添加)。
  final String file;

  /// 情绪分类:angry / confused / daily / happy / sad / shy / sleep / surprised / work。
  /// 用户自添加的图没有现成分类,统一落在 `mine`。
  final String tag;

  /// 一句中文描述。**AI 就是靠这句话挑图的**,所以用户自添加的图也要填。
  final String caption;

  /// 空格分隔的中文关键词。
  final String keywords;

  /// 是不是用户自己添加的(不在安装包里,在应用私有目录)。
  final bool fromUser;

  /// 消息里记的引用:内置的带 `asset:` 前缀,自添加的就是文件名。
  ///
  /// 两种来源共用一条消息格式,渲染和"把历史图再发给模型"都只需要认这个引用,
  /// 不必各自记两套逻辑。
  String get messageRef => fromUser ? file : 'asset:$assetPath';

  /// 内置图的包内路径。用户自添加的没有意义。
  String get assetPath => 'memes/$file';

  /// 给模型看的那个短 id(不带目录和扩展名,省 token)。
  String get id => p.basenameWithoutExtension(file);

  static Meme fromJson(Map<String, Object?> json, {bool fromUser = false}) => Meme(
        file: (json['file'] as String?) ?? '',
        tag: (json['tag'] as String?) ?? '',
        caption: (json['caption'] as String?) ?? '',
        keywords: (json['keywords'] as String?) ?? '',
        fromUser: fromUser,
      );

  Map<String, Object?> toJson() => {
        'file': file,
        'tag': tag,
        'caption': caption,
        'keywords': keywords,
      };

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
///
/// 图库由**两份来源合并**:
/// - 内置:安装包里的 108 张,只读;
/// - 用户自添加:应用私有目录里的 `user_memes/`,一份 JSON 索引 + 图片文件。
///
/// 合并之后,挑图、清单、渲染、手动挑选面板全都只看这一份结果,
/// 所以"以后自己加图"不需要改提示词或解析逻辑——这是刻意留的扩展点。
class MemeLibrary {
  MemeLibrary._(this.memes);

  /// 直接从一份索引建库,不读打包资源。
  ///
  /// 给"既要准备提示词、又要打真实接口"的测试用:读 assets 需要 widget 绑定,
  /// 而那个绑定会把所有真实 HTTP 变成 400——两者不能同时要。
  /// 这类测试改成从磁盘读 index.json 再走这个构造器,两个需求就都满足了。
  factory MemeLibrary.fromIndex(List<Meme> memes) => MemeLibrary._(memes);

  /// 解析一份索引 JSON(和 assets 里那份格式相同),返回条目。
  static List<Meme> parseIndex(Object? decoded, {bool fromUser = false}) {
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map)
          Meme.fromJson(item.cast<String, Object?>(), fromUser: fromUser),
    ].where((m) => m.file.isNotEmpty).toList();
  }

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

  /// 已经在内存里的那份图库(还没加载完时为 null)。
  ///
  /// 给**同步**的场合用:解析引用、渲染气泡这些地方不能 await 一次加载,
  /// 但顺手做一次内存查找是可以的(见 [ChatImage.parse])。
  static MemeLibrary? get cached => _cached;

  /// 直接给定图库(测试用)。
  ///
  /// widget 测试里 `rootBundle.loadString` 会**永远不返回**(不打日志也不报错),
  /// 所以不能靠等真实读取来准备图库——等它只会把用例挂死或者拿到空库。
  /// 测试把已经解析好的那份塞进来。
  static void primeForTest(MemeLibrary library) {
    _cached = library;
    ChatImage.clearResolvedRefs();
  }

  /// 读图库:**内置 + 用户自添加合并**。
  ///
  /// 读不到内置素材时返回空图库(某些构建变体没打包),不该让聊天崩掉;
  /// 用户那部分读不到也只是少几张,一样不该崩。
  static Future<MemeLibrary> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    var builtin = const <Meme>[];
    try {
      // **必须带超时**:资源读取卡住时那个 Future 既不打日志也不报错,
      // 就是永远不完成。没有超时的话整条调用链都会停在这里。
      final raw = await rootBundle
          .loadString(_indexPath)
          .timeout(const Duration(seconds: 5));
      builtin = parseIndex(jsonDecode(raw));
    } catch (_) {
      // 素材没打进包、或者读取卡住:表情包功能静默不可用,其余聊天功能照常。
    }

    final user = await ChatImages.loadUserMemes();
    // 用户添加的排在后面:内置那批有精心写好的分类和描述,先让它们参与匹配;
    // 用户那批是同分时的补充。
    return _cached = MemeLibrary._([...builtin, ...user]);
  }

  /// 丢掉缓存。用户添加/删除表情包之后要调一次,否则新图进不了清单。
  static void invalidate() {
    _cached = null;
    // 描述回查的结果也要一起作废:图库内容变了,同一句描述可能指向别的图。
    ChatImage.clearResolvedRefs();
    ChatImages.clearMemeBytesCache();
  }

  bool get isEmpty => memes.isEmpty;

  /// 用户自添加的那些。
  List<Meme> get userMemes =>
      [for (final meme in memes) if (meme.fromUser) meme];

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
    final exact = matchByCaption(caption, tag: tag);
    if (exact != null) return exact;
    // 都没对上就按关键词打分,最后还是不行才随机——宁可给一张同情绪的,
    // 也不要什么都不发(用户已经看到 AI 说"这个给你")。
    return pick(tag: tag, query: caption, seed: seed);
  }

  /// 只认**真的对得上**的描述,对不上就返回 null。
  ///
  /// 和 [pickByCaption] 的区别是**没有兜底**:它不做关键词打分、不随机抽。
  /// 用在"拿一句话去反查具体是哪张图"的场合(比如模型把清单里的描述当引用
  /// 写了出来)。那种场合随便给一张图是错的——用户会看到一张跟上下文无关的图,
  /// 比画不出来更奇怪。
  Meme? matchByCaption(String caption, {String? tag}) {
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
      // 两个方向都要求"短的那一串"够长:一句话里恰好含着一个很短的 caption
      // 是常事(关键词级别的词),那种巧合不该定到某一张图上去。
      if (wanted.length >= 5 && shown.contains(wanted)) return meme;
      if (shown.length >= 4 && wanted.contains(shown)) return meme;
    }
    return null;
  }

  /// 按**消息里可能出现的那串引用**找图。
  ///
  /// 一条消息里的引用有五种来历,这里全都认:
  /// - `data:image/...`:字节就在里面(不在这里处理,调用方自己有分支);
  /// - `asset:memes/<file>`:内置图;
  /// - `<file>` / `<id>`:自添加的图库文件名,或内置图的短 id;
  /// - **一句描述**:模型偶尔会把清单里的描述当成引用写进正文,
  ///   按描述反查就能把它救回成一张真实的图(而不是显示「图不在了」)。
  Meme? findByRef(String ref) {
    final text = ref.trim();
    if (text.isEmpty) return null;
    for (final meme in memes) {
      if (meme.messageRef == text ||
          meme.assetPath == text ||
          meme.file == text) {
        return meme;
      }
    }
    final name = text.split(RegExp(r'[/\\]')).last;
    for (final meme in memes) {
      if (p.basename(meme.file) == name || meme.id == text) return meme;
    }
    return matchByCaption(text);
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
      final all = byTag(tag);
      // **用户自己加的一张都不截。**
      //
      // 他加图的全部目的就是让 AI 能用上它;按 perTag 截掉的话,加到第七张
      // 之后前面几张就"消失"了——用户会认为"我加了 AI 却调不出来"。
      // 那批通常只有几张,全列出来不占多少 token。内置那批仍然按 perTag 截。
      final shown = <Meme>[
        ...all.where((meme) => meme.fromUser),
        ...all.where((meme) => !meme.fromUser).take(perTag),
      ];
      if (shown.isEmpty) continue;
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
    // 注意这里把 _dir 置空而不是设成 value:value 是**根**目录,
    // 而 dir() 返回的是它下面的 chat_images/ 子目录。
    // 直接写 _dir = value 会让后续读写落到根目录上,和真实布局不一致
    // (踩过一次:测试里文件写在根上,渲染却去 chat_images 找,永远找不到)。
    _dir = null;
    _override = value;
    _avatarDir = null;
    _userMemeDir = null;
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

  /// 用户自添加表情包的目录。
  ///
  /// 和内置素材分开放:内置的在安装包里只读,用户加的必须在私有目录里
  /// (否则升级安装包会把它们冲掉)。
  static Future<Directory> userMemeDir() async {
    final cached = _userMemeDir;
    if (cached != null) return cached;
    final base = await _base();
    final target = Directory(p.join(base.path, 'user_memes'));
    if (!await target.exists()) await target.create(recursive: true);
    return _userMemeDir = target;
  }

  static Directory? _userMemeDir;

  /// 用户表情包的索引文件名。
  static const _userIndexName = 'index.json';

  /// 读用户自添加的表情包索引。没有就返回空。
  static Future<List<Meme>> loadUserMemes() async {
    try {
      final dir = await userMemeDir();
      final index = File(p.join(dir.path, _userIndexName));
      if (!await index.exists()) return const [];
      final decoded = jsonDecode(await index.readAsString());
      // 索引里记了但文件被清理掉的条目要跳过,否则 AI 会挑到一张打不开的图。
      final entries = MemeLibrary.parseIndex(decoded, fromUser: true);
      final alive = <Meme>[];
      for (final meme in entries) {
        if (await File(p.join(dir.path, meme.file)).exists()) alive.add(meme);
      }
      return alive;
    } catch (_) {
      return const [];
    }
  }

  /// 加一张用户表情包,返回新条目。失败返回 null。
  ///
  /// [caption] 是**必须的**:AI 挑图靠的就是这句话,留空的话这张图
  /// 永远进不了它的候选清单——用户会以为加了却用不上。
  static Future<Meme?> addUserMeme({
    required Uint8List bytes,
    required String caption,
    String keywords = '',
    String tag = 'mine',
  }) async {
    final text = caption.trim();
    if (text.isEmpty) return null;
    try {
      final dir = await userMemeDir();
      final name = 'user_${DateTime.now().microsecondsSinceEpoch}.png';
      await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);

      final meme = Meme(
        file: name,
        tag: tag.trim().isEmpty ? 'mine' : tag.trim(),
        caption: text,
        keywords: keywords.trim(),
        fromUser: true,
      );
      final existing = await loadUserMemes();
      await _writeUserIndex(dir, [...existing, meme]);
      MemeLibrary.invalidate();
      return meme;
    } on Exception {
      return null;
    }
  }

  /// 删掉一张用户表情包(连同它的索引项和图片文件)。
  static Future<bool> removeUserMeme(Meme meme) async {
    if (!meme.fromUser) return false;
    try {
      final dir = await userMemeDir();
      final remaining =
          (await loadUserMemes()).where((m) => m.file != meme.file).toList();
      await _writeUserIndex(dir, remaining);
      final file = File(p.join(dir.path, meme.file));
      if (await file.exists()) await file.delete();
      MemeLibrary.invalidate();
      return true;
    } on Exception {
      return false;
    }
  }

  static Future<void> _writeUserIndex(Directory dir, List<Meme> memes) async {
    final index = File(p.join(dir.path, _userIndexName));
    await index.writeAsString(
      jsonEncode([for (final meme in memes) meme.toJson()]),
      flush: true,
    );
  }

  /// 取一张表情包的字节:内置的走 asset,用户自添加的走用户目录。
  static Future<Uint8List?> memeBytes(Meme meme) async {
    try {
      if (!meme.fromUser) {
        final data = await rootBundle.load('assets/${meme.assetPath}');
        return data.buffer.asUint8List();
      }
      final dir = await userMemeDir();
      final file = File(p.join(dir.path, meme.file));
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 用户表情包的字节,**带缓存**。
  ///
  /// 挑图面板是个网格,滚一下就会重建;每次都去读一遍文件既慢,又会让
  /// `Image.memory` 认成"另一张新图"重新解码。返回同一个字节对象就不会。
  static Future<Uint8List?> cachedMemeBytes(Meme meme) async {
    if (!meme.fromUser) return memeBytes(meme);
    final cached = _memeBytesCache[meme.file];
    if (cached != null) return cached;
    final bytes = await memeBytes(meme);
    if (bytes != null && bytes.isNotEmpty) _memeBytesCache[meme.file] = bytes;
    return bytes;
  }

  static final Map<String, Uint8List> _memeBytesCache = {};

  /// 用户图库变了之后要清一次,否则删了又加的图会拿着旧的字节。
  static void clearMemeBytesCache() => _memeBytesCache.clear();

  /// 取一张已保存的图。不存在返回 null。
  /// 取磁盘上的一张图。取不到就返回 null。
  ///
  /// 这里**不加 `.timeout`**:超时会挂一个定时器,而渲染是每帧都可能走的路径,
  /// 定时器还没回收就被拆掉时测试会直接报 "Pending timers"。
  /// 目录查找本身失败会抛异常,那条路由 catch 兜住。
  static Future<File?> file(String name) async {
    try {
      final directory = await dir();
      final file = File(p.join(directory.path, name));
      return await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// 同步版的 [file]。
  ///
  /// 目录已经知道时(测试注入了 [_override],或者之前查过一次)不必走异步:
  /// 少一次事件循环往返,渲染时能更快出图,也**不会在测试里留下 pending timer**
  /// (`Future.timeout` 会挂一个定时器,测试结束前没回收就直接报错)。
  static File? fileSync(String name) {
    final base = _dir ?? _override;
    if (base == null) return null;
    // 走的是和 dir() 同一套布局:`<根>/chat_images/<名>`,不是把根当目录。
    // 这里曾经把 override 直接当目录用,于是测试里文件写在一处、渲染找另一处。
    final root = _dir == null ? Directory('${_override!.path}/chat_images') : _dir!;
    if (!root.existsSync()) return null;
    final target = File('${root.path}/$name');
    return target.existsSync() ? target : null;
  }

  /// **测试用**:把目录解析固定下来,让同步路径立刻可用。
  ///
  /// widget 测试里 `getApplicationSupportDirectory()` 背后的平台通道不响应,
  /// 目录查询既不返回也不报错,`_DiskImage` 于是永远停在转圈上——
  /// 那是测试环境的性质,不是产品缺陷。给它一个确定的目录,测试才谈得上"验渲染"。
  static void pinDirectoryForTest(Directory dir) {
    _override = dir;
    final images = Directory(p.join(dir.path, 'chat_images'));
    // **必须真的建出来**:`dir()` 命中缓存就返回,不会再创建,
    // 于是写文件会静默失败(踩过:测试里 save 一直返回 null)。
    if (!images.existsSync()) images.createSync(recursive: true);
    _dir = images;
    _avatarDir = null;
    _userMemeDir = null;
  }

  /// 把消息文本里所有图片行的字节读成 data URL,供多模态请求使用。
  ///
  /// 用来**把历史里的图重新发给模型**。以前只有当前这一轮带图,历史只带
  /// `![图] asset:...` 这行文字——模型于是只能看到一句路径,完全不知道
  /// 用户当时发的是什么。用户的原话:"用户发的表情包,ai 看不到"。
  ///
  /// 读不到的条目直接跳过(文件被清理、asset 缺失),不阻断整次请求。
  static Future<List<String>> imageDataUrls(String content) async {
    final urls = <String>[];
    for (final line in content.split('\n')) {
      final image = ChatImage.parse(line);
      if (image == null) continue;
      final bytes = await bytesOf(image);
      if (bytes == null || bytes.isEmpty) continue;
      urls.add('data:image/${_mimeOf(image)};base64,${base64Encode(bytes)}');
    }
    return urls;
  }

  /// 取一张图的原始字节:内置的走 asset,用户自添加的走磁盘。
  ///
  /// 磁盘文件找不到时**回退到图库里的同一张**。
  ///
  /// **三个地方都要查**,少一个就会出现"图和库都在、引用也对,却显示图不在了":
  /// 1. 聊天图片目录(`chat_images/`)——用户发的照片在这里;
  /// 2. **用户表情包目录**(`user_memes/`)——用户自己加的图在这里,
  ///    它和聊天目录是两回事,以前这条回退只查了聊天目录,所以
  ///    自带表情包失败了就永远救不回来;
  /// 3. 安装包内的内置图——按文件名回查索引。
  static Future<Uint8List?> bytesOf(ChatImage image) async {
    try {
      // 自包含:字节就在引用里,不必查任何东西。
      final inline = image.inlineBytes;
      if (inline != null && inline.isNotEmpty) return inline;
      if (image.isAsset) {
        final data = await rootBundle.load('assets/${image.assetPath}');
        return data.buffer.asUint8List();
      }
      // **先用同步查询拿到确切结论。**
      //
      // 这条路径在"回答落库"和"把历史图发给模型"两条关键链上:一旦挂住,
      // 用户看到的是回答永远出不来。目录已知时同步查一次就有答案;
      // 目录还不知道时只让异步去把它准备好,不在这里等。
      final sync = fileSync(image.fileName);
      if (sync != null) {
        final bytes = await sync.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      } else {
        unawaited(_warmDirectory());
      }
      // 磁盘上没有:**用户表情包目录**和**图库**都还要查一次。
      // 只查聊天图片目录的话,用户自己加的图永远找不回来。
      return await _userMemeBytes(image.fileName) ??
          await _libraryFallback(image.ref);
    } catch (_) {
      return null;
    }
  }

  /// 把聊天图片目录准备好(不阻塞调用方)。
  static Future<void> _warmDirectory() async {
    try {
      await dir();
    } catch (_) {
      // 目录建不出来只是少一条查询路径,不影响别处。
    }
  }

  /// 从用户表情包目录里按文件名取字节。
  static Future<Uint8List?> _userMemeBytes(String fileName) async {
    try {
      final dir = await userMemeDir();
      final target = File(p.join(dir.path, fileName));
      if (!await target.exists()) return null;
      final bytes = await target.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  /// 按**消息里那串引用**回查图库:文件名、短 id、一句描述都认。
  ///
  /// 这是「图不在了」的最后一道救援:图其实好好在图库里,只是消息里那串字
  /// 不完全是它的路径(模型自己把描述写成了引用,历史版本写错过前缀……)。
  /// 认得出是哪张图,就能把它画出来,而不是给用户看一个破图占位。
  static Future<Uint8List?> _libraryFallback(String ref) async {
    try {
      // 图库本身可能卡住(资源读取),不能让它拖住渲染。
      final library = await MemeLibrary.load().timeout(
        const Duration(seconds: 3),
      );
      final meme = library.findByRef(ref);
      if (meme == null) return null;
      // 内置的走 asset,自添加的走用户目录,[memeBytes] 两种都认识。
      return await memeBytes(meme).timeout(const Duration(seconds: 3));
    } catch (_) {
      // 图库读不出来只是少一条退路,不影响别处。
    }
    return null;
  }

  /// 从文件名推 MIME 类型。
  static String mimeForName(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' => 'jpeg',
      '.webp' => 'webp',
      '.gif' => 'gif',
      '.bmp' => 'bmp',
      _ => 'png',
    };
  }

  static String _mimeOf(ChatImage image) =>
      mimeForName(image.isAsset ? image.assetPath : image.fileName);

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
