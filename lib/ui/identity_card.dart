import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../state/app_state.dart';
import 'chat_sidebar.dart';
import 'prompt_dialog.dart';
import 'theme.dart';

/// 用户身份卡片。
///
/// 放在「我的」页最上方:这是"我"的页面,先看到该是自己,而不是 AI 的模型名。
/// 卡片上有自定义背景、头像、ID(就是称呼)和个性签名,都能点着改。
class IdentityCard extends StatelessWidget {
  const IdentityCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = state.cardBackgroundBytes;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            // 底:自定义背景图,没设过就用一层渐变。
            Positioned.fill(
              child: background != null
                  ? Image.memory(
                      background,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) => _GradientBackdrop(dark: dark),
                    )
                  : _GradientBackdrop(dark: dark),
            ),
            // 背景图可能很亮,压一层暗罩保证白字读得清。
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: background == null ? 0.06 : 0.34),
              ),
            ),
            InkWell(
              onTap: () => _editSignature(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 12, 20),
                child: Row(
                  children: [
                    // 点头像换图。
                    GestureDetector(
                      onTap: () => pickImageInto(
                        context,
                        title: '换头像',
                        onPicked: state.saveUserAvatar,
                      ),
                      child: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.75),
                                width: 2,
                              ),
                            ),
                            child: UserAvatar(
                              bytes: state.userAvatarBytes,
                              name: state.identityLabel,
                              size: 56,
                            ),
                          ),
                          // 一个小的相机角标,不然没人知道头像是可以点的。
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: AppTheme.accent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.photo_camera,
                                size: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            state.identityLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            state.bio.trim().isEmpty ? '点这里写一句签名' : state.bio,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: Colors.white.withValues(
                                alpha: state.bio.trim().isEmpty ? 0.65 : 0.9,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 换背景图。
                    IconButton(
                      onPressed: () => pickImageInto(
                        context,
                        title: '换背景',
                        onPicked: state.saveCardBackground,
                        onRemove: state.cardBackgroundBytes == null
                            ? null
                            : () => state.saveCardBackground(null),
                      ),
                      icon: Icon(
                        Icons.wallpaper,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                      tooltip: '换背景',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editSignature(BuildContext context) async {
    final state = AppScope.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => TextPromptDialog(
        title: '个性签名',
        initialValue: state.bio,
        hintText: '想对自己说点什么',
        maxLength: 40,
        maxLines: 2,
      ),
    );
    if (result != null) await state.saveBio(result);
  }
}

/// 没设背景图时的默认底:一层低饱和渐变,和浅/深色主题各自协调。
class _GradientBackdrop extends StatelessWidget {
  const _GradientBackdrop({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF2B3242), Color(0xFF1D2230)]
              : const [Color(0xFF4C6BA8), Color(0xFF6E8BD0)],
        ),
      ),
    );
  }
}

/// 从相册选一张图,裁成方形后交给 [onPicked]。
///
/// 抽出来是因为头像和背景两处都要用,而"选图 → 压缩 → 存字节 → 错误提示"
/// 这段逻辑一模一样。三处各写一遍必然会漂。
Future<void> pickImageInto(
  BuildContext context, {
  required String title,
  required Future<void> Function(Uint8List? bytes) onPicked,
  VoidCallback? onRemove,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选一张'),
            onTap: () => Navigator.pop(context, 'pick'),
          ),
          if (onRemove != null)
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('恢复默认'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ],
      ),
    ),
  );

  if (choice == 'remove') {
    onRemove?.call();
    return;
  }
  if (choice != 'pick' || !context.mounted) return;

  try {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // 展示尺寸不大,先让系统压到 1024,省内存也省存储。
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 88,
    );
    if (file == null) return;
    await onPicked(await file.readAsBytes());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$title成功')));
  } on Exception catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('选图失败:$error')));
  }
}
