<!-- 适配新机型/新内核的 PR 用此模板 -->

## 目标内核

```
uname -r: 
/proc/version: 
机型 / 系统版本 / 安全补丁: 
```

## 5 项标定值（缺一项就别急着提 PR）

| 项 | 值 | 来源/推导方式 |
|---|---|---|
| `physBase` |  | boot.img 解 kernel，按 `_text` 链接基址反推 |
| `selinux_state` 偏移 |  | 符号表 / kallsyms / BTF |
| `module_layout` CRC |  | 内核 `__versions` 或 vendor 模块 modinfo |
| 模块 vermagic |  | `uname -r` 整串 |
| 离线符号表 |  | 内核 kallsyms（脱敏 s 后压缩入库） |

## 真机验证

- [ ] ① permissive 命中（`getenforce`=Permissive，且 `selinux_state.initialized` 未被破坏）
- [ ] ④ cap_bset 清零（`CAPBND_ZERO`）
- [ ] ⑤ cap_effective（`CAPEFF_OK`）
- [ ] ⑥ 模块装载（`ROOT_OK` / `AFTER_MOD uid=0`）
- [ ] ⑦ KernelSU 加载、⑧ `su -c id` = uid=0
- [ ] 跑完整链后：相机、电话、输入法正常（**这是必测项**）

## 清单

- [ ] `lib/known_kernels.dart` 增加了本内核条目（含 note 说明来源）
- [ ] 载荷已重新编译并更新 md5（说明编译器/参数）
- [ ] README §6「适配其他内核」如有新坑，已补进去
