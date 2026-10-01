package com.example.piliplus

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// LibrePili: a user-initiated data transfer job (Android 14+) held around a
// model download that Dart does itself (lib/services/background_transfer.dart).
//
// Android 15 takes the network from an app that is not on screen
// (BLOCKED_REASON_APP_BACKGROUND, measured on a Pixel 6 Pro 2026-09-29).
// JobServiceContext binds a running user-initiated job that has a network
// constraint with BIND_BYPASS_POWER_NETWORK_RESTRICTIONS, which gives the
// app's process PROCESS_CAPABILITY_POWER_RESTRICTED_NETWORK, and
// NetworkPolicyManagerService exempts a uid with that capability from the
// background block (android15-release sources, see
// research/uidt-download-2026-09-29.md). So the job transfers nothing
// itself: it is running, it shows the notification the system requires, and
// it ends when Dart says the download has.
//
// Everything here runs on the main thread: the channel's handler, the
// JobService callbacks and the watchdog are all posted to the main looper.
@TargetApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class TransferJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean = TransferJobs.onStart(this, params)

    // not rescheduled: the download is Dart's, which goes on in-process or
    // has failed by the time a new job could start, and resumes on the next
    // tap from the .part it left
    override fun onStopJob(params: JobParameters): Boolean {
        TransferJobs.onStop(params)
        return false
    }
}

/** The notification's cancel button. */
class TransferCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(TransferJobs.EXTRA_ID, -1)
        if (id >= 0) TransferJobs.cancelFromNotification(id)
    }
}

object TransferJobs {
    private const val TAG = "TransferJobs"
    private const val METHOD_CHANNEL = "librepili/transfer"
    private const val NOTIFICATION_CHANNEL = "model_download"
    const val EXTRA_ID = "id"

    // job ids double as notification ids; clear of anything else the app
    // schedules or posts (it schedules no other jobs today)
    private const val FIRST_ID = 0x4c5000

    // Dart sends progress at least every 30 s while a download runs (the
    // heartbeat). Silence this long means the engine or the download went
    // away without a word: end the job rather than hold a notification up
    // for the 12 h such a job may run.
    private const val SILENCE_LIMIT_MS = 3 * 60 * 1000L
    private const val WATCHDOG_PERIOD_MS = 60 * 1000L

    private class Transfer(val id: Int, val title: String) {
        var text = ""
        var received = 0L
        var total = 0L
        var lastHeard = SystemClock.elapsedRealtime()
        var service: JobService? = null
        var params: JobParameters? = null
    }

    private val transfers = HashMap<Int, Transfer>()
    private var nextId = FIRST_ID
    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var engine: FlutterEngine? = null
    private var swept = false
    private var watching = false
    private val main = Handler(Looper.getMainLooper())

    /**
     * Called from configureFlutterEngine, which runs again for every
     * activity attached to the cached engine: nothing here may disturb a
     * transfer already running.
     */
    fun attach(context: Context, flutterEngine: FlutterEngine) {
        appContext = context.applicationContext
        val methods = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
        methods.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(
                    start(
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<Number>("total")?.toLong() ?: 0L,
                    ),
                )
                "progress" -> {
                    val id = call.argument<Int>("id")
                    if (id != null) {
                        progress(
                            id,
                            call.argument<String>("text"),
                            call.argument<Number>("received")?.toLong() ?: 0L,
                            call.argument<Number>("total")?.toLong() ?: 0L,
                        )
                    }
                    result.success(null)
                }
                "finish" -> {
                    call.argument<Int>("id")?.let { end(it, call.argument<String>("outcome")) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = methods
        if (engine !== flutterEngine) {
            engine = flutterEngine
            // the Dart download dies with its engine: nothing will say
            // "finish", so end every job now
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = endAll("engine restarted")
                override fun onEngineWillDestroy() = endAll("engine destroyed")
            })
        }
    }

