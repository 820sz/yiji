import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_client.dart';

/// AI 设置的读写。key 只存在手机本地的 SharedPreferences 里,不上传任何服务器。
class SettingsStore {
  SettingsStore(this._prefs);

  static const _keyApiKey = 'ai_api_key';
  static const _keyBaseUrl = 'ai_base_url';
  static const _keyModel = 'ai_model';
  static const _keyThinking = 'ai_thinking_level';
  static const _keyDisplayName = 'user_display_name';
  static const _keyAvatar = 'ai_avatar_base64';
  static const _keyDarkMode = 'ui_dark_mode';
  static const _keySplashText = 'ui_splash_text';

  /// 开屏那句话的默认值。
  static const defaultSplashText = '小习惯、大不同';

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async {
    return SettingsStore(await SharedPreferences.getInstance());
  }

  AiConfig get aiConfig => AiConfig(
        apiKey: _prefs.getString(_keyApiKey) ?? '',
        baseUrl: _prefs.getString(_keyBaseUrl) ?? AiConfig.defaultBaseUrl,
        model: _prefs.getString(_keyModel) ?? AiConfig.defaultModel,
        thinking: ThinkingLevel.fromKey(_prefs.getString(_keyThinking)),
      );

  Future<void> saveAiConfig(AiConfig config) async {
    await _prefs.setString(_keyApiKey, config.apiKey.trim());
    await _prefs.setString(_keyBaseUrl, config.baseUrl.trim());
    await _prefs.setString(_keyModel, config.model);
    await _prefs.setString(_keyThinking, config.thinking.name);
  }

  /// 报告里怎么称呼本人(如"我"或名字),用于让 AI 的行文更贴身。
  String get displayName => _prefs.getString(_keyDisplayName) ?? '';

  Future<void> saveDisplayName(String name) async {
    await _prefs.setString(_keyDisplayName, name.trim());
  }

  /// 用户自定义的 AI 头像;没设过返回 null,界面用模型图标兜底。
  ///
  /// 用 base64 存在 SharedPreferences 而不是写真个文件:头像很小(展示时已压到
  /// 256px),省掉文件路径、权限与清理逻辑。
  Uint8List? get avatarBytes {
    final encoded = _prefs.getString(_keyAvatar);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      // 存坏了(极少见):当作没设过,不要把界面拖崩。
      return null;
    }
  }

  Future<void> saveAvatar(Uint8List? bytes) async {
    if (bytes == null) {
      await _prefs.remove(_keyAvatar);
      return;
    }
    await _prefs.setString(_keyAvatar, base64Encode(bytes));
  }

  /// 深色模式。默认关(浅色,与原子笔记一致)。
  bool get darkMode => _prefs.getBool(_keyDarkMode) ?? false;

  Future<void> saveDarkMode(bool value) async {
    await _prefs.setBool(_keyDarkMode, value);
  }

  /// 开屏那句话。留空时回到默认文案——开屏上不该出现空白。
  String get splashText {
    final text = _prefs.getString(_keySplashText)?.trim() ?? '';
    return text.isEmpty ? defaultSplashText : text;
  }

  Future<void> saveSplashText(String text) async {
    await _prefs.setString(_keySplashText, text.trim());
  }
}
