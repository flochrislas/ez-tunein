import 'package:flutter/foundation.dart';

/// Log an otherwise-swallowed exception so a field failure leaves a trace in
/// `adb logcat` / the console, without surfacing it to the user. `debugPrint`
/// is a no-op in release builds, so this stays free there. Use at `catch (e)`
/// sites that are deliberately best-effort but worth diagnosing (A5).
void logSwallowed(String where, Object e) {
  debugPrint('ez_tunein: swallowed error in $where: $e');
}
