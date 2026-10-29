import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../app_state.dart';
import '../ide_labels.dart';
import '../models.dart';
import '../widgets/linkified_text.dart';

class PromptsTab extends StatefulWidget {
  const PromptsTab({super.key});

  @override
  State<PromptsTab> createState() => _PromptsTabState();
}

class _PromptsTabState extends State<PromptsTab> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  bool _sending = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    final next = _controller.text.trim().isNotEmpty;
    if (next != _hasText) setState(() => _hasText = next);
  }

  /// ListView reverse:true 时，offset 0 = 最新消息（视觉底部）
  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (animate) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onInputChanged);
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending) return;
    _focusNode.unfocus();
    setState(() => _sending = true);
    try {
      await context.read<AppState>().sendPrompt(content);
      _controller.clear();
      _scrollToLatest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openProjectPicker() async {
    final state = context.read<AppState>();
    await state.refreshAll();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Consumer<AppState>(
          builder: (context, s, _) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.65,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '连接 / 选择 AI 项目',
                              style: Theme.of(ctx).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: '刷新项目列表',
                            onPressed: () => s.refreshAll(),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '在 PC 上打开工作区并启用 MCP（Cursor / Codex / Trae / WorkBuddy 等）后，项目会出现在这里。对话按项目隔离。',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: s.projects.isEmpty
                          ? const Center(
                              child: Text('暂无项目，请先在 PC 打开 AI 工具并启用 MCP'),
                            )
                          : ListView.separated(
                              itemCount: s.projects.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final p = s.projects[i];
                                final selected = s.activeProjectId == p.id;
                                return ListTile(
                                  selected: selected,
                                  leading: Icon(
                                    Icons.circle,
                                    size: 12,
                                    color:
                                        p.online ? Colors.green : Colors.grey,
                                  ),
                                  title: Text(p.displayName),
                                  subtitle: Text(
                                    '${p.online ? '在线' : '离线'} · ${p.ideLabel} · ${p.workspacePath}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: selected
                                      ? const Icon(Icons.check)
                                      : null,
                                  onTap: () async {
                                    await s.selectProject(p.id);
                                    if (ctx.mounted) Navigator.pop(ctx);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addSession() async {
    try {
      await context.read<AppState>().addChatSession();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已新建会话（对应 PC 侧新 Session）')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  Future<void> _confirmDeleteSession(ChatSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${session.title}」？该会话内的消息也会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().deleteChatSession(session.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除「${session.title}」')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：$e')),
        );
      }
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    final project = context.read<AppState>().activeProject;
    if (project == null || _sending) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    setState(() => _sending = true);
    try {
      final bytes = await picked.readAsBytes();
      final name = picked.name.trim().isNotEmpty
          ? picked.name
          : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final mime = picked.mimeType ??
          (name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');
      final caption = _controller.text.trim();
      await context.read<AppState>().sendImageToAgent(
            fileName: name,
            bytes: bytes,
            mimeType: mime,
            message: caption.isEmpty ? null : caption,
          );
      _controller.clear();
      _scrollToLatest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送图片失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showImageSourceSheet() async {
    if (context.read<AppState>().activeProject == null) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_pickAndSendImage(ImageSource.gallery));
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('拍照'),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_pickAndSendImage(ImageSource.camera));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusHint(PromptJob m) {
    if (m.attachment != null && !m.attachment!.isToAgent) return '文件';
    final hasResult = m.result != null && m.result!.trim().isNotEmpty;
    if (hasResult && (m.status == 'done' || m.status == 'failed')) {
      return m.status == 'failed' ? '失败' : '完成';
    }
    if (hasResult &&
        (m.status == 'running' ||
            m.status == 'delivered' ||
            m.status == 'queued')) {
      // 结果已回传但状态偶发未刷新
      return '完成';
    }
    switch (m.status) {
      case 'queued':
        return '排队等待…';
      case 'delivered':
        return '已拉取…';
      case 'running':
        return '执行中…';
      case 'done':
        return '完成';
      case 'failed':
        return '失败';
      default:
        return m.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.activeProject;
    final ideLabel = project?.ideLabel ?? kGenericIdeLabel;
    final sessions = state.chatSessions;
    final messages = state.chatMessages;
    final chat = state.activeChatSession;

    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final s in sessions)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onLongPress: () => _confirmDeleteSession(s),
                              child: ChoiceChip(
                                label: Text(s.title),
                                selected: state.activeChatSessionId == s.id,
                                onSelected: (_) =>
                                    state.selectChatSession(s.id),
                              ),
                            ),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.add, size: 18),
                          label: const Text('新会话'),
                          onPressed: project == null ? null : _addSession,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '选择 / 连接项目',
                  onPressed: _openProjectPicker,
                  icon: Icon(
                    project == null
                        ? Icons.link_off
                        : Icons.folder_special_outlined,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: project == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('请先选择要对话的 $ideLabel 项目'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _openProjectPicker,
                        icon: const Icon(Icons.link),
                        label: const Text('连接项目'),
                      ),
                    ],
                  ),
                )
              : messages.isEmpty
                  ? Center(
                      child: Text(
                        chat?.hasContext == true
                            ? '本会话已有 $ideLabel 上下文，继续发指令即可'
                            : '在本会话发送指令，同一 Session 会保持 $ideLabel 上下文',
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      // reverse：打开会话时默认停在最新消息（底部）
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final m = messages[messages.length - 1 - index];
                        return _MessageBubble(
                          message: m,
                          statusHint: _statusHint(m),
                        );
                      },
                    ),
        ),
        _ComposerBar(
          controller: _controller,
          focusNode: _focusNode,
          enabled: project != null && !_sending,
          canSend: project != null && !_sending && _hasText,
          sending: _sending,
          hasProject: project != null,
          ideLabel: ideLabel,
          onSend: _send,
          onPickImage: _showImageSourceSheet,
        ),
      ],
    );
  }
}

