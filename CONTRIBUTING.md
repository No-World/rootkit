# 贡献与分支规则

> 一句话：**`main` 只收 PR 和发版，任何改动都先开分支。**

## 1. 分支模型

| 分支 | 用途 | 谁写 |
|---|---|---|
| `main` | 只接受 PR 合并；每次合并都必须是可发布的提交 | **不允许直推**（分支保护已开） |
| `feat/<简述>` | 新功能 | 开分支 → PR |
| `fix/<简述>` | 缺陷修复 | 开分支 → PR |
| `chore/<简述>` | 构建/CI/文档/依赖 | 开分支 → PR |

`main` 已开保护：**禁止强推、禁止删除、必须走 PR、必须过 `build-debug` 检查**（连管理员也受约束）。

## 2. 一次改动的完整流程

```bash
git checkout main && git pull            # 1. 从最新的 main 开始
git checkout -b fix/camera-hal-nullptr   # 2. 开分支（名字写清做什么）

# ...改代码...

git add -A && git commit -m "fix: ..."   # 3. 提交（信息写「改了什么 + 为什么」）
git push -u origin fix/camera-hal-nullptr

gh pr create --base main --fill           # 4. 开 PR（或网页开）
# 等 CI：build-debug 必须绿（它是唯一门禁：编译 + 8 个载荷齐全 + APK 能出）
gh pr merge --squash --delete-branch      # 5. 合并（squash，保持 main 单线可读）
```

## 3. PR 的测试包（怎么在自己手机上验）

每个 PR 的 `debug` 检查会顺手构建一个**可直接装机的测试包**（两种拿法）：

| 拿法 | 地址 | 是否 zip |
|---|---|---|
| 直链（推荐） | Releases 里的预发布 `pr-<号>`：`…/releases/download/pr-3/RootKit-v1.0.16-pr3-test.apk` | **不是**，点开就是 apk |
| Actions Artifacts | PR → Checks → `debug` → 页面底部 | 是（GitHub 强制 zip） |

| 项 | 值 |
|---|---|
| 包名 | `com.noworld.rootkit.debug` |
| 构建 | **release / AOT**（与正式版同构），不是 JIT debug 包 |
| 体积 | ≈19MB（debug 包要 157MB，artifact 71MB） |
| 签名 | debug key ⇒ 可与正式版共存；**不能**覆盖正式版 |

```bash
adb install -r RootKit-v1.0.16-pr3-test.apk
```

**坑（都踩过）**：

- **`actions/upload-artifact` 永远打包成 zip**，单文件也一样。要「点开就是 apk」只能挂 Release，
  所以这里给每个 PR 建预发布 `pr-<号>`，PR 关闭时由 `pr-cleanup.yml` 自动删除。
- **测试包不要用 `flutter build apk --debug`**：157MB，artifact 压完还有 71MB，
  下载和装机都慢；改用 `PR_TEST_BUILD=1 flutter build apk --release`（gradle 会给 release
  追加 `.debug` 包名与 `-prtest` 版本后缀），体积回到 ≈19MB 且行为与正式版一致。
- **`upload-artifact` 找不到文件时默认只 warn**，会产出一个「没有任何 Artifacts」的绿色运行 ——
  所以设了 `if-no-files-found: error`。看到「CI 没出包」先看是不是 0 job 的失败运行
  （workflow 表达式写错时 GitHub 会造一个 0 job 的 failure run，页面上只有一句
  `Invalid workflow file: …`）。
- 包名带 `.debug` ⇒ 与正式版 `com.noworld.rootkit` 是两个 App，桌面图标同名，别点错。

## 4. 模板（Issue / PR）

开 Issue 时按类型选模板，**它们问的都是定位必需的信息**，不填没法查：

| 模板 | 用在什么时候 |
|---|---|
| 问题反馈 · Bug 报告 | 闪退、卡在某阶段、异常重启、相机/系统异常 |
| 适配申请 · 新机型/新内核 | 想支持别的机器或别的内核镜像（要 5 项标定值） |
| 功能建议 | App 功能层面的想法（不是适配） |

PR 模板可点选：`?template=bugfix.md` / `feature.md` / `adaptation.md` / `chore.md`
（默认模板 `PULL_REQUEST_TEMPLATE.md` 就是这四个的索引）。
适配类 PR 必须带**跑完整链后相机/电话/输入法正常**这一项 —— 这是「写坏内核状态」最容易漏测的地方。

## 5. 发版流程（只有 `main` 才发）

```bash
git checkout main && git pull
# 1) 改版本：pubspec.yaml 的 version: 1.0.17+10017 与 lib/main.dart 的 kAppVersion 同步改
# 2) 写 CHANGELOG.md（新段在最上）
# 3) 提交并走 PR 合并进 main（发版准备也走 PR）
gh release create v1.0.17 --title "v1.0.17 —— ..." --notes-file notes.md
```

- **发布 Release 才会构建签名包**：`build-release.yml` 由 `release: published` 触发，
  checkout 该 tag → 构建 → 校验签名 → 把 `RootKit-<tag>.apk` + `.md5` 挂到同一个 Release。
- **只打 tag 不发 Release ⇒ 不会构建**（tag 只是里程碑）。
- 所以：**先合并进 `main`，再在 `main` 的提交上打 tag**；tag 指向的提交里必须有当版 workflow，
  否则 CI 用的是旧 workflow。

## 6. PR 检查清单

- [ ] `flutter analyze` 无新增 error（模板自带的 `test/widget_test.dart` 报错属已知，不影响）
- [ ] CI `build-debug` 绿
- [ ] 改了原生载荷（`assets/*.gz`、`module.ko`、`ksu_template.ko`）时，同步说明改动来源与 md5
- [ ] 改了阶段逻辑时，CHANGELOG 写清「现象 → 根因 → 修法 → 验证判据」
- [ ] **绝不提交**：签名私钥（`*.jks`）、`key.properties`、真实收款码、设备序列号/IP/口令

## 7. 为什么这么定（踩过的坑）

- **直推 `main` 曾把带真实收款码的历史推上去**，事后只能重建历史 + 删 tag/Release。
  PR 至少留一次「合并前看得见」的机会。
- **没有门禁时，改坏的载荷会被直接发出去**：`build-debug` 会检查 8 个载荷是否齐全，
  少一个立即红。
- **squash 合并**保证 `main` 每个提交都能独立构建（bisect 才有意义）。
