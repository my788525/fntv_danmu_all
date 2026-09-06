package android.hardware.bydauto.gearbox;

import android.content.Context;

// 仅编译期占位 stub。真实类由 DiLink 车机固件框架在运行时提供；
// 非 BYD 设备上此 stub 生效（getInstance 返回 null → 检测功能安全停用）。
public class BYDAutoGearboxDevice {
    public static BYDAutoGearboxDevice getInstance(Context context) { return null; }
    public void registerListener(AbsBYDAutoGearboxListener l) {}
    public void unregisterListener(AbsBYDAutoGearboxListener l) {}
    public String getGearboxCode() { return "P"; }
    public int getGearboxState() { return 0; }
}
