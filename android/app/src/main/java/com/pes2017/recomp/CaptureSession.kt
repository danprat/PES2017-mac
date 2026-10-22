package com.pes2017.recomp

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.PixelCopy
import android.view.SurfaceView
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A debugging capture, started and stopped with the CAPTURE button: everything
 * needed to work out what went wrong in a stretch of play, in one folder.
 *
 *   files/captures/<name>/
 *     summary.txt    device, build, every setting, renderer and driver, frame statistics
 *     stats.csv      once every half second: fps, frame time, texture memory, temperatures
 *     game.log       the runtime's log for the stretch (and what led up to it)
 *     logcat.txt     Android's own log for the app, which holds crashes the runtime log cannot
 *     screenshot.png the picture at the moment of stopping
 *     <name>.macro   the controller input of the stretch, replayable with Macro (also copied
 *                    to files/macros so it can be played from the menu)
 *
 * It also asks the renderer for its own capture (the CAPTURE request file the
 * renderer already understands) when it starts and when it stops, so the log
 * has the per-frame draw counts around both moments and a dump of a frame.
 */
class CaptureSession(private val activity: Activity, private val prefs: Prefs) {

    private val handler = Handler(Looper.getMainLooper())
    private val base: File = activity.getExternalFilesDir(null) ?: activity.filesDir
    private val stats = FloatArray(8)
    private val samples = StringBuilder("t_ms,fps,frame_ms,texture_mb,width,height,battery_c,thermal,ram_free_mb\n")
    private var fpsMin = Float.MAX_VALUE
    private var fpsMax = 0f
    private var fpsSum = 0.0
    private var worstFrameMs = 0f
    private var count = 0

    @Volatile var active = false
        private set
    private var startedAt = 0L
    private var startedWall = 0L
    private var logOffset = 0L
    private lateinit var folder: File

    /** Called with the elapsed seconds, to keep the button's label current. */
    var onTick: ((Int) -> Unit)? = null

    private val tick = object : Runnable {
        override fun run() {
            if (!active) return
            sample()
            onTick?.invoke(((SystemClock.elapsedRealtime() - startedAt) / 1000).toInt())
            handler.postDelayed(this, 500)
        }
    }

    fun start() {
        if (active) return
        samples.setLength(samples.indexOf("\n") + 1)
        fpsMin = Float.MAX_VALUE; fpsMax = 0f; fpsSum = 0.0; worstFrameMs = 0f; count = 0
        startedAt = SystemClock.elapsedRealtime()
        startedWall = System.currentTimeMillis()
        logOffset = File(base, "game.log").let { if (it.isFile) it.length() else 0L }
        folder = File(base, "captures/pending").apply { deleteRecursively(); mkdirs() }
        Log.i(TAG, "capture started")
        // The renderer's view of the moments before the start, and a frame.
        requestRendererCapture()
        Macro.startRecording()
        active = true
        handler.post(tick)
    }

