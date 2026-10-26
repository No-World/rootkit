import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chain.dart';
import 'version.dart';
import 'shizuku.dart';
import 'github_icon.dart';

/// 版本号（与 pubspec 的 version 保持一致）
// 版本号在 lib/version.dart（chain.dart 也要用，避免循环 import）

/// 项目主页（AppBar 与选项里都可一键跳转）
const String kRepoUrl = 'https://github.com/No-World/rootkit';

void main() {
  runApp(const RootKitApp());
}

class RootKitApp extends StatelessWidget {
  const RootKitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '越狱助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D6B),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101416),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final RootChain chain = RootChain();
  final GlobalKey _logCardKey = GlobalKey();   // 日志卡片（用于"从卡片放大"的起点矩形）
  final GlobalKey _logBodyKey = GlobalKey();
  final ScrollController _logScroll = ScrollController();
  bool _shizuku = false;
  bool _stagesExpanded = false; // 阶段列表默认折叠
  Timer? _shizukuPoll;   // Shizuku 授权状态轮询（3s，仅 binder 查询）
  Timer? _coolTick;   // 冷却倒计时用（1s，纯 UI，不 spawn shell）
  bool _pollBusy = false;
  bool _statusProbed = false;

  @override
  void initState() {
    super.initState();
    chain.addListener(_onChange);
    WidgetsBinding.instance.addObserver(this);
    chain.loadOptions();
    _refreshShizuku();
    _startShizukuPoll();
    chain.startHealthPolling();   // 空闲期每 5s 刷状态；跑链期间自动静默
    _maybeShowDisclaimer();
  }

  /// 主动轮询 Shizuku 授权状态：用户在别的界面授权/撤销后，本界面 3 秒内跟上
  void _startShizukuPoll() {
    _shizukuPoll?.cancel();
    _shizukuPoll = Timer.periodic(const Duration(seconds: 3), (_) => _pollShizuku());
  }

  /// 约定：任何"额外的后台工作"（状态探测、更新检查、网络请求）都必须先看 [chain.busy]
  /// —— 跑链期间一律不做，避免干扰竞态窗口（见 CHANGELOG v1.0.17 的 panic 分析）。
  Future<void> _pollShizuku() async {
    if (!mounted || _pollBusy) return;
    _pollBusy = true;
    try {
      final ok = await ShizukuShell.checkPermission();
      if (!mounted) return;
      if (ok && !_shizuku) {
        setState(() => _shizuku = true);
        // 授权成功 ⇒ 立刻开始空闲期轮询（内部先刷一次健康条）
        chain.startHealthPolling();
      } else if (ok && _shizuku) {
        // 这个 3s 定时器只负责"权限还活着吗"（binder 查询，不 spawn 进程）；
        // 状态刷新交给 startHealthPolling 的 5s 轮询（空闲期才跑）。
      } else if (!ok && _shizuku) {
        // 权限查询可能滞后：用一条真实命令复核，避免图标闪跳
        final r = await ShizukuShell.run('echo RK_OK');
        final alive = r.out.contains('RK_OK');
        if (mounted && !alive) setState(() => _shizuku = false);
      }
    } catch (_) {
      // 轮询失败不改状态
    } finally {
      _pollBusy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshShizuku();
      _startShizukuPoll();
      chain.startHealthPolling();
    } else if (state == AppLifecycleState.paused) {
      _shizukuPoll?.cancel();
      _shizukuPoll = null;
      chain.stopHealthPolling();
    }
  }

  bool _celebrated = false;

