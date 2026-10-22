package com.pes2017.recomp

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator
import kotlin.math.sin

/**
 * The launcher's backdrop: navy floodlight haze top-right, a
 * pitch-green glow bottom-left, slow-drifting. Pure decoration, drawn once per
 * animation tick (10 fps is plenty) and deliberately cheap.
 */
class BackdropView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyle: Int = 0,
) : View(context, attrs, defStyle) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var phase = 0f

    private val animator = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 24000L
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener {
            phase = it.animatedValue as Float
            postInvalidateOnAnimation()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (!animator.isStarted) animator.start()
    }

    override fun onDetachedFromWindow() {
        animator.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val t = phase * Math.PI.toFloat() * 2f

        canvas.drawColor(Color.rgb(0x07, 0x0D, 0x1C))

        // Floodlight haze, top right, breathing slowly.
        paint.shader = RadialGradient(
            w * (0.86f + 0.03f * sin(t).toFloat()),
            h * (0.10f + 0.02f * sin((t * 1.3f).toFloat())),
            w.coerceAtLeast(h) * 0.75f,
            Color.argb(80, 0x2C, 0x6C, 0xC4),
            Color.TRANSPARENT,
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, w, h, paint)

        // Second wisp, upper middle, offset phase.
        paint.shader = RadialGradient(
            w * (0.45f + 0.04f * sin((t * 0.7f + 2f).toFloat())),
            h * 0.28f,
            w.coerceAtLeast(h) * 0.55f,
            Color.argb(50, 0x1A, 0x3A, 0x78),
            Color.TRANSPARENT,
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, w, h, paint)

        // Pitch-green glow, bottom left.
        paint.shader = RadialGradient(
            w * (0.06f + 0.02f * sin((t * 0.5f + 4f).toFloat())),
            h * (0.98f - 0.02f * sin((t * 0.6f).toFloat())),
            w.coerceAtLeast(h) * 0.65f,
            Color.argb(84, 0x1F, 0x8A, 0x4C),
            Color.TRANSPARENT,
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, w, h, paint)

        // Vignette so entries and pane sit on darkness.
        paint.shader = null
        paint.color = Color.argb(110, 0x00, 0x00, 0x00)
        canvas.drawRect(0f, 0f, w, h * 0.16f, paint)
        canvas.drawRect(0f, h * 0.84f, w, h, paint)
    }
}
