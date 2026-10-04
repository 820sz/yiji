import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 聊天里附带的一个附件。
///
/// 两类走不同的路:
/// - **图片**按 OpenAI 兼容的多模态格式发给模型(DeepSeek 只有 `deepseek-flash` 支持);
/// - **文本文件**读成文本拼进消息里——模型看的是内容,不是二进制。
///
/// 二进制文件(压缩包、exe 之类)没有意义,在挑选阶段就挡掉。
class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.isImage,
    this.imageBytes,
    this.text,
    this.sizeBytes = 0,
    this.imageRef = '',
    this.memeCaption = '',
  });

  final String name;
  final bool isImage;

  /// 图片的原始字节(仅 [isImage] 时有值)。
  final Uint8List? imageBytes;

  /// 文本文件的内容(仅非图片时有值)。
  final String? text;

  final int sizeBytes;

  /// 图片存下来之后的引用(`asset:...` 或磁盘文件名)。
  ///
  /// 消息文本里记的是它而不是字节:回看历史要能把图重新渲染出来,
  /// 而 base64 进库会让每条消息膨胀几百 KB。
  final String imageRef;

  /// 表情包的一句描述(只有表情包会填),用来在待发列表里说明这是什么。
  final String memeCaption;

  /// 能直接读成文本的扩展名。
  ///
  /// 只列常见的纯文本类型:宁可让用户看到"不支持",也不要把二进制硬读成乱码塞给模型。
  static const textExtensions = {
    'txt', 'md', 'markdown', 'json', 'yaml', 'yml', 'csv', 'tsv',
    'dart', 'kt', 'java', 'py', 'js', 'ts', 'html', 'css', 'xml',
    'log', 'ini', 'toml', 'sh', 'bat', 'sql',
  };

  static const imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};

  /// 文本文件读到内存的上限。
  ///
  /// 超过这个大小就不读:整本书塞进上下文既贵又没用,而且手机内存也吃不消。
  static const maxTextBytes = 256 * 1024;

  /// 从磁盘上的一个文件构造附件。
  ///
  /// 返回 null 表示这个类型不支持(调用方据此提示用户)。
  static Future<ChatAttachment?> fromFile(File file, String name) async {
    return fromBytes(await file.readAsBytes(), name);
  }

  /// 从内存里的字节构造附件。
  ///
  /// 选择器给出字节时用这个,省掉一次落盘再读回来。
  /// 返回 null 表示类型不支持或超过大小上限。
  static Future<ChatAttachment?> fromBytes(Uint8List bytes, String name) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final size = bytes.length;

    if (imageExtensions.contains(ext)) {
      return ChatAttachment(
        name: name,
        isImage: true,
        imageBytes: bytes,
        sizeBytes: size,
      );
    }
    if (textExtensions.contains(ext)) {
      if (size > maxTextBytes) return null;
      // 用 allowMalformed 兜住偶发的非 UTF-8 字节,避免整次发送因为一个坏字符失败。
      return ChatAttachment(
        name: name,
        isImage: false,
        text: utf8.decode(bytes, allowMalformed: true),
        sizeBytes: size,
      );
    }
    return null;
  }

  /// 从内置或用户自添加的表情包构造一个附件。
  ///
  /// **内置图一律用 `asset:` 引用,不落盘。**
  ///
  /// 曾经反过来做过:把内置图的字节抄一份到私有目录、消息里记那个文件名。
  /// 那是错的——文件会被系统清掉、也可能写失败,一旦没了,那条消息就永远
  /// 显示"图不在了",而同一张图就在安装包里躺着(用户报的正是这个)。
  /// `asset:` 引用指向 APK 内的资源,不可能丢失。
  ///
  /// 用户自己发来的照片仍然落盘,它没有别的来源。
  factory ChatAttachment.meme({
    required String assetPath,
    required String caption,
    required String tag,
    Uint8List? bytes,
    bool fromUser = false,
  }) {
    // 用户自添加的表情包:图在私有目录里,只能靠文件名引用,
    // 所以它必须落盘(和照片同一条路)。
    if (fromUser) {
      return ChatAttachment(
        name: caption.isEmpty ? '表情包' : caption,
        isImage: true,
        imageBytes: bytes,
        imageRef: '',
        memeCaption: caption,
        sizeBytes: bytes?.length ?? 0,
      );
    }
    return ChatAttachment(
      name: caption.isEmpty ? '表情包' : caption,
      isImage: true,
      imageBytes: null,
      imageRef: 'asset:$assetPath',
      memeCaption: caption,
      sizeBytes: 0,
    );
  }

  /// 拼进消息文本里的样子。
  ///
  /// 图片行写成 `![图] <引用>[ | 说明]`,界面据此把图渲染出来(而不是显示文件名)。
  ///
  /// **说明保留**:模型现在能看图了(多模态),但那句话仍是有效的补充——
  /// 它告诉模型这张图在情绪上是什么意思,尤其在画面本身不直白的时候。
  String get describe {
    if (!isImage) return '[文件] $name';
    if (imageRef.isEmpty) return '[图片] $name';
    return '![图] $imageRef${memeCaption.isEmpty ? '' : ' | $memeCaption'}';
  }
}
