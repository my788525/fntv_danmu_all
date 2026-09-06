package com.fntv.fnos_tv_all

import android.content.Context
import android.hardware.bydauto.gearbox.AbsBYDAutoGearboxListener
import android.hardware.bydauto.gearbox.BYDAutoGearboxDevice
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * 车载摄像头覆盖检测（倒车影像 / 360 环视）。
 *
 * 原理：DiLink 3 车机固件框架暴露 android.hardware.bydauto.gearbox.BYDAutoGearboxDevice
 * （boot classpath，本 APK 内的同名 stub 在真机上被固件实现遮蔽），注册挡位监听后，
 * 挂 R 挡即视为「摄像头画面已接管车机屏幕」，通过 MethodChannel 通知 Flutter 侧暂停播放。
 *
 * 部分固件上 GearboxDevice 可能注册失败（byd-trip-stats 项目实测有此情况），
 * 此场景由 Flutter 侧的 App 生命周期信号兜底（倒车画面若是独立 Activity 会触发 onPause）。
 * 非 BYD 设备上 stub getInstance 返回 null，本插件安全 no-op。
 */
class CarCoverPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var device: BYDAutoGearboxDevice? = null
    private var listener: AbsBYDAutoGearboxListener? = null
    private var lastCovered: Boolean? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "isCovered") {
                    result.success(lastCovered)
                } else {
                    result.notImplemented()
                }
            }
        }
        tryRegister(binding.applicationContext)
    }

    private fun tryRegister(ctx: Context) {
        try {
            val d = BYDAutoGearboxDevice.getInstance(ctx)
            if (d == null) {
                Log.i(TAG, "BYDAutoGearboxDevice unavailable (getInstance=null) — 挡位检测停用，仅靠生命周期信号")
                return
            }
            device = d
            val l = object : AbsBYDAutoGearboxListener() {
                override fun onCurrentGearChanged(gear: Int) {
                    // DiLink 3 实测映射：0=N 1=R 2=D 3=P
                    update(gear == 1, "gear=$gear")
                }

                override fun onGearboxAutoModeTypeChanged(type: Int) {
                    // 选挡杆位置：1=P 2=R 3=N 4=D 5=M 6=S
                    update(type == 2, "autoModeType=$type")
                }
            }
            listener = l
            d.registerListener(l)
            Log.i(TAG, "BYDAutoGearboxDevice registered")
            // 初始状态同步：选挡杆位置 getter（可能不存在，best-effort）
            try {
                val t = d.javaClass.getMethod("getGearboxAutoModeType").invoke(d) as? Int
                if (t != null) update(t == 2, "initial autoModeType=$t")
            } catch (_: Throwable) {
            }
            try {
                update(d.getGearboxCode() == "R", "initial gearCode=${d.getGearboxCode()}")
            } catch (_: Throwable) {
            }
        } catch (t: Throwable) {
            Log.i(TAG, "BYDAutoGearboxDevice register failed: $t")
        }
    }

    private fun update(covered: Boolean, source: String) {
        if (covered == lastCovered) return
        lastCovered = covered
        Log.i(TAG, "covered=$covered ($source)")
        channel?.invokeMethod("onCoverChanged", covered)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            device?.let { d -> listener?.let { d.unregisterListener(it) } }
        } catch (_: Throwable) {
        }
        device = null
        listener = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        private const val TAG = "CarCover"
        private const val CHANNEL = "com.fntv.fnos_tv_all/car_cover"
    }
}
