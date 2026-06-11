import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'models/playlist_video.dart';
import 'services/audio_player_service.dart';
import 'services/auth_service.dart';

import 'services/local_storage_service.dart';
import 'services/youtube_api_service.dart';
import 'utils/playlist_parser.dart';

class YoutubeRandomPlayerApp extends StatelessWidget {
  const YoutubeRandomPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Youtube Random Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const PlayerHomePage(),
    );
  }
}

class PlayerHomePage extends StatefulWidget {
  const PlayerHomePage({super.key});

  @override
  State<PlayerHomePage> createState() => _PlayerHomePageState();
}

class _PlayerHomePageState extends State<PlayerHomePage> with WidgetsBindingObserver {
  final TextEditingController _playlistInputController =
      TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final YoutubeApiService _youtubeApiService = YoutubeApiService();

  final AuthService _authService = AuthService();
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final LocalStorageService _localStorage = LocalStorageService();

  final List<PlaylistVideo> _allVideos = <PlaylistVideo>[];
  final List<PlaylistVideo> _playbackQueue = <PlaylistVideo>[];
  final List<PlaylistVideo> _visibleVideos = <PlaylistVideo>[];


  List<Map<String, dynamic>> _myYtPlaylists = [];

  int _currentIndex = -1;
  PlaylistVideo? _playingVideo;
  bool _isLoadingPlaylist = false;
  bool _isShuffleMode = false;
  bool _isSearchExpanded = false;
  String _playlistTitle = '';
  final List<PlaylistVideo> _globalSearchResults = <PlaylistVideo>[];
  bool _isGlobalSearch = false;
  bool _isGlobalSearching = false;

  bool _isPlaying = false;
  bool _isInit = false;
  bool _isChangingTrack = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  
  String? _lastSkippedVideoId;
  DateTime? _lastAutoSkipAt;
  Timer? _playbackWatchdogTimer;
  int _consecutiveSkipFailures = 0;
  int _playSessionId = 0;
  Timer? _autoSkipDelayTimer;

