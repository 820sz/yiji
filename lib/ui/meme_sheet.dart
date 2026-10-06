import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/chat_attachment.dart';
import '../data/chat_images.dart';
import '../state/app_state.dart';
import 'image_cropper.dart';
import 'theme.dart';

/// 挑一张表情包。
///
/// 与 AI 自动发表情包并存:AI 挑的是它觉得贴题的那张,这一层是用户自己的选择。
/// 分类按图库的 tag 走(开心 / 无语 / 累 / 生气……),而不是按文件名——
/// 文件名是时间戳,认不出任何东西。
Future<ChatAttachment?> showMemeSheet(BuildContext context) async {
  return showModalBottomSheet<ChatAttachment>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _MemeSheet(),
  );
}

class _MemeSheet extends StatefulWidget {
  const _MemeSheet();

  @override
  State<_MemeSheet> createState() => _MemeSheetState();
}

class _MemeSheetState extends State<_MemeSheet> {
  MemeLibrary? _library;
  String? _tag;

  /// tag 的中文名。图库自己的 tag 是英文的(要跟 DB 的语义标注一致),
  /// 但给用户看的分类名得是中文。
  static const _tagLabels = <String, String>{
    'happy': '开心',
    'angry': '生气',
    'sad': '无语 / 难过',
    'shy': '害羞',
    'confused': '困惑',
    'surprised': '惊讶',
    'sleep': '困了',
    'work': '工作',
    'daily': '日常',
  };

  static String labelOf(String tag) => _tagLabels[tag] ?? tag;

