import 'package:flutter/material.dart';

/// 一个单行输入的对话框。
///
/// 存在的理由是一个很容易踩的坑:`await showDialog(...)` 之后再去
/// `controller.dispose()` 是**错的**。dialog 的 future 在 pop 的那一刻就完成了,
/// 但路由还要跑完退场动画(约 150ms),这期间输入框仍在树上;键盘收起会让
/// 对话框重建,重建时会读 `controller.value.text`,读到已释放的 controller
/// 就抛 "A TextEditingController was used after being disposed"。
///
/// 所以 controller 必须由对话框自己建、自己放——也就是下面这个 StatefulWidget
/// 干的事。调用方只管传初值和校验,不碰 controller。
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.initialValue,
    this.hintText,
    this.suffixText,
    this.maxLength,
    this.maxLines = 1,
    this.confirmLabel = '保存',
    this.keyboardType,
    this.validator,
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final String? suffixText;
  final int? maxLength;
  final int maxLines;
  final String confirmLabel;
  final TextInputType? keyboardType;

  /// 返回 null 表示这份输入可以接受;返回一句话则显示在输入框下方并拦住保存。
  final String? Function(String text)? validator;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final problem = widget.validator?.call(text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        maxLength: widget.maxLength,
        maxLines: widget.maxLines,
        minLines: 1,
        decoration: InputDecoration(
          hintText: widget.hintText,
          suffixText: widget.suffixText,
          errorText: _error,
          counterText: '',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// 弹一个只收一个正数的输入框(带单位后缀),取消或填不合法时返回 null。
///
/// 用于修正 AI 判断错的推进量:点一条记录就能把数字改对,而不是只能删掉重来。
Future<double?> showAmountDialog(
  BuildContext context, {
  required String initial,
  required String unit,
}) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) => TextPromptDialog(
      title: '改成多少',
      initialValue: initial,
      hintText: '推进量',
      suffixText: unit.isEmpty ? null : unit,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (value) {
        final parsed = double.tryParse(value);
        if (parsed == null) return '填一个数字';
        if (parsed <= 0) return '要大于 0';
        return null;
      },
    ),
  );
  return text == null ? null : double.tryParse(text);
}
