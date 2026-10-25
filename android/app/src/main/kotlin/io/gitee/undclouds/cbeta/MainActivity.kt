package io.gitee.undclouds.cbeta

import android.Manifest
import android.app.PendingIntent
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "xuefo/app_updater"
    private val downloadChannelName = "xuefo/download_notifications"
    private var downloadChannel: MethodChannel? = null
    private var pendingOpenDownloadManager = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstallPackages" -> {
                    val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(allowed)
                }
                "supportedAbis" -> {
                    result.success(Build.SUPPORTED_ABIS.toList())
                }
                "openInstallPermissionSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        )
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_path", "APK 路徑為空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        // 優先使用 ACTION_VIEW，系統會顯示明確的安裝／權限提示。
                        launchInstallerIntent(path)
                        result.success(null)
                    } catch (error: Exception) {
                        try {
                            // 退回 PackageInstaller 工作階段安裝。
                            installWithPackageInstaller(path)
                            result.success(null)
                        } catch (fallbackError: Exception) {
                            result.error(
                                "install_failed",
                                fallbackError.message
                                    ?: error.message
                                    ?: "無法啟動安裝程式",
                                null,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        val notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadChannelName,
        )
        downloadChannel = notificationChannel
        notificationChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                "start" -> dispatchDownloadService(
                    DownloadForegroundService.ACTION_START,
                    call,
                    result,
                )
                "update" -> dispatchDownloadService(
                    DownloadForegroundService.ACTION_UPDATE,
                    call,
                    result,
                )
                "stop" -> dispatchDownloadService(
                    DownloadForegroundService.ACTION_STOP,
                    call,
                    result,
                )
                "consumeOpenDownloadManager" -> {
                    result.success(pendingOpenDownloadManager)
                    pendingOpenDownloadManager = false
                }
                else -> result.notImplemented()
            }
        }
        if (intent?.getBooleanExtra(
                DownloadForegroundService.EXTRA_OPEN_DOWNLOAD_MANAGER,
                false,
            ) == true
        ) {
            intent.removeExtra(DownloadForegroundService.EXTRA_OPEN_DOWNLOAD_MANAGER)
            pendingOpenDownloadManager = true
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!intent.getBooleanExtra(
                DownloadForegroundService.EXTRA_OPEN_DOWNLOAD_MANAGER,
                false,
            )
        ) {
            return
        }
        intent.removeExtra(DownloadForegroundService.EXTRA_OPEN_DOWNLOAD_MANAGER)
        val channel = downloadChannel
        if (channel == null) {
            pendingOpenDownloadManager = true
        } else {
            channel.invokeMethod("openDownloadManager", null)
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                2001,
            )
        }
    }

    private fun dispatchDownloadService(
        action: String,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val intent = Intent(this, DownloadForegroundService::class.java).apply {
            this.action = action
            putExtra(
                DownloadForegroundService.EXTRA_TITLE,
                call.argument<String>("title") ?: "正在下載經文",
            )
            putExtra(
                DownloadForegroundService.EXTRA_TEXT,
                call.argument<String>("text") ?: "",
            )
            putExtra(
                DownloadForegroundService.EXTRA_PROGRESS,
                call.argument<Int>("progress") ?: 0,
            )
            putExtra(
                DownloadForegroundService.EXTRA_MAX,
                call.argument<Int>("max") ?: 1,
            )
        }
        try {
            if (action == DownloadForegroundService.ACTION_START &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            ) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("download_service_failed", error.message, null)
        }
    }

    /**
     * 使用 PackageInstaller 工作階段安裝，來源明確為本 App，
     * 可避免系統以「未知來源」為由攔截。
     */
    private fun installWithPackageInstaller(apkPath: String) {
        val file = File(apkPath)
        if (!file.exists()) {
            throw IllegalArgumentException("APK 檔案不存在")
        }
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        )
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            FileInputStream(file).use { input ->
                session.openWrite("base.apk", 0, file.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val intent = Intent(this, InstallResultReceiver::class.java).apply {
                putExtra(PackageInstaller.EXTRA_SESSION_ID, sessionId)
            }
            val pendingIntent = PendingIntent.getBroadcast(
                this,
                sessionId,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
            session.commit(pendingIntent.intentSender)
        }
    }

    private fun launchInstallerIntent(apkPath: String) {
        val file = File(apkPath)
        if (!file.exists()) {
            throw IllegalArgumentException("APK 檔案不存在")
        }
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.updateFileProvider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            clipData = ClipData.newRawUri("apk", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }
}
