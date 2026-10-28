# 鸿蒙（HarmonyOS / OpenHarmony）构建说明

本客户端业务代码在 `mobile/lib`，Android / iOS 已由 Flutter 标准工程覆盖。鸿蒙端复用同一套 Dart 代码。

## 推荐路径

1. 安装支持 OpenHarmony 的 Flutter SDK（Flutter-OHOS / 社区或厂商发行版）。
2. 在 `mobile` 目录生成 ohos 平台工程（具体命令以你安装的 Flutter-OHOS 文档为准），例如：

```bash
cd mobile
flutter create --platforms=ohos .
```

3. 使用同一 `lib/` 源码构建：

```bash
flutter pub get
flutter build hap
# 或厂商文档中的安装/运行命令
```

4. 手机端 Server URL 填写电脑局域网 IP，例如 `http://192.168.1.10:8787`，Token 与中继服务 `ACCESS_TOKEN` 一致。

## 注意

- 需允许应用访问局域网 HTTP（明文）；若鸿蒙网络策略默认禁止 cleartext，请在 ohos 工程网络配置中放行开发环境。
- MVP 不单独维护原生三套 UI；鸿蒙差异仅体现在平台工程与打包链路。
