import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/ai_client.dart';
import '../ai/search_service.dart';
import '../core/day.dart';
import '../data/chat_attachment.dart';
import '../data/chat_images.dart';
import '../data/data_range.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'ai_avatar.dart';
import 'chat_sidebar.dart';
import 'image_cropper.dart';
import 'meme_sheet.dart';
import 'theme.dart';

/// 聊天气泡的排版尺度。
///
/// 单独拎成常量是因为用户对这一块的反馈都是**具体数字**
/// ("界面太挤""ai 头像太小""图占 ui 太大"),而零散写在 build 里的话
/// 下一次调整就会悄悄回到原样。测试直接断言这些常量。
class ChatMetrics {
  const ChatMetrics._();

  /// 消息头像边长。28 → 36:小的那个在 1080p 上只有指甲盖大。
  static const avatarSize = 36.0;

  /// 相邻两条消息之间的间距。8 → 14:上一版收得过头,连着两条长消息发闷。
  static const bubbleGap = 14.0;

  /// 气泡内边距(纯文字)。
  static const bubblePadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 11,
  );

  /// 思考区封顶高度:内容在里面滚,不随文字长高。
  static const reasoningMaxHeight = 170.0;
}

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
      final attachment = await ChatAttachment.fromBytes(
        picked.bytes,
        picked.name,
      );
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  /// 从内置图库里挑一张表情包,加进待发列表。
  Future<void> _pickMeme() async {
    final picked = await showMemeSheet(context);
    if (picked == null || !mounted) return;
    setState(() => _attachments.add(picked));
  }

  /// 换这个对话的 AI 头像:选图 → 调整 → 保存。
  Future<void> _editConversationAvatar() async {
    final state = AppScope.of(context);
    final hasAvatar = state.currentConversationAvatar != null;

    if (hasAvatar) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('换一张'),
                onTap: () => Navigator.pop(context, 'pick'),
              ),
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('恢复默认头像'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'remove') {
        await state.saveConversationAvatar(null);
        return;
      }
    }

    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final cropped = await showImageCropper(
        context,
        bytes: bytes,
        aspect: 1,
        withShape: true,
      );
      if (cropped == null) return;
      try {
        await state.saveConversationAvatar(cropped.bytes);
      } on AvatarSaveException catch (error) {
        // 保存失败必须报出来:调整页正常退出、头像却没变,
        // 用户只会觉得"这个功能是坏的"(之前就是静默失败)。
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像已更新')));
    } on Exception catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('选图失败:$error')));
    }
  }

  /// 仅对本次对话生效的思考强度;null 表示跟随设置。
  ThinkingLevel? _overrideThinking;

  /// 每个会话各自记住滚到哪了。
  ///
  /// 用户报过"有概率切换对话后,返回后无法停留在上次的进度那":以前换会话
  /// 一律重新滚到底,长对话翻回去就找不着刚才看的地方了。
  final Map<int, double> _scrollMemory = {};

  /// 是否已经离开底部。决定要不要显示"回到底部"按钮。
  bool _awayFromBottom = false;

  /// 是否跟着新内容贴住底部。
  ///
  /// 默认跟;用户**自己动手**往上翻之后就停,滑回底部再自动恢复。
  bool _followBottom = true;

  /// 这一帧的滚动是不是手指带出来的。
  bool _userDragging = false;

  /// 上一次看到的当前会话 id。用来发现"用户换了个对话"。
  int _lastConversationId = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 刚进来时看看有没有"今日想法"要分享——有就挂到输入框上方等着发。
    // 排在下一帧:这时 AppScope 一定可用。
    WidgetsBinding.instance.addPostFrameCallback((_) => _pickUpStagedShare());
  }

  /// 把别处暂存的想法挂成待发附件。
  ///
  /// 用户要的流程是:想法里点「分享给 AI」→ 选对话 → **附件悬在打字框上方**,
  /// 他再补充一句需求才发。所以这里只挂附件,不自动发送。
  void _pickUpStagedShare() {
    if (!mounted) return;
    final share = AppScope.of(context).takePendingShare();
    if (share == null || share.isEmpty) return;
    setState(() {
      if (share.text.isNotEmpty) {
        _attachments.add(
          ChatAttachment(
            name: share.text,
            isImage: false,
            text: share.text,
            sizeBytes: share.text.length,
          ),
        );
      }
      for (final name in share.photos) {
        // 只记文件名:聊天页在渲染和发送时会按需读字节,
        // 现在同步读一遍只会把界面卡住。
        _attachments.add(
          ChatAttachment(name: name, isImage: true, imageRef: name),
        );
      }
    });
  }

  /// 用户动了列表:更新"离底部多远",并决定还要不要跟底。
  ///
  /// 判据只看两件事,而且都是**客观事实**,不猜意图:
  /// - 这次滚动是不是手指带的(`dragDetails != null`);
  /// - 手指松开时离底部多远。
  ///
  /// 程序化的 `jumpTo` 既不会带来 `dragDetails`,也不会把 `_followBottom`
  /// 打开——所以"贴底 → 位置变成在底部 → 状态重置 → 再贴底"这个死循环
  /// 从结构上就不可能出现。上一轮就是因为让 jumpTo 也能改状态,
  /// 才把列表锁死在底部的。
  bool _onScrollStart(ScrollStartNotification notification) {
    if (notification.dragDetails != null) {
      _userDragging = true;
      // **手指一碰就停止自动跟底**,不要再抢用户的滚动。
      // 他松手时到底了,才会重新跟上。
      _followBottom = false;
    }
    return false;
  }

  bool _onScrollEnd(ScrollEndNotification notification) {
    if (!_userDragging) return false;
    _userDragging = false;
    if (!_scroll.hasClients) return false;
    final position = _scroll.position;
    // 松手时已经在底部附近:重新跟上后续的新消息。
    _followBottom = position.maxScrollExtent - position.pixels <= 80;
    return false;
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 往上留一点余量:刚到底部时按钮不该闪出来。
    final away = position.maxScrollExtent - position.pixels > 80;
    if (away != _awayFromBottom) setState(() => _awayFromBottom = away);
  }

  /// 内容长高了就跟着贴住底部。
  ///
  /// **这是"发出去的消息要手动滑才看得见"的修法。**
  /// 原来只在发送那一刻调一次 `_scrollToBottom`,而它滚的是**下一帧**的位置;
  /// 可新消息是在之后的状态更新里才进列表的,那一帧的 `maxScrollExtent`
  /// 还是旧值——滚过去等于没动,新消息就落在屏幕外。
  ///
  /// 用 [ScrollMetricsNotification] 而不是控制器监听:列表变长时滚动位置
  /// 没变,控制器的监听器根本不会被调用。
  bool _onMetrics(ScrollMetricsNotification notification) {
    // **只看外层列表。**
    //
    // 这个通知会从**任何后代** Scrollable 冒泡上来,包括思考块内部那个
    // 滚动区。不判深度的话,思考区里滚一下就会把外层列表拽到底。
    if (notification.depth != 0) return false;
    if (!_followBottom) return false;
    final metrics = notification.metrics;
    // 已经在底部就不用动。
    if (metrics.pixels >= metrics.maxScrollExtent - 2) return false;
    _scroll.jumpTo(metrics.maxScrollExtent);
    return false;
  }

  /// 离开某个会话时把当前滚动位置记下来。
  void _rememberScroll(int conversationId) {
    if (!_scroll.hasClients || conversationId == 0) return;
    _scrollMemory[conversationId] = _scroll.position.pixels;
  }

  /// 切到某个会话后恢复它上次的位置。没记录过就到底部(新消息在下面)。
  void _restoreScroll(int conversationId) {
    final saved = _scrollMemory[conversationId];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = saved ?? _scroll.position.maxScrollExtent;
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
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
        _scroll.animateTo(
          target,
          duration: AppTheme.medium,
          curve: AppTheme.easeOut,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  /// 滚到指定位置(回顶用)。
  void _animateTo(double target) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: AppTheme.medium,
      curve: AppTheme.easeOut,
    );
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
    // 先把附件取出来再清空输入区。顺序反过来的话,下面传过去的会是清空后的
    // 空列表——图选了、发出去了、什么都没带上,而且一个错都不报。
    final attachments = List.of(_attachments);
    final range = _attachRange;
    setState(() {
      _sending = true;
      _error = null;
      _attachments.clear();
      _attachRange = null;
    });
    _scrollToBottom();

    _subscription = state
        .sendChat(
          text,
          range: range,
          attachments: attachments,
          thinking: thinking,
        )
        .listen(
          (chunk) {
            if (!mounted) return;
            // **不在这里 setState**。
            //
            // 每个分片重建整页(头部、输入框、整个消息列表)是"回答生成时页面
            // 乱飘"的根因:几十个分片就是几十次全量重建,任何一处尺寸变化都会
            // 被放大成抖动。正文由 _StreamingSlot 自己订阅 streamTick 重绘,
            // 这里只负责跟随滚动。
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
    // 这个对话自己的头像;没设过时回落到全局设置里那个。
    final aiAvatar = state.currentConversationAvatar ?? state.avatarBytes;

    // 会话切换时:先记下旧会话的滚动位置,再恢复新会话的位置。
    //
    // 放在 build 里判断而不是去改侧边栏:切换会话有好几个入口(侧边栏、
    // 新建、删除后自动选中的那条),每个都去调一次很容易漏;而
    // "当前会话 id 变了"这件事在 build 里一定能看到。
    final conversationId = state.currentConversationId;
    if (conversationId != _lastConversationId) {
      if (_lastConversationId != 0) _rememberScroll(_lastConversationId);
      _lastConversationId = conversationId;
      _restoreScroll(conversationId);
    }

    // 有新的分享要挂上时补挂一次。
    //
    // 聊天页在 IndexedStack 里只构建一次,所以 initState 那一次
    // 只够第一次分享用;第二次起得靠这里。放在 build 里是安全的:
    // takePendingShare 会立刻把暂存清空,取完下次重建就什么都不做。
    if (state.hasPendingShare) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickUpStagedShare());
    }

    return Scaffold(
      // 侧边栏挂在这里:会话列表要从左边滑出来,而且不该占着正文的位置。
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      // 关闭抽屉走 closeDrawer,**不走 Navigator.pop**。
      //
      // 抽屉是 Scaffold 自己的状态;用 pop 去关它属于"借导航通道做状态切换",
      // 一旦这条 context 链上有别的 PopScope,行为就不确定了——上一轮
      // 就是这么坏的:抽屉关不掉,人还被顶到任务页。
      drawer: ChatSidebar(
        onClose: () => _scaffoldKey.currentState?.closeDrawer(),
      ),
      body: Column(
        children: [
          _ChatHeader(
            provider: provider,
            model: state.aiConfig.model,
            // 这个对话自己的头像;没设过时回落到全局设置里那个。
            avatar: state.currentConversationAvatar ?? state.avatarBytes,
            dark: dark,
            thinking: thinking,
            followingSettings: _overrideThinking == null,
            onOpenSidebar: () => _scaffoldKey.currentState?.openDrawer(),
            onEditAvatar: _editConversationAvatar,
            onPickThinking: (level) => setState(
              () => _overrideThinking = level == state.aiConfig.thinking
                  ? null
                  : level,
            ),
            onClear: messages.isEmpty ? null : _clear,
          ),
          Expanded(
            child: messages.isEmpty && !state.streaming
                ? _EmptyChat(hasKey: hasKey, dark: dark)
                // 回顶/回底**浮在列表上方**,不占布局。
                //
                // 用户的原话是:"回顶和回底功能,竟然单独占了一整行的图层"。
                // 它们本来就是辅助动作,不该让聊天区矮一截——浮层既不挡正文
                // (贴在右下角空白处),也不吃高度。
                : Stack(
                    children: [
                      // **SelectionArea 只包在每条消息上,不包整个列表。**
                      //
                      // 包在外面时它要给整个视口建选区基础设施:滚动时每帧都在
                      // 参与命中测试与语义树构建,长列表就是持续掉帧
                      // (用户报的"上下滑动有明显卡帧")。包进条目里之后,
                      // 只有真正挂载的那几条参与,滚动是纯滚动。
                      // 手势通知:判断"这次滚动是不是手指带出来的"。
                      // 只有用户自己的滑动才有资格改变跟不跟底。
                      NotificationListener<ScrollStartNotification>(
                        onNotification: _onScrollStart,
                        child: NotificationListener<ScrollEndNotification>(
                          onNotification: _onScrollEnd,
                          child: NotificationListener<ScrollMetricsNotification>(
                            onNotification: _onMetrics,
                            child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          // 多留一点预渲染范围:滚动时上下各半屏已经在树上了,
                          // 手指带过去不会看到空白帧。
                          scrollCacheExtent: const ScrollCacheExtent.viewport(
                            1.0,
                          ),
                          // 流式输出时每帧都会重建这一页。用 builder + key 让已经发出去的
                          // 消息保持原样,只重建最后那条正在生成的——否则整列气泡每帧重排,
                          // 看上去就是持续抖动。
                          itemCount:
                              messages.length + (state.streaming ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= messages.length) {
                              // 用 AppScope.of 现取最新的 state:这一块的父级在流式期间
                              // 已经不再重建了,闭包里那份 state 还是开始生成时的快照。
                              return const _StreamingSlot();
                            }
                            final message = messages[index];
                            return SelectionArea(
                              key: ValueKey('message-${message.id}'),
                              child: _MessageBlock(
                                message: message,
                                provider: provider,
                                avatar: aiAvatar,
                                userAvatar: state.userAvatarBytes,
                                userName: state.identityLabel,
                                dark: dark,
                                isLast: index == messages.length - 1,
                              ),
                            );
                          },
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 10,
                        child: _JumpButtons(
                          dark: dark,
                          awayFromBottom: _awayFromBottom,
                          onTop: () => _animateTo(0),
                          onBottom: () => _scrollToBottom(animate: true),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 16,
                    color: Color(0xFFE05252),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Color(0xFFE05252),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // 联网搜索开着时,把来源摆出来。
          //
          // 用户得知道"这次回答是联网来的"以及"依据是哪几条",
          // 否则搜没搜、搜到什么完全看不见,跟不联网没区别。
          if (state.searching)
            _SearchStatusBar(
              icon: Icons.travel_explore,
              text: '正在联网搜索…',
              dark: dark,
              spinning: true,
            )
          else if (state.lastSearch != null && !state.lastSearch!.isEmpty)
            _SearchStatusBar(
              icon: Icons.public,
              text: '已联网 · ${state.lastSearch!.sources.length} 条来源',
              dark: dark,
              sources: state.lastSearch!.sources,
            )
          else if (state.searchFailed != null)
            _SearchStatusBar(
              icon: Icons.cloud_off,
              text: state.searchFailed!,
              dark: dark,
            ),
          _Composer(
            controller: _input,
            sending: _sending,
            attachRange: _attachRange,
            attachments: _attachments,
            dark: dark,
            webSearch: state.webSearchEnabled,
            onToggleWebSearch: state.toggleWebSearch,
            onPickRange: () => _pickRange(),
            onClearRange: () => setState(() => _attachRange = null),
            onAttach: _showAttachSheet,
            onMeme: _pickMeme,
            onRemoveAttachment: (index) =>
                setState(() => _attachments.removeAt(index)),
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// 联网搜索的状态条:正在搜 / 搜到了几条 / 没搜到。
///
/// 存在的理由是"让用户看得见":搜没搜、依据是什么,如果界面上没有任何痕迹,
/// 用户就没法判断这个回答该不该信。
class _SearchStatusBar extends StatelessWidget {
  const _SearchStatusBar({
    required this.icon,
    required this.text,
    required this.dark,
    this.spinning = false,
    this.sources = const [],
  });

  final IconData icon;
  final String text;
  final bool dark;
  final bool spinning;
  final List<SearchSource> sources;

  @override
  Widget build(BuildContext context) {
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Row(
        children: [
          if (spinning)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 14, color: AppTheme.accent),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: textSecondary),
            ),
          ),
          // 有来源时可以点开看是哪几条。
          if (sources.isNotEmpty)
            GestureDetector(
              onTap: () => _showSources(context, sources, dark),
              child: Text(
                '查看',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static void _showSources(
    BuildContext context,
    List<SearchSource> sources,
    bool dark,
  ) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          children: [
            const Text(
              '这次搜到的来源',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final source in sources)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.title,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      source.url,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: dark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 浮在聊天列表右下角的回顶/回底。
///
/// 两个设计要点:
/// 1. **不占布局**——它们是辅助动作,不该让聊天区矮一截(用户明确抱怨过这点)。
/// 2. **只在用得上时出现**——停在最新一条时不显示「回底」(没意义),
///    完全在顶部时不显示「回顶」。出现/消失用淡入淡出,不用位移,
///    免得在滚动时跟着手指抖。
class _JumpButtons extends StatelessWidget {
  const _JumpButtons({
    required this.dark,
    required this.awayFromBottom,
    required this.onTop,
    required this.onBottom,
  });

  final bool dark;
  final bool awayFromBottom;
  final VoidCallback onTop;
  final VoidCallback onBottom;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AnimatedOpacity(
          // 停在底部时"回到最新"没有意义,直接隐藏。
          opacity: awayFromBottom ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: !awayFromBottom,
            child: _JumpButton(
              icon: Icons.vertical_align_bottom,
              tooltip: '回到最新',
              dark: dark,
              onTap: onBottom,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _JumpButton(
          icon: Icons.vertical_align_top,
          tooltip: '回到最早',
          dark: dark,
          onTap: onTop,
        ),
      ],
    );
  }
}

/// 单个圆形小钮。半透明、平时不抢视线,命中区撑到 40 好点。
class _JumpButton extends StatelessWidget {
  const _JumpButton({
    required this.icon,
    required this.tooltip,
    required this.dark,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    return Tooltip(
      message: tooltip,
      child: Material(
        // 半透明:压在消息上时要能看见底下的字,别像一块不透明的补丁。
        color: (dark ? AppTheme.darkSurface : Colors.white).withValues(
          alpha: 0.86,
        ),
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: textSecondary),
          ),
        ),
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
        // 用可见版本:模型要表情包那行指令不能显示出来。
        answer: state.visibleStreamingAnswer,
        provider: provider,
        avatar: state.currentConversationAvatar ?? state.avatarBytes,
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
    required this.onEditAvatar,
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

  /// 点头像换这个对话的 AI 头像。
  final VoidCallback onEditAvatar;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark
        ? AppTheme.darkTextPrimary
        : AppTheme.lightTextPrimary;
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;

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
          // 头像点一下就能换。头像是**每个对话各自**的:不同主题的对话
          // 可以是不同的人设,不用全局改来改去。
          GestureDetector(
            onTap: onEditAvatar,
            child: AiAvatar(
              provider: provider,
              bytes: avatar,
              dark: dark,
              size: 34,
            ),
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
                Text(
                  model,
                  style: TextStyle(fontSize: 12, color: textSecondary),
                ),
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
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;

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
                  option == level
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: option == level ? AppTheme.accent : textSecondary,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
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
          color: temporary
              ? AppTheme.accent.withValues(alpha: 0.14)
              : Colors.transparent,
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
    final textPrimary = dark
        ? AppTheme.darkTextPrimary
        : AppTheme.lightTextPrimary;
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;

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
                onTap: () =>
                    Navigator.pop(context, DataRange.lastDays(entry.days)),
                leading: Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: textSecondary,
                ),
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
              leading: Icon(
                Icons.date_range_outlined,
                size: 18,
                color: textSecondary,
              ),
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
      crossAxisAlignment: message.isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (message.hasReasoning)
          ReasoningPanel(
            text: message.reasoning,
            dark: dark,
            // 落库之后一律收起。
            //
            // 以前这里传 isLast,让刚生成完的那条保持展开——那是因为当时
            // 收起会让回答完成瞬间高度突变、整列往上跳。现在收起本身带了
            // 动画(AnimatedSize),而且**顺带解决了用户抱怨的那个问题**:
            // "用户还得等 ai 思考完手动收起思考过程"。生成完就自己收掉,
            // 想看再点开。
            initiallyExpanded: false,
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

  /// 判断"用户有没有自己动过这个折叠面板"。
  ///
  /// 用户的原话:"流式思考经常直接一口气把屏幕顶满,用户还得等 ai 思考完
  /// 手动收起思考过程"。所以思考结束时**自动收起**是必须的。
  ///
  /// 但如果用户在思考过程中自己点开看了,就不能再自动收起——
  /// 那会把他正在读的东西抽走。所以只自动收起"他没碰过"的那种。
  bool _userToggled = false;

  /// 思考区内部滚动用的控制器。
  ///
  /// **必须显式持有**:Scrollbar 要求关联的 controller 上只挂一个
  /// ScrollPosition,而它默认会去用 PrimaryScrollController —— 外层消息列表
  /// 也挂在同一个主控制器上,于是直接抛
  /// "attached to more than one ScrollPosition"。
  final ScrollController _inner = ScrollController();

  @override
  void dispose() {
    _inner.dispose();
    super.dispose();
  }

  /// 思考区的**固定高度**。
  ///
  /// 这是这一条需求的全部要点:参考 DS app——区域大小定死、内容在里面滚动。
  /// 以前是"文字多高就长多高",一段长思考直接把屏幕顶满,
  /// 正在写的回答被挤到看不见的地方,用户还得等它想完再手动收起。
  static const _maxHeight = ChatMetrics.reasoningMaxHeight;

  @override
  void didUpdateWidget(ReasoningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 思考结束(生成中 → 完成)时自动收起。
    if (oldWidget.live && !widget.live && !_userToggled) {
      setState(() => _expanded = false);
    }
    // 流式追加时自己滚到底,让用户看到最新的想法。
    // (以前靠 `reverse: true` 实现,但那会让展开瞬间的内容位置很怪。)
    if (widget.text != oldWidget.text && _expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_inner.hasClients) return;
        _inner.jumpTo(_inner.position.maxScrollExtent);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textSecondary = widget.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    final surface = widget.dark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return Padding(
      padding: const EdgeInsets.only(left: 46, right: 36, bottom: 8),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // 思考中也能点开/收起:以前 live 时整个面板不可点,用户想看一眼
          // 它到底在纠结什么也没办法。
          onTap: () => setState(() {
            _userToggled = true;
            _expanded = !_expanded;
          }),
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
                      Icon(
                        Icons.psychology_outlined,
                        size: 15,
                        color: textSecondary,
                      ),
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
                          child: ConstrainedBox(
                            // **高度封顶 + 内部滚动**,而不是让它随文字长高。
                            constraints: const BoxConstraints(
                              maxHeight: _maxHeight,
                            ),
                            child: PrimaryScrollController.none(
                              // 这层 Scrollbar 必须有自己的控制器,不能借用
                              // PrimaryScrollController:外层消息列表也挂在同一个
                              // 主控制器上,一个控制器挂两个位置会直接抛
                              // "attached to more than one ScrollPosition"。
                              child: Scrollbar(
                                controller: _inner,
                                // 内容还在长时不要显示滚动条:它会在每一帧抖动。
                                thumbVisibility: !widget.live,
                                child: SingleChildScrollView(
                                  controller: _inner,
                                  primary: false,
                                  // **不用 reverse。**
                                  //
                                  // reverse 会让内容从底部开始排,展开的瞬间
                                  // 那一块文字像是"从下往上贴",再被外层列表
                                  // 的贴底逻辑拽一下——用户看到的就是"点思考
                                  // 过程之后整块乱串"。改成正常方向,并在
                                  // 流式追加时自己滚到底。
                                  padding: const EdgeInsets.only(right: 6),
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
                                ),
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
    final textPrimary = dark
        ? AppTheme.darkTextPrimary
        : AppTheme.lightTextPrimary;
    // 气泡宽度上限。QQ/微信那种紧凑感来自"气泡贴着内容",所以这里比常见的
    // 0.75 再收一点:长句换行更早,但右侧留白也跟着变少。
    final maxWidth = MediaQuery.of(context).size.width * 0.68;

    // 正文里可能夹着图片行(`![图] <引用>`)。要把它们**画成图**,
    // 而不是把那一行当文字显示出来——用户发的是照片,不是文件名。
    final parts = splitMessageParts(text);
    final images = [
      for (final part in parts)
        if (part.image != null) part.image!,
    ];
    final texts = [
      for (final part in parts)
        if (part.image == null && part.text.trim().isNotEmpty) part.text.trim(),
    ];
    // **全是图、没有文字**时不画气泡。
    //
    // 用户明确说过图"所占 ui 空间太大了…像 qq 那样":QQ 和微信里表情包
    // 就是一张圆角缩略图,外面没有气泡壳、也没有那一圈内边距。
    // 图本来就自带留白,再套一层壳就是白占地方。
    final bare = images.isNotEmpty && texts.isEmpty;

    return Padding(
      // 消息之间的间隔。用户反馈"气泡之间太密,上下留白不够"——
      // 上一版从 10 收到 8 是为了紧凑,但连着两条长消息时读起来发闷。
      // 定成 [ChatMetrics.bubbleGap]:比微信略紧、比之前的 8 松。
      padding: const EdgeInsets.only(bottom: ChatMetrics.bubbleGap),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            // 头像从 28 提到 36。用户说"ai 头像太小"——
            // 28 在 1080p 上只有指甲盖大,头像里的图形完全看不清。
            AiAvatar(
              provider: provider,
              bytes: avatar,
              dark: dark,
              size: ChatMetrics.avatarSize,
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: bare
                ? Column(
                    crossAxisAlignment: isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      for (final image in images)
                        _MessageImage(image: image, isUser: isUser),
                    ],
                  )
                : Container(
                    constraints: BoxConstraints(
                      // 有图时稍微放宽一点,但仍然不让一张图吃掉半屏。
                      maxWidth: images.isNotEmpty ? maxWidth * 1.1 : maxWidth,
                    ),
                    // 内边距。用户说"气泡内文字太贴边"——上一版 12/9 是偏紧。
                    padding: images.isNotEmpty
                        ? const EdgeInsets.all(8)
                        : ChatMetrics.bubblePadding,
                    decoration: BoxDecoration(
                      color: isUser ? AppTheme.accent : surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        for (final image in images)
                          _MessageImage(image: image, isUser: isUser),
                        for (var i = 0; i < texts.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                              top: images.isNotEmpty && i == 0 ? 4 : 0,
                            ),
                            // 用 Text 而不是 SelectableText:后者会给每条消息
                            // 挂上一套选区手势识别器 + 独立的选区状态,
                            // 一屏十几条时滚动明显掉帧(用户报的"上下划动不丝滑、
                            // 有卡顿和抽帧感")。要选中时整页统一选即可,
                            // 见消息列表外那层 SelectionArea。
                            child: Text(
                              texts[i],
                              style: TextStyle(
                                fontSize: 15,
                                // 1.6 而不是 1.5:中文行距太紧会糊成一片。
                                height: 1.6,
                                color: isUser ? Colors.white : textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          if (streaming)
            const Padding(
              padding: EdgeInsets.only(left: 6, top: 12),
              child: SizedBox(
                width: 9,
                height: 9,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          // 用户那侧的头像放在气泡右边,和 AI 那侧对称、同样大小。
          // (两边不等大时视觉上会往小的一侧倾。)
          if (isUser) ...[
            const SizedBox(width: 10),
            UserAvatar(bytes: userAvatar, name: userName, size: 36),
          ],
        ],
      ),
    );
  }
}

/// 消息正文的一段:要么是一段文字,要么是一张图。
class MessagePart {
  const MessagePart.text(this.text) : image = null;
  const MessagePart.image(this.image) : text = '';

  final String text;
  final ChatImage? image;
}

/// 把消息正文按图片标记切成若干段。
///
/// 图片单独成行(`![图] <引用>`),所以按行扫一遍就够了。
/// 之所以在渲染层切而不是在存储层存两份:消息文本本身就是"回看时到底发了什么"
/// 的完整记录,一份数据一个来源,不会再出现"文本和附件对不上"。
List<MessagePart> splitMessageParts(String raw) {
  final parts = <MessagePart>[];
  final buffer = StringBuffer();

  void flush() {
    final text = buffer.toString();
    if (text.trim().isNotEmpty) parts.add(MessagePart.text(text));
    buffer.clear();
  }

  for (final line in raw.split('\n')) {
    final image = ChatImage.parse(line);
    if (image == null) {
      buffer.writeln(line);
      continue;
    }
    flush();
    parts.add(MessagePart.image(image));
  }
  flush();
  return parts;
}

/// 气泡里的一张图。
///
/// 两种来源:内置表情包(asset)和用户自己发的图(应用私有目录里的文件)。
/// 点一下看大图——缩略图尺寸有限,想看清还得能放大。
class _MessageImage extends StatelessWidget {
  const _MessageImage({required this.image, required this.isUser});

  final ChatImage image;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    // 内置引用渲染失败时**不是终点**:按文件名回查一次图库。
    //
    // 消息里可能出现各种历史遗留的引用(以前写过 `asset:memes/user_x.png`
    // 这种安装包里根本不存在的路径)。只要图还在库里,就该把它画出来,
    // 而不是给用户看一个"图不在了"——那等于把他的历史永久弄坏。
    final source = image.isAsset
        ? _AssetImage(
            assetPath: image.assetPath,
            fileName: image.fileName,
            rawRef: image.ref,
          )
        : _DiskImage(fileName: image.fileName);

    // 尺寸按来源分档。
    //
    // 用户说过图"所占 ui 空间太大了…像 qq 那样":表情包在 QQ/微信里就是
    // 一张小方图,而 240×240 在手机上接近大半屏宽,一屏看不了两条消息。
    // 表情包(内置图库)本来就只要表达情绪,140 够看清;
    // 用户自己拍的照片要多留些细节,给到 200。
    final limit = image.isAsset ? 140.0 : 200.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: GestureDetector(
          onTap: () => _openFullScreen(context, image),
          child: ConstrainedBox(
            // 只限宽:**不限高**。占位框里要放诊断文字,给死高度就会溢出。
            // 图本身的高度由它自己的宽高比决定,不会失控。
            constraints: BoxConstraints(maxWidth: limit),
            child: source,
          ),
        ),
      ),
    );
  }

}

/// 内置图:**渲染失败时按文件名回查图库,再退回磁盘**。
///
/// 消息里的引用可能来自任何历史版本。只认一条精确路径的话,当年写错的那种
/// 引用就永远显示"图不在了"——而图其实好好躺在图库里或磁盘上。
class _AssetImage extends StatefulWidget {
  const _AssetImage({
    required this.assetPath,
    required this.fileName,
    required this.rawRef,
  });

  final String assetPath;
  final String fileName;

  /// 消息里原本那串引用。抢救失败时要显示出来——
  /// 不然只能看到一个「图不在了」,谁都判断不出是哪一串引用出的问题。
  final String rawRef;

  @override
  State<_AssetImage> createState() => _AssetImageState();
}

class _AssetImageState extends State<_AssetImage> {
  var _failed = false;
  Uint8List? _rescued;
  var _tried = false;

  /// 抢救失败的原因。显示在占位上,一眼看得到是哪一步断的。
  String _why = '';

  Future<void> _rescue() async {
    if (_tried) return;
    _tried = true;
    String why;
    try {
      final bytes = await ChatImages.bytesOf(ChatImage(ref: widget.fileName));
      if (bytes != null && bytes.isNotEmpty) {
        if (!mounted) return;
        setState(() => _rescued = bytes);
        return;
      }
      why = '按文件名「${widget.fileName}」在磁盘和内置图库里都没找到';
    } catch (error) {
      why = '读取失败:$error';
    }
    if (!mounted) return;
    setState(() => _why = why);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      if (_rescued != null) {
        return Image.memory(_rescued!, fit: BoxFit.contain);
      }
      // 没救回来:把**引用和原因**一起显示出来。
      return _brokenBox(context, ref: widget.rawRef, why: _why);
    }
    return Image.asset(
      'assets/${widget.assetPath}',
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) {
        // 在 build 里不能直接 setState,排到下一帧。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _failed = true);
          // **这里补上抢救**:以前只置了 _failed 却没调 _rescue,
          // 于是"回查图库"那条路根本不会走,永远停在破图上。
          unawaited(_rescue());
        });
        return const SizedBox(width: 120, height: 90);
      },
    );
  }
}

/// 截断一段可能很长的文本,给占位框用。
String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// 图片加载不出来时的占位。
///
/// **把引用和原因一起显示出来**。以前只有一个「图不在了」——
/// 用户和我都看不出是哪一串引用出的问题,只能靠猜(这就是这个 bug
/// 拖了好几轮的真正原因:没有数据)。
Widget _brokenBox(BuildContext context, {String ref = '', String why = ''}) {
  final textSecondary = Theme.of(context).brightness == Brightness.dark
      ? AppTheme.darkTextSecondary
      : AppTheme.lightTextSecondary;
  final detail = [
    if (ref.isNotEmpty) '引用:${_clip(ref, 120)}',
    if (why.isNotEmpty) _clip(why, 120),
  ].join('\n');
  return GestureDetector(
    // 点一下就能把这串诊断信息复制走。
    //
    // 让用户"截图发我"其实很别扭:字小、要来回切应用。复制粘贴最省事——
    // 而且这串引用正是定位这个 bug 唯一需要的东西。
    onTap: detail.isEmpty
        ? null
        : () async {
            await Clipboard.setData(ClipboardData(text: detail));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已复制,发给开发者就能定位')),
            );
          },
    child: Container(
      // 不给固定高度:诊断文字有几行算几行,给死高度就会溢出。
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: Colors.black12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, size: 20, color: textSecondary),
              const SizedBox(width: 6),
              Text(
                '图不在了',
                style: TextStyle(fontSize: 11.5, color: textSecondary),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(width: 6),
                Icon(Icons.copy, size: 12, color: textSecondary),
              ],
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            // 用 Text 不用 SelectableText:诊断信息不该引入选区那套东西
            // (它会跟着外层的选区一起注册,行为难以预期)。
            Text(
              detail,
              style: TextStyle(
                fontSize: 10,
                height: 1.35,
                color: textSecondary,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// 磁盘上的一张图,**找不到时退回内置图库的同名图**。
///
/// 老消息里存的是内置表情包的磁盘副本文件名,而那份副本会被系统清掉。
/// 直接显示"图不在了"等于把用户的历史永久弄坏;而同一张图就在安装包里,
/// 按文件名回查一次就能救回来。
class _DiskImage extends StatefulWidget {
  const _DiskImage({required this.fileName});

  final String fileName;

  @override
  State<_DiskImage> createState() => _DiskImageState();
}

class _DiskImageState extends State<_DiskImage> {
  File? _file;
  Uint8List? _fallback;
  var _done = false;
  String _why = '';

  @override
  void initState() {
    super.initState();
    // 同步能出结果就绝不等异步:目录已知时这里一次就定下来了,
    // 不必经过"转圈 → 一帧后才有内容"的过程。
    final sync = ChatImages.fileSync(widget.fileName);
    if (sync != null) {
      _file = sync;
      _done = true;
      return;
    }
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    // **全程带超时**:目录查询或回查卡住时,不能永远停在空白占位上——
    // 那既不显示图、也不报错,用户只看到一片灰。
    const budget = Duration(seconds: 3);
    String why = '';
    try {
      final onDisk = await ChatImages.file(widget.fileName).timeout(budget);
      if (!mounted) return;
      if (onDisk != null) {
        setState(() {
          _file = onDisk;
          _done = true;
        });
        return;
      }
      why = '磁盘上没这个文件';
    } catch (_) {
      why = '查磁盘超时(3 秒)';
    }

    // 磁盘上没有了:按文件名回查内置图库。
    Uint8List? bytes;
    try {
      bytes = await ChatImages.bytesOf(
        ChatImage(ref: widget.fileName),
      ).timeout(budget);
    } catch (_) {
      why = '$why;回查图库超时';
    }
    if (!mounted) return;
    setState(() {
      _fallback = bytes;
      _why = bytes == null ? '$why,图库里也没有同名的内置图' : '';
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_done) {
      return const SizedBox(
        width: 120,
        height: 90,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final file = _file;
    if (file != null) {
      return Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => _brokenBox(
          context,
          ref: widget.fileName,
          why: '文件读不出来:$error',
        ),
      );
    }
    final bytes = _fallback;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.contain);
    }
    return _brokenBox(
      context,
      ref: widget.fileName,
      why: _why.isEmpty ? '磁盘上没有这个文件' : _why,
    );
  }
}

/// 点开看大图。
Future<void> _openFullScreen(BuildContext context, ChatImage image) async {
  await Navigator.of(
    context,
  ).push<void>(MaterialPageRoute(builder: (_) => _FullImagePage(image: image)));
}

class _FullImagePage extends StatelessWidget {
  const _FullImagePage({required this.image});

  final ChatImage image;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: image.isAsset
              ? Image.asset('assets/${image.assetPath}', fit: BoxFit.contain)
              : FutureBuilder<File?>(
                  future: ChatImages.file(image.fileName),
                  builder: (context, snapshot) {
                    final file = snapshot.data;
                    if (file == null) {
                      return const Text(
                        '图不在了',
                        style: TextStyle(color: Colors.white70),
                      );
                    }
                    return Image.file(file, fit: BoxFit.contain);
                  },
                ),
        ),
      ),
    );
  }
}

/// 只渲染一个气泡,给测试用。
///
/// 测试要验证"图片消息画的是图,不是 `![图] 文件名` 这行字"。
/// 为了这一条去启动整个 app(要 key、要存储、要平台通道)代价太大,
/// 所以把气泡单独暴露出来。
class ChatBubbleProbe extends StatelessWidget {
  const ChatBubbleProbe({super.key, required this.text, this.isUser = true});

  final String text;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    return _Bubble(
      text: text,
      isUser: isUser,
      dark: Theme.of(context).brightness == Brightness.dark,
      provider: AiProvider.unknown,
      avatar: null,
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
    required this.webSearch,
    required this.onToggleWebSearch,
    required this.onPickRange,
    required this.onClearRange,
    required this.onAttach,
    required this.onMeme,
    required this.onRemoveAttachment,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final DataRange? attachRange;
  final List<ChatAttachment> attachments;
  final bool dark;
  final bool webSearch;
  final VoidCallback onToggleWebSearch;
  final VoidCallback onPickRange;
  final VoidCallback onClearRange;
  final VoidCallback onAttach;
  final VoidCallback onMeme;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    final attached = attachRange != null;

    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          top: BorderSide(
            color: dark ? const Color(0xFF2A2D33) : const Color(0xFFE8E9ED),
          ),
        ),
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 12,
        top: 10,
        bottom: MediaQuery.of(context).viewInsets.bottom + 10,
      ),
      child: Column(
        children: [
          // 这两个胶囊**横向可滚**,不是硬挤在一行里。
          //
          // 用户反馈"输入框那排按钮太挤"。挤的根源是这一行必须容下两个
          // 带文字的胶囊,而文字长度随状态变("带上近期数据"↔具体日期区间,
          // "联网搜索"↔"联网搜索已开")——窄屏上必然溢出。
          // 让它能滚,就不用为了塞下最长的那种情况去压缩间距。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                InkWell(
                  onTap: onPickRange,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
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
                          attached
                              ? Icons.check_circle
                              : Icons.add_circle_outline,
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
                const SizedBox(width: 6),
                // 联网搜索开关。默认关:一次搜索在服务端是一个完整模型回合,
                // 花多少由用户自己决定。
                InkWell(
                  onTap: onToggleWebSearch,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: webSearch
                          ? AppTheme.accent.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: webSearch
                            ? AppTheme.accent
                            : textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          webSearch ? Icons.public : Icons.public_off,
                          size: 13,
                          color: webSearch ? AppTheme.accent : textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          webSearch ? '联网搜索已开' : '联网搜索',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: webSearch ? AppTheme.accent : textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 已附上的图片/文件先在这儿露个脸,可以逐个去掉。
          if (attachments.isNotEmpty) ...[
            SizedBox(
              height: 58,
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
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 加附件。
              IconButton(
                onPressed: sending ? null : onAttach,
                icon: Icon(
                  Icons.add_photo_alternate_outlined,
                  color: textSecondary,
                ),
                tooltip: '加图片或文件',
              ),
              // 表情包。和"加附件"分成两个按钮:一个是发自己的文件,
              // 一个是从内置图库里挑,用户的心智不一样。
              IconButton(
                onPressed: sending ? null : onMeme,
                icon: Icon(Icons.emoji_emotions_outlined, color: textSecondary),
                tooltip: '发表情包',
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
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    final textPrimary = dark
        ? AppTheme.darkTextPrimary
        : AppTheme.lightTextPrimary;

    // 图片/表情包直接显示**缩略图**,不是"图片 xxx.jpg"这种文件名。
    // 选了图之后要能一眼确认选的是哪张——那正是用户此刻唯一关心的事。
    if (attachment.isImage) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 62,
                height: 62,
                child: _AttachmentThumb(attachment: attachment),
              ),
            ),
            // 右上角的叉,压在图上。命中区撑到 24 才好点。
            Positioned(
              right: -6,
              top: -6,
              child: InkWell(
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF3A3D44) : Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: Icon(Icons.close, size: 14, color: textSecondary),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: textSecondary.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 15, color: AppTheme.accent),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
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
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 待发图片的缩略图。
///
/// 三种来源都要能画出来:内存里的字节(刚从相册选的)、内置表情包(asset)、
/// 以及已落盘的本地文件。
class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({required this.attachment});

  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Colors.black12,
      child: Icon(
        Icons.image_outlined,
        size: 20,
        color: Colors.white.withValues(alpha: 0.8),
      ),
    );

    final bytes = attachment.imageBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => placeholder,
      );
    }
    if (attachment.imageRef.startsWith('asset:')) {
      return Image.asset(
        'assets/${attachment.imageRef.substring('asset:'.length)}',
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => placeholder,
      );
    }
    if (attachment.imageRef.isNotEmpty) {
      return FutureBuilder<File?>(
        future: ChatImages.file(attachment.imageRef),
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) return placeholder;
          return Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) => placeholder,
          );
        },
      );
    }
    return placeholder;
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.hasKey, required this.dark});

  final bool hasKey;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final textSecondary = dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
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
