package app.alextran.immich.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import app.alextran.immich.MainActivity
import app.alextran.immich.R
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import java.util.concurrent.TimeUnit

private const val TAG = "BackgroundWorker"

class BackgroundWorker(context: Context, params: WorkerParameters) :
  ListenableWorker(context, params), BackgroundWorkerBgHostApi {
  private val ctx: Context = context.applicationContext

  /// The Flutter loader that loads the native Flutter library and resources.
  /// This must be initialized before starting the Flutter engine.
  private var loader: FlutterLoader = FlutterInjector.instance().flutterLoader()

  /// The Flutter engine created specifically for background execution.
  /// This is a separate instance from the main Flutter engine that handles the UI.
  /// It operates in its own isolate and doesn't share memory with the main engine.
  /// Must be properly started, registered, and torn down during background execution.
  private var engine: FlutterEngine? = null

  // Used to call methods on the flutter side
  private var flutterApi: BackgroundWorkerFlutterApi? = null

  /// Result returned when the background task completes. This is used to signal
  /// to the WorkManager that the task has finished, either successfully or with failure.
  private val completionHandler: SettableFuture<Result> = SettableFuture.create()

  /// Flag to track whether the background task has completed to prevent duplicate completions
  private var isComplete = false

  private val notificationManager =
    ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

  private var foregroundFuture: ListenableFuture<Void>? = null

  companion object {
    private const val NOTIFICATION_CHANNEL_ID = "immich::background_worker::notif"
    private const val NOTIFICATION_ID = 100

    /**
     * How long one background run may keep uploading, in minutes.
     *
     * When it elapses the upload in progress is cancelled, and nothing is resumed: the next run
     * sends that file again from its first byte. So this has to cover the largest single file at
     * the slowest link it is realistically sent over, or that file can never be backed up from
     * the background at all. At 20 minutes, a 4.9 GB video that was getting 2.8 MB/s through a
     * CDN was cut off 19 minutes into every hourly run, about two thirds of the way through, and
     * never arrived. (The uplink was not the limit: sent directly, the same file went at 10 MB/s.)
     *
     * Three hours is about 30 GB at the slower rate. It is also half of the six hours a day that
     * Android 15 and later allow a dataSync foreground service, so that a single run cannot use
     * up the allowance by itself. A run that does reach the allowance is stopped by WorkManager
     * through onStopped(), which needs work-runtime 2.10 or newer: before that the timeout went
     * unanswered and the system killed the app.
     */
    private const val BACKUP_BUDGET_MINUTES = 180L
  }

  override fun startWork(): ListenableFuture<Result> {
    if (BackgroundWorkerPreferences(ctx).isLocked() && BackgroundEngineLock.connectEngines > 0) {
      Log.i(TAG, "Foreground engine active, skipping background worker")
      return Futures.immediateFuture(Result.success())
    }

    Log.i(TAG, "Starting background upload worker")

    if (!loader.initialized()) {
      loader.startInitialization(ctx)
    }

    val notificationChannel = NotificationChannel(
      NOTIFICATION_CHANNEL_ID,
      ctx.getString(R.string.background_worker_notification_channel_name),
      NotificationManager.IMPORTANCE_LOW
    )
    notificationManager.createNotificationChannel(notificationChannel)
    val notificationConfig = BackgroundWorkerPreferences(ctx).getNotificationConfig()
    showNotification(notificationConfig.first, notificationConfig.second)

    loader.ensureInitializationCompleteAsync(ctx, null, Handler(Looper.getMainLooper())) {
      if (isStopped || isComplete) {
        return@ensureInitializationCompleteAsync
      }

      engine = FlutterEngine(ctx)
      FlutterEngineCache.getInstance().put(BackgroundWorkerApiImpl.ENGINE_CACHE_KEY, engine!!)

      // Register custom plugins
      MainActivity.registerPlugins(ctx, engine!!)
      flutterApi =
        BackgroundWorkerFlutterApi(binaryMessenger = engine!!.dartExecutor.binaryMessenger)
      BackgroundWorkerBgHostApi.setUp(
        binaryMessenger = engine!!.dartExecutor.binaryMessenger,
        api = this
      )

      engine!!.dartExecutor.executeDartEntrypoint(
        DartExecutor.DartEntrypoint(
          loader.findAppBundlePath(),
          "package:immich_mobile/domain/services/background_worker.service.dart",
          "backgroundSyncNativeEntrypoint"
        )
      )
    }

    return completionHandler
  }

  /**
   * Called by the Flutter side when it has finished initialization and is ready to receive commands.
   * Routes the appropriate task type (refresh or processing) to the corresponding Flutter method.
   * This method acts as a bridge between the native Android background task system and Flutter.
   */
  override fun onInitialized() {
    flutterApi?.onAndroidUpload(maxMinutesArg = BACKUP_BUDGET_MINUTES) { handleHostResult(it) }
  }

  // TODO: Move this to a separate NotificationManager class
  private fun showNotification(title: String, content: String) {
    val notification = NotificationCompat.Builder(applicationContext, NOTIFICATION_CHANNEL_ID)
      .setSmallIcon(R.drawable.notification_icon)
      .setOnlyAlertOnce(true)
      .setOngoing(true)
      .setTicker(title)
      .setContentTitle(title)
      .setContentText(content)
      .build()

    if (isIgnoringBatteryOptimizations()) {
      foregroundFuture = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        setForegroundAsync(
          ForegroundInfo(
            NOTIFICATION_ID,
            notification,
            FOREGROUND_SERVICE_TYPE_DATA_SYNC
          )
        )
      } else {
        setForegroundAsync(ForegroundInfo(NOTIFICATION_ID, notification))
      }
    } else {
      notificationManager.notify(NOTIFICATION_ID, notification)
    }
  }

  override fun close() {
    if (isComplete) {
      return
    }

    val api = flutterApi
    if (api == null) {
      Handler(Looper.getMainLooper()).postAtFrontOfQueue {
        complete(Result.failure())
      }
      return
    }

    Handler(Looper.getMainLooper()).postAtFrontOfQueue {
      api.cancel {
        complete(Result.failure())
      }
    }

    waitForForegroundPromotion()

    Handler(Looper.getMainLooper()).postDelayed({
      complete(Result.failure())
    }, 5000)
  }

  /**
   * Called when the system has to stop this worker because constraints are
   * no longer met or the system needs resources for more important tasks
   * This is also called when the worker has been explicitly cancelled or replaced
   */
  override fun onStopped() {
    Log.d(TAG, "About to stop BackupWorker")
    close()
  }

  private fun handleHostResult(result: kotlin.Result<Unit>) {
    if (isComplete) {
      return
    }

    result.fold(
      onSuccess = { _ -> complete(Result.success()) },
      onFailure = { _ -> onStopped() }
    )
  }

  /**
   * Cleans up resources by destroying the Flutter engine context and invokes the completion handler.
   * This method ensures that the background task is marked as complete, releases the Flutter engine,
   * and notifies the caller of the task's success or failure. This is the final step in the
   * background task lifecycle and should only be called once per task instance.
   *
   * - Parameter success: Indicates whether the background task completed successfully
   */
  private fun complete(success: Result) {
    Log.d(TAG, "About to complete BackupWorker with result: $success")
    isComplete = true
    if (engine != null) {
      MainActivity.cancelPlugins(engine!!)
    }
    engine?.destroy()
    engine = null
    flutterApi = null
    notificationManager.cancel(NOTIFICATION_ID)
    FlutterEngineCache.getInstance().remove(BackgroundWorkerApiImpl.ENGINE_CACHE_KEY)
    waitForForegroundPromotion()
    completionHandler.set(success)
  }

  /**
   * Returns `true` if the app is ignoring battery optimizations
   */
  private fun isIgnoringBatteryOptimizations(): Boolean {
    val powerManager = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
    return powerManager.isIgnoringBatteryOptimizations(ctx.packageName)
  }

  /**
   *  Calls to setForegroundAsync() that do not complete before completion of a ListenableWorker will signal an IllegalStateException
   * https://android-review.googlesource.com/c/platform/frameworks/support/+/1262743
   * Wait for a short period of time for the foreground promotion to complete before completing the worker
   */
  private fun waitForForegroundPromotion() {
    val foregroundFuture = this.foregroundFuture
    if (foregroundFuture != null && !foregroundFuture.isCancelled && !foregroundFuture.isDone) {
      try {
        foregroundFuture.get(500, TimeUnit.MILLISECONDS)
      } catch (e: Exception) {
        // ignored, there is nothing to be done
      }
    }
  }
}
