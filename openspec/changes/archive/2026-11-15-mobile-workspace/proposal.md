## Why

用户确认：为当前显示为ChatGPT、实际bundleID为com.openai.codex的应用适配字号；进入Snug手机屏后统一收拢当前桌面普通工作窗口，切换时留在手机屏，断开后统一归位，特殊状态不自动展开。用户同时要求fork到chent1024/snug、提交推送codex/mobile-workspace，并对齐上游最新代码。

## What Changes

- 基线为上游main 489ee4b5d85ba1411763e727deb839f16487b087（2.3.0），保留上游资源库、新建/关闭App和自适应模式。
- 迁入红米488×1084、iPhone13 585×1266两个基础画面像素选项，保留标准1×和4级字号；大窗口按上游机制临时扩展同宽高比档位，回列表回基础档。
- 当前目标com.openai.codex加入专用缩放规则：增加字号按官方⌘+，减少按⌘−，记实际步数并反向撤回，不使用⌘0。用户已手动确认可放大并恢复。
- 从进入手机屏开始，普通工作窗口整会话收拢并在断开后统一恢复。创建前完整保存身份、原位、桌面归属；只在真实读回匹配后销账，锁屏保留记录待解锁续行。物理屏保持开启。

## Capabilities

### New Capabilities
- `mobile-workspace`: 两套基础尺寸、受支持应用缩放和整会话工作窗口归位。

### Modified Capabilities
无上游已有OpenSpec capability；旧2.1定制Worktree保留作为迁移来源。

## Impact

PhoneDesk/WindowControl与系统窗口接口、配置尺寸/ScreenFit、字号规则、必要UI/文档及测试。新增会话恢复记录；保留旧单窗记录的受控归位，不覆盖未知旧记录。当前已安装App不自动升级。电脑操作工具禁止访问当前com.openai.codex；不会换CLI/UI脚本绕过，自动运行验证只用隔离替身/测试窗口，目标App实际字号验收由用户手工反馈。
