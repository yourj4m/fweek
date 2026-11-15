package io.github.yourj4m.weektodo

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The app's single screen, plus the few things the Dart side asks Android
 * for directly (channel "weektodo/platform"): scheduled reminders, the
 * notification permission, saving a file through the system's picker, and
 * handing a link or a place to the app that shows such things.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var launchTask: String? = null
    private var permissionResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var saveBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launchTask = taskOf(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::onCall)
        }
    }

    /** The task a reminder notification asked to open, unless this is a relaunch from Recents. */
    private fun taskOf(intent: Intent?): String? {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return intent.getStringExtra(Reminders.EXTRA_TASK)?.takeIf { it.isNotEmpty() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        taskOf(intent)?.let { channel?.invokeMethod("openTask", it) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "syncReminders" -> {
                val items = call.argument<List<Map<String, Any?>>>("reminders").orEmpty()
                Reminders.replace(
                    this,
                    items.map {
                        Reminder(
                            (it["id"] as Number).toInt(),
                            (it["at"] as Number).toLong(),
                            it["title"] as String,
                            it["body"] as? String ?: "",
                            it["task"] as? String ?: "",
                        )
                    },
                )
                result.success(null)
            }
            "notificationsAllowed" ->
                result.success(getSystemService(NotificationManager::class.java).areNotificationsEnabled())
            "requestNotifications" -> requestNotifications(result)
            "openNotificationSettings" -> {
                startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
                )
                result.success(null)
            }
            "takeLaunchTask" -> {
                result.success(launchTask)
                launchTask = null
            }
            "saveDocument" -> saveDocument(call, result)
            "openUri" -> result.success(openUri(call.arguments as? String))
            else -> result.notImplemented()
        }
    }

    /**
     * Shows a web or mail address, or a geo: place, in the app the user has
     * for it. Only those kinds: what is opened comes out of notes and
     * calendar descriptions. False when no app takes it.
     */
    private fun openUri(text: String?): Boolean {
        val uri = text?.let { Uri.parse(it) } ?: return false
        if (uri.scheme !in setOf("http", "https", "mailto", "tel", "geo")) return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        // A second request while the system dialog is open: answer the first as declined.
        permissionResult?.success(false)
        permissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        permissionResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        permissionResult = null
    }

    /** Lets the user pick where to save, then writes the bytes there. */
    private fun saveDocument(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        val bytes = call.argument<ByteArray>("bytes")
        if (name == null || bytes == null) {
            result.error("bad_arguments", "name and bytes are required", null)
            return
        }
        saveResult?.success(false)
        saveResult = result
        saveBytes = bytes
        try {
            startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(call.argument<String>("mime") ?: "application/octet-stream")
                    .putExtra(Intent.EXTRA_TITLE, name),
                REQUEST_SAVE,
            )
        } catch (error: Exception) {
            saveResult = null
            saveBytes = null
            result.error("no_picker", "No app on this device can save files: ${error.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_SAVE) return
        val result = saveResult ?: return
        val bytes = saveBytes
        saveResult = null
        saveBytes = null
        val target = data?.data
        if (resultCode != Activity.RESULT_OK || target == null || bytes == null) {
            result.success(false) // cancelled
            return
        }
        try {
            val stream = contentResolver.openOutputStream(target, "wt")
                ?: throw IllegalStateException("the chosen location cannot be written")
            stream.use { it.write(bytes) }
            result.success(true)
        } catch (error: Exception) {
            result.error("write_failed", error.message, null)
        }
    }

    private companion object {
        const val CHANNEL = "weektodo/platform"
        const val REQUEST_NOTIFICATIONS = 0x5701
        const val REQUEST_SAVE = 0x5702
    }
}
