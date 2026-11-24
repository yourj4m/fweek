package io.github.yourj4m.weektodo

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Opened by the "Back to fweek" link (`fweek://…`) on the page the browser
 * shows after Google sign-in. It brings fweek's own task to the front, as
 * its icon in the launcher does, and closes at once: a link would otherwise
 * start a second fweek inside the browser's task.
 */
class ReturnActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            // As the launcher starts it: into fweek's own task, which comes
            // forward as it was left.
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            startActivity(it)
        }
        finish()
    }
}
