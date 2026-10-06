/// 消息里的图片行:统一怎么解析、怎么归一化、怎么给模型看。
///
/// 这一层存在的理由是一个反复出问题的 bug:用户不止一次看到 AI 发来的图变成
/// 「图不在了」。查下来引用串有各种来历——模型自己照着格式写的一行、旧版本
/// 写错的路径、用户自添加的图、一句描述……渲染层每遇到一种就补一个分支,
/// 补到最后还是漏。
///
/// 所以改成一条规则:**消息里留下的图片行,必须是画得出来的**。
/// 落库之前把它归一化成自包含的字节;归一化不了的整行不留。
library;

import 'dart:convert';

import 'chat_images.dart';

/// 把一串引用变成**自包含**的 data URL。解析不出来返回 null。
///
/// 认清三种来历:字节已经在引用里、资产/磁盘文件名、以及**一句描述**
/// (模型把图库清单里的描述当成引用写了出来,按描述反查就能救回那张图)。
///
/// 全程带超时:这条路径在"回答落库"上,而读打包资源的 Future 在异常情况下
/// **既不报错也不完成**——那会把落库整个挂住(用户看到的是回答永远出不来)。
Future<String?> inlineRefFor(String rawRef, {MemeLibrary? library}) async {
  const budget = Duration(seconds: 3);
  final ref = rawRef.trim();
  if (ref.isEmpty) return null;

  final image = ChatImage(ref: ref);
  if (image.isInline) {
    final bytes = image.inlineBytes;
    return bytes == null || bytes.isEmpty ? null : ref;
  }

  try {
    final lib = library ?? await _loadLibrary();
    final meme = lib?.findByRef(ref);
    if (meme != null) {
      final bytes = await ChatImages.memeBytes(meme).timeout(budget);
      if (bytes != null && bytes.isNotEmpty) return _dataUrl(meme.file, bytes);
    }

    final bytes = await ChatImages.bytesOf(image).timeout(budget);
    if (bytes == null || bytes.isEmpty) return null;
    final name = image.isAsset ? image.assetPath : image.fileName;
    return _dataUrl(name, bytes);
  } on Exception {
    // 超时或读字节失败都按"解析不出来"处理:调用方据此决定留不留这一行。
    return null;
  }
}

/// 把正文里所有图片行归一化。
///
/// 能解析出字节的写回自包含的 data URL;**解析不出来的整行删掉**——
/// 留一条永远画不出来的引用,就是给用户留一个「图不在了」,
/// 而且那条历史再也修不回来。
Future<String> normalizeImageLines(String text, {MemeLibrary? library}) async {
  if (!text.contains(ChatImage.marker)) return text;
  final kept = <String>[];
  for (final line in text.split('\n')) {
    final image = ChatImage.parse(line);
    if (image == null) {
      kept.add(line);
      continue;
    }
    final inline = await inlineRefFor(image.ref, library: library);
    if (inline == null) continue;
    // 说明(如果有)跟着一起留下:它不影响渲染,但看历史时是那句话的来源。
    final caption = ChatImage.captionOf(line);
    kept.add(
      caption.isEmpty
          ? '${ChatImage.marker} $inline'
          : '${ChatImage.marker} $inline | $caption',
    );
  }
  return kept.join('\n').trim();
}

/// 一条消息文本 → **发给模型的**文本。
///
/// 存下来的正文里有两种东西不能给模型:
/// - **内联的 base64**:一张图几十 KB,几条就够把上下文挤爆,而模型看不出
///   这些字符有什么意义;
/// - **`![图] ...` 这个格式本身**:提示词里用它举过一次例,模型会照着模仿,
///   把它想要的那张图也写成一行——而那一行里的东西并不是路径,渲染层只认引用,
///   最后就显示成「图不在了」。给模型的版本改成纯文字,这个模仿就没有了对象。
String projectForModel(String stored, {required bool isUser}) {
  if (!stored.contains(ChatImage.marker)) return stored;
  final who = isUser ? '他发的图' : '我发的图';
  final lines = <String>[];
  for (final line in stored.split('\n')) {
    if (ChatImage.parse(line) == null) {
      lines.add(line);
      continue;
    }
    final caption = ChatImage.captionOf(line);
    lines.add(caption.isEmpty ? '[$who]' : '[$who:$caption]');
  }
  return lines.join('\n').trim();
}

/// 正文里有没有图片行。
bool hasImageLine(String text) =>
    text.contains(ChatImage.marker) &&
    text.split('\n').any((line) => ChatImage.parse(line) != null);

String _dataUrl(String name, List<int> bytes) =>
    'data:image/${ChatImages.mimeForName(name)};base64,${base64Encode(bytes)}';

Future<MemeLibrary?> _loadLibrary() async {
  try {
    return await MemeLibrary.load().timeout(const Duration(seconds: 5));
  } catch (_) {
    // 图库读不出来只是少一条救援路径;调用方还会走磁盘/资产那两条。
    return null;
  }
}