    private fun start(title: String, text: String, total: Long): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return refused("Android ${Build.VERSION.SDK_INT} has no user-initiated jobs")
        }
        val context = appContext ?: return refused("no context")
        val scheduler = context.getSystemService(JobScheduler::class.java)
            ?: return refused("no JobScheduler")
        sweep(context, scheduler)
        if (!scheduler.canRunUserInitiatedJobs()) {
            return refused("RUN_USER_INITIATED_JOBS not granted")
        }
        ensureChannel(context)
        val id = nextId++
        val info = JobInfo.Builder(id, ComponentName(context, TransferJobService::class.java))
            .setUserInitiated(true)
            // required of a user-initiated job; ANY, as the download itself
            // has always gone ahead on whatever network there is
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setEstimatedNetworkBytes(if (total > 0) total else JobInfo.NETWORK_BYTES_UNKNOWN.toLong(), 0L)
            .build()
        val result = try {
            scheduler.schedule(info)
        } catch (e: Exception) {
            // SecurityException without the permission, IllegalArgument
            // for a job the platform will not take
            return refused("${e.javaClass.simpleName}: ${e.message}")
        }
        if (result != JobScheduler.RESULT_SUCCESS) {
            // JobSchedulerService.validateJob returns RESULT_FAILURE when the
            // app is not in a state to schedule one (not visible)
            return refused("schedule() refused: app not visible?")
        }
        transfers[id] = Transfer(id, title).also {
            it.text = text
            it.total = total
        }
        watch()
        return mapOf("scheduled" to true, "id" to id)
    }

    private fun refused(reason: String): Map<String, Any?> {
        Log.i(TAG, "no job: $reason")
        return mapOf("scheduled" to false, "reason" to reason)
    }

    /**
     * Jobs are not persisted but outlive a killed process; in a new
     * process none of ours has a Dart download behind it any more.
     */
    private fun sweep(context: Context, scheduler: JobScheduler) {
        if (swept) return
        swept = true
        val ours = ComponentName(context, TransferJobService::class.java)
        for (job in scheduler.allPendingJobs) {
            if (job.service == ours && !transfers.containsKey(job.id)) scheduler.cancel(job.id)
        }
    }

    fun onStart(service: JobService, params: JobParameters): Boolean {
        val transfer = transfers[params.jobId]
            // a job from before the process was killed, or one whose
            // download ended before it started: nothing to hold
            ?: return false
        transfer.service = service
        transfer.params = params
        post(transfer)
        return true
    }

    fun onStop(params: JobParameters) {
        val transfer = transfers.remove(params.jobId) ?: return
        val reason = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) params.stopReason else 0
        Log.i(TAG, "job ${transfer.id} stopped by the system, reason $reason")
        channel?.invokeMethod("stopped", mapOf("id" to transfer.id, "reason" to reason))
    }

    private fun progress(id: Int, text: String?, received: Long, total: Long) {
        val transfer = transfers[id] ?: return
        if (text != null) transfer.text = text
        transfer.received = received
        transfer.total = total
        transfer.lastHeard = SystemClock.elapsedRealtime()
        if (transfer.params != null) post(transfer)
    }

    private fun end(id: Int, outcome: String?) {
        val transfer = transfers.remove(id) ?: return
        Log.i(TAG, "job $id ended: $outcome")
        val service = transfer.service
        val params = transfer.params
        if (service != null && params != null) {
            // JOB_END_NOTIFICATION_POLICY_REMOVE takes the notification down
            service.jobFinished(params, false)
        } else {
            // not started yet (a download that was over at once)
            appContext?.getSystemService(JobScheduler::class.java)?.cancel(id)
        }
    }

    private fun endAll(why: String) {
        for (id in transfers.keys.toList()) end(id, why)
    }

    fun cancelFromNotification(id: Int) {
        if (!transfers.containsKey(id)) return
        // the job ends at once, whether or not Dart is there to hear it;
        // Dart's own "finish" that follows finds nothing left to end
        channel?.invokeMethod("cancel", mapOf("id" to id))
        end(id, "cancelled from the notification")
    }

    private fun watch() {
        if (watching) return
        watching = true
        main.postDelayed(object : Runnable {
            override fun run() {
                val now = SystemClock.elapsedRealtime()
                for (transfer in transfers.values.toList()) {
                    if (now - transfer.lastHeard > SILENCE_LIMIT_MS) {
                        end(transfer.id, "no word from Dart for ${SILENCE_LIMIT_MS / 1000} s")
                    }
                }
                if (transfers.isEmpty()) {
                    watching = false
                } else {
                    main.postDelayed(this, WATCHDOG_PERIOD_MS)
                }
            }
        }, WATCHDOG_PERIOD_MS)
    }

    private fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL) != null) return
        // low: a progress bar the user asked for, no sound, no heads-up
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL, "模型下载", NotificationManager.IMPORTANCE_LOW),
        )
    }

    @TargetApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun post(transfer: Transfer) {
        val service = transfer.service ?: return
        val params = transfer.params ?: return
        val context = appContext ?: service.applicationContext
        val builder = Notification.Builder(context, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(transfer.title)
            .setContentText(transfer.text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
        if (transfer.total > 0) {
            val percent = (transfer.received * 100 / transfer.total).toInt().coerceIn(0, 100)
            builder.setProgress(100, percent, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            builder.setContentIntent(
                PendingIntent.getActivity(context, transfer.id, it, PendingIntent.FLAG_IMMUTABLE),
            )
        }
        val cancel = Intent(context, TransferCancelReceiver::class.java)
            .putExtra(EXTRA_ID, transfer.id)
        builder.addAction(
            Notification.Action.Builder(
                null as Icon?,
                "取消",
                PendingIntent.getBroadcast(
                    context,
                    transfer.id,
                    cancel,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            ).build(),
        )
        try {
            // called again for every update: the notification stays tied to
            // the job (JobNotificationCoordinator keeps the latest one)
            service.setNotification(
                params,
                transfer.id,
                builder.build(),
                JobService.JOB_END_NOTIFICATION_POLICY_REMOVE,
            )
            service.updateTransferredNetworkBytes(params, transfer.received, 0L)
        } catch (e: Exception) {
            Log.w(TAG, "notification for job ${transfer.id} failed", e)
        }
    }
}
