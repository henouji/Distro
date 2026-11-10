import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/local_network.dart';
import '../../settings/settings_controller.dart';
import '../camera.dart';
import '../camera_controller.dart';
import 'camera_editor.dart';
import 'camera_player.dart';
import 'camera_view.dart';

class CameraTile extends ConsumerStatefulWidget {
  const CameraTile({super.key, required this.camera});
  final CameraConfig camera;
  @override
  ConsumerState<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends ConsumerState<CameraTile> {
  bool _away = false;

  Future<void> _open({bool edit = false}) async {
    setState(() {
      _away = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => edit
            ? CameraEditor(camera: widget.camera)
            : CameraView(camera: widget.camera),
      ),
    );
    if (mounted) {
      setState(() {
        _away = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(settingsProvider).livePreviews;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _open,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (preview && !_away)
                    CameraPlayer(
                      key: ValueKey(widget.camera),
                      camera: widget.camera,
                      preview: true,
                    )
                  else
                    const ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Icon(
                          Icons.videocam_outlined,
                          color: Colors.white70,
                          size: 36,
                        ),
                      ),
                    ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: IconButton.filledTonal(
                      tooltip: 'Open ${widget.camera.name}',
                      onPressed: _open,
                      icon: const Icon(Icons.fullscreen),
                    ),
                  ),
                ],
              ),
            ),
          ),
          InkWell(
            onTap: _open,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.camera.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Camera options',
                    onSelected: (action) async {
                      if (action == 'edit') {
                        await _open(edit: true);
                      } else if (await confirmDelete(
                        context,
                        widget.camera.name,
                      )) {
                        try {
                          await ref
                              .read(camerasProvider.notifier)
                              .delete(widget.camera.id);
                        } catch (error) {
                          if (context.mounted) {
                            showMessage(context, friendlyError(error));
                          }
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CameraGrid extends StatelessWidget {
  const CameraGrid({super.key, required this.cameras});
  final List<CameraConfig> cameras;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth < 600
          ? 1
          : constraints.maxWidth < 1000
          ? 2
          : 3;
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent:
              (constraints.maxWidth - (columns - 1) * 12) / columns * 9 / 16 +
              52,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: cameras.length,
        itemBuilder: (context, index) => CameraTile(
          key: ValueKey(cameras[index].id),
          camera: cameras[index],
        ),
      );
    },
  );
}
