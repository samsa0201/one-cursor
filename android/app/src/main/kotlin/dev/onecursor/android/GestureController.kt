package dev.onecursor.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.util.Log

/**
 * Turns mouse buttons and wheel motion into touch gestures.
 *
 * A held left button becomes one continuous stroke built from short segments
 * (`StrokeDescription.continueStroke`), so press-move-release drags, holds
 * become long presses and quick clicks become taps. Gestures must not overlap,
 * so the next segment is only dispatched when the previous one completed;
 * moves arriving in between are coalesced. Main thread only.
 */
class GestureController(
    private val service: AccessibilityService,
    private val screenSize: () -> Pair<Int, Int>,
) {
    private var stroke: GestureDescription.StrokeDescription? = null
    private var inFlight = false
    private var buttonDown = false
    private var releaseRequested = false
    private var lastX = 0f
    private var lastY = 0f
    private var targetX = 0f
    private var targetY = 0f

    // Wheel deltas waiting to be turned into a swipe (in 1/120 notch units).
    private var wheelX = 0
    private var wheelY = 0
    private var scrollHoldPending: GestureDescription.StrokeDescription? = null

    var scrollSpeed = 1f
    var invertScroll = false

    val isDragging: Boolean get() = buttonDown

    fun press(x: Float, y: Float) {
        if (buttonDown) return
        buttonDown = true
        releaseRequested = false
        val (px, py) = clamp(x, y)
        targetX = px
        targetY = py
        if (!inFlight) startStroke()
    }

    fun move(x: Float, y: Float) {
        if (!buttonDown) return
        val (px, py) = clamp(x, y)
        targetX = px
        targetY = py
        if (!inFlight) pump()
    }

    fun release() {
        if (!buttonDown) return
        releaseRequested = true
        if (!inFlight) pump()
    }

    /** A long press at the given point, e.g. for a right click. */
    fun longPress(x: Float, y: Float) {
        if (buttonDown || inFlight) return
        val (px, py) = clamp(x, y)
        val path = Path().apply { moveTo(px, py); lineTo(px, py) }
        dispatch(GestureDescription.StrokeDescription(path, 0, LONG_PRESS_MS, false))
    }

    fun wheel(xDelta: Int, yDelta: Int, cursorX: Float, cursorY: Float) {
        if (buttonDown) return
        val sign = if (invertScroll) -1 else 1
        wheelX += xDelta * sign
        wheelY += yDelta * sign
        scrollAnchorX = cursorX
        scrollAnchorY = cursorY
        if (!inFlight) pump()
    }

    fun cancel() {
        buttonDown = false
        releaseRequested = false
        stroke = null
        wheelX = 0
        wheelY = 0
        scrollHoldPending = null
    }

    private var scrollAnchorX = 0f
    private var scrollAnchorY = 0f

    private fun startStroke() {
        val path = Path().apply { moveTo(targetX, targetY); lineTo(targetX, targetY) }
        lastX = targetX
        lastY = targetY
        val s = GestureDescription.StrokeDescription(path, 0, SEGMENT_MS, true)
        stroke = s
        dispatch(s)
    }

    /** Dispatches whatever is pending: the next drag segment or a scroll swipe. */
    private fun pump() {
        if (inFlight) return
        // Finish a scroll swipe (lift the finger) before anything else.
        scrollHoldPending?.let {
            scrollHoldPending = null
            dispatch(it)
            return
        }
        if (buttonDown) {
            val current = stroke
            if (current == null) {
                startStroke()
                return
            }
            val moved = targetX != lastX || targetY != lastY
            if (!moved && !releaseRequested) return
            val path = Path().apply { moveTo(lastX, lastY); lineTo(targetX, targetY) }
            lastX = targetX
            lastY = targetY
            val finishing = releaseRequested
            val next = try {
                current.continueStroke(path, 0, SEGMENT_MS, !finishing)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "continueStroke failed", e)
                cancel()
                return
            }
            if (finishing) {
                buttonDown = false
                releaseRequested = false
                stroke = null
            } else {
                stroke = next
            }
            dispatch(next)
            return
        }
        if (wheelX != 0 || wheelY != 0) dispatchScroll()
    }

    private fun dispatchScroll() {
        val (w, h) = screenSize()
        val step = h * SCROLL_STEP_FRACTION * scrollSpeed
        // Positive deltas scroll up/right, which means the finger moves down/left.
        var dy = (wheelY / 120f) * step
        var dx = -(wheelX / 120f) * step
        wheelX = 0
        wheelY = 0
        val maxDy = h * 0.45f
        val maxDx = w * 0.45f
        dy = dy.coerceIn(-maxDy, maxDy)
        dx = dx.coerceIn(-maxDx, maxDx)
        if (kotlin.math.abs(dx) < 1f && kotlin.math.abs(dy) < 1f) return

        // Keep the whole swipe on screen by sliding its start point.
        val startX = scrollAnchorX.coerceIn(maxOf(0f, -dx) + 1, minOf(w - 1f, w - 1f - dx) - 1)
        val startY = scrollAnchorY.coerceIn(maxOf(0f, -dy) + 1, minOf(h - 1f, h - 1f - dy) - 1)
        val path = Path().apply { moveTo(startX, startY); lineTo(startX + dx, startY + dy) }
        val swipe = GestureDescription.StrokeDescription(path, 0, SCROLL_MS, true)
        // Holding still before lifting the finger prevents a fling.
        val endX = startX + dx
        val endY = startY + dy
        scrollHoldPending = swipe.continueStroke(
            Path().apply { moveTo(endX, endY); lineTo(endX, endY) }, 0, SCROLL_HOLD_MS, false,
        )
        dispatch(swipe)
    }

    private fun dispatch(s: GestureDescription.StrokeDescription) {
        val gesture = GestureDescription.Builder().addStroke(s).build()
        inFlight = true
        val ok = service.dispatchGesture(gesture, object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                inFlight = false
                pump()
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                inFlight = false
                // A cancelled segment ends the whole stroke; start over on the next press.
                cancel()
            }
        }, null)
        if (!ok) {
            inFlight = false
            cancel()
        }
    }

    private fun clamp(x: Float, y: Float): Pair<Float, Float> {
        val (w, h) = screenSize()
        return x.coerceIn(0f, (w - 1).toFloat()) to y.coerceIn(0f, (h - 1).toFloat())
    }

    private companion object {
        const val TAG = "OneCursor"
        const val SEGMENT_MS = 16L
        const val LONG_PRESS_MS = 650L
        const val SCROLL_MS = 120L
        const val SCROLL_HOLD_MS = 40L
        const val SCROLL_STEP_FRACTION = 0.06f
    }
}
