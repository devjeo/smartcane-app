// Tagged call diagnostics. Filter with:  adb -s <serial> logcat -s flutter | findstr CALL
// ignore_for_file: avoid_print
import 'dart:isolate';

void callLog(String msg) {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final ms = n.millisecond.toString().padLeft(3, '0');
  print('[CALL ${two(n.hour)}:${two(n.minute)}:${two(n.second)}.$ms ${Isolate.current.debugName}#${Isolate.current.hashCode % 1000}] $msg');
}
