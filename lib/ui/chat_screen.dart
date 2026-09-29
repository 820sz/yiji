import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/ai_client.dart';
import '../core/day.dart';
import '../data/chat_attachment.dart';
import '../data/data_range.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'ai_avatar.dart';
import 'chat_sidebar.dart';
import 'theme.dart';

/// 聊天页:一个配了自己 API key 的对话窗口。
///
/// 与普通聊天工具的三处不同:
/// 1. 思考过程单独一块、可折叠——模型想什么不该被藏起来,但也不该淹没回答;
/// 2. 思考强度可以**只对这一次**临时改,不必去设置里改全局;
/// 3. 「带上本周数据」开关,把他手动复制总结给 AI 的动作变成一次点击。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// 从选择器拿到的原始字节。
///
/// 两个选择器(image_picker / file_picker)返回的类型完全不同,先在
/// 这里归成一种,后面的"转附件"就只写一遍。
class _Picked {
  const _Picked(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

class _ChatScreenState extends State<ChatScreen> {
  /// 侧边栏要从头部那个按钮打开,所以需要 Scaffold 的句柄。
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final _input = TextEditingController();
  final _scroll = ScrollController();

  bool _sending = false;
  String? _error;

  /// 要附带的"近期数据"范围;null 表示不带。
  ///
  /// 从"本周"改成可选范围:他有时想聊这一周,有时想聊一整个月,
  /// 固定一周会让另一种需求落空。
  DataRange? _attachRange;

  /// 本次要发的图片/文件。发完清空。
  final List<ChatAttachment> _attachments = [];

  /// 正在挑文件。挡住连点:插件同时只能有一个选择器在跑,
  /// 第二次会以 "already_active" 失败,用户看到的就是又白点一次。
  var _picking = false;

  /// 本轮读不出来的文件名。挑完统一提示,而不是弹一串 snackbar。
  final List<String> _rejected = [];

  StreamSubscription<AiChunk>? _subscription;

  /// 挑图片或文件。
  ///
  /// 图片走多模态(只有 DeepSeek 的 flash 支持),文本文件读成文本附上。
  /// 挑到不支持的二进制类型时明说,而不是悄悄发出去让模型看见乱码。
  Future<void> _pickFiles({required bool imagesOnly}) async {
    if (_picking) return;
    _picking = true;
    try {
      final files = imagesOnly
          // 照片走 image_picker:头像/背景一直在用它,是这台设备上验证过能用的路。
          // file_picker 拿相册在部分机型上会返回取不到路径的条目。
          ? await _pickImages()
          : await _pickAnyFiles();
      if (files == null) return; // 用户取消
      if (!mounted) return;
      await _absorb(files);
    } on Exception catch (error) {
      _complain('挑选失败:${_describe(error)}');
    } on Error catch (error) {
      // 联邦插件没注册时会抛 UnimplementedError,它是 Error 不是 Exception,
      // 只 catch Exception 的话用户看到的就是"点了没反应"。
      _complain('挑选失败:${_describe(error)}');
    } finally {
      _picking = false;
    }
  }

  /// 相册选图,可多选。
  Future<List<_Picked>?> _pickImages() async {
    final picked = await ImagePicker().pickMultiImage(
      // 展示尺寸不大,压一下省内存,也避免几 MB 的原图撑爆请求。
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (picked.isEmpty) return null;
    final out = <_Picked>[];
    for (final file in picked) {
      out.add(_Picked(file.name, await file.readAsBytes()));
    }
    return out;
  }

  /// 系统文件选择器,任意类型。
  Future<List<_Picked>?> _pickAnyFiles() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return null;
    final out = <_Picked>[];
    for (final picked in files) {
      // readAsBytes 走的是插件拷到缓存目录的那份文件。插件取不到路径时
      // 会抛异常,记下来当"读不了"处理,不让整次选择失败。
      try {
        out.add(_Picked(picked.name, await picked.readAsBytes()));
      } on Exception {
        _rejected.add(picked.name);
      }
    }
    return out;
  }

  /// 把挑到的字节转成附件,并给出反馈。
  Future<void> _absorb(List<_Picked> files) async {
    final added = <ChatAttachment>[];
    for (final picked in files) {
      final attachment = await ChatAttachment.fromBytes(picked.bytes, picked.name);
      if (attachment == null) {
        _rejected.add(picked.name);
      } else {
        added.add(attachment);
      }
    }
    if (!mounted) return;
    final rejected = _rejected.toList();
    _rejected.clear();
    setState(() => _attachments.addAll(added));
    if (added.isEmpty) {
      _complain(rejected.isEmpty ? '没选到文件' : '这些读不了:${rejected.join('、')}');
    } else if (rejected.isNotEmpty) {
      _complain('加了 ${added.length} 个,这些读不了:${rejected.join('、')}');
    }
  }

  /// 把异常说成人话。
  ///
  /// 插件的错误码本身就是线索("no_activity" 是选择器启动时界面还没回到前台),
  /// 原来它们只被 toString 成一句泛泛的失败,排查时等于什么都没有。
  String _describe(Object error) {
    if (error is PlatformException) {
      final detail = error.message?.trim() ?? '';
      return detail.isEmpty ? error.code : '${error.code} · $detail';
    }
    return error.toString();
  }

  void _complain(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showAttachSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('照片'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('文件'),
              subtitle: const Text('文本类可以读,压缩包之类读不了'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _pickFiles(imagesOnly: choice == 'image');
  }

  /// 仅对本次对话生效的思考强度;null 表示跟随设置。
  ThinkingLevel? _overrideThinking;

  @override
  void dispose() {
    _subscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool animate = false}) {
    // 列表长度在下一帧才更新,post-frame 里滚动才能到底。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(target, duration: AppTheme.medium, curve: AppTheme.easeOut);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  Future<void> _send() async {
    final state = AppScope.of(context);
    final text = _input.text.trim();
    // 只发了附件、没写字也算有效的一次发送。
    if ((text.isEmpty && _attachments.isEmpty) || _sending) return;

    if (!state.aiConfig.isUsable) {
      setState(() => _error = '还没填 API key,去「我的」里填一下');
      return;
    }

    _input.clear();
    final thinking = _overrideThinking;
    setState(() {
      _sending = true;
      _error = null;
      // 附件已经交给这次请求了,从输入区清掉。
      _attachments.clear();
    });
    _scrollToBottom();

    _subscription = state
        .sendChat(
          text,
          range: _attachRange,
          attachments: List.of(_attachments),
          thinking: thinking,
        )
        .listen(
      (chunk) {
        if (!mounted) return;
        // 回答开始吐出之后才跟随滚动;思考阶段不跟随,否则正文还没出现页面就在抖。
        setState(() {});
        if (!chunk.isReasoning) _scrollToBottom();
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _sending = false;
          _error = error is Exception ? error.toString() : '出错了:$error';
        });
      },
      onDone: () async {
        if (!mounted) return;
        setState(() => _sending = false);
        await state.commitAssistantMessage();
        _scrollToBottom(animate: true);
      },
      cancelOnError: true,
    );
  }

  Future<void> _clear() async {
    final state = AppScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空聊天记录?'),
        content: const Text('待办和想法不受影响,只删对话。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      // 清空 = 删掉当前会话(连同它的消息)。会话列表会重新加载。
      await state.deleteConversation(state.currentConversationId);
    }
  }

  /// 选要附带的数据范围:三个常用档 + 自选。
  Future<void> _pickRange() async {
    final picked = await showModalBottomSheet<DataRange>(
      context: context,
      builder: (_) => const _RangeSheet(),
    );
    if (picked == null || !mounted) return;
    setState(() => _attachRange = picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final messages = state.chat;
    final hasKey = state.aiConfig.isUsable;
    final thinking = _overrideThinking ?? state.aiConfig.thinking;
    // 厂商只算一次:每帧重新推一遍既浪费也会让头像组件的入参变化。
    final provider = AiProvider.from(
      model: state.aiConfig.model,
      baseUrl: state.aiConfig.baseUrl,
    );

    return Scaffold(
      // 侧边栏挂在这里:会话列表要从左边滑出来,而且不该占着正文的位置。
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      drawer: ChatSidebar(onClose: () => Navigator.of(context).maybePop()),
      body: Column(
        children: [
          _ChatHeader(
            provider: provider,
            model: state.aiConfig.model,
            avatar: state.avatarBytes,
            dark: dark,
            thinking: thinking,
            followingSettings: _overrideThinking == null,
            onOpenSidebar: () => _scaffoldKey.currentState?.openDrawer(),
            onPickThinking: (level) => setState(
              () => _overrideThinking =
                  level == state.aiConfig.thinking ? null : level,
            ),
            onClear: messages.isEmpty ? null : _clear,
          ),
          Expanded(
            child: messages.isEmpty && !state.streaming
                ? _EmptyChat(hasKey: hasKey, dark: dark)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                    // 流式输出时每帧都会重建这一页。用 builder + key 让已经发出去的消息
                    // 保持原样,只重建最后那条正在生成的——否则整列气泡每帧重排,
                    // 看上去就是持续抖动。
                    itemCount: messages.length + (state.streaming ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= messages.length) {
                        // 用 AppScope.of 现取最新的 state:这一块的父级在流式期间
                        // 已经不再重建了,闭包里那份 state 还是开始生成时的快照。
                        return const _StreamingSlot();
                      }
                      final message = messages[index];
                      return _MessageBlock(
                        // key 让同一批消息在重建时被复用,而不是重新挂载。
                        key: ValueKey('message-${message.id}'),
                        message: message,
                        provider: provider,
                        avatar: state.avatarBytes,
                        userAvatar: state.userAvatarBytes,
                        userName: state.identityLabel,
                        dark: dark,
                        isLast: index == messages.length - 1,
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 16, color: Color(0xFFE05252)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFFE05252)),
                    ),
                  ),
                ],
              ),
            ),
          _Composer(
            controller: _input,
            sending: _sending,
            attachRange: _attachRange,
            attachments: _attachments,
            dark: dark,
            onPickRange: () => _pickRange(),
            onClearRange: () => setState(() => _attachRange = null),
            onAttach: _showAttachSheet,
            onRemoveAttachment: (index) => setState(() => _attachments.removeAt(index)),
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// 正在生成的那一条。
///
/// 只订阅 [AppState.streamTick],所以每收一个字重画的只有这一块;
/// 外面那层列表、头部和输入框在整段生成期间一动不动——这正是
/// "回答生成时整页在抖"的根因。
class _StreamingSlot extends StatelessWidget {
  const _StreamingSlot();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 厂商只算一次:每帧重新推一遍既浪费也会让头像组件的入参变化。
    final provider = AiProvider.from(
      model: state.aiConfig.model,
      baseUrl: state.aiConfig.baseUrl,
    );

    return AnimatedBuilder(
      animation: state.streamTick,
      builder: (context, _) => _StreamingBlock(
        reasoning: state.streamingReasoning,
        answer: state.streamingAnswer,
        provider: provider,
        avatar: state.avatarBytes,
        dark: dark,
      ),
    );
  }
}

/// 聊天页头部:侧边栏入口 + 厂商 + 思考强度 + 清空。
class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.provider,
    required this.model,
    required this.avatar,
    required this.dark,
    required this.thinking,
    required this.followingSettings,
    required this.onOpenSidebar,
    required this.onPickThinking,
    required this.onClear,
  });

  final VoidCallback onOpenSidebar;

  final AiProvider provider;
  final String model;
  final Uint8List? avatar;
  final bool dark;
  final ThinkingLevel thinking;

  /// true 表示当前强度跟随设置(而不是本次临时指定)。
  final bool followingSettings;

  final ValueChanged<ThinkingLevel> onPickThinking;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 8, 8),
      child: Row(
        children: [
          // 侧边栏入口放在最左:会话是这一页的"上一层",位置要和它对应。
          IconButton(
            onPressed: onOpenSidebar,
            icon: Icon(Icons.menu, color: textPrimary),
            tooltip: '全部对话',
          ),
          AiAvatar(
            provider: provider,
            bytes: avatar,
            dark: dark,
            size: 34,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.label,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(model, style: TextStyle(fontSize: 12, color: textSecondary)),
              ],
            ),
          ),
          _ThinkingButton(
            level: thinking,
            temporary: !followingSettings,
            dark: dark,
            onPick: onPickThinking,
          ),
          IconButton(
            onPressed: onClear,
            icon: Icon(Icons.delete_sweep_outlined, color: textSecondary),
            tooltip: '清空对话',
          ),
        ],
      ),
    );
  }
}