  /// 冷却倒计时：只在「运行中或冷却中」时每秒刷一次 UI（纯 setState，不 spawn 任何进程）
  void _ensureCoolTick() {
    final need = chain.running || chain.startCooldownLeft > 0;
    if (!need) {
      _coolTick?.cancel();
      _coolTick = null;
      return;
    }
    _coolTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!chain.running && chain.startCooldownLeft == 0) {
        _coolTick?.cancel();
        _coolTick = null;
      }
    });
  }

  void _onChange() {
    _ensureCoolTick();
    if (!mounted) return;
    setState(() {});
    if (chain.success && !_celebrated) {
      _celebrated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showSuccessDialog());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _refreshShizuku() async {
    var ok = await ShizukuShell.checkPermission();
    if (!ok) {
      // 权限查询偶尔滞后：直接用一条命令验证真实能力
      final r = await ShizukuShell.run('echo RK_OK');
      ok = r.out.contains('RK_OK');
    }
    if (mounted) setState(() => _shizuku = ok);
    if (ok) _probeStatusOnce();
  }

  /// 授权后自动探测一次设备现状（打开 App 即显示「现状：…」，无需点开始）
  void _probeStatusOnce() {
    if (_statusProbed) return;
    _statusProbed = true;
    chain.detectStatus().catchError((Object e) {
      _statusProbed = false;   // 失败允许下次重试
    });
  }

  Future<void> _authorize() async {
    final ok = await ShizukuShell.requestPermission();
    if (mounted) setState(() => _shizuku = ok);
  }

  @override
  void dispose() {
    _shizukuPoll?.cancel();
    _coolTick?.cancel();
    chain.stopHealthPolling();
    WidgetsBinding.instance.removeObserver(this);
    chain.removeListener(_onChange);
    chain.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// 头部状态指示点：成功/已越狱=绿（带光晕）、运行中=蓝、有失败=红、空闲=灰
  Color _statusDotColor() {
    if (chain.success || chain.alreadyRooted) return const Color(0xFF59C98B);
    if (chain.stages.any((s) => s.status == StageStatus.failed)) {
      return const Color(0xFFE05B5B);
    }
    if (chain.running) return const Color(0xFF4FA3E3);
    return Colors.white30;
  }

  Color _statusColor(StageStatus s) {
    switch (s) {
      case StageStatus.ok:
        return const Color(0xFF4CAF80);
      case StageStatus.running:
        return const Color(0xFF4FA3E3);
      case StageStatus.failed:
        return const Color(0xFFE05B5B);
      case StageStatus.skipped:
        return const Color(0xFF6FA8A0);      // 完成态但略淡，区别"本次执行"与"已满足跳过"
      case StageStatus.pending:
        return Colors.white38;
    }
  }

  IconData _statusIcon(StageStatus s) {
    switch (s) {
      case StageStatus.ok:
        return Icons.check_circle_rounded;
      case StageStatus.running:
        return Icons.sync_rounded;
      case StageStatus.failed:
        return Icons.error_rounded;
      case StageStatus.skipped:
        return Icons.check_circle_rounded;   // 跳过 = 已满足，视觉上按完成态处理
      case StageStatus.pending:
        return Icons.radio_button_unchecked_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: _showSuccessDialog,   // 长按标题：预览成功弹窗（不跑链，仅看 UI）
          child: const Row(
            children: [
              Text('越狱助手'),
              SizedBox(width: 6),
              Text('v$kAppVersion', style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'GitHub 项目主页',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 34),
            icon: const GithubMark(size: 19),
            onPressed: _openRepo,
          ),
          IconButton(
            tooltip: '选项',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 34),
            icon: const Icon(Icons.tune_rounded, size: 19),
            onPressed: _showOptions,
          ),
          PopupMenuButton<String>(
            tooltip: '重启',
            padding: EdgeInsets.zero,
            iconSize: 19,
            icon: const Icon(Icons.restart_alt_rounded, size: 19),
            onSelected: (v) => _confirmReboot(soft: v == 'soft'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'soft',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.bolt_rounded, size: 20),
                  title: Text('软重启', style: TextStyle(fontSize: 13)),
                  subtitle: Text('只重启系统框架，KSU 模块保留',
                      style: TextStyle(fontSize: 10.5)),
                ),
              ),
              PopupMenuItem(
                value: 'hard',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.power_settings_new_rounded, size: 20),
                  title: Text('重启', style: TextStyle(fontSize: 13)),
                  subtitle: Text('正常重启整机（约 30–60 秒）',
                      style: TextStyle(fontSize: 10.5)),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: _shizuku ? 'Shizuku 已授权' : 'Shizuku 未授权（点击授权）',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 34),
            icon: Icon(
              _shizuku ? Icons.shield_rounded : Icons.shield_outlined,
              size: 19,
              color: _shizuku ? const Color(0xFF4CAF80) : Colors.orange,
            ),
            onPressed: _shizuku ? null : _authorize,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _headerCard(),
              const SizedBox(height: 6),
              _adviceCard(),
              const SizedBox(height: 6),
              Expanded(child: _logCard()),
              const SizedBox(height: 8),
              _buttons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCard() {
    final done = chain.stages
        .where((s) => s.status == StageStatus.ok || s.status == StageStatus.skipped)
        .length;
    final total = chain.stages.length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _statusDotColor(),
                    boxShadow: (chain.success || chain.alreadyRooted)
                        ? [
                            BoxShadow(
                              color: const Color(0xFF59C98B).withOpacity(0.55),
                              blurRadius: 7,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '状态：${!chain.running && chain.allDoneOrSkipped && chain.phase == '空闲' ? '已完成（含跳过）' : chain.phase}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: _showStagesDialog,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text('$done / $total ›',
                      style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ),
              ],
            ),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 4,
                backgroundColor: Colors.white10,
              ),
            ),
            const SizedBox(height: 7),
            if (!_shizuku)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Shizuku 未授权：点右上角盾牌图标授权后自动探测设备状态',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: Color(0xFFD8A13A))),
              ),
            _healthRow(),
            if (chain.lastError != null) ...[
              const SizedBox(height: 5),
              Text(
                chain.lastError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFE05B5B), fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 状态条：**一行看完**设备现状（原来"现状"那行已并进来）
  ///
  /// 顺序按"越靠前越容易出问题"排：温度 → 内存/slab → SELinux → 模块/KSU 管理器/su/资产 → 内核。
  /// 全部来自 5s 轮询的 health，不需要打开 App 后再点开始。
  Widget _healthRow() {
    final h = chain.health;
    final items = <String>[];
    final t = int.tryParse(h['T'] ?? '');
    if (t != null && t > 0) {
      // 分档与参考实现一致：≤40 最佳 / ≤55 可用 / >55 偏高
      final tier = RootChain.tempTier(t);
      final tag = tier == 0 ? '最佳' : (tier == 1 ? '可用' : '偏高');
      items.add('${(t / 1000).toStringAsFixed(1)}°C $tag');
    }
    if ((h['W'] ?? '').isNotEmpty) items.add(h['W']!);
    // M 现在是 '7G/14G' 形式（旧版是 14858/15011MB），别再加 MB 后缀
    if ((h['M'] ?? '').isNotEmpty) items.add('内存 ${h['M']}');
    if ((h['P'] ?? '').isNotEmpty) items.add('posix ${h['P']}');
    if ((h['C'] ?? '').isNotEmpty) items.add('cred ${h['C']}');
    if ((h['E'] ?? '').isNotEmpty) items.add(h['E']!);
    // 下面这几项原来在"现状：…"那一行，现在并进同一条状态带
    final ksu = int.tryParse((h['K'] ?? '0').trim()) ?? 0;
    final pwn = int.tryParse((h['G'] ?? '0').trim()) ?? 0;
    if (ksu > 0) {
      items.add('KSU 已加载');
    } else if (pwn > 0) {
      items.add('root 模块 $pwn');
    } else {
      items.add('KSU 未加载');
    }
    items.add(chain.ksuAppInstalled
        ? '管理器 ${chain.ksuAppVersion.isEmpty ? "已装" : "v${chain.ksuAppVersion}"}'
        : '管理器 未装');
    items.add((h['S'] ?? '0').trim() == '1' ? 'su ✓' : 'su ✗');
    if ((h['A'] ?? '').isNotEmpty) items.add('资产 ${h['A']}/4');
    if (chain.lastResetType.toLowerCase().contains('panic')) items.add('上次 panic');
    final kv = chain.calib.kernelVersion;
    if (kv.isNotEmpty) {
      items.add('内核 ${kv.split('-').take(2).join('-')}');
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final s in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(s,
                style: const TextStyle(fontSize: 9.5, color: Colors.white54)),
          ),
      ],
    );
  }

  /// 首次启动免责声明（勾「不再显示」后永久记住）
  Future<void> _maybeShowDisclaimer() async {
    // 存在设备目录而不是 App 私有 prefs：系统清包/重装后仍然记得
    // 注意：不要放子目录 —— 若该目录被子目录曾被 root 域进程创建，SELinux 标签会变成
    // u:r:kernel:s0，之后 shell 用户再也写不进去（真机实测 Permission denied）
    final seen = await ShizukuShell.run(
        'cat /data/local/tmp/rk/.disclaimer_hidden /data/local/tmp/rk/state/disclaimer.hidden '
        '2>/dev/null | head -1');
    if (seen.out.trim() == '1') return;
    final pref = await ShizukuShell.getPref('disclaimer.hidden');
    if (pref == '1') return;
    if (!mounted) return;
    var dontShow = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSt) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, size: 40, color: Color(0xFFFFC857)),
          title: const Text('免责声明', textAlign: TextAlign.center),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('本工具仅用于「本人自有设备」的学习与研究，用于理解 Android 内核的'
                    '权限模型、SELinux 与内核模块加载机制。',
                    style: TextStyle(fontSize: 12.5, height: 1.5)),
                const SizedBox(height: 8),
                const Text('请勿用于任何未经授权的设备；由此产生的一切后果由使用者自行承担。',
                    style: TextStyle(fontSize: 12.5, height: 1.5)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A2C12),
                    borderRadius: const BorderRadius.all(Radius.circular(9)),
                    border: Border.all(color: const Color(0xFFD8A13A), width: 1),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Icon(Icons.warning_amber_rounded,
                          size: 15, color: Color(0xFFD8A13A)),
                      SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '如果你没打算 root：请立刻把系统升级到最新版本。'
                          '本工具利用的是未打补丁系统上的真实漏洞，'
                          '不运行本工具不代表别人不会利用它。',
                          style: TextStyle(
                              fontSize: 11.5,
                              height: 1.45,
                              color: Color(0xFFE8C070)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('运行过程中设备可能内核 panic 重启，属已知现象；请确保已备份重要数据。',
                    style: TextStyle(fontSize: 11.5, color: Colors.white54, height: 1.4)),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actions: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: dontShow,
                  onChanged: (v) => setSt(() => dontShow = v ?? false),
                  visualDensity: VisualDensity.compact,
                ),
                const Text('不再显示', style: TextStyle(fontSize: 12)),
              ],
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx2).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      ),
    );
    if (dontShow) {
      await ShizukuShell.setPref('disclaimer.hidden', '1');
      await ShizukuShell.run(
          'echo 1 > /data/local/tmp/rk/.disclaimer_hidden');
    }
  }

  Future<void> _showCalibDialog() async {
    final c = chain.calib;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.biotech_rounded, size: 20),
            SizedBox(width: 8),
            Flexible(child: Text('校准结果', style: TextStyle(fontSize: 16))),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final it in c.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(it.ok ? Icons.check_circle_rounded : Icons.error_rounded,
                            size: 14,
                            color: it.ok ? const Color(0xFF4CAF80) : const Color(0xFFE05B5B)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(it.name, style: const TextStyle(fontSize: 12.5)),
                              Text(it.value,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10.5,
                                      color: Colors.white54)),
                              if (it.note.isNotEmpty)
                                Text(it.note,
                                    style: const TextStyle(fontSize: 10, color: Colors.white38)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Text('零写目标 selinux 别名：${c.selinuxAliasHex}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5,
                        color: Color(0xFF4FA3E3))),
                if (!c.items.any((e) => e.name == '内核物理基址' && e.ok))
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('提示：物理基址需 root 读 /proc/iomem；拿不到时请用该机 boot.img 推导后手动填入。',
                        style: TextStyle(fontSize: 10.5, color: Colors.orange)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _editPhysBase();
            },
            child: const Text('手填物理基址'),
          ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 手动填入内核物理基址（从该机 boot.img 推导出的加载地址）
  Future<void> _editPhysBase() async {
    final ctrl = TextEditingController(
        text: '0x${chain.calib.physBase.toRadixString(16)}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('内核物理基址', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'phys base (hex)',
                hintText: '0xC7800000',
              ),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            const Text('要求 2MB 对齐、0x80000000–0xFFFFFFFF。\n'
                '取法：① root 下读 /proc/iomem 的 “Kernel code”（自动）；'
                '② 上传本机 boot.img → 识别内核版本/哈希 → 命中记录即自动套用；'
                '③ 用已知同型号的值。',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 6),
            Text('当前别名：${chain.calib.selinuxAliasHex}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5,
                    color: Color(0xFF4FA3E3))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('应用')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final v = int.tryParse(ctrl.text.trim().replaceAll('0x', ''), radix: 16);
    if (v == null || !chain.calib.setPhysBase(v)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('地址无效：需 2MB 对齐且在 0x80000000–0xFFFFFFFF')),
        );
      }
      return;
    }
    await chain.calib.save();
    chain.addLogFromCalib('物理基址已手填为 0x${v.toRadixString(16)}，'
        '别名=${chain.calib.selinuxAliasHex}');
    if (mounted) setState(() {});
  }

  Future<void> _showSuccessDialog() async {
    final soft = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_rounded, size: 44, color: Color(0xFF4CAF80)),
        title: const Text('越狱成功 🎉', textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('su 已验证通过：', style: TextStyle(fontSize: 13)),
            SizedBox(height: 4),
            const SelectableText('uid=0(root) … context=u:r:ksu:s0',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5,
                    color: Color(0xFF4CAF80))),
            const SizedBox(height: 10),
            const Text('KernelSU 面板如果还显示「未安装 / 未工作」，通常是管理器状态没刷新。',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            const Text('建议顺序：① 先试「软重启」（只重启框架，KSU 模块保留）→ ② 再打开 KernelSU。',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            const Text('软重启无效时，再用右上角的「重启」（正常重启；重启后需要重新运行本工具）。',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 6),
            const Text('屏幕常亮 / 关 WiFi·蓝牙 等选项的影响已自动恢复原状。',
                style: TextStyle(fontSize: 11, color: Color(0xFF4CAF80))),
            const SizedBox(height: 12),
            const Divider(height: 1, color: Colors.white10),
            const SizedBox(height: 10),
            const Text('如果对你有帮助，可以请作者喝杯咖啡',
                style: TextStyle(fontSize: 12, color: Color(0xFFFFC857))),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _QrTile(
                    asset: 'assets/qr_wechat.png',
                    label: '微信',
                    fileName: 'rootkit_wechat.png',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _QrTile(
                    asset: 'assets/qr_alipay.png',
                    label: '支付宝',
                    fileName: 'rootkit_alipay.png',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text('点图放大 · 长按保存到相册',
                style: TextStyle(fontSize: 10, color: Colors.white38)),
          ],
        ),
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(0),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('打开 KernelSU'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(1),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      child: const Text('软重启'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(2),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                      child: const Text('稍后'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
    if (soft == null || !mounted) return;
    if (soft == 1) {
      final ok = await chain.softReboot();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '已发出软重启，等桌面恢复后再打开 KernelSU（模块仍在）'
            : '软重启被拒；请用右上角「重启」做正常重启'),
      ));
    } else if (soft == 0) {
      // 打开前先杀掉 KernelSU 后台，让它重新读取模块状态
      await ShizukuShell.run('am force-stop me.weishu.kernelsu');
      await Future.delayed(const Duration(milliseconds: 600));
      await ShizukuShell.openApp('me.weishu.kernelsu');
    }
  }

  /// 打开项目主页（GitHub）
  Future<void> _openRepo() async {
    final ok = await ShizukuShell.openUrl(kRepoUrl);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可用的浏览器，请手动访问 $kRepoUrl')),
      );
    }
  }

  Future<void> _showOptions() async {
    final maxH = MediaQuery.of(context).size.height * 0.72;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSt) => AlertDialog(
          // 关闭按钮放在标题右侧（原来在最底部，屏幕矮时够不到）
          titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
          title: Row(
            children: [
              const Icon(Icons.tune_rounded, size: 20),
              const SizedBox(width: 8),
              const Text('选项', style: TextStyle(fontSize: 16)),
              const Spacer(),
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
          // 设置项可上下滑动：内容比屏幕高时不再被截断
          content: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: chain.optTap,
                    title: const Text('每轮自动点屏', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('防止息屏/doze 让命中率归零（建议开）',
                        style: TextStyle(fontSize: 11)),
                    onChanged: (v) async {
                      await chain.setOptions(tap: v);
                      if (ctx2.mounted) setSt(() {});
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: chain.optStayOn,
                    title: const Text('保持屏幕常亮', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('运行期间不让屏幕熄灭（建议开）',
                        style: TextStyle(fontSize: 11)),
                    onChanged: (v) async {
                      await chain.setOptions(stayOn: v);
                      if (ctx2.mounted) setSt(() {});
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        icon: const Icon(Icons.brightness_2_rounded, size: 15),
                        label: const Text('现在关闭常亮（含开发者选项里的「保持唤醒」）',
                            style: TextStyle(fontSize: 11.5)),
                        onPressed: () async {
                          await chain.disableStayOnNow();
                          if (ctx2.mounted) {
                            ScaffoldMessenger.of(ctx2).showSnackBar(const SnackBar(
                                content: Text('已关闭常亮并恢复屏幕超时')));
                          }
                        },
                      ),
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: chain.optWifiOff,
                    title: const Text('运行前关闭 WiFi / 蓝牙（开飞行模式）',
                        style: TextStyle(fontSize: 14)),
                    subtitle: const Text('只开飞行模式（WiFi/蓝牙由系统自行关闭，不单独去关）。'
                        '命中率更高（射频干扰更少）。代价：Shizuku 的无线调试会断开；'
                        '重启后需要先重新打开 WiFi、在开发者选项里重新开启「无线调试」，'
                        '才能再启动 Shizuku（或者用电脑 adb 启动，不需要 WiFi）',
                        style: TextStyle(fontSize: 11)),
                    onChanged: (v) async {
                      await chain.setOptions(wifiOff: v);
                      if (ctx2.mounted) setSt(() {});
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: chain.optKillBg,
                    title: const Text('开打前清理后台（默认关）',
                        style: TextStyle(fontSize: 14)),
                    subtitle: const Text('每发之前只清理第三方 App 的后台进程'
                        '（系统/供应商服务、Shizuku、KernelSU 一律不动）。'
                        '后台多时会抢 pipe 页预算、干扰页回收，落位更容易失败（进而 panic）；'
                        '被杀的后台重新打开即恢复，软重启可全部复原',
                        style: TextStyle(fontSize: 11)),
                    onChanged: (v) async {
                      await chain.setOptions(killBg: v);
                      if (ctx2.mounted) setSt(() {});
                    },
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: chain.optCleanup,
                    title: const Text('成功后清理残留文件', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('停掉 5556 root shell、删除 /data/local/tmp/rk 里的原生件与临时文件'
                        '（已加载的模块不受影响；下次运行会自动重新部署）',
                        style: TextStyle(fontSize: 11)),
                    onChanged: (v) async {
                      await chain.setOptions(cleanup: v);
                      if (ctx2.mounted) setSt(() {});
                    },
                  ),
                  const Divider(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      icon: const Icon(Icons.restore_rounded, size: 15),
                      label: const Text('立即恢复运行前的系统设置（超时/常亮/飞行/WiFi/蓝牙）',
                          style: TextStyle(fontSize: 11.5)),
                      onPressed: () async {
                        await chain.restoreOptions();
                        if (ctx2.mounted) {
                          ScaffoldMessenger.of(ctx2).showSnackBar(const SnackBar(
                              content: Text('已恢复运行前的系统设置')));
                        }
                      },
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        setState(() => chain.phase = '校准中');
                        await chain.calib.detect(log: chain.addLogFromCalib);
                        if (mounted) {
                          setState(() => chain.phase = '空闲');
                          _showCalibDialog();
                        }
                      },
                      icon: const Icon(Icons.biotech_rounded, size: 16),
                      label: const Text('重新校准（5 项自动探测）',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                  ),
                  const Divider(height: 16),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const GithubMark(size: 20),
                    title: const Text('GitHub 项目主页', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(kRepoUrl, style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 16),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _openRepo();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showPrevLog() async {
    final lines = await chain.loadPrevLog();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: const Color(0xFF101416),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    const Text('历史日志（含上次运行）',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      tooltip: '复制',
                      icon: const Icon(Icons.copy_rounded, size: 19),
                      onPressed: () =>
                          _copyLogs(lines, label: '历史日志', ctx: ctx),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 21),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white10),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    lines.isEmpty ? '（还没有历史日志）' : lines.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.3,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmReboot({bool soft = false}) async {
    if (soft) {
      final ok = await chain.softReboot();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '已发出软重启（KSU 模块保留）' : '软重启被拒，请改用正常重启'),
      ));
      return;
    }
    final permissive = chain.health['E'] == 'Permissive';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.restart_alt_rounded, size: 20),
            SizedBox(width: 8),
            Text('重启设备', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Text(
          permissive
              ? '当前是 Permissive（SELinux 已被打坏）。现在做一次**正常重启**，'
                  '比等它 panic 重启快得多，也不会长时间黑屏。\n\n'
                  '重启后 SELinux 会恢复 Enforcing，需要重新运行本工具。'
              : '将执行正常重启（约 30–60 秒）。\n\n'
                  '如果刚跑到一半，进度会丢失，重启后需要重新开始。',
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('立即重启'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    chain.logs.add('[reboot] 正在重启（正常 reboot）…');
    chain.notifyListeners();
    // 先把能恢复的恢复（有 root shell 时让模块修 initialized），再 reboot
    await ShizukuShell.run(
      'echo "chmod 755 /data/local/tmp/rk/module.ko 2>/dev/null; '
      'for m in /data/local/tmp/rk/module*.ko; do /data/local/tmp/rk/ml2 \$m >/dev/null 2>&1; done" '
      '| nc -w 3 127.0.0.1 5556 2>/dev/null',
      timeoutMs: 8000,
    );
    await ShizukuShell.run('svc power reboot 2>/dev/null || reboot', timeoutMs: 8000);
  }

  /// 取日志卡片当前在屏幕上的矩形（动效起点）
  Rect? _logCardRect() {
    final ro = _logCardKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      final off = ro.localToGlobal(Offset.zero);
      return off & ro.size;
    }
    return null;
  }

  Future<void> _showLogFullscreen() async {
    final from = _logCardRect();
    await Navigator.of(context).push(_ExpandFromRectRoute(
      from: from,
      background: const Color(0xFF101416),
      builder: (ctx) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
              child: Row(
                children: [
                  const Text('日志（全屏）',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    tooltip: '复制',
                    icon: const Icon(Icons.copy_rounded, size: 19),
                    onPressed: () => _copyLogs(chain.logs, ctx: ctx),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded, size: 21),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  chain.logs.isEmpty ? '（等待运行…）' : chain.logs.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.35,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  // ignore: unused_element
  Future<void> _showLogFullscreenOld() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: const Color(0xFF101416),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    const Text('日志（全屏）',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      tooltip: '复制',
                      icon: const Icon(Icons.copy_rounded, size: 19),
                      onPressed: () => _copyLogs(chain.logs, ctx: ctx),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close_rounded, size: 21),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white10),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    chain.logs.isEmpty ? '（等待运行…）' : chain.logs.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.35,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showStagesDialog() async {
    final done = chain.stages
        .where((s) => s.status == StageStatus.ok || s.status == StageStatus.skipped)
        .length;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.checklist_rounded, size: 18),
            const SizedBox(width: 8),
            Text('阶段进度 $done/${chain.stages.length}',
                style: const TextStyle(fontSize: 15)),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < chain.stages.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: Colors.white10),
                  _stageRow(chain.stages[i]),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _stageRow(StageState s) {
    final c = _statusColor(s.status);
    final rate = s.hasRate
        ? '命中 ${s.hits}/${s.tries} (${(s.rate * 100).toStringAsFixed(0)}%)'
        : (s.runs > 0 ? '轮数 ${s.runs}' : '');
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -4),
      leading: Icon(_statusIcon(s.status), color: c, size: 17),
      title: Text(s.title,
          style: TextStyle(
            fontSize: 12.5,
            color: s.status == StageStatus.pending ? Colors.white54 : Colors.white,
            fontWeight: s.status == StageStatus.running
                ? FontWeight.w600
                : FontWeight.normal,
          )),
      subtitle: Text(
        [
          if (s.status == StageStatus.skipped && s.detail.isNotEmpty) '已满足（跳过）· ${s.detail}',
          if (s.status != StageStatus.skipped && rate.isNotEmpty) rate,
          if (s.status != StageStatus.skipped && s.detail.isNotEmpty) s.detail,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Colors.white38),
      ),
      trailing: s.status == StageStatus.running
          ? const SizedBox(
              width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
    );
  }

  Widget _adviceCard() {
    final list = chain.suggestions.take(2).toList();
    return Card(
      margin: EdgeInsets.zero,
      color: const Color(0xFF1B2A2E),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.lightbulb_outline, size: 14, color: Color(0xFFFFC857)),
                SizedBox(width: 5),
                Text('建议', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            for (final s in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('· $s',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ),
          ],
        ),
      ),
    );
  }

  /// 一键复制：把「版本 + 设备现状 + 阶段结果 + 日志」一起复制
  ///
  /// 只复制日志时，别人拿到截图/文本不知道你跑的是哪个版本、卡在哪个阶段；
  /// 这里把这三样拼在头部，配合 App 里的 [diag:*] 行，远程排障不用再问一轮。
  Future<void> _copyLogs(List<String> lines,
      {String label = '日志', BuildContext? ctx}) async {
    final buf = StringBuffer()
      ..writeln('=== 越狱助手 v$kAppVersion $label ===')
      ..writeln('时间: ${DateTime.now().toString().substring(0, 19)}')
      ..writeln('设备: ${chain.devState}');
    final bad = chain.stages
        .where((s) => s.status == StageStatus.failed)
        .map((s) => '${s.title}=${s.detail}')
        .join(' | ');
    if (bad.isNotEmpty) buf.writeln('失败阶段: $bad');
    if (chain.lastError != null && chain.lastError!.isNotEmpty) {
      buf.writeln('lastError: ${chain.lastError}');
    }
    buf
      ..writeln('阶段: ${chain.stages.map((s) => '${s.title}=${s.status.name}').join(' ')}')
      ..writeln('--- 日志 ${lines.length} 行 ---')
      ..writeln(lines.join('\n'));
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    final c = ctx ?? context;
    if (!c.mounted) return;
    ScaffoldMessenger.of(c).showSnackBar(
      SnackBar(content: Text('已复制 ${lines.length} 行（含版本与阶段摘要）')),
    );
  }

  Widget _logCard() {
    return Card(
      key: _logCardKey,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            child: Row(
              children: [
                const Text('日志',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  tooltip: '复制全部日志',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_all_rounded, size: 18),
                  onPressed: () => _copyLogs(chain.logs),
                ),
                IconButton(
                  tooltip: '上次运行日志',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.history_rounded, size: 18),
                  onPressed: _showPrevLog,
                ),
                IconButton(
                  tooltip: '全屏',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.fullscreen_rounded, size: 18),
                  onPressed: _showLogFullscreen,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: Scrollbar(
              key: _logBodyKey,
              controller: _logScroll,
              child: SingleChildScrollView(
                controller: _logScroll,
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: SelectableText(
                  chain.logs.isEmpty ? '（等待运行…）' : chain.logs.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.3,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buttons() {
    final busy = chain.running;
    final cool = chain.startCooldownLeft;   // >0 = 冷却中，禁止再次点「开始」
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: FilledButton.icon(
            // 连点保护：运行中 或 冷却中 一律禁用（连点只会让设备反复重启升温）
            onPressed: (busy || cool > 0 || !chain.canStart) ? null : () => chain.start(),
            icon: Icon(busy
                ? Icons.hourglass_top_rounded
                : (cool > 0 ? Icons.thermostat_rounded : Icons.play_arrow_rounded),
                size: 18),
            label: Text(
                busy
                    ? '执行中…'
                    : (cool > 0 ? '冷却中 ${cool}s' : '开始越狱'),
                style: const TextStyle(fontSize: 13)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: OutlinedButton(
            onPressed: busy ? () => chain.stop() : null,
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 11)),
            child: const Text('停止', style: TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: OutlinedButton(
            onPressed: () => ShizukuShell.openApp('me.weishu.kernelsu'),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 11)),
            child: const Text('KernelSU', style: TextStyle(fontSize: 13)),
          ),
        ),
      ],
    );
  }
}


/// 从某个矩形（例如日志卡片）展开成全屏的路由。
/// 进入：从 from 矩形放大到全屏（圆角 16 -> 0，略淡入）
/// 退出：反向收缩回 from 矩形
class _ExpandFromRectRoute<T> extends PageRouteBuilder<T> {
  final Rect? from;
  final Color background;
  final WidgetBuilder builder;

  _ExpandFromRectRoute({
    required this.from,
    required this.background,
    required this.builder,
  }) : super(
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 230),
          opaque: false,
          barrierColor: Colors.black26,
          pageBuilder: (ctx, a1, a2) => Material(
            color: background,
            child: builder(ctx),
          ),
        );

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final size = MediaQuery.of(context).size;
    final t = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic);
    final begin = from ?? Rect.fromCenter(
        center: Offset(size.width / 2, size.height * 0.75),
        width: size.width * 0.9,
        height: 160);
    return AnimatedBuilder(
      animation: t,
      builder: (ctx, _) {
        final r = Rect.lerp(begin, Offset.zero & size, t.value)!;
        return Stack(
          children: [
            Positioned(
              left: r.left,
              top: r.top,
              width: r.width,
              height: r.height,
              child: Opacity(
                opacity: (0.55 + 0.45 * t.value).clamp(0.0, 1.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16 * (1 - t.value)),
                  child: FittedBox(
                    fit: BoxFit.fill,
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 收款码卡片：点击放大（可双指缩放），长按保存到相册
class _QrTile extends StatelessWidget {
  final String asset;
  final String label;
  final String fileName;

  const _QrTile({
    required this.asset,
    required this.label,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showZoom(context),
          onLongPress: () => _saveWithDialog(context, asset, fileName),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Image.asset(asset, height: 132, fit: BoxFit.contain),
          ),
        ),
        const SizedBox(height: 3),
        Text(label,
            style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
      ],
    );
  }

  /// 保存结果用弹窗提示（用户要求：保存时弹窗）
  static Future<void> _saveWithDialog(BuildContext ctx, String asset, String fileName) async {
    final msg = await ShizukuShell.saveImage(asset, fileName);
    if (!ctx.mounted) return;
    final ok = msg.startsWith('saved');
    await showDialog<void>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        icon: Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded,
            size: 38, color: ok ? const Color(0xFF4CAF80) : const Color(0xFFE05B5B)),
        title: Text(ok ? '已保存到相册' : '保存失败',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
        content: Text(
          ok ? '路径：${msg.replaceFirst('saved: ', '')}\n\n可在系统相册 → Pictures/RootKit 里找到。' : msg,
          style: const TextStyle(fontSize: 12.5, height: 1.5),
          textAlign: TextAlign.center,
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  void _showZoom(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onLongPress: () => _saveWithDialog(ctx, asset, fileName),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.asset(asset, height: 320, fit: BoxFit.contain),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => _saveWithDialog(ctx, asset, fileName),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('保存到相册'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
