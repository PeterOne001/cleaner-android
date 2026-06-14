import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:image/image.dart' as img;

void main() => runApp(const CleanerApp());

class CleanerApp extends StatelessWidget {
  const CleanerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '手機清理器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3EA6FF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0E121B),
      ),
      home: const HomePage(),
    );
  }
}

/// one photo with its perceptual hash
class Shot {
  final AssetEntity asset;
  final int hash; // 64-bit aHash
  Uint8List? thumb;
  Shot(this.asset, this.hash);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = '準備掃描相簿…';
  bool _scanning = false;
  double _progress = 0;
  List<List<Shot>> _similarGroups = [];
  List<AssetEntity> _bigVideos = [];
  final Set<String> _selected = {}; // asset ids to delete
  int _tab = 0;

  Future<void> _scan() async {
    setState(() { _scanning = true; _status = '請求相簿權限…'; _similarGroups = []; _bigVideos = []; _selected.clear(); });
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() { _scanning = false; _status = '沒有相簿權限，無法掃描。請到設定開啟相簿存取。'; });
      return;
    }
    // ---- images: perceptual hash + group similar ----
    setState(() => _status = '讀取照片…');
    final imgAlbums = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    final List<Shot> shots = [];
    if (imgAlbums.isNotEmpty) {
      final all = imgAlbums.first;
      final total = await all.assetCountAsync;
      const page = 200;
      int done = 0;
      for (int start = 0; start < total; start += page) {
        final batch = await all.getAssetListRange(start: start, end: (start + page).clamp(0, total));
        for (final a in batch) {
          final h = await _ahash(a);
          if (h != null) shots.add(Shot(a, h));
          done++;
          if (done % 25 == 0) setState(() { _progress = total == 0 ? 0 : done / total; _status = '比對相似照片… $done/$total'; });
        }
      }
    }
    // greedy grouping by hamming distance
    setState(() => _status = '整理相似照片…');
    final used = List<bool>.filled(shots.length, false);
    final groups = <List<Shot>>[];
    for (int i = 0; i < shots.length; i++) {
      if (used[i]) continue;
      final g = <Shot>[shots[i]];
      used[i] = true;
      for (int j = i + 1; j < shots.length; j++) {
        if (used[j]) continue;
        if (_hamming(shots[i].hash, shots[j].hash) <= 5) { g.add(shots[j]); used[j] = true; }
      }
      if (g.length > 1) {
        g.sort((a, b) => b.asset.createDateTime.compareTo(a.asset.createDateTime)); // newest first
        groups.add(g);
      }
    }
    // ---- large videos ----
    setState(() => _status = '找大影片…');
    final vidAlbums = await PhotoManager.getAssetPathList(type: RequestType.video, onlyAll: true);
    final List<AssetEntity> bigVids = [];
    if (vidAlbums.isNotEmpty) {
      final all = vidAlbums.first;
      final total = await all.assetCountAsync;
      final vids = await all.getAssetListRange(start: 0, end: total);
      vids.sort((a, b) => b.videoDuration.compareTo(a.videoDuration));
      bigVids.addAll(vids.take(100)); // longest first
    }
    setState(() {
      _scanning = false;
      _similarGroups = groups;
      _bigVideos = bigVids;
      _status = '找到 ${groups.length} 組相似照片、${bigVids.length} 個影片';
    });
  }

  /// average-hash from a tiny grayscale thumbnail
  Future<int?> _ahash(AssetEntity a) async {
    try {
      final data = await a.thumbnailDataWithSize(const ThumbnailSize(32, 32));
      if (data == null) return null;
      final im = img.decodeImage(data);
      if (im == null) return null;
      final small = img.copyResize(im, width: 8, height: 8);
      int sum = 0;
      final g = List<int>.filled(64, 0);
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          final p = small.getPixel(x, y);
          final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
          g[y * 8 + x] = lum; sum += lum;
        }
      }
      final avg = sum ~/ 64;
      int bits = 0;
      for (int i = 0; i < 64; i++) { if (g[i] >= avg) bits |= (1 << i); }
      return bits;
    } catch (_) { return null; }
  }

  int _hamming(int a, int b) {
    int x = a ^ b, c = 0;
    while (x != 0) { c += x & 1; x >>= 1; }
    return c;
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移到垃圾桶？'),
        content: Text('要把勾選的 ${ids.length} 個項目刪除嗎？\n（Android 會放進「最近刪除」，30 天內可復原）'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return;
    final removed = await PhotoManager.editor.deleteWithIds(ids);
    final gone = removed.toSet();
    setState(() {
      _similarGroups = _similarGroups
          .map((g) => g.where((s) => !gone.contains(s.asset.id)).toList())
          .where((g) => g.length > 1).toList();
      _bigVideos = _bigVideos.where((v) => !gone.contains(v.id)).toList();
      _selected.removeAll(gone);
      _status = '已刪除 ${removed.length} 個項目';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🧹 手機清理器'),
        actions: [
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF5C6C)),
                onPressed: _deleteSelected,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text('刪 ${_selected.length}'),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(12), child: Text(_status, style: const TextStyle(color: Colors.white70))),
          if (_scanning) LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          if (!_scanning && _similarGroups.isEmpty && _bigVideos.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: FilledButton.icon(onPressed: _scan, icon: const Icon(Icons.search), label: const Text('開始掃描相簿')),
            ),
          if (_similarGroups.isNotEmpty || _bigVideos.isNotEmpty) ...[
            Row(children: [
              _tabBtn('相似照片 (${_similarGroups.length})', 0),
              _tabBtn('大影片 (${_bigVideos.length})', 1),
            ]),
            Expanded(child: _tab == 0 ? _buildSimilar() : _buildVideos()),
          ],
        ],
      ),
    );
  }

  Widget _tabBtn(String label, int i) => Expanded(
        child: TextButton(
          onPressed: () => setState(() => _tab = i),
          style: TextButton.styleFrom(
            backgroundColor: _tab == i ? const Color(0xFF222B3D) : Colors.transparent,
            foregroundColor: _tab == i ? Colors.white : Colors.white54,
          ),
          child: Text(label),
        ),
      );

  Widget _buildSimilar() {
    if (_similarGroups.isEmpty) return const Center(child: Text('沒有相似照片 🎉', style: TextStyle(color: Colors.white54)));
    return ListView.builder(
      itemCount: _similarGroups.length,
      itemBuilder: (c, gi) {
        final g = _similarGroups[gi];
        // default: keep first (newest), preselect rest
        for (int i = 1; i < g.length; i++) { _selected.add(g[i].asset.id); }
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: const Color(0xFF161D2B),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.all(4), child: Text('第 ${gi + 1} 組 · ${g.length} 張相似（綠框保留、其它勾選刪）', style: const TextStyle(color: Colors.white54, fontSize: 12))),
              Wrap(spacing: 8, runSpacing: 8, children: [for (int i = 0; i < g.length; i++) _photoTile(g[i].asset, i == 0)]),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildVideos() {
    if (_bigVideos.isEmpty) return const Center(child: Text('沒有影片', style: TextStyle(color: Colors.white54)));
    return ListView.builder(
      itemCount: _bigVideos.length,
      itemBuilder: (c, i) {
        final v = _bigVideos[i];
        final sel = _selected.contains(v.id);
        final mins = v.videoDuration.inMinutes;
        final secs = v.videoDuration.inSeconds % 60;
        return ListTile(
          leading: SizedBox(width: 56, height: 56, child: _thumb(v)),
          title: Text('影片 ${i + 1}', style: const TextStyle(color: Colors.white)),
          subtitle: Text('長度 ${mins}:${secs.toString().padLeft(2, '0')} · ${v.createDateTime.year}/${v.createDateTime.month}', style: const TextStyle(color: Colors.white54)),
          trailing: Checkbox(value: sel, onChanged: (x) => setState(() => x == true ? _selected.add(v.id) : _selected.remove(v.id))),
          onTap: () => setState(() => sel ? _selected.remove(v.id) : _selected.add(v.id)),
        );
      },
    );
  }

  Widget _photoTile(AssetEntity a, bool keep) {
    final sel = _selected.contains(a.id);
    return GestureDetector(
      onTap: () => setState(() => sel ? _selected.remove(a.id) : _selected.add(a.id)),
      child: Stack(children: [
        Container(
          width: 92, height: 92,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: keep ? const Color(0xFF3DDC91) : (sel ? const Color(0xFFFF5C6C) : Colors.transparent), width: 2),
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(7), child: _thumb(a)),
        ),
        if (keep) const Positioned(left: 2, top: 2, child: _Badge('保留', Color(0xFF3DDC91))),
        if (sel && !keep) const Positioned(left: 2, top: 2, child: _Badge('刪', Color(0xFFFF5C6C))),
      ]),
    );
  }

  Widget _thumb(AssetEntity a) => FutureBuilder<Uint8List?>(
        future: a.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
        builder: (c, snap) => snap.data == null
            ? Container(color: const Color(0xFF0C0F16))
            : Image.memory(snap.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
      );
}

class _Badge extends StatelessWidget {
  final String text; final Color color;
  const _Badge(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
        child: Text(text, style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
      );
}