class _ComposerBar extends StatefulWidget {
  const _ComposerBar({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.canSend,
    required this.sending,
    required this.hasProject,
    required this.ideLabel,
    required this.onSend,
    required this.onPickImage,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool canSend;
  final bool sending;
  final bool hasProject;
  final String ideLabel;
  final VoidCallback onSend;
  final VoidCallback onPickImage;

  @override
  State<_ComposerBar> createState() => _ComposerBarState();
}

class _ComposerBarState extends State<_ComposerBar> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  bool _voiceBusy = false;
  String _liveSpeech = '';
  String _prefixBeforeSpeech = '';
  /// 安卓 10 上 locales() / 复杂 locale 易闪退，固定简体
  static const _localeId = 'zh_CN';

  String get _hint {
    if (_listening) {
      return _liveSpeech.isEmpty ? '正在听…再点麦克风结束' : _liveSpeech;
    }
    if (!widget.hasProject) return '请先右上角连接 AI 项目';
    if (widget.sending) return '正在发送…';
    return '输入指令给 ${widget.ideLabel}…';
  }

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    try {
      setState(fn);
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    } catch (_) {}
  }

  Future<bool> _ensureSpeech() async {
    var mic = await Permission.microphone.status;
    if (!mic.isGranted) {
      mic = await Permission.microphone.request();
    }
    if (!mic.isGranted) {
      _snack('需要麦克风权限才能语音输入');
      try {
        await openAppSettings();
      } catch (_) {}
      return false;
    }
    if (_speechReady && _speech.isAvailable) return true;
    try {
      // 安卓 10(SDK29)：stop 默认会 destroy 识别器易闪退；关蓝牙；OEM 需 intentLookup
      _speechReady = await _speech.initialize(
        onError: (e) {
          _voiceBusy = false;
          _safeSetState(() => _listening = false);
          _snack('语音识别错误：${e.errorMsg}');
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _voiceBusy = false;
            _safeSetState(() => _listening = false);
          }
        },
        options: [
          stt.SpeechToText.androidNoBluetooth,
          stt.SpeechToText.androidIntentLookup,
          stt.SpeechToText.androidAlwaysUseStop,
        ],
      );
    } catch (e) {
      _speechReady = false;
      _snack('语音初始化失败：$e');
      return false;
    }
    if (!_speechReady && mounted) {
      _snack('本机不支持语音识别，请安装/启用系统语音服务后重试');
    }
    return _speechReady;
  }

  Future<void> _startVoice() async {
    if (!widget.enabled || _listening || _voiceBusy) return;
    _voiceBusy = true;
    try {
      final ok = await _ensureSpeech();
      if (!ok || !mounted) {
        _voiceBusy = false;
        return;
      }

      _prefixBeforeSpeech = widget.controller.text;
      if (_prefixBeforeSpeech.isNotEmpty &&
          !_prefixBeforeSpeech.endsWith(' ') &&
          !_prefixBeforeSpeech.endsWith('\n')) {
        _prefixBeforeSpeech = '$_prefixBeforeSpeech ';
      }
      _safeSetState(() {
        _listening = true;
        _liveSpeech = '';
      });
      try {
        await HapticFeedback.lightImpact();
      } catch (_) {}
      _snack('正在录音，再点麦克风结束');

      // confirmation 比 dictation 稳；cancelOnError=false 避免 native 竞态闪退
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          final words = result.recognizedWords.trim();
          _liveSpeech = words;
          final next = '$_prefixBeforeSpeech$words';
          try {
            widget.controller.value = TextEditingValue(
              text: next,
              selection: TextSelection.collapsed(offset: next.length),
            );
          } catch (_) {}
          _safeSetState(() {});
          if (result.finalResult) {
            _voiceBusy = false;
            _safeSetState(() => _listening = false);
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 3),
          partialResults: true,
          cancelOnError: false,
          listenMode: stt.ListenMode.confirmation,
          localeId: _localeId,
        ),
      );
    } catch (e) {
      _safeSetState(() => _listening = false);
      _snack('无法开始录音：$e');
    } finally {
      // listen 已启动后由 stop/status 清 busy；若未进入 listening 则在此清
      if (!_listening) _voiceBusy = false;
    }
  }

  Future<void> _stopVoice() async {
    if (_voiceBusy && !_speech.isListening) {
      // 识别器还在启动中，稍后再停，避免安卓 10 destroy/stop 竞态闪退
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (_) {
      try {
        await _speech.cancel();
      } catch (_) {}
    }
    _voiceBusy = false;
    _safeSetState(() => _listening = false);
  }

  Future<void> _toggleMic() async {
    if (!widget.enabled || _voiceBusy && !_listening) return;
    if (_listening || _speech.isListening) {
      await _stopVoice();
    } else {
      await _startVoice();
    }
  }

  @override
  void dispose() {
    try {
      if (_speech.isListening) {
        unawaited(_speech.cancel());
      }
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled;
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton.filledTonal(
                tooltip: '发送图片到 PC',
                onPressed: enabled ? widget.onPickImage : null,
                style: IconButton.styleFrom(
                  fixedSize: const Size(44, 44),
                  minimumSize: const Size(44, 44),
                  maximumSize: const Size(44, 44),
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
              const SizedBox(width: 8),
              Expanded(
                // 安卓 10：不要在 TextField 上长按触发语音（选区冲突 + stop 竞态易闪退）
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 1,
                  maxLines: 6,
                  enabled: enabled,
                  readOnly: _listening,
                  enableInteractiveSelection: !_listening,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  style: Theme.of(context).textTheme.bodyLarge,
                  decoration: InputDecoration(
                    hintText: _hint,
                    filled: true,
                    fillColor: _listening
                        ? scheme.primaryContainer.withValues(alpha: 0.55)
                        : enabled
                            ? scheme.surfaceContainerHighest.withValues(
                                alpha: 0.72,
                              )
                            : scheme.surfaceContainerHighest.withValues(
                                alpha: 0.35,
                              ),
                    prefixIcon: _listening
                        ? Icon(Icons.mic, color: scheme.primary)
                        : null,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.45),
                        width: 1.5,
                      ),
                    ),
                    disabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              AnimatedOpacity(
                opacity: widget.canSend || widget.sending || _listening ? 1 : 0.45,
                duration: const Duration(milliseconds: 160),
                child: IconButton.filled(
                  tooltip: _listening ? '结束语音' : '发送',
                  onPressed: _listening
                      ? () => unawaited(_stopVoice())
                      : (widget.canSend ? widget.onSend : null),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    backgroundColor: _listening ? scheme.error : null,
                  ),
                  icon: widget.sending
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : Icon(
                          _listening ? Icons.stop_rounded : Icons.send_rounded,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.statusHint,
  });

  final PromptJob message;
  final String statusHint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasResult =
        message.result != null && message.result!.trim().isNotEmpty;
    final attachment = message.attachment;
    final fromPc = attachment != null && !attachment.isToAgent;
    final toAgent = attachment?.isToAgent == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment:
                fromPc ? Alignment.centerLeft : Alignment.centerRight,
            child: GestureDetector(
              onLongPress: fromPc
                  ? null
                  : () async {
                      final text = message.content.trim();
                      if (text.isEmpty) return;
                      await Clipboard.setData(ClipboardData(text: text));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制用户消息'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.82,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: fromPc
                      ? scheme.secondaryContainer
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(14),
                    topRight: const Radius.circular(14),
                    bottomLeft: Radius.circular(fromPc ? 4 : 14),
                    bottomRight: Radius.circular(fromPc ? 14 : 4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(message.content),
                    const SizedBox(height: 4),
                    Text(
                      statusHint,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    if (fromPc) ...[
                      const SizedBox(height: 8),
                      _FileDownloadButton(attachment: attachment!),
                    ],
                    if (toAgent && attachment != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            attachment.isImage
                                ? Icons.image
                                : Icons.attach_file,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '已发送到 PC：${attachment.fileName}',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (hasResult && !fromPc) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.88,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                  ),
                ),
                child: LinkifiedText(message.result!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileDownloadButton extends StatefulWidget {
  const _FileDownloadButton({required this.attachment});

  final FileAttachment attachment;

  @override
  State<_FileDownloadButton> createState() => _FileDownloadButtonState();
}

class _FileDownloadButtonState extends State<_FileDownloadButton> {
  bool _busy = false;
  String? _savedPath;

  String _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.apk')) {
      return 'application/vnd.android.package-archive';
    }
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt') || lower.endsWith('.log') || lower.endsWith('.md')) {
      return 'text/plain';
    }
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.json')) return 'application/json';
    return widget.attachment.mimeType?.trim().isNotEmpty == true
        ? widget.attachment.mimeType!.trim()
        : '*/*';
  }

  Future<void> _ensureCanInstallApk() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.requestInstallPackages.status;
    if (status.isGranted) return;
    final req = await Permission.requestInstallPackages.request();
    if (!req.isGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请允许「安装未知应用」后再打开 APK')),
      );
      await openAppSettings();
    }
  }

  Future<void> _openSaved() async {
    final path = _savedPath;
    if (path == null || path.isEmpty) return;
    if (!await File(path).exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件不存在，请重新下载')),
      );
      return;
    }

    final mime = _mimeForPath(path);
    if (path.toLowerCase().endsWith('.apk')) {
      await _ensureCanInstallApk();
    }

    final result = await OpenFilex.open(path, type: mime);
    if (!mounted) return;
    if (result.type == ResultType.done) return;

    // 系统无法直接打开时，走分享面板（可选文件管理器/安装器）
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: mime)],
          text: widget.attachment.fileName,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开：${result.message}；$e')),
      );
    }
  }

  Future<Directory> _resolveSaveDir() async {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final d = Directory('${ext.path}/CodeAssistDownloads');
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/CodeAssistDownloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _shareSaved() async {
    final path = _savedPath;
    if (path == null || path.isEmpty) return;
    final mime = _mimeForPath(path);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: mime)],
        text: widget.attachment.fileName,
      ),
    );
  }

  Future<void> _copyPath() async {
    final path = _savedPath;
    if (path == null || path.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('路径已复制')),
    );
  }

  Future<void> _download() async {
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final bytes =
          await state.downloadAttachmentBytes(widget.attachment.id);
      final saveDir = await _resolveSaveDir();
      final safeName = widget.attachment.fileName
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${saveDir.path}/$safeName');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() => _savedPath = file.path);
      // 短提示自动消失；完整路径与「打开」已在下方按钮区展示，避免挡住输入框
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('下载完成'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(left: 12, right: 12, bottom: 88),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('下载失败：$e'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(left: 12, right: 12, bottom: 88),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.attachment.size;
    final sizeLabel = size >= 1024 * 1024
        ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(size / 1024).ceil()} KB';
    final scheme = Theme.of(context).colorScheme;
    final isApk = widget.attachment.fileName.toLowerCase().endsWith('.apk');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _download,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(
            _savedPath == null
                ? '下载 ${widget.attachment.fileName}（$sizeLabel）'
                : '重新下载 ${widget.attachment.fileName}',
          ),
        ),
        if (_savedPath != null) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _openSaved,
            icon: Icon(isApk ? Icons.android : Icons.open_in_new),
            label: Text(isApk ? '打开 / 安装 APK' : '打开已下载文件'),
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: _shareSaved,
            icon: const Icon(Icons.share_outlined),
            label: const Text('分享到其他应用打开'),
          ),
          const SizedBox(height: 6),
          Material(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: _openSaved,
              onLongPress: _copyPath,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.link, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _savedPath!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                              decoration: TextDecoration.underline,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Text(
            '点路径可打开；长按复制。APK 需允许「安装未知应用」',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ],
    );
  }
}
