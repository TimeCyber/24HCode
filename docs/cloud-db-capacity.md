# 云端 CodeAssist 表已满排查

## 当前确认的范围

本仓库 `packages/server` 使用 SQLite，表名为 `tasks`、`prompts`。
`ca_task`、`ca_prompt` 来自另一套云端 Java/MySQL 实现，本机源码位于
`D:/mcp-x/ruoyi-ai-main/ruoyi-admin/src/main/java/org/ruoyi/codeassist/`。
优化本地 Node Store 不会修复线上 MySQL 表的容量错误。

尚未取得线上完整 SQL 异常、MySQL 错误日志或磁盘/配额数据，因此不能确认线上故障的最终原因。
如果实际错误为 MySQL 1114 (`The table ... is full`)，先检查磁盘、数据库配额、
表引擎和表空间扩展限制。不要把修改 TEXT 字段或增加查询 LIMIT 当作恢复写入容量的方法。

## 源码发现

云端 `service/CodeAssistRelayService.java`：

- `deleteChatSession` 只删 `ca_chat_session`，没有处理同会话的 prompt/delivery；
  删除会话不会清理这些历史数据。附件记录及磁盘文件也需要纳入生命周期设计。
- `createTask` 每次插入新记录，没有保留期限或归档策略。bridge 每次手机指令执行后
  还会创建一条任务摘要，任务 detail 与 prompt/delivery result 存在重复保存。
- `listTasks` 无分页；`listPrompts` 按项目或会话查询时也无分页，只有未指定筛选时 LIMIT 100。
  历史增长后会放大数据库读取、网络传输和客户端内存开销。
- `pullPrompts` 一次取出全部 queued 后逐条置为 delivered，没有条件更新抢占；
  多消费者可能重复领取，进程在领取后退出时也缺少 delivered 租约回收。
  这能解释部分排队/领取异常，但不能单独证明容量错误的原因。
- 初始化 DDL 使用 InnoDB；必须用线上 SHOW CREATE TABLE 核对实际表引擎和结构。

## 恢复与优化顺序

1. 在云端应用数据库运行 `scripts/diagnose-cloud-db.sql` 的只读查询，保留完整异常和 MySQL 日志。
   在数据库宿主机检查 datadir、tmpdir 所在磁盘空间、inode、容器卷或托管数据库配额。
2. 先恢复数据库可写容量。空间不足时不要直接运行 OPTIMIZE TABLE 或全表重建，
   它们可能需要额外空间。单纯 DELETE 不保证把 InnoDB 文件空间返还操作系统。
3. 为任务摘要制定可配置的归档期限；会话历史和附件采取用户可控的保留策略。
   分批清理已完成记录，保留运行中任务、待审批任务和未消费决策，先备份及核对关联数据。
4. 给列表增加游标分页与对应索引；给创建请求增加幂等键，避免断线重试产生重复记录。
5. 将指令领取改为小批量条件抢占（或事务锁），增加 delivered/running 租约及恢复，
   完成回传保持幂等，避免单纯重启 bridge 导致重复执行。

本文和诊断 SQL 未修改或清理线上数据，未部署云端服务。
