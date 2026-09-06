import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 车载摄像头覆盖检测（倒车影像 / 360 环视接管车机屏幕）。
///
/// 两个独立信号源，任一命中即视为「被覆盖」：
/// 1. **DiLink 3 挡位信号**（原生 CarCoverPlugin）：挂 R 挡 → covered=true。
///    部分固件 GearboxDevice 注册不成功时此信号静默缺失。
/// 2. **App 生命周期信号**：车机把倒车/环视画面作为独立 Activity/系统界面
///    覆盖上来时，本 App 会收到 paused/hidden → covered=true；回到前台恢复。
class CarCoverDetector with WidgetsBindingObserver {
  CarCoverDetector._();
  static final CarCoverDetector instance = CarCoverDetector._();

  static const _channel = MethodChannel('com.fntv.fnos_tv_all/car_cover');

  /// 是否被车载摄像头画面覆盖（挡位信号 || 生命周期信号）。
  final ValueNotifier<bool> covered = ValueNotifier(false);

  bool _initialized = false;
  bool _gearCovered = false;
  bool _lifecycleCovered = false;

  void init() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCoverChanged') {
        _gearCovered = call.arguments == true;
        _recompute();
        if (kDebugMode) {
          debugPrint('[CarCover] gear signal covered=$_gearCovered');
        }
      }
      return null;
    });
    WidgetsBinding.instance.addObserver(this);
  }

  void _recompute() {
    covered.value = _gearCovered || _lifecycleCovered;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleCovered = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;
    _recompute();
  }

  /// 主动查询原生侧当前覆盖状态（可选；注册成功时原生会主动推送）。
  Future<bool> isCoveredNow() async {
    try {
      return await _channel.invokeMethod('isCovered') == true;
    } catch (_) {
      return false;
    }
  }
}
