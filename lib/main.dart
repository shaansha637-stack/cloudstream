import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:video_player/video_player.dart';

const videoExts = ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts', 'm2ts', 'wmv', 'flv'];
const iosExts = ['mp4', 'm4v', 'mov'];

String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

String fmtSize(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String? initError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await LibtorrentFlutter.init();
  } catch (e) {
    initError = e.toString();
  }
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CloudStream',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const StreamPage(),
    );
  }
}

class StreamPage extends StatefulWidget {
  const StreamPage({super.key});

  @override
  State<StreamPage> createState() => _StreamPageState();
}

class _StreamPageState extends State<StreamPage> {
  final _ctrl = TextEditingController();
  String? _status;
  bool _busy = false;
  List<FileInfo> _choices = [];
  int? _id;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _cleanup() {
    if (_id != null) {
      try {
        LibtorrentFlutter.instance.disposeTorrent(_id!);
      } catch (_) {}
      _id = null;
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    setState(() => _ctrl.text = data?.text ?? '');
  }

  Future<void> _start() async {
    final magnet = _ctrl.text.trim();
    if (!magnet.startsWith('magnet:')) {
      setState(() => _status = 'Please paste a valid magnet link.');
      return;
    }
    if (initError != null) {
      setState(() => _status = 'Torrent engine failed to start: $initError');
      return;
    }
    _cleanup();
    setState(() {
      _busy = true;
      _choices = [];
      _status = 'Adding magnet…';
    });
    final engine = LibtorrentFlutter.instance;
    try {
      final id = engine.addMagnet(magnet);
      _id = id;

      int waited = 0;
      while (true) {
        final t = engine.torrents[id];
        if (t != null && t.hasMetadata) break;
        if (!mounted) return;
        if (waited > 120) {
          throw 'Timed out waiting for metadata. The torrent may have no seeders.';
        }
        setState(() => _status = 'Fetching metadata… peers: ${t?.numPeers ?? 0}');
        await Future.delayed(const Duration(seconds: 1));
        waited++;
      }

      final files = engine
          .getFiles(id)
          .where((f) => videoExts.contains(extOf(f.name)))
          .toList()
        ..sort((a, b) => b.size.compareTo(a.size));

      if (files.isEmpty) throw 'No video file found in this torrent.';

      if (files.length == 1 || files.first.size >= files[1].size * 5) {
        await _play(id, files.first);
      } else {
        setState(() {
          _choices = files;
          _status = 'Pick a file to play';
        });
      }
    } catch (e) {
      _cleanup();
      if (mounted) setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play(int id, FileInfo f) async {
    final engine = LibtorrentFlutter.instance;
    setState(() {
      _busy = true;
      _choices = [];
      _status = 'Buffering…';
    });
    try {
      final StreamInfo s = await engine.startStream(
        id,
        fileIndex: f.index,
        maxCacheBytes: 500 * 1024 * 1024,
      );
      try {
        await engine.streamUpdates
            .firstWhere((m) => m.values.any((x) => x.url == s.url && x.isReady))
            .timeout(const Duration(seconds: 60));
      } catch (_) {}
      if (!mounted) return;
      setState(() => _status = null);
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlayerPage(url: s.url, title: f.name)),
      );
      _cleanup();
      if (mounted) {
        setState(() => _status = 'Stopped. Torrent data was removed from your phone.');
      }
    } catch (e) {
      _cleanup();
      if (mounted) setState(() => _status = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(FileInfo f) async {
    final id = _id;
    if (id == null) return;
    await _play(id, f);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CloudStream')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _ctrl,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Magnet link',
              hintText: 'magnet:?xt=urn:btih:…',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(onPressed: _busy ? null : _paste, child: const Text('Paste')),
              const Spacer(),
              FilledButton.icon(
                onPressed: _busy ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(_busy ? 'Working…' : 'Stream'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_status != null)
            Row(
              children: [
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 10),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Expanded(child: Text(_status!)),
              ],
            ),
          if (_choices.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final f in _choices)
              Card(
                child: ListTile(
                  title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    fmtSize(f.size) + (iosExts.contains(extOf(f.name)) ? '' : ' · may not play on iPhone'),
                  ),
                  onTap: () => _pick(f),
                ),
              ),
          ],
          const SizedBox(height: 24),
          const Text(
            'Streams directly on your phone. Data is deleted when you close the player. '
            'Use only for content you have the right to watch.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class PlayerPage extends StatefulWidget {
  final String url;
  final String title;
  const PlayerPage({super.key, required this.url, required this.title});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final VideoPlayerController _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _c.addListener(() {
      if (mounted) setState(() {});
    });
    _c.initialize().then((_) {
      if (mounted) {
        setState(() {});
        _c.play();
      }
    }).catchError((e) {
      if (mounted) {
        setState(() => _error =
            "Can't play this file on iPhone (${extOf(widget.title).toUpperCase()}). "
            'MP4 / MOV / M4V work best. Try another release.');
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _skip(int seconds) {
    var p = _c.value.position + Duration(seconds: seconds);
    if (p < Duration.zero) p = Duration.zero;
    _c.seekTo(p);
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
                Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
            Expanded(
              child: Center(
                child: _error != null
                    ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center))
                    : v.isInitialized
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(_c)),
                              if (v.isBuffering) const CircularProgressIndicator(),
                            ],
                          )
                        : const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text('Starting stream…'),
                            ],
                          ),
              ),
            ),
            if (v.isInitialized) ...[
              VideoProgressIndicator(
                _c,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(iconSize: 32, icon: const Icon(Icons.replay_10), onPressed: () => _skip(-10)),
                  IconButton(
                    iconSize: 48,
                    icon: Icon(v.isPlaying ? Icons.pause_circle : Icons.play_circle),
                    onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
                  ),
                  IconButton(iconSize: 32, icon: const Icon(Icons.forward_10), onPressed: () => _skip(10)),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}
