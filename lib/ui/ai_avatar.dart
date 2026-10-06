import 'dart:typed_data';

import 'package:flutter/material.dart';

/// AI 供应商识别。
///
/// 头像默认用**所配模型背后的厂商 logo**——用户配的是 DeepSeek,就该看到 DeepSeek 的鲸鱼,
/// 而不是这个 app 的图标。认不出来的厂商回退到通用的助手标记。
enum AiProvider {
  deepseek('DeepSeek', Color(0xFF4D6BFE)),
  openai('OpenAI', Color(0xFF10A37F)),
  anthropic('Anthropic', Color(0xFFD97757)),
  unknown('其他', Color(0xFF6B7280));

  const AiProvider(this.label, this.brandColor);

  final String label;

  /// 品牌色,用在没有专门绘制 logo 的厂商上。
  final Color brandColor;

  /// 从模型名或接口地址推断厂商。
  ///
  /// 模型名优先(它更具体),"gpt-4o-mini" 这类一眼就能认出来;
  /// 认不出模型名时看接口地址,自建代理往往只改地址不改模型名。
  static AiProvider from({required String model, required String baseUrl}) {
    final modelLower = model.toLowerCase();
    if (modelLower.contains('deepseek')) return AiProvider.deepseek;
    if (modelLower.startsWith('gpt') ||
        modelLower.startsWith('o1') ||
        modelLower.startsWith('o3') ||
        modelLower.contains('openai')) {
      return AiProvider.openai;
    }
    if (modelLower.contains('claude')) return AiProvider.anthropic;

    final urlLower = baseUrl.toLowerCase();
    if (urlLower.contains('deepseek')) return AiProvider.deepseek;
    if (urlLower.contains('openai')) return AiProvider.openai;
    if (urlLower.contains('anthropic') || urlLower.contains('claude')) {
      return AiProvider.anthropic;
    }
    return AiProvider.unknown;
  }
}

/// 品牌标记:深色圆角方块 + 暖黄钩子。
///
/// 和桌面图标、开屏图标是同一套形状,所以空状态也用它,
/// 用户在三处看到的是同一个符号。
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size, this.radius = 22});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF2E3136),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        Icons.check_rounded,
        size: size * 0.56,
        color: const Color(0xFFFBE8A6),
      ),
    );
  }
}

/// AI 头像。
///
/// 优先级:用户上传的图 > 厂商 logo。用户主动换过头像就不再被厂商 logo 覆盖。
///
/// 头像字节做**静态缓存**:聊天流式输出时整棵列表每帧重建,如果每次都新建
/// Image.memory,Flutter 会认成另一张图而重新解码 + 重新淡入,
/// 表现出来就是"头像一直闪"。缓存住 ImageProvider,同一张图只解码一次。
class AiAvatar extends StatelessWidget {
  const AiAvatar({
    super.key,
    required this.provider,
    required this.dark,
    this.bytes,
    this.size = 32,
  });

  /// 用户自定义头像;为 null 时用厂商 logo。
  final Uint8List? bytes;

  final AiProvider provider;
  final bool dark;
  final double size;

  /// 按字节内容缓存,而不是按每次传进来的 list 实例。
  static final Map<int, MemoryImage> _cache = {};

  static MemoryImage _cachedImage(Uint8List bytes) {
    // 头像很小,用长度 + 前若干字节做键就足够区分;真撞了也只是显示别人的头像,
    // 代价远小于"每帧重新解码"。
    final key = Object.hash(bytes.length, bytes.isEmpty ? 0 : bytes[0], bytes.length > 32 ? bytes[16] : 0);
    return _cache.putIfAbsent(key, () => MemoryImage(bytes));
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.3);

    if (bytes != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image(
          image: _cachedImage(bytes!),
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // 头像文件坏掉时不要整页崩,退回厂商 logo。
          errorBuilder: (context, error, stack) =>
              _ProviderMark(provider: provider, size: size, radius: radius),
        ),
      );
    }
    return _ProviderMark(provider: provider, size: size, radius: radius);
  }
}

/// 厂商标记。有专门画法的画 logo,否则用品牌色 + 首字母。
class _ProviderMark extends StatelessWidget {
  const _ProviderMark({
    required this.provider,
    required this.size,
    required this.radius,
  });

  final AiProvider provider;
  final double size;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    if (provider == AiProvider.deepseek) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: provider.brandColor,
          borderRadius: radius,
        ),
        child: CustomPaint(
          painter: _DeepSeekWhalePainter(),
          size: Size.square(size),
        ),
      );
    }
    if (provider == AiProvider.unknown) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF2E3136),
          borderRadius: radius,
        ),
        child: Icon(
          Icons.auto_awesome,
          size: size * 0.52,
          color: const Color(0xFFFBE8A6),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: provider.brandColor,
        borderRadius: radius,
      ),
      child: Text(
        provider.label.characters.first,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// DeepSeek 的鲸鱼标志,单色描边,不带底座。
///
/// 用在思考过程那一栏上:DS 自己的样式就是浅蓝底 + 一枚品牌色鲸鱼 + 一行蓝字。
class WhaleMark extends StatelessWidget {
  const WhaleMark({
    super.key,
    this.size = 14,
    this.color = const Color(0xFF4D6BFE),
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _DeepSeekWhalePainter(color: color),
      );
}

/// DeepSeek 的鲸鱼标志。
///
/// 按品牌图形的手绘近似:一条上扬的鲸背 + 尾部的水花,用两段三次贝塞尔画成,
/// 所以不需要外挂图片资源,缩到任何尺寸都清晰。
class _DeepSeekWhalePainter extends CustomPainter {
  const _DeepSeekWhalePainter({this.color = Colors.white});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    // 鲸背:从左下的水花起势,拱起到右上。
    final back = Path()
      ..moveTo(w * 0.20, h * 0.66)
      ..cubicTo(w * 0.30, h * 0.30, w * 0.62, h * 0.22, w * 0.80, h * 0.38);
    canvas.drawPath(back, paint);

    // 尾鳍:一个短小的回勾,给轮廓一个收束点。
    final tail = Path()
      ..moveTo(w * 0.80, h * 0.38)
      ..cubicTo(w * 0.86, h * 0.46, w * 0.80, h * 0.56, w * 0.70, h * 0.56);
    canvas.drawPath(tail, paint);

    // 水花:左下两滴,点出"跃出水面"的意思。
    final splash = Paint()..color = color;
    canvas.drawCircle(Offset(w * 0.20, h * 0.66), w * 0.055, splash);
    canvas.drawCircle(Offset(w * 0.32, h * 0.78), w * 0.035, splash);
  }

  @override
  bool shouldRepaint(covariant _DeepSeekWhalePainter oldDelegate) =>
      oldDelegate.color != color;
}
