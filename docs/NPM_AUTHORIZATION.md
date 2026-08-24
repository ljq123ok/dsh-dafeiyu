# npm 发布授权申请 / npm Publish Authorization Request

> **状态 / Status**: 已提交 Issue [#42](https://github.com/QCYTSN/dsh-dafeiyu/issues/42)（2026-08-24）
> 原作者 QCYTSN 尚未响应 / Pending original-author review.

## 请求内容 / Request

我们请求原作者 **QCYTSN** 授权 fork 仓库 **ljq123ok/dsh-dafeiyu** 通过 npm **Trusted Publishing (OIDC)** 发布 `dsh-dafeiyu` 包：

### 原作者只需一步 / One step for the author

在 npm 上打开 `dsh-dafeiyu` 包 → **Access / Settings → Trusted Publishing** → 添加：

- **Repository**: `ljq123ok/dsh-dafeiyu`
- **Environment**: `main`（或默认）

> 或者：把 `ljq123ok` 加为 npm 包的 **collaborator**（publish 权限）。

### 或直接联系我们 / Or contact us

- Fork 仓库：https://github.com/ljq123ok/dsh-dafeiyu
- 发布分支：`main`（tag `v0.2.0`）
- GitHub Release：https://github.com/ljq123ok/dsh-dafeiyu/releases/tag/v0.2.0

## 我们发布的内容 / What we publish

| 项目 | 说明 |
| --- | --- |
| 包名 | `dsh-dafeiyu@0.2.0` |
| 平台 | **仅 Apple Silicon (arm64) macOS**（M1/M2/M3/M4） |
| 实现 | Swift + AppKit 原生重构（`DafeiyuHelper.app` 替代原版 Python/Qt helper） |
| 功能 | 对齐原版 v0.1.5：状态动画/程序化动效/点击互动/右键菜单/完成音效/系统通知/微动画频率/crossfade |
| 声明 | README/CHANGELOG 已注明原作者 QCYTSN（MIT，视觉素材除外）与功能对比 |

## 许可合规 / License compliance

- 代码：MIT（LICENSE 保留 Copyright (c) 2026 QCYTSN 2026）
- 视觉素材：`assets/pet/` 遵循 ASSET_LICENSE.md（不在 MIT 内，保持原作者版权）

## 后续步骤 / Next steps

1. 原作者授权 npm OIDC 或加 collaborator
2. 重新触发 fork 的 `.github/workflows/publish.yml`（workflow_dispatch, dist_tag=latest）
3. npm 发布 `dsh-dafeiyu@0.2.0`（含 macOS .app）

---

*English summary: We request authorization for the fork `ljq123ok/dsh-dafeiyu` to publish `dsh-dafeiyu` via npm Trusted Publishing (OIDC), as a macOS-only Swift/AppKit refactor of the original package by QCYTSN. See [Issue #42](https://github.com/QCYTSN/dsh-dafeiyu/issues/42).*