  /// 添加一张自己的表情包:选图 → 裁成方形 → **手填一句描述**。
  ///
  /// 描述是必填的,不是走过场:AI 就是靠这句话挑图的(它从清单里抄一条,
  /// 系统按描述精确定位)。没有描述,这张图永远进不了候选清单——
  /// 用户会以为加了却用不上,那比不给入口更糟。
  Future<void> _addMeme() async {
    // 把所有 BuildContext 的使用都在同一个 mounted 检查下完成:
    // 中途 await 了好几次,用错层的 context 会被 lint 拦下来(lint 是对的)。
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 90,
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;

      final cropped = await showImageCropper(
        context,
        bytes: bytes,
        aspect: 1,
        withShape: false,
      );
      if (cropped == null || !mounted) return;

      final caption = await _askCaption(context);
      if (caption == null || caption.trim().isEmpty || !mounted) return;

      final added = await ChatImages.addUserMeme(
        bytes: cropped.bytes,
        caption: caption.trim(),
      );
      if (!mounted) return;
      if (added == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('这张没存上,再试一次')),
        );
        return;
      }
      // 图库换了内容,重新读一遍,新图立刻出现在面板里。
      // addUserMeme 内部已经 invalidate 过缓存,这里拿到的是含新图的那份。
      final refreshed = await MemeLibrary.load();
      if (!mounted) return;
      setState(() {
        _library = refreshed;
        _tag = 'mine';
      });
      // **还要刷新 AI 那一份。**
      //
      // 提示词里的候选清单是启动时准备好的另一份拷贝;不刷新的话,新加的图
      // 这一整个会话都进不了模型的清单——用户会以为"我加了,AI 还是调不出来"。
      await AppScope.of(context).refreshMemeCatalog();
      messenger.showSnackBar(
        const SnackBar(content: Text('加好了,AI 现在也能挑到它')),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('加表情包失败:$error')));
    }
  }

  /// 问用户一句描述。返回 null 表示他取消了。
  Future<String?> _askCaption(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('给它写一句描述'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI 靠这句话认图——它挑图时就是从这些描述里选一条。'
              '写清"画面里是什么、什么情绪"最好用。',
              style: TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: '比如:抱着抱枕打滚笑,开心到冒泡',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('加进图库'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  void initState() {
    super.initState();
    MemeLibrary.load().then((library) {
      if (!mounted) return;
      setState(() {
        _library = library;
        _tag = library.tags.isEmpty ? null : library.tags.first;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final library = _library;

    if (library == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (library.isEmpty) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Text(
            '表情包还没打进这个安装包',
            style: TextStyle(fontSize: 14, color: textSecondary),
          ),
        ),
      );
    }

    final tag = _tag ?? library.tags.first;
    final memes = library.byTag(tag);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                Text(
                  '表情包',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                  ),
                ),
                const Spacer(),
                // 添加自己的表情包。
                //
                // 存储和匹配两层早就做好了(addUserMeme / 图库合并 / AI 清单
                // 跟着变),但**一直没有入口**——用户说"表情包添加功能也没有",
                // 就是这里缺的。
                IconButton(
                  onPressed: _addMeme,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
                  tooltip: '添加自己的表情包',
                  visualDensity: VisualDensity.compact,
                ),
                Text(
                  '共 ${library.memes.length} 张',
                  style: TextStyle(fontSize: 12, color: textSecondary),
                ),
              ],
            ),
          ),
          // 分类横排。用滚动而不是 Wrap:标签多了会把列表挤下去。
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final t in library.tags)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(labelOf(t)),
                      selected: t == tag,
                      onSelected: (_) => setState(() => _tag = t),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: GridView.builder(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: memes.length,
              itemBuilder: (context, index) {
                final meme = memes[index];
                return GestureDetector(
                  // 内置图直接用 asset 引用带走,不读字节、不落盘。
                  // 用户自添加的图在私有目录里,只能靠文件名引用,所以要读字节。
                  onTap: () async {
                    final bytes =
                        meme.fromUser ? await ChatImages.memeBytes(meme) : null;
                    if (!context.mounted) return;
                    Navigator.pop(
                      context,
                      ChatAttachment.meme(
                        assetPath: meme.assetPath,
                        caption: meme.caption,
                        tag: meme.tag,
                        bytes: bytes,
                        fromUser: meme.fromUser,
                      ),
                    );
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      color: dark ? AppTheme.darkBackground : AppTheme.lightBackground,
                      // **用户自己加的那批不在安装包里**,`Image.asset` 只会画出
                      // 一张破图(用户报的"自己加的图在库里显示不出来")。
                      // 它们得从私有目录读字节来画。
                      child: meme.fromUser
                          ? _UserMemeThumb(meme: meme, caption: meme.caption)
                          : Image.asset(
                              'assets/${meme.assetPath}',
                              fit: BoxFit.contain,
                              // 描述作为语义标签:读屏用户听得到这是哪张图。
                              semanticLabel: meme.caption,
                              errorBuilder: (context, error, stack) => Icon(
                                Icons.broken_image_outlined,
                                size: 20,
                                color: textSecondary,
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户自己加的那张图:从私有目录读字节来画。
///
/// `Image.asset` 画不了它——那张图不在安装包里,只有文件名是对的,
/// 画出来就是一张破图(用户报的"我加的图在表情包库里显示不出来")。
/// 字节读一次就缓存住([ChatImages.cachedMemeBytes]):滚动重建时既不重复读盘,
/// 也不会让 `Image.memory` 认成另一张图重新解码。
class _UserMemeThumb extends StatefulWidget {
  const _UserMemeThumb({required this.meme, required this.caption});

  final Meme meme;
  final String caption;

  @override
  State<_UserMemeThumb> createState() => _UserMemeThumbState();
}

class _UserMemeThumbState extends State<_UserMemeThumb> {
  Uint8List? _bytes;
  var _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final bytes = await ChatImages.cachedMemeBytes(widget.meme);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      // 还在读,或者真读不出来(文件被系统清理过):给个不刺眼的占位。
      if (!_done) {
        return const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      return const Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 20,
          color: Color(0xFF9EA3AC),
        ),
      );
    }
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      semanticLabel: widget.caption,
    );
  }
}
