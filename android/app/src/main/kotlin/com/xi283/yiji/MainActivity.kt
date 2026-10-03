package com.xi283.yiji

import android.app.DownloadManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 让 Flutter 掌控屏幕边缘,并提供"安装下载好的 APK"这个能力。
///
/// 不显式设置 insets 归属的话,不同 ROM 对"内容是否铺到状态栏下面"的默认行为不一致:
/// 同一份布局在有的机型上顶到刘海、有的留白。这里统一声明为应用自己处理,
/// 布局侧再用 SafeArea 让开状态栏与手势区。
///
/// 安装 APK 没有用第三方插件:`install_plugin` 已两年没更新、缺少 AGP 8 要求的
/// namespace 声明,会直接让构建失败。自己写这几十行更可控,也少一个停更依赖。
class MainActivity : FlutterActivity() {
    private val channelName = "com.xi283.yiji/install"

    /// 打开系统设置用的通道。和安装分开:安装那条只在下载更新时用,
    /// 这条会在用户设提醒、发现通知没开时用到。
    private val settingsChannelName = "com.xi283.yiji/app"

    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 状态栏与导航栏透明,底色交给 Flutter 的 Scaffold。
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "缺少 path", null)
                        } else {
                            installApk(path, result)
                        }
                    }
                    // 交给系统下载器。
                    //
                    // 应用内那条路(Dart 流式读到内存再落盘)在受限网络下会拿到
                    // 拦截页、或者被中途掐断,而且失败只能靠我们自己辨认。
                    // 系统下载器是独立的、带通知进度、会自己重试,失败了用户也能
                    // 在通知栏看见并重来——网络不好的时候这条路成功率高得多。
                    "downloadWithSystem" -> {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "yiji-update.apk"
                        if (url == null) {
                            result.error("bad_args", "缺少 url", null)
                        } else {
                            startSystemDownload(url, fileName, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, settingsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openNotificationSettings" -> {
                        result.success(openNotificationSettings())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 跳到本应用的通知设置页。
    ///
    /// Android 8 起可以直接落到应用的通知页;更老的系统只能落到应用详情页。
    private fun openNotificationSettings(): Boolean {
        val intents = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                add(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                )
            }
            add(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:$packageName"))
            )
        }
        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // 这个 ROM 没有这个页面,试下一个。
            }
        }
        return false
    }

    /// 用系统下载器把安装包下到公共「下载」目录。
    ///
    /// 选公共下载目录而不是应用私有目录:下载完的通知点一下就能装,
    /// 装不上时用户也能自己在文件管理器里找到它。
    private fun startSystemDownload(url: String, fileName: String, result: MethodChannel.Result) {
        try {
            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle("忆记更新包")
                .setDescription("正在下载 $fileName")
                .setMimeType("application/vnd.android.package-archive")
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
                // 允许在计费网络上继续:用户既然主动点了,就别因为切到流量而中断。
                .setAllowedOverMetered(true)

            val manager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
            val id = manager.enqueue(request)
            result.success(id)
        } catch (error: Exception) {
            result.error("download_failed", error.message ?: "系统下载器启动失败", null)
        }
    }

    /// Android 8 起安装未知来源应用需要用户单独授权。
    private fun canRequestPackageInstalls(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun installApk(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists()) {
            result.error("missing_file", "安装包不存在:$path", null)
            return
        }

        // 没授权时先把用户送到那个设置页:直接 startActivity 会被系统静默拒掉,
        // 用户只会看到"点了没反应"。
        if (!canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:$packageName"))
            )
            result.error("no_permission", "请先允许「安装未知应用」,再点一次", null)
            return
        }

        try {
            // 用 FileProvider 给安装器一个临时可读的 content:// 地址:
            // 直接把 file:// 交出去在 Android 7 以上会抛 FileUriExposedException。
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            result.success(null)
        } catch (error: Exception) {
            result.error("install_failed", error.message ?: "安装失败", null)
        }
    }
}