/// 思考强度按钮:点开选档位,只影响本次对话。
class _ThinkingButton extends StatelessWidget {
  const _ThinkingButton({
    required this.level,
    required this.temporary,
    required this.dark,
    required this.onPick,
  });

  final ThinkingLevel level;
  final bool temporary;
  final bool dark;
  final ValueChanged<ThinkingLevel> onPick;

  @override
  Widget build(BuildContext context) {
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return PopupMenuButton<ThinkingLevel>(
      onSelected: onPick,
      tooltip: '思考强度',
      itemBuilder: (context) => [
        for (final option in ThinkingLevel.values)
          PopupMenuItem(
            value: option,
            child: Row(
              children: [
                Icon(
                  option == level ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 18,
                  color: option == level ? AppTheme.accent : textSecondary,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      option.hint,
                      style: TextStyle(fontSize: 11.5, color: textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: temporary ? AppTheme.accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 17,
              color: temporary ? AppTheme.accent : textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              level.label,
              style: TextStyle(
                fontSize: 12.5,
                color: temporary ? AppTheme.accent : textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数据范围选择面板。
///
/// 三个常用档直接点,想精确到某段就"自选"。
class _RangeSheet extends StatelessWidget {
  const _RangeSheet();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '带上哪段时间的数据',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            for (final entry in const [
              (label: '近 7 天', days: 7),
              (label: '近 14 天', days: 14),
              (label: '近 30 天', days: 30),
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                onTap: () => Navigator.pop(context, DataRange.lastDays(entry.days)),
                leading: Icon(Icons.calendar_today_outlined, size: 18, color: textSecondary),
                title: Text(
                  entry.label,
                  style: TextStyle(fontSize: 15, color: textPrimary),
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              onTap: () async {
                final picked = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (picked == null || !context.mounted) return;
                Navigator.pop(
                  context,
                  DataRange.between(dayKey(picked.start), dayKey(picked.end)),
                );
              },
              leading: Icon(Icons.date_range_outlined, size: 18, color: textSecondary),
              title: Text(
                '自选起止日期',
                style: TextStyle(fontSize: 15, color: textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条已落库的消息。带思考过程时,上面挂一个可折叠的思考块。
class _MessageBlock extends StatelessWidget {
  const _MessageBlock({
    super.key,
    required this.message,
    required this.provider,
    required this.avatar,
    required this.userAvatar,
    required this.userName,
    required this.dark,
    this.isLast = false,
  });

  final ChatMessage message;
  final AiProvider provider;
  final Uint8List? avatar;
  final Uint8List? userAvatar;
  final String userName;
  final bool dark;

  /// 是不是最后一条。
  ///
  /// 最后一条刚生成完,思考过程默认展开:流式那一块在生成时是展开的,
  /// 落库后如果改成收起,回答刚写完的那一瞬间高度会突然变,整列消息跳一下。
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          message.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (message.hasReasoning)
          ReasoningPanel(
            text: message.reasoning,
            dark: dark,
            initiallyExpanded: isLast,
          ),
        _Bubble(
          text: message.content,
          isUser: message.isUser,
          dark: dark,
          provider: provider,
          avatar: avatar,
          userAvatar: userAvatar,
          userName: userName,
        ),
      ],
    );
  }
}

/// 正在流式接收的那一条。
class _StreamingBlock extends StatelessWidget {
  const _StreamingBlock({
    required this.reasoning,
    required this.answer,
    required this.provider,
    required this.avatar,
    required this.dark,
  });

  final String reasoning;
  final String answer;
  final AiProvider provider;
  final Uint8List? avatar;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reasoning.isNotEmpty)
          ReasoningPanel(
            text: reasoning,
            dark: dark,
            // 还在思考时展开:这一刻用户最想知道的就是它在想什么。
            live: answer.isEmpty,
          ),
        if (answer.isNotEmpty)
          _Bubble(
            text: answer,
            isUser: false,
            dark: dark,
            provider: provider,
            avatar: avatar,
            streaming: true,
          ),
      ],
    );
  }
}

/// 思考过程面板。
///
/// 默认收起(思考是过程,不是结论),正在思考时展开显示。
/// 用 140ms 的尺寸过渡 + 箭头旋转;这是"偶尔看一眼"的东西,不做花活。
class ReasoningPanel extends StatefulWidget {
  const ReasoningPanel({
    super.key,
    required this.text,
    required this.dark,
    this.live = false,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool dark;

  /// 正在生成:自动展开、显示进行中的指示。
  final bool live;

  /// 刚生成完的那一条默认展开,避免生成结束时高度突变。其余默认收起。
  final bool initiallyExpanded;

  @override
  State<ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<ReasoningPanel> {
  late bool _expanded = widget.live || widget.initiallyExpanded;

  @override
  void didUpdateWidget(ReasoningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从"正在思考"变成"思考完了"时**保持展开**。
    //
    // 以前这里会自动收起,于是回答刚写完的那一瞬间,上面这一块突然缩掉,
    // 整列消息往上跳一下——用户看到的就是"回答完成时闪一下/跳一下"。
    // 生成结束时高度不该变,要收起来由他自己点。
  }

  @override
  Widget build(BuildContext context) {
    final textSecondary =
        widget.dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final surface = widget.dark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return Padding(
      padding: const EdgeInsets.only(left: 40, right: 30, bottom: 6),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.live ? null : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (widget.live)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    else
                      Icon(Icons.psychology_outlined, size: 15, color: textSecondary),
                    const SizedBox(width: 7),
                    Text(
                      widget.live ? '思考中' : '思考过程',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: textSecondary,
                      ),
                    ),
                    const Spacer(),
                    if (!widget.live)
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: AppTheme.fast,
                        curve: AppTheme.easeOut,
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          size: 18,
                          color: textSecondary,
                        ),
                      ),
                  ],
                ),
                AnimatedSize(
                  duration: AppTheme.fast,
                  curve: AppTheme.easeOut,
                  alignment: Alignment.topLeft,
                  child: _expanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: SizedBox(
                            width: double.infinity,
                            child: Text(
                              widget.text,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.6,
                                color: textSecondary,
                              ),
                            ),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条气泡。用户消息靠右、AI 靠左,两侧各带自己的头像。
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.isUser,
    required this.dark,
    required this.provider,
    required this.avatar,
    this.userAvatar,
    this.userName = '',
    this.streaming = false,
  });

  final String text;
  final bool isUser;
  final bool dark;
  final AiProvider provider;
  final Uint8List? avatar;

  /// 用户自己的头像,只在用户那侧显示。
  final Uint8List? userAvatar;
  final String userName;

  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    // 两侧都要放头像,所以气泡可用宽度要比只有一侧时更窄一点。
    final maxWidth = MediaQuery.of(context).size.width * 0.68;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            AiAvatar(provider: provider, bytes: avatar, dark: dark, size: 30),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: isUser ? AppTheme.accent : surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.62,
                  color: isUser ? Colors.white : textPrimary,
                ),
              ),
            ),
          ),
          if (streaming)
            const Padding(
              padding: EdgeInsets.only(left: 8, top: 12),
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          // 用户那侧的头像放在气泡右边,和 AI 那侧对称。
          if (isUser) ...[
            const SizedBox(width: 10),
            UserAvatar(bytes: userAvatar, name: userName, size: 30),
          ],
        ],
      ),
    );
  }
}

/// 底部输入区,含"带上近期数据"的范围选择与附件。
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.attachRange,
    required this.attachments,
    required this.dark,
    required this.onPickRange,
    required this.onClearRange,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final DataRange? attachRange;
  final List<ChatAttachment> attachments;
  final bool dark;
  final VoidCallback onPickRange;
  final VoidCallback onClearRange;
  final VoidCallback onAttach;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final attached = attachRange != null;

    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          top: BorderSide(color: dark ? const Color(0xFF2A2D33) : const Color(0xFFE8E9ED)),
        ),
      ),
      padding: EdgeInsets.only(
        left: 14,
        right: 10,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                InkWell(
                  onTap: onPickRange,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: attached
                          ? AppTheme.accent.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: attached
                            ? AppTheme.accent
                            : textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          attached ? Icons.check_circle : Icons.add_circle_outline,
                          size: 13,
                          color: attached ? AppTheme.accent : textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          // 选了范围就把范围显示出来——附带了什么数据会直接影响回答,
                          // 不能让它变成一个看不见的状态。
                          attached ? attachRange!.label : '带上近期数据',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: attached ? AppTheme.accent : textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (attached) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: onClearRange,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 14, color: textSecondary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 已附上的图片/文件先在这儿露个脸,可以逐个去掉。
          if (attachments.isNotEmpty) ...[
            SizedBox(
              height: 46,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: attachments.length,
                itemBuilder: (context, index) => _AttachmentChip(
                  attachment: attachments[index],
                  dark: dark,
                  onRemove: () => onRemoveAttachment(index),
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 加附件。
              IconButton(
                onPressed: sending ? null : onAttach,
                icon: Icon(Icons.add_photo_alternate_outlined, color: textSecondary),
                tooltip: '加图片或文件',
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  maxLines: 5,
                  minLines: 1,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                  decoration: const InputDecoration(hintText: '说点什么'),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                onPressed: sending ? null : onSend,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward, size: 20),
                tooltip: '发送',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 已附加的一个文件/图片。
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.dark,
    required this.onRemove,
  });

  final ChatAttachment attachment;
  final bool dark;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: textSecondary.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              attachment.isImage ? Icons.image_outlined : Icons.description_outlined,
              size: 15,
              color: AppTheme.accent,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                attachment.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: textPrimary),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close, size: 13, color: textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.hasKey, required this.dark});

  final bool hasKey;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Text(
          hasKey ? '说点什么吧' : '先去「我的」填一个 API key',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, color: textSecondary),
        ),
      ),
    );
  }
}
