import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../state/app_state.dart';
import 'chat_sidebar.dart';
import 'image_cropper.dart';
import 'prompt_dialog.dart';
import 'theme.dart';

/// 用户身份卡片。
///
/// 放在「我的」页最上方:这是"我"的页面,先看到该是自己,而不是 AI 的模型名。
/// 卡片上有自定义背景、头像、ID(就是称呼)和个性签名。
///
/// **每一项都能点着改,而且点哪里改什么是明确的**:
/// - 点头像 → 换头像
/// - 点名字 → 改称呼
/// - 点签名 → 改签名
/// - 右下角画笔 → 换背景图
///
/// 之前这几处的问题出在命中区互相压:整张卡被一个"改签名"的 InkWell 包住,
/// 头像的点击被它抢走,而换背景只有一个不显眼的小图标。现在每个可点区域
/// 各自独立,并且在卡片上放了一个明确的「编辑名片」入口。
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
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // 底:自定义背景图,没设过就用一层渐变。
            Positioned.fill(
              child: background != null
                  ? Image.memory(
                      background,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) =>
                          _GradientBackdrop(dark: dark),
                    )
                  : _GradientBackdrop(dark: dark),
            ),
            // 背景图可能很亮,压一层暗罩保证白字读得清。
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: background == null ? 0.06 : 0.34),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 10, 18),
              child: Row(
                children: [
                  _AvatarButton(state: state),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 名字:点一下改称呼。
                        _TapRow(
                          onTap: () => _editName(context, state),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  state.identityLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.w700,
                                    height: 1.15,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                Icons.edit,
                                size: 13,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        // 签名:点一下改签名。
                        _TapRow(
                          onTap: () => _editSignature(context, state),
                          child: Text(
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
                        ),
                      ],
                    ),
                  ),
                  // 换背景。画笔比"壁纸"图标更像"编辑这张卡"。
                  IconButton(
                    onPressed: () => _editBackground(context, state),
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.28),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.brush_outlined,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                    tooltip: '换背景图',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 改称呼。留空就回到默认的"我"。
  static Future<void> _editName(BuildContext context, AppState state) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => TextPromptDialog(
        title: '怎么称呼你',
        initialValue: state.displayName,
        hintText: '留空就只显示「我」',
        maxLength: 12,
      ),
    );
    if (name != null) await state.saveDisplayName(name);
  }

  static Future<void> _editSignature(BuildContext context, AppState state) async {
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

  /// 换背景:没设过就直接选图;设过则先问是调整还是恢复默认。
  ///
  /// "调整"是重选一张再调——把已存的图拿出来调需要额外存原图,
  /// 而名片背景本来就是低频操作,重选一次的代价远小于为此存两份数据。
  static Future<void> _editBackground(BuildContext context, AppState state) async {
    final hasBackground = state.cardBackgroundBytes != null;
    if (hasBackground) {
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
                title: const Text('恢复默认渐变'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      );
      if (choice == null || !context.mounted) return;
      if (choice == 'remove') {
        await state.saveCardBackground(null);
        return;
      }
    }
    if (!context.mounted) return;
    await _changeBackground(context, state);
  }
}

/// 一个"点了就有反应"的小区域。
///
/// 用 InkWell 而不是 GestureDetector:在图片背景上能给出水波反馈,
/// 用户才知道这里是可点的。
class _TapRow extends StatelessWidget {
  const _TapRow({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: child,
      ),
    );
  }
}

/// 头像 + 一个明确的相机角标。
class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _changeAvatar(context, state),
      customBorder: const CircleBorder(),
      child: Stack(
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.8),
                width: 2,
              ),
            ),
            child: UserAvatar(
              bytes: state.userAvatarBytes,
              name: state.identityLabel,
              size: 58,
              shape: state.userAvatarShape,
            ),
          ),
          // 相机角标:不点它也算点头像,但它让人知道头像是可以换的。
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppTheme.accent,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: const Icon(
                Icons.photo_camera,
                size: 11,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
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

/// 换头像:选图 → 调整(缩放/位置/形状)→ 保存。
///
/// 之前只做到"选一张",没有任何调整手段,主体偏了就只能重选——用户明确说过
/// 头像和背景"全都没法调整"。调整这一步不能省。
Future<void> _changeAvatar(BuildContext context, AppState state) async {
  final picked = await _pickFromGallery(context);
  if (picked == null || !context.mounted) return;

  final cropped = await showImageCropper(
    context,
    bytes: picked,
    aspect: 1,
    withShape: true,
    initialShape: state.userAvatarShape,
  );
  if (cropped == null) return;
  await state.saveUserAvatar(cropped.bytes);
  await state.saveUserAvatarShape(cropped.shape);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('头像已更新')));
}

/// 换背景图,同样先让用户调好位置。
Future<void> _changeBackground(BuildContext context, AppState state) async {
  final picked = await _pickFromGallery(context);
  if (picked == null || !context.mounted) return;

  final cropped = await showImageCropper(
    context,
    bytes: picked,
    // 名片是宽的,按 16:9 让用户调。
    aspect: 16 / 9,
  );
  if (cropped == null) return;
  await state.saveCardBackground(cropped.bytes);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('背景已更新')));
}

/// 从相册选一张原图字节。用户取消返回 null。
Future<Uint8List?> _pickFromGallery(BuildContext context) async {
  try {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // 不给系统压:压缩会先把边缘裁掉,用户再调就没有余地了。
      // 真正落盘的尺寸由裁剪页控制。
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 92,
    );
    if (file == null) return null;
    return await file.readAsBytes();
  } on Exception catch (error) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('选图失败:$error')));
    return null;
  }
}
