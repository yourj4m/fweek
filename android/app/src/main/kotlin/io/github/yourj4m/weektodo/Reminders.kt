package io.github.yourj4m.weektodo

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

/** A reminder the system shows at [at] (milliseconds since the epoch). */
data class Reminder(
    val id: Int,
    val at: Long,
    val title: String,
    val body: String,
    /** The task to open when the notification is tapped. */
    val task: String,
) {
    fun toJson(): JSONObject =
        JSONObject().put("id", id).put("at", at).put("title", title).put("body", body).put("task", task)

    companion object {
        fun fromJson(json: JSONObject) = Reminder(
            json.getInt("id"),
            json.getLong("at"),
            json.getString("title"),
            json.optString("body"),
            json.optString("task"),
        )
    }
}

/**
 * Task reminders, kept by Android's alarm service so they appear while the
 * app is closed. The app hands over the upcoming reminders whenever they
 * change; nothing runs in between. The list is also kept on disk, because the
 * system drops alarms on a reboot and on an app update.
 */
object Reminders {
    const val ACTION_FIRE = "io.github.yourj4m.weektodo.REMINDER"
    const val EXTRA_ID = "id"
    const val EXTRA_TASK = "task"

    private const val CHANNEL = "reminders"
    private const val PREFS = "reminders"
    private const val KEY = "scheduled"

    /** A reminder missed while the phone was off is still shown if it is younger than this. */
    private const val CATCH_UP_MS = 12 * 60 * 60 * 1000L

    private fun load(context: Context): List<Reminder> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
            ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            List(array.length()) { Reminder.fromJson(array.getJSONObject(it)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun save(context: Context, reminders: List<Reminder>) {
        val array = JSONArray()
        reminders.forEach { array.put(it.toJson()) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, array.toString()).apply()
    }

    private fun alarmIntent(context: Context, id: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            id,
            Intent(context, ReminderReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun arm(context: Context, alarms: AlarmManager, reminder: Reminder) {
        val intent = alarmIntent(context, reminder.id)
        if (alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, intent)
        } else {
            // Without the exact-alarm permission the system may deliver this a
            // few minutes late, which still beats not at all.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminder.at, intent)
        }
    }

    /** Makes [wanted] the set of scheduled reminders. */
    fun replace(context: Context, wanted: List<Reminder>) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val keep = wanted.mapTo(HashSet()) { it.id }
        for (old in load(context)) {
            if (old.id !in keep) alarms.cancel(alarmIntent(context, old.id))
        }
        save(context, wanted)
        wanted.forEach { arm(context, alarms, it) }
    }

    /** Sets every alarm again; shows what came due while the phone was off. */
    fun rearm(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val now = System.currentTimeMillis()
        val ahead = ArrayList<Reminder>()
        for (reminder in load(context)) {
            when {
                reminder.at > now -> {
                    arm(context, alarms, reminder)
                    ahead += reminder
                }
                now - reminder.at <= CATCH_UP_MS -> show(context, reminder)
            }
        }
        save(context, ahead)
    }

    /** The alarm for reminder [id] went off. */
    fun fire(context: Context, id: Int) {
        val all = load(context)
        val reminder = all.firstOrNull { it.id == id } ?: return
        show(context, reminder)
        save(context, all.filter { it.id != id })
    }

    private fun show(context: Context, reminder: Reminder) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reminders", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Reminders you set on tasks" },
        )
        val open = PendingIntent.getActivity(
            context,
            reminder.id,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_TASK, reminder.task),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_reminder)
            .setContentTitle(reminder.title)
            .setWhen(reminder.at)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(open)
        if (reminder.body.isNotEmpty()) {
            builder.setContentText(reminder.body)
                .setStyle(Notification.BigTextStyle().bigText(reminder.body))
        }
        // Without the notification permission this is silently dropped.
        manager.notify(reminder.id, builder.build())
    }
}

/** Receives the alarms set by [Reminders], and the events that clear them. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Reminders.ACTION_FIRE -> Reminders.fire(context, intent.getIntExtra(Reminders.EXTRA_ID, 0))
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> Reminders.rearm(context)
        }
    }
}