    /**
     * Stops and writes the folder. `name` and `note` come from the player (what
     * to call it, and what went wrong); `done` gets the folder written.
     */
    fun stop(surface: SurfaceView, name: String, note: String, done: (File?, String) -> Unit) {
        if (!active) return
        active = false
        handler.removeCallbacks(tick)
        sample()
        requestRendererCapture()
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date(startedWall))
        val clean = name.trim().map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }
            .joinToString("").ifEmpty { "capture" }
        val finalFolder = File(base, "captures/$stamp-$clean")
        val events = Macro.stopRecording(activity, clean)
        screenshot(surface) { png ->
            // Give the renderer a moment to write its capture lines to the log.
            Thread {
                try {
                    Thread.sleep(1500)
                    folder.renameTo(finalFolder)
                    val target = if (finalFolder.isDirectory) finalFolder else folder
                    png?.let { copyBitmap(it, File(target, "screenshot.png")) }
                    writeFiles(target, clean, note, events)
                    activity.runOnUiThread { done(target, "saved") }
                } catch (error: Throwable) {
                    Log.e(TAG, "capture failed", error)
                    activity.runOnUiThread { done(null, error.message ?: "failed") }
                }
            }.start()
        }
    }

    fun cancel() {
        active = false
        handler.removeCallbacks(tick)
        Macro.stopRecording(activity, "last")
    }

    // ---- gathering ------------------------------------------------------------

    private fun sample() {
        if (!NativeBridge.isLoaded()) return
        try {
            NativeBridge.nativeStats(stats)
        } catch (_: Throwable) {
            return
        }
        val fps = stats[0]
        val frameMs = stats[4]
        count++
        if (fps > 0f) {
            fpsMin = minOf(fpsMin, fps); fpsMax = maxOf(fpsMax, fps); fpsSum += fps
        }
        worstFrameMs = maxOf(worstFrameMs, frameMs)
        val ms = SystemClock.elapsedRealtime() - startedAt
        samples.append("$ms,${"%.1f".format(Locale.US, fps)},${"%.1f".format(Locale.US, frameMs)},")
            .append("${stats[1].toInt()},${stats[2].toInt()},${stats[3].toInt()},")
            .append("${"%.1f".format(Locale.US, batteryTemp())},${thermal()},${freeMemoryMb()}\n")
    }

    private fun batteryTemp(): Float {
        val intent = activity.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        return (intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10f
    }

    private fun thermal(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            (activity.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus
        else -1

    private fun freeMemoryMb(): Long {
        val info = android.app.ActivityManager.MemoryInfo()
        (activity.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(info)
        return info.availMem shr 20
    }

    private fun requestRendererCapture() {
        try {
            File(base, "capture_request").writeText("1")
        } catch (_: Throwable) {
        }
    }

    private fun screenshot(surface: SurfaceView, done: (Bitmap?) -> Unit) {
        if (surface.width <= 0 || surface.height <= 0) { done(null); return }
        try {
            val bitmap = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
            PixelCopy.request(surface, bitmap, { result ->
                done(if (result == PixelCopy.SUCCESS) bitmap else null)
            }, handler)
        } catch (_: Throwable) {
            done(null)
        }
    }

    private fun copyBitmap(bitmap: Bitmap, file: File) {
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 90, it) }
    }

    private fun writeFiles(target: File, name: String, note: String, events: Int) {
        File(target, "stats.csv").writeText(samples.toString())

        // The runtime's log from where the session began, with 400 lines before
        // it for what led up to the stretch.
        val log = File(base, "game.log")
        if (log.isFile) {
            val text = try { log.readTextTail(6_000_000) } catch (_: Throwable) { "" }
            val total = log.length()
            val dropped = (total - 6_000_000).coerceAtLeast(0)
            val from = (logOffset - dropped).coerceIn(0, text.length.toLong()).toInt()
            val lead = text.take(from).lines().takeLast(400).joinToString("\n")
            File(target, "game.log").writeText(lead + "\n===== capture starts here =====\n" + text.drop(from))
        }

        try {
            val process = Runtime.getRuntime().exec(arrayOf("logcat", "-d", "-t", "4000"))
            File(target, "logcat.txt").writeText(process.inputStream.bufferedReader().readText())
        } catch (_: Throwable) {
        }

        val macro = File(Macro.directory(activity), "$name.macro")
        if (macro.isFile) macro.copyTo(File(target, "$name.macro"), overwrite = true)

        File(target, "summary.txt").writeText(summary(name, note, events))
    }

    private fun summary(name: String, note: String, events: Int): String {
        val seconds = (SystemClock.elapsedRealtime() - startedAt) / 1000.0
        val average = if (count > 0) fpsSum / count else 0.0
        val renderer = try { NativeBridge.nativeRendererInfo() } catch (_: Throwable) { "" }
        val driver = try { NativeBridge.nativeDriverDescription() } catch (_: Throwable) { "" }
        val info = StringBuilder()
        info.append("PES 2017 Android capture: $name\n")
        info.append("what went wrong: ${note.ifBlank { "(not said)" }}\n\n")
        info.append("duration: ${"%.1f".format(Locale.US, seconds)} s, $count samples\n")
        info.append("fps: avg ${"%.1f".format(Locale.US, average)}, min ${if (fpsMin == Float.MAX_VALUE) 0 else fpsMin}, max $fpsMax; worst frame $worstFrameMs ms\n")
        info.append("controller events recorded: $events (macro \"$name\")\n\n")
        info.append("device: ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})\n")
        info.append("build: ${BuildConfig.BUILD_SHA} ${BuildConfig.BUILD_STAMP}\n")
        info.append("renderer: $renderer\n")
        info.append("driver: $driver\n")
        info.append("game folder: ${prefs.gameDirectory}\n\n")
        info.append("settings:\n")
        info.append("  performance preset ${prefs.preset.ifEmpty { "none" }}\n")
        info.append("  display resolution ${(prefs.resolutionScale * 100).toInt()}%, internal scale ${prefs.renderScale}x, " +
            "scene ${prefs.sceneScalePercent}%\n")
        info.append("  msaa ${prefs.multisampling}, 60 Hz lock ${prefs.prefer60Hz}, fsr ${prefs.fsr} (sharpness ${prefs.fsrSharpness}), " +
            "30 fps cap ${prefs.cap30}, low memory ${prefs.lowMemory}\n")
        info.append("  texture memory ${if (prefs.textureBudgetMB > 0) "${prefs.textureBudgetMB} MB" else "auto"}, " +
            "compile all shaders ${prefs.prewarmAllShaders}, audio ${prefs.audioEnabled}\n")
        info.append("  touch controls ${prefs.touchControls}, gamepad ${prefs.gamepadEnabled}, vibration ${prefs.vibration}\n")
        return info.toString()
    }

    companion object {
        private const val TAG = "PES17.Capture"
    }
}
