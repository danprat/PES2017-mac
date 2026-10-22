package com.pes2017.recomp

import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import kotlin.math.roundToInt

/**
 * Everything the player can change outside a match. Each setting is written
 * the moment it is touched: there is no "apply", because there is nothing
 * to apply to -- the values are read when a match starts (GameActivity).
 */
class SettingsActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_TAB = "pes17.tab"
        const val TAB_PICTURE = 0
        const val TAB_PORT = 1
        const val TAB_CONTROLS = 2
        const val TAB_FILES = 3
    }

    private lateinit var prefs: Prefs
    private val tabButtons = mutableListOf<Button>()
    private val tabPages = mutableListOf<android.view.View>()
    private lateinit var storageAccess: TextView
    private lateinit var grantStorage: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)
        prefs = Prefs(this)
        title = getString(R.string.entry_settings)

        // ---- tab bar (plain views, no new deps): one page visible at a time ----
        tabButtons.add(findViewById(R.id.tab_picture))
        tabButtons.add(findViewById(R.id.tab_port))
        tabButtons.add(findViewById(R.id.tab_controls))
        tabButtons.add(findViewById(R.id.tab_files))
        tabPages.add(findViewById(R.id.page_picture))
        tabPages.add(findViewById(R.id.page_port))
        tabPages.add(findViewById(R.id.page_controls))
        tabPages.add(findViewById(R.id.page_files))
        tabButtons.forEachIndexed { index, button -> button.setOnClickListener { selectTab(index) } }
        selectTab(intent.getIntExtra(EXTRA_TAB, TAB_PICTURE).coerceIn(0, 3))

        // ---- picture ----
        bar(R.id.resolution, R.id.resolution_label, 65, ((prefs.resolutionScale * 100f) - 35f).roundToInt(),
            { getString(R.string.resolution, it + 35) }) { prefs.resolutionScale = (it + 35) / 100f }
        bar(R.id.render_scale, R.id.render_scale_label, 2, prefs.renderScale - 1,
            { getString(R.string.render_scale, it + 1) }) { prefs.renderScale = it + 1 }
        switch(R.id.msaa, prefs.multisampling) { prefs.multisampling = it }
        switch(R.id.prefer60, prefs.prefer60Hz) { prefs.prefer60Hz = it }
        switch(R.id.widescreen, prefs.widescreen) { prefs.widescreen = it }

        // ---- match performance (the runtime's own switches) ----
        bar(R.id.scene_scale, R.id.scene_scale_label, 10, (prefs.sceneScalePercent - 50) / 5,
            { getString(R.string.scene_scale, 50 + it * 5) }) { prefs.sceneScalePercent = 50 + it * 5 }
        switch(R.id.fsr, prefs.fsr) { prefs.fsr = it }
        bar(R.id.fsr_sharp, R.id.fsr_sharp_label, 20, (prefs.fsrSharpness * 10f).roundToInt(),
            { getString(R.string.fsr_sharp, it / 10f) }) { prefs.fsrSharpness = it / 10f }
        switch(R.id.cap30, prefs.cap30) { prefs.cap30 = it }
        switch(R.id.low_memory, prefs.lowMemory) { prefs.lowMemory = it }
        // 0 means "let the runtime decide"; then 128 MB steps to 2 GB.
        bar(R.id.texture_budget, R.id.texture_label, 15,
            if (prefs.textureBudgetMB <= 0) 0 else (prefs.textureBudgetMB / 128).coerceIn(1, 15),
            { textureText(it) }) { prefs.textureBudgetMB = if (it == 0) 0 else it * 128 }
        switch(R.id.prewarm_all, prefs.prewarmAllShaders) { prefs.prewarmAllShaders = it }
        switch(R.id.stats, prefs.showStats) { prefs.showStats = it }

        // ---- sound and controls ----
        switch(R.id.audio, prefs.audioEnabled) { prefs.audioEnabled = it }
        switch(R.id.touch, prefs.touchControls) { prefs.touchControls = it }
        switch(R.id.gamepad, prefs.gamepadEnabled) { prefs.gamepadEnabled = it }
        switch(R.id.gamepad_p2, prefs.padAsPlayer2) { prefs.padAsPlayer2 = it }
        switch(R.id.vibration, prefs.vibration) { prefs.vibration = it }

        // ---- the game files ----
        val paths: TextView = findViewById(R.id.paths)
        storageAccess = findViewById(R.id.storage_access)
        grantStorage = findViewById(R.id.grant_storage)
        grantStorage.setOnClickListener {
            val intent = GameFolder.accessIntent(this)
            if (intent != null) {
                try {
                    startActivity(intent)
                } catch (_: Throwable) {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                    } catch (_: Throwable) {
                    }
                }
            } else {
                requestPermissions(GameFolder.legacyPermissions, 1)
            }
        }
        findViewById<Button>(R.id.change_folder).setOnClickListener {
            // The folder picker lives in the main menu, where the permission
            // flow and the check of default.xex are.
            finish()
        }
        findViewById<Button>(R.id.forget).setOnClickListener {
            AlertDialog.Builder(this)
                .setTitle(R.string.forget_install)
                .setMessage(R.string.forget_explained)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.reset) { _, _ ->
                    prefs.gameDirectory = ""
                    paths.text = getString(R.string.paths_none)
                }
                .show()
        }
        paths.text = pathsText()

        // ---- storage ----
        val storage: TextView = findViewById(R.id.storage)
        refreshStorage(storage)
        findViewById<Button>(R.id.clear_shaders).setOnClickListener {
            shaderCacheFiles().forEach { try { it.delete() } catch (_: Throwable) {} }
            storage.text = getString(R.string.shaders_cleared)
            refreshStorage(storage)
        }
        findViewById<Button>(R.id.clear_logs).setOnClickListener {
            listOf("game.log", "launcher.log", "last-crash-game.txt", "last-crash-launcher.txt").forEach {
                try {
                    java.io.File(filesDir, it).delete()
                } catch (_: Throwable) {
                }
            }
            storage.text = getString(R.string.logs_cleared)
            refreshStorage(storage)
        }
    }

    override fun onResume() {
        super.onResume()
        // Back from the permission screen.
        val granted = GameFolder.hasAccess(this)
        storageAccess.setText(if (granted) R.string.storage_granted else R.string.storage_not_granted)
        grantStorage.visibility = if (granted) android.view.View.GONE else android.view.View.VISIBLE
    }

    private fun pathsText(): String =
        if (prefs.gameDirectory.isEmpty()) getString(R.string.paths_none)
        else getString(R.string.paths_line, prefs.gameDirectory)

    /** Custom tab bar: highlight bar on the chosen tab, one page shown. */
    private fun selectTab(index: Int) {
        tabPages.forEachIndexed { i, page ->
            page.visibility = if (i == index) android.view.View.VISIBLE else android.view.View.GONE
        }
        tabButtons.forEachIndexed { i, button ->
            if (i == index) {
                button.setBackgroundResource(R.drawable.bg_entry_selected)
                button.setTextColor(0xFF2CC4FF.toInt())
            } else {
                button.setBackgroundColor(android.graphics.Color.TRANSPARENT)
                button.setTextColor(0xFFEAF1FF.toInt())
            }
        }
    }

    /** A slider whose label follows it; `onChange` only for the player's own touches. */
    private fun bar(
        barId: Int, labelId: Int, max: Int, initial: Int,
        label: (Int) -> String, onChange: (Int) -> Unit,
    ) {
        val text: TextView = findViewById(labelId)
        val seek: SeekBar = findViewById(barId)
        seek.max = max
        seek.progress = initial.coerceIn(0, max)
        text.text = label(seek.progress)
        seek.setOnSeekBarChangeListener(object : Simple() {
            override fun onProgressChanged(view: SeekBar, value: Int, fromUser: Boolean) {
                text.text = label(value)
                if (fromUser) onChange(value)
            }
        })
    }

    private fun gameBase(): java.io.File = getExternalFilesDir(null) ?: filesDir

    private fun shaderCacheFiles(): List<java.io.File> {
        val base = gameBase()
        return listOf(
            java.io.File(base, "shader_cache.bin"),
            java.io.File(filesDir, "shader_cache.bin"),
            java.io.File(filesDir, "pipeline.cache"),
        )
    }

    private fun refreshStorage(view: TextView) {
        view.text = getString(R.string.storage_computing)
        Thread {
            fun sizeOf(dir: java.io.File): Long = try {
                if (dir.isFile) dir.length()
                else dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
            } catch (_: Throwable) {
                0L
            }
            val gameDir = prefs.gameDirectory.ifEmpty { null }?.let { java.io.File(it) }
            val base = gameBase()
            val saves = java.io.File(
                (gameDir?.parent ?: base.absolutePath) + "/saves",
            )
            val rows = listOf(
                getString(R.string.section_files) to (gameDir?.let { sizeOf(it) } ?: 0L),
                getString(R.string.saves_files) to sizeOf(saves),
                getString(R.string.clear_shaders) to shaderCacheFiles().sumOf {
                    try {
                        it.length()
                    } catch (_: Throwable) {
                        0L
                    }
                },
                getString(R.string.view_log) to listOf(
                    "game.log", "launcher.log", "last-crash-game.txt", "last-crash-launcher.txt",
                ).sumOf {
                    try {
                        java.io.File(filesDir, it).length()
                    } catch (_: Throwable) {
                        0L
                    }
                },
            )
            val text = rows.joinToString("\n") { (label, bytes) ->
                getString(R.string.storage_line, label, formatSize(bytes))
            }
            runOnUiThread { view.text = text }
        }.start()
    }

    private fun formatSize(bytes: Long): String =
        android.text.format.Formatter.formatFileSize(this, bytes)

    private fun textureText(step: Int): String =
        if (step == 0) getString(R.string.texture_budget_auto)
        else getString(R.string.texture_budget, step * 128)

    private fun switch(id: Int, initial: Boolean, onChange: (Boolean) -> Unit) {
        val view: SwitchCompat = findViewById(id)
        view.isChecked = initial
        view.setOnCheckedChangeListener { _, checked -> onChange(checked) }
    }

    /** The two methods nobody ever needs, out of the way. */
    private abstract class Simple : SeekBar.OnSeekBarChangeListener {
        override fun onStartTrackingTouch(bar: SeekBar) = Unit
        override fun onStopTrackingTouch(bar: SeekBar) = Unit
    }
}
