package android.hardware.bydauto.gearbox;

import android.hardware.bydauto.BYDAutoEventValue;
import android.hardware.bydauto.IBYDAutoEvent;

// 仅编译期占位 stub。真实类由 DiLink 车机固件框架在运行时提供。
// 挡位事件映射（DiLink 3 真机实测，byd-trip-stats 项目同款）：
//   onCurrentGearChanged:        0=N 1=R 2=D 3=P
//   onGearboxAutoModeTypeChanged: 1=P 2=R 3=N 4=D 5=M 6=S
public abstract class AbsBYDAutoGearboxListener {
    public void onBrakeFluidLevelChanged(int level) {}
    public void onBrakePedalStateChanged(int state) {}
    public void onCurrentGearChanged(int gear) {}
    public void onDataChanged(IBYDAutoEvent event) {}
    public void onDataEventChanged(int eventId, BYDAutoEventValue value) {}
    public void onEPBStateChanged(int state) {}
    public void onError(int code, String msg) {}
    public void onGearboxAutoModeTypeChanged(int type) {}
    public void onGearboxManualModeLevelChanged(int level) {}
    public void onGearboxStateChanged(int state) {}
    public void onParkBrakeSwitchChanged(int state) {}
}
