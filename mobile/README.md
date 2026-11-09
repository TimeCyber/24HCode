# codeassist_mobile

## 1.3.13（221）

- 已提醒任务的记录按服务器和账号持久化；启动/重连重放的历史完成事件不再重复弹通知。
- 项目首次按名称排列并保存位置；刷新、心跳、在线变化、项目改名和路径别名合并不会重新排序，新项目追加到末尾。
- 使用 `flutter test test/client_update_policy_test.dart` 验证项目顺序与历史通知过滤。

客户端支持在「定时任务」页面创建重复 prompt。任务保存在本机，首次执行从设定间隔后开始；客户端处于前台并已连接时，每 15 秒检查到期任务并向指定项目发送固定 prompt。应用进入后台时暂停调度，回到前台后处理已到期的任务。

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
