package com.mw2.recomp

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.view.InputDevice
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread
import org.json.JSONArray

/**
 * The launcher: is the game installed, which driver will be used, and the
 * button that starts it. It runs in its own process, separate from the game
 * (see the manifest), so that ending a run -- which means killing the
 * game's process -- leaves this one standing.
 *
 * It is written so that it cannot fail to appear. The native library is not
 * needed to draw this screen and is loaded in a guarded step afterwards: a
 * library that will not load leaves a launcher that says so, with the log
 * and the last crash still reachable, rather than an app that vanishes.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var prefs: Prefs
    private lateinit var status: TextView
    private lateinit var footer: TextView
    private lateinit var play: Button
    private lateinit var installButton: Button
    private lateinit var otherAppButton: Button
    private lateinit var modsButton: Button
    private lateinit var tu6Button: Button
    private lateinit var updatesButton: Button
    private lateinit var quitButton: Button
    private lateinit var detailTitle: TextView
    private lateinit var detailText: TextView
    private lateinit var versionTag: TextView
    private lateinit var directLaunchSwitch: androidx.appcompat.widget.SwitchCompat
    private var detectedIsoFile: File? = null
    private var detectedSources: List<GameSource> = emptyList()
    private var nativeReady = false
    private var hasAutoLaunched = false
    private var pendingInstallId: Long = -1
    private var pendingUpdateUrl: String? = null

    private val downloadDone = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
            if (id != pendingInstallId) return
            pendingInstallId = -1
            installDownloadedApk(id)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)

        status = findViewById(R.id.status)
        footer = findViewById(R.id.footer)
        play = findViewById(R.id.play)
        installButton = findViewById(R.id.install)
        otherAppButton = findViewById(R.id.other_app)
        modsButton = findViewById(R.id.entry_mods)
        tu6Button = findViewById(R.id.entry_tu6)
        updatesButton = findViewById(R.id.entry_updates)
        quitButton = findViewById(R.id.entry_quit)
        detailTitle = findViewById(R.id.detail_title)
        detailText = findViewById(R.id.detail_text)
        versionTag = findViewById(R.id.version_tag)
        directLaunchSwitch = findViewById(R.id.direct_launch_switch)
        try {
            val info = packageManager.getPackageInfo(packageName, 0)
            val name = info.versionName ?: ""
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toInt()
            else info.versionCode
            val tu = BuildConfig.MW2_TU.uppercase()
            val build = if (isTu6()) "TITLE UPDATE 6" else "DISC VERSION 1.0.557"
            versionTag.text = "$name · vcode $code · $tu · $build"
        } catch (_: Throwable) {
        }
        // TU6 apps offer the TU0 archives instead (PC launcher parity).
        if (isTu6()) tu6Button.text = getString(R.string.entry_tu0)

        directLaunchSwitch.isChecked = prefs.autoLaunch
        directLaunchSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.autoLaunch = isChecked
        }

        play.setOnClickListener {
            select(play)
            showDetail(getString(R.string.play), status.text.toString())
            val gameDirectory = prefs.gameDirectory
            val installed = gameDirectory.isNotEmpty() && safely(false) {
                NativeBridge.nativeGameInstalled(gameDirectory)
            }
            if (installed) {
                startGame()
            } else if (detectedIsoFile != null) {
                val intent = Intent(this, InstallActivity::class.java).apply {
                    putExtra(InstallActivity.EXTRA_INITIAL_PATH, detectedIsoFile!!.absolutePath)
                    putExtra(InstallActivity.EXTRA_AUTO_START, true)
                }
                startActivity(intent)
            } else {
                startActivity(Intent(this, InstallActivity::class.java))
            }
        }
        // The other half of the game, when it is installed: campaign jumps
        // straight into multiplayer and back, no home screen in between.
        otherAppButton.setOnClickListener {
            select(otherAppButton)
            launchOtherApp()
        }
        installButton.setOnClickListener {
            select(installButton)
            showDetail(
                getString(R.string.install_game),
                getString(R.string.install_hint),
            )
            if (detectedSources.size > 1) chooseSource()
            else startActivity(Intent(this, InstallActivity::class.java))
        }
        findViewById<Button>(R.id.driver).setOnClickListener {
            select(it as Button)
            showDetail(
                getString(R.string.graphics_driver),
                getString(R.string.driver_hint),
            )
            startActivity(Intent(this, DriverActivity::class.java))
        }
        findViewById<Button>(R.id.settings).setOnClickListener {
            select(it as Button)
            showDetail(getString(R.string.network_settings), getString(R.string.player_name_hint))
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        findViewById<Button>(R.id.log).setOnClickListener {
            select(it as Button)
            showDetail(getString(R.string.view_log), "")
            showLog()
        }
        modsButton.setOnClickListener {
            select(modsButton)
            showDetail(getString(R.string.entry_mods), getString(R.string.mods_detail_phone))
            startActivity(
                Intent(this, SettingsActivity::class.java).apply {
                    putExtra(SettingsActivity.EXTRA_TAB, SettingsActivity.TAB_FILES)
                },
            )
        }
        tu6Button.setOnClickListener {
            select(tu6Button)
            // Mirror of the PC launcher's GET TU6/GET TU0 entry: each build
            // points at the other game version's archives. Same-version rule:
            // TU0 plays only with TU0, TU6 only with TU6.
            if (isTu6()) {
                tu6Button.text = getString(R.string.entry_tu0)
                showDetail(getString(R.string.entry_tu0), getString(R.string.tu0_detail_phone))
            } else {
                showDetail(getString(R.string.entry_tu6), getString(R.string.tu6_detail_phone))
            }
            openReleasesPage()
        }
        updatesButton.setOnClickListener {
            select(updatesButton)
            showDetail(getString(R.string.check_updates), "")
            checkForUpdates(manual = true)
        }
        quitButton.setOnClickListener {
            select(quitButton)
            finishAndRemoveTask()
        }

        // Whatever killed the app last time, shown before anything else is
        // attempted -- it may well be about to happen again.
        val crash = Trail.lastCrash(this)
        if (crash.isNotEmpty()) showLastCrash(crash)

        // The library is loaded after the screen exists, so a failure here
        // is reported rather than fatal. The breadcrumb is what identifies a
        // native crash inside the load itself, which no handler can catch.
        Trail.note(this, "launcher: loading the runtime library")
        nativeReady = NativeBridge.load()
        if (nativeReady) {
            Trail.note(this, "launcher: library loaded, initialising")
            try {
                NativeBridge.nativeInit(
                    filesDir.absolutePath,
                    (getExternalFilesDir(null) ?: filesDir).absolutePath,
                    cacheDir.absolutePath,
                    applicationInfo.nativeLibraryDir,
                    null,
                )
            } catch (error: Throwable) {
                nativeReady = false
                NativeBridge.noteInitFailure(error.message ?: error.toString())
            }
        }
        Trail.clear(this)
        ContextCompat.registerReceiver(
            this, downloadDone,
            android.content.IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        checkForUpdates()
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(downloadDone)
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        refresh()
        // Back from the install-permission screen with a download waiting.
        pendingUpdateUrl?.let { url ->
            pendingUpdateUrl = null
            if (packageManager.canRequestPackageInstalls()) startUpdateDownload(url)
        }
    }

    private fun refresh() {
        if (!nativeReady) {
            status.text = getString(
                R.string.status_library_missing,
                NativeBridge.loadError() ?: getString(R.string.unknown_reason),
            )
            play.isEnabled = false
            footer.text = getString(
                R.string.footer, device(), getString(R.string.driver_system),
                BuildConfig.BUILD_SHA, BuildConfig.BUILD_STAMP,
            )
            return
        }
        refreshOtherApp()

        var gameDirectory = prefs.gameDirectory
        if (gameDirectory.isEmpty()) {
            val defaultGameDir = File(getExternalFilesDir(null) ?: filesDir, "game")
            if (defaultGameDir.exists() && safely(false) { NativeBridge.nativeGameInstalled(defaultGameDir.absolutePath) }) {
                gameDirectory = defaultGameDir.absolutePath
                prefs.gameDirectory = gameDirectory
            }
        }
        val installed = gameDirectory.isNotEmpty() && safely(false) {
            NativeBridge.nativeGameInstalled(gameDirectory)
        }

        if (installed) {
            play.isEnabled = true
            play.text = "▶ LAUNCH GAME"
            status.text = "Status: Game Ready\nLocation: $gameDirectory"
            installButton.visibility = android.view.View.GONE
            directLaunchSwitch.visibility = android.view.View.VISIBLE

            if (prefs.autoLaunch && !hasAutoLaunched) {
                hasAutoLaunched = true
                startGame()
                return
            }
        } else {
            // Whatever disc images and extracted folders can be seen. The one the
            // player last picked wins; otherwise the likeliest (GameSources.find).
            detectedSources = GameSources.find(this, File(gameDirectory.ifEmpty { "/nonexistent" }))
            val chosen = detectedSources.firstOrNull { it.file.absolutePath == prefs.lastSource }
                ?: detectedSources.firstOrNull()
            detectedIsoFile = chosen?.file

            if (detectedIsoFile != null) {
                play.isEnabled = true
                play.text = "⚡ INSTALL & PLAY"
                val c = chosen!!
                val more = if (detectedSources.size > 1) "\n${detectedSources.size - 1} other source(s) found." else ""
                status.text = "Game found (${c.kind}):\n${c.file.name}\nReady for one-click setup.$more"
                installButton.visibility = android.view.View.VISIBLE
                installButton.text = if (detectedSources.size > 1) "Choose Game Source (${detectedSources.size})" else "Choose Another Source"
            } else {
                play.isEnabled = false
                play.text = getString(R.string.play)
                status.text = getString(R.string.status_not_installed)
                installButton.visibility = android.view.View.VISIBLE
                installButton.text = getString(R.string.install_game)
            }
            directLaunchSwitch.visibility = android.view.View.GONE
        }

        applyDriverChoice()
        footer.text = getString(
            R.string.footer, device(), currentDriverName(),
            BuildConfig.BUILD_SHA, BuildConfig.BUILD_STAMP,
        )
    }

    /** Pick which disc image or folder to install from, or go and look for another. */
    private fun chooseSource() {
        val names = detectedSources.map {
            "${it.file.name}  (${it.kind}, ${android.text.format.Formatter.formatFileSize(this, it.bytes)})"
        } + getString(R.string.choose_source)
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle(R.string.install_game)
            .setItems(names.toTypedArray()) { _, which ->
                if (which < detectedSources.size) {
                    prefs.lastSource = detectedSources[which].file.absolutePath
                    refresh()
                } else {
                    startActivity(Intent(this, InstallActivity::class.java))
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun device(): String {
        val vkVersion = packageManager.systemAvailableFeatures
            .firstOrNull { it.name == "android.hardware.vulkan.version" }?.version ?: 0
        val vkMajor = vkVersion shr 22
        val vkMinor = (vkVersion shr 12) and 0x3ff
        val vkStr = if (vkVersion > 0) "Vulkan $vkMajor.$vkMinor" else "No Vulkan"
        return "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} ($vkStr), " +
            "Android ${android.os.Build.VERSION.RELEASE}"
    }

    /** A native call that must not take the launcher with it if it fails. */
    private fun <T> safely(fallback: T, call: () -> T): T = try {
        call()
    } catch (_: Throwable) {
        fallback
    }

    private fun applyDriverChoice() {
        val directory = prefs.driverDirectory
        val library = prefs.driverLibrary
        if (directory.isNotEmpty() && library.isNotEmpty() && File(directory, library).exists()) {
            safely(Unit) { NativeBridge.nativeSelectDriver(directory, library) }
        } else {
            // A driver that was deleted from underneath the setting.
            if (directory.isNotEmpty()) {
                prefs.driverDirectory = ""
                prefs.driverLibrary = ""
            }
            safely(Unit) { NativeBridge.nativeSelectDriver("", "") }
        }
    }

    private fun currentDriverName(): String {
        val directory = prefs.driverDirectory
        if (directory.isEmpty()) return getString(R.string.driver_system)
        return File(directory).name
    }

    private fun startGame() {
        if (!nativeReady) return
        // A physical pad means a second player can join (split-screen Spec
        // Ops / multiplayer). Warn once: two viewports cost frames and heat.
        if (!prefs.seenPadWarning && physicalPadCount() > 0) {
            showSplitscreenWarning()
            return
        }
        GameActivity.start(this)
    }

    private fun showDetail(title: String, text: String) {
        detailTitle.text = title
        detailText.text = text
    }

    /** com.mw2.recomp.mp and com.mw2.recomp.mp.tu6 are both multiplayer. */
    private fun isMp(): Boolean = packageName.contains(".mp")

    /** com.mw2.recomp.sp.tu6 / .mp.tu6 run title update 6. */
    private fun isTu6(): Boolean = packageName.endsWith(".tu6")

    /** The other flavor's package, or null when it is not installed. */
    private fun otherApp(): Pair<String, String>? {
        // Same game version on both ends: TU6 cross-launches the TU6 sibling.
        val base = if (isMp()) ".sp" else ".mp"
        val pkg = "com.mw2.recomp$base" + if (isTu6()) ".tu6" else ""
        val label = getString(
            R.string.launch_other,
            getString(if (isMp()) R.string.other_name_campaign else R.string.other_name_multiplayer),
        )
        return try {
            packageManager.getLaunchIntentForPackage(pkg) ?: return null
            pkg to label
        } catch (_: Throwable) {
            null
        }
    }

    private fun refreshOtherApp() {
        val other = otherApp()
        if (other == null) {
            otherAppButton.visibility = android.view.View.GONE
        } else {
            otherAppButton.visibility = android.view.View.VISIBLE
            otherAppButton.text = other.second
        }
    }

    private fun launchOtherApp() {
        val other = otherApp()
        if (other == null) {
            showDetail(
                getString(R.string.play),
                getString(
                    R.string.other_missing,
                    getString(
                        if (isMp()) R.string.other_name_campaign
                        else R.string.other_name_multiplayer,
                    ),
                ),
            )
            return
        }
        showDetail(other.second, "")
        try {
            startActivity(packageManager.getLaunchIntentForPackage(other.first))
        } catch (_: Throwable) {
        }
    }

    private fun physicalPadCount(): Int {
        var count = 0
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            if (device.isVirtual) continue
            val sources = device.sources
            if (sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
                sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK) {
                count++
            }
        }
        return count
    }

    private fun showSplitscreenWarning() {
        AlertDialog.Builder(this)
            .setTitle(R.string.splitscreen_title)
            .setMessage(R.string.splitscreen_warning)
            .setPositiveButton(R.string.play_anyway) { _, _ -> GameActivity.start(this) }
            .setNegativeButton(R.string.cancel, null)
            .setNeutralButton(R.string.dont_show_again) { _, _ ->
                prefs.seenPadWarning = true
                GameActivity.start(this)
            }
            .show()
    }

    private var selectedEntry: Button? = null

    /** The PC launcher's black-bar highlight on the chosen entry. */
    private fun select(entry: Button) {
        selectedEntry?.setBackgroundColor(android.graphics.Color.TRANSPARENT)
        selectedEntry = entry
        entry.setBackgroundResource(R.drawable.bg_entry_selected)
    }

    /** TU-aware asset match: TU0 never takes a TU6 APK and vice versa.
     * Unmarked (pre-TU) assets match TU0 only, the version they were. */
    private fun assetMatches(asset: String, wantTitle: String, wantTu: String): Boolean {
        if (!asset.contains(wantTitle, ignoreCase = true)) return false
        val hasTu6 = asset.contains("tu6", ignoreCase = true)
        return if (wantTu == "tu6") hasTu6 else !hasTu6
    }

    /** A newer published APK, if there is one: silent when offline. */
    private fun checkForUpdates(manual: Boolean = false) {
        thread(name = "update-check", isDaemon = true) {
            var offered = false
            try {
                val connection = (URL("https://api.github.com/repos/CyberLifeYT/mw2-crossplay/releases?per_page=10")
                    .openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15000
                    readTimeout = 15000
                    setRequestProperty("Accept", "application/vnd.github+json")
                }
                if (connection.responseCode == 200) {
                    val releases = JSONArray(connection.inputStream.bufferedReader().readText())
                    val wantTitle = if (isMp()) "multiplayer" else "campaign"
                    val wantTu = if (isTu6()) "tu6" else "tu0"
                    for (i in 0 until releases.length()) {
                        val release = releases.getJSONObject(i)
                        if (release.optBoolean("draft")) continue
                        val assets = release.optJSONArray("assets") ?: continue
                        val matches = (0 until assets.length()).any {
                            assetMatches(assets.getJSONObject(it).optString("name"), wantTitle, wantTu)
                        }
                        if (!matches) continue
                        val tag = release.optString("tag_name")
                        val code = Regex("APK versionCode:\\s*(\\d+)")
                            .find(release.optString("body"))?.groupValues?.get(1)?.toIntOrNull() ?: 0
                        val installed = packageManager.getPackageInfo(packageName, 0).let {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode.toInt()
                            else it.versionCode
                        }
                        // Newest matching release only: older ones stay buried.
                        if (code > installed && tag.isNotEmpty() && tag != prefs.seenUpdateTag) {
                            val page = release.optString("html_url")
                            val apkUrl = (0 until assets.length())
                                .map { assets.getJSONObject(it) }
                                .firstOrNull {
                                    it.optString("name").endsWith(".apk", ignoreCase = true) &&
                                        assetMatches(it.optString("name"), wantTitle, wantTu)
                                }?.optString("browser_download_url") ?: ""
                            val notes = release.optString("body").take(1500)
                            offered = true
                            runOnUiThread { showUpdateDialog(tag, page, apkUrl, notes, installed, code) }
                        }
                        break
                    }
                }
            } catch (_: Throwable) {
            }
            if (manual && !offered) {
                runOnUiThread {
                    AlertDialog.Builder(this)
                        .setMessage(R.string.up_to_date)
                        .setPositiveButton(R.string.close, null)
                        .show()
                }
            }
        }
    }

    private fun showUpdateDialog(tag: String, page: String, apkUrl: String, notes: String, installed: Int, code: Int) {
        val body = TextView(this)
        body.setPadding(32, 8, 32, 8)
        body.textSize = 12f
        body.text = getString(R.string.update_message, installed, code) + "\n\n" + notes
        val scroll = ScrollView(this)
        scroll.addView(body)
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.update_title, tag))
            .setView(scroll)
            .setPositiveButton(R.string.update_download) { _, _ ->
                if (apkUrl.isNotEmpty()) downloadAndInstall(apkUrl)
                else openPage(page)
            }
            .setNeutralButton(R.string.skip_version) { _, _ -> prefs.seenUpdateTag = tag }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    private fun openPage(page: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(page)))
        } catch (_: Throwable) {
        }
    }

    /** TU6 lives in separate PC archives; Android stays TU0 (future work, not started). */
    private fun openReleasesPage() {
        openPage("https://github.com/CyberLifeYT/mw2-crossplay/releases")
    }

    private fun downloadAndInstall(apkUrl: String) {
        if (!packageManager.canRequestPackageInstalls()) {
            // System sends the user to allow installs from this app; the
            // download starts when they come back (onResume).
            pendingUpdateUrl = apkUrl
            try {
                startActivity(
                    Intent(
                        android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    )
                )
            } catch (_: Throwable) {
                pendingUpdateUrl = null
            }
            return
        }
        startUpdateDownload(apkUrl)
    }

    private fun startUpdateDownload(apkUrl: String) {
        try {
            val manager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
            val request = DownloadManager.Request(Uri.parse(apkUrl))
                .setTitle("MW2 update")
                .setDescription("Downloading APK")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "mw2-update.apk")
                .setAllowedOverMetered(true)
            pendingInstallId = manager.enqueue(request)
            Toast.makeText(this, R.string.update_downloading, Toast.LENGTH_SHORT).show()
        } catch (_: Throwable) {
            openPage("https://github.com/CyberLifeYT/mw2-crossplay/releases")
        }
    }

    private fun installDownloadedApk(id: Long) {
        try {
            val manager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
            val uri = manager.getUriForDownloadedFile(id) ?: return
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
        } catch (_: Throwable) {
            AlertDialog.Builder(this)
                .setMessage(R.string.update_failed)
                .setPositiveButton(R.string.open_page) { _, _ ->
                    openPage("https://github.com/CyberLifeYT/mw2-crossplay/releases")
                }
                .setNegativeButton(R.string.cancel, null)
                .show()
        }
    }

    private fun showLastCrash(crash: String) {
        AlertDialog.Builder(this)
            .setTitle(R.string.last_crash)
            .setMessage(crash.take(4000))
            .setPositiveButton(R.string.close) { _, _ -> Trail.forgetCrash(this) }
            .setNeutralButton(R.string.share) { _, _ -> share(crash) }
            .show()
    }

    /**
     * The log screen: a summary of it, with the whole thing one button away
     * (LogSummary says what is kept and what is only counted). Share sends the
     * whole log, because that is what a bug report needs.
     */
    private fun showLog() {
        val session = if (nativeReady) safely("") { NativeBridge.nativeLogTail() } else ""
        val renderer = if (nativeReady) safely("") { NativeBridge.nativeRendererInfo() } else ""
        showLogText(LogSummary.build(this, renderer, session), 11f)
    }

    /** Everything, as it was, for when the summary is not enough. */
    private fun showWholeLog() {
        val session = if (nativeReady) safely("") { NativeBridge.nativeLogTail() } else ""
        showLogText(LogSummary.whole(this, session), 10f)
    }

    private fun showLogText(text: String, textSize: Float) {
        val body = TextView(this)
        body.setPadding(32, 24, 32, 24)
        body.textSize = textSize
        body.setTextIsSelectable(true)
        body.text = text
        val scroll = ScrollView(this)
        scroll.addView(body)
        AlertDialog.Builder(this)
            .setTitle(R.string.view_log)
            .setView(scroll)
            .setPositiveButton(R.string.close, null)
            .setNegativeButton(R.string.log_everything) { _, _ -> showWholeLog() }
            .setNeutralButton(R.string.share) { _, _ -> share(wholeLog()) }
            .show()
    }

    /** What Share sends: every log and crash file, not the summary. */
    private fun wholeLog(): String {
        val session = if (nativeReady) safely("") { NativeBridge.nativeLogTail() } else ""
        return LogSummary.whole(this, session)
    }

    private fun share(text: String) {
        val intent = Intent(Intent.ACTION_SEND)
        intent.type = "text/plain"
        intent.putExtra(Intent.EXTRA_SUBJECT, "MW2 log")
        intent.putExtra(Intent.EXTRA_TEXT, text.takeLast(200_000))
        startActivity(Intent.createChooser(intent, getString(R.string.share)))
    }
}

/** The end of a file, which is the part of a log anyone wants. */
fun File.readTextTail(bytes: Int): String = try {
    val length = length()
    if (length <= bytes) readText()
    else inputStream().use { stream ->
        stream.skip(length - bytes)
        stream.readBytes().toString(Charsets.UTF_8)
    }
} catch (_: Throwable) {
    ""
}
