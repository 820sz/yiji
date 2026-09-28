import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// 接口设置页:API key、模型、地址、称呼。
///
/// API key 保存在手机本地,界面里要如实说明,不能让用户以为被上传了。
/// 思考强度与头像在「我的」页直接改,不埋在这里。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _key = TextEditingController();
  final _baseUrl = TextEditingController();
  final _name = TextEditingController();
  String _model = AiConfig.defaultModel;
  bool _obscure = true;
  bool _filled = false;

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _name.dispose();
    super.dispose();
  }

  /// 用已保存的设置把输入框填上。
  ///
  /// 必须放在 `didChangeDependencies` 而不是 `initState`:
  /// 继承组件(AppScope)不允许在 initState 里读取。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_filled) return;
    _filled = true;

    final state = AppScope.of(context);
    final config = state.aiConfig;
    _key.text = config.apiKey;
    _baseUrl.text = config.baseUrl;
    _name.text = state.displayName;
    _model = config.model;
  }

  Future<void> _save() async {
    final state = AppScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await state.saveAiConfig(
      state.aiConfig.copyWith(
        apiKey: _key.text,
        baseUrl: _baseUrl.text.trim().isEmpty
            ? AiConfig.defaultBaseUrl
            : _baseUrl.text.trim(),
        model: _model,
      ),
    );
    await state.saveDisplayName(_name.text);
    messenger.showSnackBar(const SnackBar(content: Text('已保存')));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('API key 与模型'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _key,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'API key',
              hintText: 'sk-...',
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: AiConfig.knownModels.contains(_model) ? _model : null,
            decoration: const InputDecoration(labelText: '模型'),
            dropdownColor: dark ? AppTheme.darkSurface : AppTheme.lightSurface,
            items: [
              for (final model in AiConfig.knownModels)
                DropdownMenuItem(value: model, child: Text(model)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _model = value);
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _baseUrl,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '接口地址',
              hintText: AiConfig.defaultBaseUrl,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'AI 怎么称呼你(可留空)',
              hintText: '留空就用「我」来写总结',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'key 只存在这台手机里。\n接口地址默认是 DeepSeek,想用别家 OpenAI 兼容接口就改这里。',
            style: TextStyle(fontSize: 12.5, height: 1.7, color: textSecondary),
          ),
          if (!state.aiConfig.isUsable)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                '还没填 key,进度同步、总结和聊天都用不了。',
                style: TextStyle(fontSize: 12.5, color: Color(0xFFE05252)),
              ),
            ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
