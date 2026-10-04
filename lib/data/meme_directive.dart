/// 从模型回复里抠出"要一张表情包"的指令。
///
/// 模型被要求在回复末尾单独写一行:
/// `[表情: 开心 | 蹦起来比心]`
/// 这一行是给系统看的,不能显示给用户。但流式输出是一段段到的,
/// 标记随时可能被切在两个字中间(例如刚收到 `[表情: 开`),
/// 所以解析要能处理"只收到一半"的情况:那时应当把标记之后的正文先藏起来,
/// 等收完整再连同标记一起去掉,而不是把半截标记当正文显示出去。
library;

/// 解析结果。
class MemeDirective {
  const MemeDirective({required this.text, this.emotion = '', this.query = ''});

  /// 去掉指令之后、能显示给用户的正文。
  final String text;

  /// 情绪词(可能为空)。
  final String emotion;

  /// 画面描述(可能为空)。
  final String query;

  bool get hasMeme => emotion.isNotEmpty || query.isNotEmpty;
}

/// 指令行的开头。用它找"是否已经开始输出指令"。
const _marker = '[表情';

/// 解析 [raw]。
///
/// 返回的 [MemeDirective.text] 已经去掉完整的指令行;如果只收到半个标记,
/// 则把标记起始位置之后的内容全部裁掉(因为那部分还没法判断是正文还是指令)。
MemeDirective stripMemeDirective(String raw) {
  final start = raw.indexOf(_marker);
  if (start < 0) return MemeDirective(text: raw);

  final head = raw.substring(0, start);
  final tail = raw.substring(start);

  // 先找闭合的 `]`。找不到说明这一行还没收完:正文只到标记之前。
  final close = tail.indexOf(']');
  if (close < 0) {
    return MemeDirective(text: head.trimRight());
  }

  final inner = tail.substring(1, close); // 去掉 `[` 和 `]`
  final directive = _parseInner(inner);

  // 指令行之后可能还有内容(模型偶尔会写点别的),保留下来。
  final rest = tail.substring(close + 1).trim();
  final body = rest.isEmpty ? head.trimRight() : '${head.trimRight()}\n$rest';

  return MemeDirective(
    text: body,
    emotion: directive.emotion,
    query: directive.query,
  );
}

/// 解析 `表情: <描述>` 里的内容。
///
/// **主格式是整条描述原文**:提示词把可选图片的清单摆给模型,要求它原样抄
/// 一行回来,所以方括号里就是一个 caption,里面通常没有竖线。
/// 抄回来的字要和库里的 caption 逐字比对(归一化后),多一个字都可能配不上图。
///
/// 同时兼容老的 `情绪 | 画面描述` 写法:那种拿不到精确匹配,只能退回
/// "情绪 + 关键词"检索,至少还能发一张同情绪的。
MemeDirective _parseInner(String inner) {
  // 去掉开头的"表情"两个字和紧随的分隔符。
  var body = inner;
  final colon = body.indexOf(RegExp(r'[:：]'));
  if (colon >= 0) {
    body = body.substring(colon + 1);
  } else if (body.startsWith('表情')) {
    body = body.substring(2);
  }
  body = body.trim();

  // 老格式:`情绪 | 描述`。只在竖线两侧都像"短情绪词"时才这么理解,
  // 免得把描述里本来就有的竖线当成分隔符。
  final bar = body.indexOf('|');
  if (bar > 0) {
    final emotion = body.substring(0, bar).trim();
    final query = body.substring(bar + 1).trim();
    // 情绪词很短(几个字),描述通常更长;两侧都非空才算老格式。
    if (emotion.isNotEmpty && query.isNotEmpty && emotion.length <= 6) {
      return MemeDirective(text: '', emotion: emotion, query: query);
    }
  }

  return MemeDirective(text: '', emotion: body, query: '');
}

/// 已经从库里挑好了图,把它写进消息正文。
///
/// 用统一的一行,回看历史时能直接渲染出那张图。
///
/// **必须传 [Meme.messageRef],不能传 [Meme.assetPath]。**
///
/// `assetPath` 永远返回 `memes/<file>`——那是**内置图**才有的包内路径。
/// 用户自添加的图在私有目录里,它的 `assetPath` 指向一个安装包里并不存在
/// 的文件,渲染必然失败成"图不在了"。`messageRef` 才是那个"两种来源各给
/// 一个正确引用"的东西(内置 → `asset:...`,用户 → 文件名)。
/// AI 发图这条路以前传的是 `assetPath`,所以它一挑到用户自己加的图就画不出来。
String memeLineFor(String ref) => ref.isEmpty ? '' : '![图] $ref';
