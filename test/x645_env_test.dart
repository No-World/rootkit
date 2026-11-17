import 'package:flutter_test/flutter_test.dart';
import 'package:rootkit/x645_env.dart';

/// x645 env 串的纯逻辑测试（不联网、不需要设备）。
///
/// 为什么值得单测：这些键拼错了**不会**让 `flutter build` 失败，也不会让
/// `dart analyze` 报错，只会在真机上退化成"跑不通"。最典型的一次是漏 `P645_LEFT`：
/// 载荷构造 fake_node 读的是它，只给 `P645_FORCE_LEFT` 时判据成立但内核零写入
/// （见 CHANGELOG「未发布 — BKQ-AN10 适配修复」）。
void main() {
  const zero = '0xffffff8049fe7a59';

  /// env 串 → key → value（这些值是单个 token，不含空格）
  Map<String, String> parse(String env) {
    final m = <String, String>{};
    for (final tok in env.split(' ')) {
      final i = tok.indexOf('=');
      m[tok.substring(0, i)] = tok.substring(i + 1);
    }
    return m;
  }

  String permissive({String? left = zero}) => x645StageEnv(
        stageFrom: 0,
        stageTo: 1,
        tries: 4,
        prePipes: 512,
        logPath: '/data/local/tmp/rk/s0_1.log',
        extra: left == null ? '' : 'P645_LEFT=$left P645_FORCE_LEFT=$left ',
      );

  group('permissive 的零写目标（这次修的 bug）', () {
    test('P645_LEFT 与 P645_FORCE_LEFT 必须同时给、且同值', () {
      final kv = parse(permissive());
      expect(kv['P645_LEFT'], zero);
      expect(kv['P645_FORCE_LEFT'], zero);
    });

    test('不给 extra 时两个键都不出现 —— 说明必须由调用方显式给，函数没有默认值', () {
      final kv = parse(permissive(left: null));
      expect(kv.containsKey('P645_LEFT'), isFalse);
      expect(kv.containsKey('P645_FORCE_LEFT'), isFalse);
    });
  });

  group('串的骨架', () {
    test('没有空 token（少一个空格会把两个键粘成一个）', () {
      expect(permissive().split(' ').where((t) => t.isEmpty), isEmpty);
    });

    test('每个 token 都是 P645_KEY=VALUE，且没有重复键', () {
      final toks = permissive().split(' ');
      for (final t in toks) {
        expect(t, startsWith('P645_'), reason: t);
        expect(t.contains('='), isTrue, reason: t);
      }
      // 重复键不会报错，只会让 getenv 取到哪一个是运气 —— 属于隐性 bug
      expect(toks.map((t) => t.substring(0, t.indexOf('='))).toSet().length,
          toks.length);
    });

    test('参数按位置注入', () {
      final kv = parse(x645StageEnv(
        stageFrom: 1,
        stageTo: 2,
        tries: 6,
        prePipes: 20000,
        logPath: '/data/local/tmp/rk/probe.log',
      ));
      expect(kv['P645_STAGE'], '1');
      expect(kv['P645_STAGE_FROM'], '1');
      expect(kv['P645_STAGE_TO'], '2');
      expect(kv['P645_STAGE_TRIES'], '6');
      expect(kv['P645_PRE_PIPES'], '20000');
      expect(kv['P645_LOG'], '/data/local/tmp/rk/probe.log');
    });

    test('extra 落在 RING_GO 之后、PRE_PIPES 之前（末尾缺空格会粘键）', () {
      expect(
          permissive(),
          contains('P645_RING_GO=0 '
              'P645_LEFT=$zero P645_FORCE_LEFT=$zero '
              'P645_PRE_PIPES=512'));
    });

    test('整串 golden：改任何默认参数都必须同时改这条', () {
      expect(
          permissive(),
          'P645_STAGE=1 P645_STAGE_FROM=0 P645_STAGE_TO=1 P645_STAGE_TRIES=4 '
          'P645_ATTEMPTS=1 P645_KIDS=0 P645_CRED_FARM=0 P645_DRAIN_AFTER=0 '
          'P645_THREAD_FILL=0 P645_FILL_SELF=0 P645_LEAK_FORK=0 P645_FORK_AFTER=0 '
          'P645_PRE_UM_MB=0 P645_TIMERS=54000 P645_REPEATS=520 P645_NDEL=7 '
          'P645_DEL_RUN_MS=2500 P645_CONC=1 P645_ANON_MB=8 P645_FREEZE=1 P645_V8=1 '
          'P645_DRAIN_WAIT_MS=25000 P645_PIPE512=64 P645_SOCKS=64 P645_SOCK_MB=8 '
          'P645_UHID=0 P645_MODE=4 P645_ANON2_MB=1024 P645_PIPE_DRAIN=1 P645_PIPE_K=4 '
          'P645_SCAN_STOP=1 P645_THRESH=32 P645_RING_GO=0 P645_LEFT=0xffffff8049fe7a59 '
          'P645_FORCE_LEFT=0xffffff8049fe7a59 P645_PRE_PIPES=512 '
          'P645_LOG=/data/local/tmp/rk/s0_1.log');
    });
  });
}
