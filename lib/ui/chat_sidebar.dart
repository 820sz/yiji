import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// 会话侧边栏。
///
/// 从左边滑出来,列出所有对话。做这个的直接原因:以前所有消息混在一条历史里,
/// 新开的对话能"看到"以前聊过的内容,AI 会提起你没在这个对话里说过的事。
/// 会话隔离之后必须有个地方切换它们,否则历史就等于被藏起来了。
class ChatSidebar extends StatelessWidget {
  const ChatSidebar({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Drawer(
      backgroundColor: dark ? AppTheme.darkBackground : AppTheme.lightBackground,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Text(
                    '对话',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {
                      state.startNewConversation();
                      onClose();
                    },
                    icon: Icon(Icons.add_circle_outline, color: textPrimary),
                    tooltip: '新对话',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: state.conversations.isEmpty
                  ? Center(
                      child: Text(
                        '还没有对话',
                        style: TextStyle(fontSize: 14, color: textSecondary),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: state.conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = state.conversations[index];
                        return _ConversationTile(
                          conversation: conversation,
                          active: conversation.id == state.currentConversationId,
                          dark: dark,
                          onTap: () {
                            state.openConversation(conversation.id);
                            onClose();
                          },
                          onDelete: () => state.deleteConversation(conversation.id),
                          onRename: () => _rename(context, conversation),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, Conversation conversation) async {
    final state = AppScope.of(context);
    final controller = TextEditingController(text: conversation.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('对话标题'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(counterText: ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) await state.renameConversation(conversation.id, result);
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.active,
    required this.dark,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
  });

  final Conversation conversation;
  final bool active;
  final bool dark;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final title = conversation.title.trim().isEmpty ? '新对话' : conversation.title;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: active ? AppTheme.accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 16,
                  color: active ? AppTheme.accent : textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active ? AppTheme.accent : textPrimary,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, size: 18, color: textSecondary),
                  tooltip: '更多',
                  onSelected: (value) => value == 'rename' ? onRename() : onDelete(),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('改标题')),
                    PopupMenuItem(value: 'delete', child: Text('删除对话')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 用户头像。没设过时用名字首字兜底——比一个灰色占位好认。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.bytes,
    required this.name,
    this.size = 30,
  });

  final Uint8List? bytes;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.3);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          bytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => _fallback(radius),
        ),
      );
    }
    return _fallback(radius);
  }

  Widget _fallback(BorderRadius radius) {
    final initial = name.trim().isEmpty ? '我' : name.trim().characters.first;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF5B6472),
        borderRadius: radius,
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.45,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
