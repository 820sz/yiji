import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

/// 头像形状。
enum AvatarShape {
  circle('圆'),
  rounded('圆角方'),
  square('方');

  const AvatarShape(this.label);

  final String label;
}

/// 裁图的结果:一张已经按用户调整好的方形 PNG,加上他选的形状。
class CroppedImage {
  const CroppedImage({required this.bytes, required this.shape});

  final Uint8List bytes;
  final AvatarShape shape;
}

/// 让用户调整一张图:放大缩小、拖动位置、选形状,确认后输出裁好的图。
///
/// 之前换头像/换背景只能从相册选一张就完事——**没法调大小和位置**,
/// 选到的图往往主体偏在一边或者被裁掉一半,而用户没有任何办法补救。
/// 这里把手动调整补上:捏合缩放、拖动、以及头像形状。
///
/// [aspect] 是裁剪框的宽高比(头像用 1,背景用 16/9)。
/// [withShape] 打开形状选择(只有头像需要)。
/// [outputSize] 输出边长。默认 512 够头像用;名片背景那类要更大的传 1080。
Future<CroppedImage?> showImageCropper(
  BuildContext context, {
  required Uint8List bytes,
  double aspect = 1,
  bool withShape = false,
  AvatarShape initialShape = AvatarShape.circle,
  int outputSize = 512,
}) {
  return Navigator.of(context).push<CroppedImage>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _CropperPage(
        bytes: bytes,
        aspect: aspect,
        withShape: withShape,
        initialShape: initialShape,
        outputSize: outputSize,
      ),
    ),
  );
}

class _CropperPage extends StatefulWidget {
  const _CropperPage({
    required this.bytes,
    required this.aspect,
    required this.withShape,
    required this.initialShape,
    required this.outputSize,
  });

  final Uint8List bytes;
  final double aspect;
  final bool withShape;
  final AvatarShape initialShape;
  final int outputSize;

  @override
  State<_CropperPage> createState() => _CropperPageState();
}

class _CropperPageState extends State<_CropperPage> {
  /// 缩放倍数。1 表示图片刚好铺满裁剪框。
  double _scale = 1;

  /// 拖动位移,单位是逻辑像素(相对裁剪框中心)。
  Offset _offset = Offset.zero;

  /// 开始手势时的基准值。
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  late AvatarShape _shape = widget.initialShape;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('调整图片', style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: _busy ? null : _confirm,
            child: Text(
              _busy ? '处理中…' : '完成',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 裁剪框:按目标比例放进可用空间。
                  final boxWidth = constraints.maxWidth - 32;
                  final boxHeight = boxWidth / widget.aspect;
                  final safeHeight = constraints.maxHeight - 32;
                  final size = boxHeight > safeHeight
                      ? Size(safeHeight * widget.aspect, safeHeight)
                      : Size(boxWidth, boxHeight);
                  return _cropBox(size, dark);
                },
              ),
            ),
          ),
          _controls(dark, textPrimary, textSecondary),
        ],
      ),
    );
  }

  Widget _cropBox(Size size, bool dark) {
    final radius = switch (_shape) {
      AvatarShape.circle => size.width / 2,
      AvatarShape.rounded => 24.0,
      AvatarShape.square => 4.0,
    };

    return GestureDetector(
      onScaleStart: (details) {
        _startScale = _scale;
        _startOffset = _offset;
        _startFocal = details.localFocalPoint;
      },
      onScaleUpdate: (details) {
        setState(() {
          // 捏合缩放(单指拖动时 scale 恒为 1,只走位移分支)。
          _scale = (_startScale * details.scale).clamp(1.0, 6.0);
          _offset = _startOffset + (details.localFocalPoint - _startFocal);
        });
      },
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 图片:按 cover 铺满,再叠加用户的缩放与位移。
              Transform.translate(
                offset: _offset,
                child: Transform.scale(
                  scale: _scale,
                  child: Image.memory(
                    widget.bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
              // 裁剪框描边,让人看清边界在哪。
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.85),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(bool dark, Color textPrimary, Color textSecondary) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.zoom_out, size: 18, color: Colors.white70),
                Expanded(
                  child: Slider(
                    value: _scale,
                    min: 1,
                    max: 6,
                    // 拖动滑杆就是放大缩小;手指在图上捏合也行。
                    onChanged: (value) => setState(() => _scale = value),
                  ),
                ),
                const Icon(Icons.zoom_in, size: 18, color: Colors.white70),
              ],
            ),
            if (widget.withShape) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '形状',
                    style: TextStyle(fontSize: 13, color: textSecondary),
                  ),
                  const SizedBox(width: 12),
                  for (final shape in AvatarShape.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(shape.label),
                        selected: _shape == shape,
                        onSelected: (_) => setState(() => _shape = shape),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '双指缩放、拖动调整位置',
              style: TextStyle(fontSize: 12, color: textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// 把用户看到的画面原样渲染成一张方形 PNG。
  ///
  /// 用 `toImage` 重画一遍,而不是把参数存下来留给界面自己去 Transform——
  /// 存参数的话,聊天头像、侧边栏、报告页每一处渲染都得跟着实现一遍同样的
  /// 变换,漏一处就长得不一样。存成图就只有一份真相。
  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final bytes = await _render();
      if (!mounted) return;
      Navigator.pop(context, CroppedImage(bytes: bytes, shape: _shape));
    } catch (_) {
      // 渲染失败就退回原图,至少不会让用户卡在这个页面出不去。
      if (!mounted) return;
      Navigator.pop(
        context,
        CroppedImage(bytes: widget.bytes, shape: _shape),
      );
    }
  }

  Future<Uint8List> _render() async {
    final output = widget.outputSize.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, output, output));

    final image = await _decode(widget.bytes);
    // 和界面上一致的 cover 计算:先把图缩放到铺满,再乘用户的缩放。
    final cover = output / (image.width < image.height ? image.width : image.height);
    // 注意界面上的裁剪框是正方形(头像)或按 aspect(背景),这里统一输出方形,
    // 背景那侧由界面自己按比例裁——存方形是为了让同一份数据能复用。
    final drawScale = cover * _scale;
    final drawnWidth = image.width * drawScale;
    final drawnHeight = image.height * drawScale;
    // 位移是相对裁剪框中心的,换算到输出画布上要按比例放大。
    final offsetScale = output / 300;
    final dx = (output - drawnWidth) / 2 + _offset.dx * offsetScale;
    final dy = (output - drawnHeight) / 2 + _offset.dy * offsetScale;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(dx, dy, drawnWidth, drawnHeight),
      Paint()..filterQuality = FilterQuality.high,
    );

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(output.toInt(), output.toInt());
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    rendered.dispose();
    image.dispose();
    return data!.buffer.asUint8List();
  }

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }
}
