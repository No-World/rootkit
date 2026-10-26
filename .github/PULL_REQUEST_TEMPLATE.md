## 选一个模板（点击下面的链接，PR 页面会带上对应结构）

- [🐞 缺陷修复 `bugfix.md`](?template=bugfix.md) —— 现象 / 根因 / 修法 / 验证 四件套
- [✨ 新功能 `feature.md`](?template=feature.md)
- [📱 适配新机型/新内核 `adaptation.md`](?template=adaptation.md) —— 5 项标定值 + 真机验证清单
- [🔧 构建 / CI / 文档 `chore.md`](?template=chore.md)

---

不确定选哪个？那就按下面这个最小结构写，四项缺一不可：

```markdown
## 改了什么

## 为什么

## 怎么验证的（可复现的判据）

## 风险 / 回滚
```

> 分支规则：`main` 只收 PR；`feat/*` `fix/*` `chore/*` 开分支 → PR → `build-debug` 绿 → squash 合并。
> 详见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
