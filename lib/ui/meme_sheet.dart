import 'package:flutter/material.dart';

import '../data/chat_attachment.dart';
import '../data/chat_images.dart';
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
                  // 点的时候把字节读出来一起带走。理由见 ChatAttachment.meme:
                  // 消息里统一记磁盘文件名,而不是两种引用并存——两种引用
                  // 已经害得用户见过"图不在了"和"AI 看不到图"。
                  onTap: () async {
                    final bytes = await ChatImages.memeBytes(meme);
                    if (!context.mounted) return;
                    Navigator.pop(
                      context,
                      ChatAttachment.meme(
                        assetPath: meme.assetPath,
                        caption: meme.caption,
                        tag: meme.tag,
                        bytes: bytes,
                      ),
                    );
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      color: dark ? AppTheme.darkBackground : AppTheme.lightBackground,
                      child: Image.asset(
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
