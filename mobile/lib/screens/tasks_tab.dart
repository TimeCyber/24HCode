import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../widgets/remote_task_card.dart';

class TasksTab extends StatelessWidget {
  const TasksTab({super.key});
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.tasks.isEmpty) return const Center(child: Text('暂无任务事件'));
    return RefreshIndicator(
      onRefresh: state.refreshAll,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: state.tasks.length,
        itemBuilder: (context, index) => RemoteTaskCard(
          key: ValueKey(state.tasks[index].id),
          task: state.tasks[index],
        ),
      ),
    );
  }
}