  void _startPlaybackWatchdog(PlaylistVideo video) {
    _playbackWatchdogTimer?.cancel();
    final sessionId = _playSessionId;
    _playbackWatchdogTimer = Timer(const Duration(seconds: 15), () {
      if (_playSessionId != sessionId) return; // 已換歌，忽略
      debugPrint('Playback watchdog fired for ${video.title} (videoId: ${video.videoId})');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('「${video.title}」載入超時，自動跳過...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      // Force-reset the lock so the skip can proceed
      _isChangingTrack = false;
      _triggerAutoSkip();
    });
  }

  void _cancelPlaybackWatchdog() {
    _playbackWatchdogTimer?.cancel();
    _playbackWatchdogTimer = null;
  }

  void _triggerAutoSkip({bool isError = true}) {
    _cancelPlaybackWatchdog();
    _autoSkipDelayTimer?.cancel();
    final now = DateTime.now();
    final currentId = _playingVideo?.videoId;

    // Only debounce duplicate error events for the SAME song
    if (currentId != null && currentId == _lastSkippedVideoId) {
      if (_lastAutoSkipAt != null &&
          now.difference(_lastAutoSkipAt!) < const Duration(seconds: 2)) {
        debugPrint('Debounced duplicate error skip for videoId: $currentId');
        return;
      }
    }

    if (isError) {
      _consecutiveSkipFailures++;
      debugPrint('Consecutive skip failures: $_consecutiveSkipFailures / ${_playbackQueue.length}');
      // 當失敗次數 >= 清單總長度，代表所有歌都試過了，才停止
      final queueLen = _playbackQueue.length;
      if (queueLen > 0 && _consecutiveSkipFailures >= queueLen) {
        _consecutiveSkipFailures = 0;
        _isChangingTrack = false;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('清單中所有影片皆無法播放，請確認網路或更換播放清單。'),
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }
    } else {
      // 正常播完，重置失敗計數
      _consecutiveSkipFailures = 0;
    }

    _lastSkippedVideoId = currentId;
    _lastAutoSkipAt = now;

    // Force-reset the lock
    _isChangingTrack = false;

    if (isError) {
      // 錯誤跳轉加入 1 秒延遲，避免緊密迴圈耗盡資源
      final sessionId = _playSessionId;
      _autoSkipDelayTimer = Timer(const Duration(seconds: 1), () {
        if (_playSessionId != sessionId) return; // 使用者已手動換歌
        _playNext();
      });
    } else {
      _playNext();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAuth();
    _loadLocalPlaylist();
    _audioPlayer.player.playingStream.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
    _audioPlayer.player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _audioPlayer.player.durationStream.listen((dur) {
      if (mounted) setState(() => _duration = dur ?? Duration.zero);
    });
    _audioPlayer.player.currentIndexStream.listen((index) {
      if (index == 1) {
        // Advanced natively to the pre-queued track!
        // The real next track is based on _playbackQueue!
        if (_playingVideo != null && _playbackQueue.isNotEmpty) {
           final oldQIndex = _playbackQueue.indexOf(_playingVideo!);
           final currentQIndex = (oldQIndex + 1) % _playbackQueue.length;
           final newPlaying = _playbackQueue[currentQIndex];
           
           _startPlaybackWatchdog(newPlaying);
           
           if (mounted) {
             setState(() {
               _playingVideo = newPlaying;
               _currentIndex = _visibleVideos.indexOf(newPlaying);
             });
           } else {
             _playingVideo = newPlaying;
             _currentIndex = _visibleVideos.indexOf(newPlaying);
           }
           
           _audioPlayer.shiftQueue().then((_) {
             final nextNextQIndex = (currentQIndex + 1) % _playbackQueue.length;
             _audioPlayer.enqueueNext(_playbackQueue[nextNextQIndex]);
           });
        }
      }
    });
    _audioPlayer.player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.ready ||
          state.processingState == ProcessingState.completed) {
        _cancelPlaybackWatchdog();
      }
      // 成功開始播放 → 重置連續失敗計數
      if (state.processingState == ProcessingState.ready) {
        _consecutiveSkipFailures = 0;
      }
      if (state.processingState == ProcessingState.completed &&
          !_isChangingTrack) {
        _triggerAutoSkip(isError: false);
      }
    });
    _audioPlayer.player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace stackTrace) {
      debugPrint('playbackEventStream error: $e');
      _cancelPlaybackWatchdog();
      // 如果播放器正在正常播放中，這是前一首的殘餘錯誤事件，忽略
      if (_audioPlayer.player.playing &&
          _audioPlayer.player.processingState == ProcessingState.ready) {
        debugPrint('Ignoring stale playback error - player is currently playing');
        return;
      }
      // Only auto-skip if this isn't already being handled by catchError in _playVideoObject
      if (!_isChangingTrack) {
         _triggerAutoSkip();
      }
    });
  }

  Future<void> _initAuth() async {
    await _authService.init();
    if (_authService.isLoggedIn) {
      _loadDrawerData();
    }
    setState(() {
      _isInit = true;
    });
  }

  Future<void> _loadLocalPlaylist() async {
    final data = await _localStorage.loadCurrentPlaylist();
    if (data != null) {
      final List<PlaylistVideo> videos = data['videos'] as List<PlaylistVideo>;
      final String title = data['title'] as String;
      if (videos.isNotEmpty) {
        setState(() {
          _allVideos.addAll(videos);
          _playbackQueue.addAll(videos);
          _visibleVideos.addAll(videos);
          _playlistTitle = title;
          _currentIndex = 0;
          _isShuffleMode = false;
        });
      }
    }
  }

  Future<void> _loadDrawerData() async {
    if (!_authService.isLoggedIn) return;

    final token = _authService.oauthToken;
    if (token != null && token.isNotEmpty) {
      final myYt = await _youtubeApiService.fetchMyPlaylists(token);
      setState(() => _myYtPlaylists = myYt);
    }
  }

  @override
  void dispose() {
    _cancelPlaybackWatchdog();
    _autoSkipDelayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _playlistInputController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _audioPlayer.pause();
      _audioPlayer.dispose();
    }
  }

  Future<void> _fetchPlaylistSource(String text) async {
    final playlistId = parsePlaylistId(text);
    if (playlistId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid Playlist ID'), duration: Duration(seconds: 2))
        );
      }
      return;
    }

    setState(() {
      _isLoadingPlaylist = true;
    });

    try {
      final videos = await _youtubeApiService.fetchPlaylistItems(playlistId);
      final title = await _youtubeApiService.fetchPlaylistTitle(playlistId);
      _setPlaylistData(videos, title ?? 'Playlist');
    } catch (e) {
      setState(() {
        _isLoadingPlaylist = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Load failed: $e'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }



  Future<void> _fetchLikedVideos() async {
    final token = _authService.oauthToken;
    if (token == null || token.isEmpty) return;

    setState(() {
      _isLoadingPlaylist = true;
    });

    try {
      final videos =
          await _youtubeApiService.fetchPlaylistItems('LL', oauthToken: token);
      _setPlaylistData(videos, 'Liked Videos');
    } catch (e) {
      setState(() {
        _isLoadingPlaylist = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Load failed: $e'),
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _setPlaylistData(List<PlaylistVideo> videos, String title) {
    if (videos.isEmpty) {
      setState(() {
        _isLoadingPlaylist = false;
        _playlistTitle = title;
        _allVideos.clear();
        _visibleVideos.clear();
        _currentIndex = -1;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No playable videos found'), duration: Duration(seconds: 2))
        );
      }
      return;
    }

    setState(() {
      _allVideos
        ..clear()
        ..addAll(videos);
      _playbackQueue
        ..clear()
        ..addAll(videos);
      _visibleVideos
        ..clear()
        ..addAll(videos);
      _playlistTitle = title;
      _currentIndex = 0;
      _isShuffleMode = false;
      _isLoadingPlaylist = false;
    });

    _localStorage.saveCurrentPlaylist(videos, title);

    _playAt(0);
  }

  void _playAt(int index) {
    if (index < 0 || index >= _visibleVideos.length) return;
    final video = _visibleVideos[index];
    _playVideoObject(video, isManual: true);
  }

  void _playVideoObject(PlaylistVideo video, {bool isManual = false}) {
    // 手動選曲時重置失敗計數，並取消進行中的自動跳轉
    if (isManual) {
      _consecutiveSkipFailures = 0;
      _autoSkipDelayTimer?.cancel();
    }
    // Allow manual plays to override the lock; only block duplicate auto-plays
    if (_isChangingTrack && !isManual) return;
    _isChangingTrack = true;
    
    // 遞增 session ID，讓舊的 callback 自動失效
    final sessionId = ++_playSessionId;
    
    _cancelPlaybackWatchdog();
    _startPlaybackWatchdog(video);

    // If the video being played is NOT in the current filtered view (search result),
    // we should automatically clear the search so the playlist can jump to its real position.
    if (mounted) {
      if (!_visibleVideos.contains(video)) {
        _searchController.clear();
        _isSearchExpanded = false;
        _visibleVideos.clear();
        _visibleVideos.addAll(_isShuffleMode ? _playbackQueue : _allVideos);
      }

      setState(() {
        _playingVideo = video;
        _currentIndex = _visibleVideos.indexOf(video);
      });

      if (_currentIndex != -1) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
      }
    } else {
      // Background: update state without setState
      _playingVideo = video;
      _currentIndex = _visibleVideos.indexOf(video);
    }

    _audioPlayer.playVideoAsCurrent(video).then((_) {
      if (_playSessionId != sessionId) return; // 已換歌，忽略舊 callback
      _cancelPlaybackWatchdog();
      _isChangingTrack = false;

      // Pre-queue the NEXT track for gapless background playback based on _playbackQueue
      if (_playbackQueue.isNotEmpty) {
        final qIndex = _playbackQueue.indexOf(video);
        if (qIndex != -1) {
           final nextIndex = (qIndex + 1) % _playbackQueue.length;
           _audioPlayer.enqueueNext(_playbackQueue[nextIndex]);
        }
      }
    }).catchError((e) {
      if (_playSessionId != sessionId) return; // 已換歌，忽略舊 callback
      _isChangingTrack = false;
      _cancelPlaybackWatchdog();

      debugPrint('playVideoObject catchError: $e');

      if (e is RateLimitedPlaybackException) {
        if (mounted) {
          final minutes = e.retryAfter.inMinutes < 1 ? 1 : e.retryAfter.inMinutes;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('YouTube 暫時限制請求，請約 $minutes 分鐘後再試。')),
          );
        }
        return;
      }

      final message = e.toString();
      if (message.contains('RequestLimitExceededException') ||
          message.contains('rate limiting')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('YouTube 暫時限制請求，請稍後再試。')),
          );
        }
        return;
      }
      
      _triggerAutoSkip();
    });
  }

  void _playNext({bool isManual = false}) {
    if (_playbackQueue.isEmpty) return;
    int currentQIndex = -1;
    if (_playingVideo != null) {
      currentQIndex = _playbackQueue.indexOf(_playingVideo!);
    }
    int next = (currentQIndex + 1) % _playbackQueue.length;
    _playVideoObject(_playbackQueue[next], isManual: isManual);
  }

  void _playPrevious() {
    if (_playbackQueue.isEmpty) return;
    int currentQIndex = -1;
    if (_playingVideo != null) {
      currentQIndex = _playbackQueue.indexOf(_playingVideo!);
    }
    int prev = (currentQIndex - 1) < 0 ? _playbackQueue.length - 1 : currentQIndex - 1;
    _playVideoObject(_playbackQueue[prev], isManual: true);
  }

  void _toggleShuffle() {
    if (_allVideos.isEmpty) return;
    setState(() {
      _isShuffleMode = !_isShuffleMode;
      _playbackQueue.clear();
      _playbackQueue.addAll(_allVideos);
      
      if (_isShuffleMode) {
        _playbackQueue.shuffle(Random());
      }
      
      // Shuffle mode changes what plays NEXT, but visible videos remain filtered as user sees them
      // Unless they aren't searching, then we can shuffle visible too:
      if (_searchController.text.trim().isEmpty) {
         _visibleVideos.clear();
         _visibleVideos.addAll(_playbackQueue);
      }
      
      if (_playingVideo != null) {
         _currentIndex = _visibleVideos.indexOf(_playingVideo!);
      } else {
         _currentIndex = 0;
      }
    });

    // Seamlessly apply new queue routing
    if (_playingVideo == null && _visibleVideos.isNotEmpty) {
      _playAt(0);
    } else if (_playingVideo != null && _playbackQueue.isNotEmpty) {
      // Re-enqueue the new track 1 of the shuffled queue gaplessly
      final qIndex = _playbackQueue.indexOf(_playingVideo!);
      final nextIndex = (qIndex + 1) % _playbackQueue.length;
      _audioPlayer.enqueueNext(_playbackQueue[nextIndex]);
    }
  }

  void _search(String keyword) {
    final normalized = keyword.trim().toLowerCase();

    setState(() {
      if (normalized.isEmpty) {
        _visibleVideos.clear();
        // If shuffle is on, we should show the shuffled playbackQueue order,
        // otherwise show the original allVideos order.
        if (_isShuffleMode) {
          _visibleVideos.addAll(_playbackQueue);
        } else {
          _visibleVideos.addAll(_allVideos);
        }
      } else {
        _visibleVideos
          ..clear()
          ..addAll(
            _allVideos.where(
              (item) => item.title.toLowerCase().contains(normalized),
            ),
          );
      }
      
      // Update _currentIndex to track the globally playing video in the new list
      if (_playingVideo != null) {
        _currentIndex = _visibleVideos.indexOf(_playingVideo!);
      } else {
        if (_visibleVideos.isEmpty) {
          _currentIndex = -1;
        } else if (_currentIndex >= _visibleVideos.length || _currentIndex < 0) {
          _currentIndex = 0;
        }
      }
    });

    // If clearing search, auto-scroll to the playing song
    if (normalized.isEmpty && _playingVideo != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPlaying());
    }
  }

  Future<void> _searchGlobal(String keyword) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) {
      setState(() {
        _globalSearchResults.clear();
        _isGlobalSearching = false;
      });
      return;
    }

    setState(() {
      _isGlobalSearching = true;
    });

    try {
      final results = await _youtubeApiService.searchVideos(normalized);
      setState(() {
        _globalSearchResults.clear();
        _globalSearchResults.addAll(results);
        _isGlobalSearching = false;
      });
    } catch (e) {
      setState(() {
        _isGlobalSearching = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e'), duration: const Duration(seconds: 2))
        );
      }
    }
  }

  Future<void> _onAddToYouTube(PlaylistVideo video) async {
    if (!_authService.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please login to add to YouTube'), duration: Duration(seconds: 2))
      );
      return;
    }

    final targetPlaylist = await _showPlaylistSelectionDialog();
    if (targetPlaylist == null) return;

    final token = _authService.oauthToken;
    if (token == null) return;

    try {
      // Check for duplicates first (Efficiently via videoId filter)
      final exists = await _youtubeApiService.checkVideoInPlaylist(
          targetPlaylist['value'], video.videoId, token);
      if (exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('"${video.title}" is already in this playlist.'),
                duration: const Duration(seconds: 2)),
          );
        }
        return;
      }

      await _youtubeApiService.addVideoToPlaylist(
          targetPlaylist['value'], video.videoId, token);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added to ${targetPlaylist['name']}!'), duration: const Duration(seconds: 2))
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add: $e'), duration: const Duration(seconds: 2))
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _showPlaylistSelectionDialog() async {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Select YouTube Playlist'),
          content: SizedBox(
            width: double.maxFinite,
            child: _myYtPlaylists.isEmpty
                ? const Text('No YouTube playlists found.')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _myYtPlaylists.length,
                    itemBuilder: (context, index) {
                      final plist = _myYtPlaylists[index];
                      return ListTile(
                        title: Text(plist['name'] ?? ''),
                        onTap: () => Navigator.pop(context, plist),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ],
        );
      },
    );
  }

  void _scrollToPlaying() {
    if (_currentIndex < 0 || !_scrollController.hasClients) return;
    
    // Exact height defined via itemExtent: 85.0
    const double itemHeight = 85.0; 
    final double viewportHeight = _scrollController.position.viewportDimension;
    final double targetOffset = (_currentIndex * itemHeight) - (viewportHeight / 2) + (itemHeight / 2);
    
    // Avoid double animation or if already near Target
    final current = _scrollController.offset;
    if ((current - targetOffset).abs() < 10) return;

    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _playPreview(PlaylistVideo video) async {
    setState(() {
      _playingVideo = video;
      _currentIndex = -1; // Not in local list
    });
    // Just play it as a one-off
    await _audioPlayer.playVideoAsCurrent(video);
  }

  @override
  Widget build(BuildContext context) {
    // Determine which video to show in the Mini-Player.
    // It should be the globally playing video, regardless of search filters!
    final PlaylistVideo? currentVideo = _playingVideo;

    if (!_isInit) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: _isSearchExpanded
            ? TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (val) {
                  if (!_isGlobalSearch) _search(val);
                },
                onSubmitted: (val) {
                  if (_isGlobalSearch) _searchGlobal(val);
                },
                decoration: InputDecoration(
                  hintText: _isGlobalSearch ? 'Search YouTube...' : 'Filter local list...',
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    icon: Icon(
                      Icons.public,
                      color: _isGlobalSearch ? Colors.redAccent : null,
                    ),
                    tooltip: 'Search on YouTube',
                    onPressed: () {
                      setState(() {
                        _isGlobalSearch = !_isGlobalSearch;
                        if (_isGlobalSearch) {
                          _searchGlobal(_searchController.text);
                        } else {
                          _search(_searchController.text);
                        }
                      });
                    },
                  ),
                ),
              )
            : const Text('Youtube Random Player'),
        actions: [
          IconButton(
            icon: Icon(_isSearchExpanded ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearchExpanded = !_isSearchExpanded;
                if (!_isSearchExpanded) {
                  _searchController.clear();
                  _isGlobalSearch = false;
                  _search(''); // Reset search
                }
              });
            },
          ),
        ],
        elevation: 4,
      ),
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              TextField(
                controller: _playlistInputController,
                decoration: InputDecoration(
                  hintText: 'Paste playlist URL or ID',
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  suffixIcon: _isLoadingPlaylist
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.download),
                          onPressed: () => _fetchPlaylistSource(
                              _playlistInputController.text),
                        ),
                ),
                onSubmitted: (val) => _fetchPlaylistSource(val),
              ),
              const SizedBox(height: 10),
              if (_playlistTitle.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Playlist: $_playlistTitle',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),

              // Playlist list — takes all available space
              Expanded(
                child: _isGlobalSearch
                  ? (_isGlobalSearching 
                      ? const Center(child: CircularProgressIndicator())
                      : _globalSearchResults.isEmpty
                        ? const Center(child: Text('No results on YouTube'))
                        : ListView.builder(
                            itemCount: _globalSearchResults.length,
                            itemBuilder: (context, index) {
                              final item = _globalSearchResults[index];
                              return Card(
                                child: ListTile(
                                  onTap: () => _playPreview(item),
                                  leading: Image.network(item.thumbnailUrl, width: 56, fit: BoxFit.cover),
                                  title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.add_circle_outline, color: Colors.redAccent),
                                    onPressed: () => _onAddToYouTube(item),
                                  ),
                                ),
                              );
                            },
                          ))
                  : (_visibleVideos.isEmpty
                      ? const Center(child: Text('Playlist not loaded yet'))
                      : ListView.builder(
                          controller: _scrollController,
                          itemExtent: 85.0, // Critical for performance with large lists (2000+)
                          itemCount: _visibleVideos.length,
                          itemBuilder: (BuildContext context, int index) {
                            final item = _visibleVideos[index];
                            final selected = _currentIndex == index;

                            return Card(
                              color: selected
                                  ? Theme.of(context).colorScheme.primaryContainer
                                  : null,
                              child: ListTile(
                                onTap: () => _playAt(index),
                                leading: item.thumbnailUrl.isEmpty
                                    ? const SizedBox(
                                        width: 56,
                                        child: Icon(Icons.music_note),
                                      )
                                    : Image.network(
                                        item.thumbnailUrl,
                                        width: 56,
                                        fit: BoxFit.cover,
                                      ),
                                title: Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text('No. ${item.position + 1}'),
                                trailing: selected
                                    ? Icon(Icons.equalizer,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer)
                                    : null,
                              ),
                            );
                          },
                        )),
              ),

              // Compact mini-player at the bottom
              if (currentVideo != null) _buildMiniPlayer(context, currentVideo),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildMiniPlayer(BuildContext context, PlaylistVideo video) {
    final totalSeconds = _duration.inSeconds.toDouble();
    final currentSeconds = _position.inSeconds
        .toDouble()
        .clamp(0.0, totalSeconds > 0 ? totalSeconds : 1.0);

    return Card(
      margin: EdgeInsets.zero,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Thumbnail + title row
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: video.thumbnailUrl.isEmpty
                      ? const Icon(Icons.music_note, size: 40)
                      : Image.network(
                          video.thumbnailUrl,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Seek slider + time labels
            Row(
              children: [
                Text(_formatDuration(_position),
                    style: const TextStyle(fontSize: 11)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      min: 0,
                      max: totalSeconds > 0 ? totalSeconds : 1,
                      value: currentSeconds,
                      onChanged: totalSeconds > 0
                          ? (v) {
                              _audioPlayer.player
                                  .seek(Duration(seconds: v.toInt()));
                            }
                          : null,
                    ),
                  ),
                ),
                Text(_formatDuration(_duration),
                    style: const TextStyle(fontSize: 11)),
              ],
            ),
            // Controls row: |◀  ⏪10  ⏸  10⏩  ▶|
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _toggleShuffle,
                  iconSize: 26,
                  color: _isShuffleMode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  icon: const Icon(Icons.shuffle),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _playPrevious,
                  iconSize: 28,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  onPressed: () => _audioPlayer.player
                      .seek(_position - const Duration(seconds: 10) <
                              Duration.zero
                          ? Duration.zero
                          : _position - const Duration(seconds: 10)),
                  iconSize: 26,
                  tooltip: '-10s',
                  icon: const Icon(Icons.replay_10),
                ),
                IconButton(
                  onPressed: () {
                    if (_isPlaying) {
                      _audioPlayer.pause();
                    } else {
                      _audioPlayer.resume();
                    }
                  },
                  iconSize: 48,
                  icon: Icon(_isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill),
                  color: Theme.of(context).colorScheme.primary,
                ),
                IconButton(
                  onPressed: () {
                    final next = _position + const Duration(seconds: 10);
                    if (_duration > Duration.zero && next < _duration) {
                      _audioPlayer.player.seek(next);
                    }
                  },
                  iconSize: 26,
                  tooltip: '+10s',
                  icon: const Icon(Icons.forward_10),
                ),
                IconButton(
                  onPressed: () => _playNext(isManual: true),
                  iconSize: 28,
                  icon: const Icon(Icons.skip_next),
                ),
                const SizedBox(width: 34), // Visually balance the shuffle button
              ],
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
            ),
            child: _authService.isLoggedIn
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundImage: _authService
                                .currentUserInfo!.avatar.isNotEmpty
                            ? NetworkImage(_authService.currentUserInfo!.avatar)
                            : null,
                        child: _authService.currentUserInfo!.avatar.isEmpty
                            ? const Icon(Icons.person, size: 30)
                            : null,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _authService.currentUserInfo!.username,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                      Text(
                        _authService.currentUserInfo!.email,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  )
                : const Center(
                    child: Text(
                      'Not Logged In',
                      style: TextStyle(color: Colors.white, fontSize: 24),
                    ),
                  ),
          ),
          if (!_authService.isLoggedIn)
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('Login with Google'),
              onTap: () async {
                final success = await _authService.login();
                if (success) {
                  await _loadDrawerData();
                  setState(() {});
                } else if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Login failed')));
                }
              },
            )
          else ...[
            ListTile(
              leading: const Icon(Icons.thumb_up),
              title: const Text('Liked Videos'),
              onTap: () {
                Navigator.pop(context);
                _fetchLikedVideos();
              },
            ),

            ExpansionTile(
              leading: const Icon(Icons.video_library),
              title: const Text('My YT'),
              children: _myYtPlaylists.isEmpty
                  ? [
                      const ListTile(
                          title: Text('No YT playlists found',
                              style: TextStyle(color: Colors.grey)))
                    ]
                  : _myYtPlaylists
                      .map((plist) => ListTile(
                            title: Text(plist['name'] ?? ''),
                            onTap: () {
                              Navigator.pop(context);
                              _fetchPlaylistSource(plist['value']);
                            },
                          ))
                      .toList(),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () async {
                await _authService.logout();
                setState(() {
                  _myYtPlaylists.clear();
                });
              },
            ),
          ]
        ],
      ),
    );
  }
}
