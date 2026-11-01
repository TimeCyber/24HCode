# CodeAssist 鸿蒙版（Flutter-OH）

本仓库鸿蒙客户端在 `mobile_ohos/`，基于社区 **Flutter-OH**（非官方 Flutter）。

## 环境

1. 已安装 **DevEco Studio**（本机：`C:\Program Files\Huawei\DevEco Studio`，SDK API 24 / HarmonyOS 6.1.1）
2. Flutter-OH：`C:\flutter_ohos`（`oh-3.35.7-release`）
3. PATH 需包含 DevEco 的 `ohpm`、`hvigor`：

```bat
set PATH=C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;C:\flutter_ohos\bin;%PATH%
set FLUTTER_ROOT=C:\flutter_ohos
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
flutter config --enable-ohos
flutter config --ohos-sdk="%DEVECO_SDK_HOME%"
```

## 编译 HAP

```bat
cd /d D:\androidproject\CodeAssit
scripts\build-ohos.bat
```

脚本会：`flutter pub get` → 尝试 `flutter build hap` → 打上 AutoFill API24 兼容补丁 → `hvigorw assembleHap` → 复制产物。

产物：

- 构建目录：`mobile_ohos/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`
- 发布副本：`releases/harmony/codeassist-ohos-arm64-unsigned.hap`

当前为**未签名**包。在 DevEco 配置签名后可得到 signed hap，再用：

```bat
hdc install -r <hap路径>
```

## 与 Android 版差异（当前）

| 能力 | Android (`mobile/`) | 鸿蒙 (`mobile_ohos/`) |
|------|---------------------|------------------------|
| 云端 / 内网连接 | ✅ | ✅ |
| 会话 / 发指令 / 收结果 | ✅ | ✅ |
| 设备配对 | ✅ | ✅ |
| 前台保活通知 | ✅ | ⏳ 占位 |
| 语音输入 | ✅ | ⏳ 暂不支持 |
| 图片附件 | ✅ | ⏳ 占位（选图返回空） |
| 内嵌 WebView | ✅ | ⏳ 外链系统浏览器 |

Android 专属插件用 `third_party_stubs/` 本地桩，保证 HAP 可编。

## 注意

- 日常 Android 打包用官方 Flutter：`D:\flutter`
- 鸿蒙打包必须用 `C:\flutter_ohos`
- `build-profile.json5` 的 SDK 版本需写成 `'6.1.1(24)'` 这类字符串（与本机 DevEco SDK 一致）
- Flutter-OH 嵌入层 AutoFill 依赖 API 26 类型；本机 SDK 为 24，构建脚本会用 `mobile_ohos/ohos_patches/OhosAutoFillHelper.ets` 覆盖
