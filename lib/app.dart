import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'models/playlist_video.dart';
import 'services/audio_player_service.dart';
import 'services/auth_service.dart';
import 'services/backend_api_service.dart';
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

  final YoutubeApiService _youtubeApiService = YoutubeApiService();
  final BackendApiService _backendApiService = BackendApiService();
  final AuthService _authService = AuthService();
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  final LocalStorageService _localStorage = LocalStorageService();

  final List<PlaylistVideo> _allVideos = <PlaylistVideo>[];
  final List<PlaylistVideo> _visibleVideos = <PlaylistVideo>[];

  List<String> _savedPlaylists = [];
  List<Map<String, dynamic>> _myYtPlaylists = [];

  int _currentIndex = -1;
  bool _isLoadingPlaylist = false;
  bool _isShuffleMode = false;
  String _playlistTitle = '';
  String _errorMessage = '';

  bool _isPlaying = false;
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAuth();
    _loadLocalPlaylist();
    _audioPlayer.player.playingStream.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
    _audioPlayer.player.currentIndexStream.listen((index) {
      // just_audio handles its own index if we use a concatenating audio source,
      // but here we are loading one by one, so we manage our own _currentIndex.
      // However, to support background next/prev we might need concatenating audio source.
      // For simplicity, we just listen to player completion here.
    });
    _audioPlayer.player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _playNext();
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

    final userId = _authService.currentUserInfo?.userId ?? '';
    if (userId.isNotEmpty) {
      final saved = await _backendApiService.fetchPlaylistNames(userId);
      setState(() => _savedPlaylists = saved);
    }

    final token = _authService.oauthToken;
    if (token != null && token.isNotEmpty) {
      final myYt = await _youtubeApiService.fetchMyPlaylists(token);
      setState(() => _myYtPlaylists = myYt);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playlistInputController.dispose();
    _searchController.dispose();
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
      setState(() => _errorMessage = 'Invalid Playlist ID');
      return;
    }

    setState(() {
      _isLoadingPlaylist = true;
      _errorMessage = '';
    });

    try {
      final videos = await _youtubeApiService.fetchPlaylistItems(playlistId);
      final title = await _youtubeApiService.fetchPlaylistTitle(playlistId);
      _setPlaylistData(videos, title ?? 'Playlist');
    } catch (e) {
      setState(() {
        _isLoadingPlaylist = false;
        _errorMessage = 'Failed to load: $e';
      });
    }
  }

  Future<void> _fetchSavedPlaylist(String listname) async {
    final userId = _authService.currentUserInfo?.userId ?? '';
    if (userId.isEmpty) return;

    setState(() {
      _isLoadingPlaylist = true;
      _errorMessage = '';
    });

    try {
      final videos =
          await _backendApiService.fetchPlaylistData(userId, listname);
      _setPlaylistData(videos, listname);
    } catch (e) {
      setState(() {
        _isLoadingPlaylist = false;
        _errorMessage = 'Failed to load saved playlist: $e';
      });
    }
  }

  void _setPlaylistData(List<PlaylistVideo> videos, String title) {
    if (videos.isEmpty) {
      setState(() {
        _isLoadingPlaylist = false;
        _errorMessage = 'No playable videos found';
        _playlistTitle = title;
        _allVideos.clear();
        _visibleVideos.clear();
        _currentIndex = -1;
      });
      return;
    }

    setState(() {
      _allVideos
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

    _playCurrent();
  }

  void _playCurrent() {
    if (_currentIndex < 0 || _currentIndex >= _visibleVideos.length) return;
    final current = _visibleVideos[_currentIndex];
    _audioPlayer.playVideo(current).catchError((e) {
      if (!mounted) return;

      if (e is RateLimitedPlaybackException) {
        final minutes = e.retryAfter.inMinutes < 1 ? 1 : e.retryAfter.inMinutes;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('YouTube 暫時限制請求，請約 $minutes 分鐘後再試。')),
        );
        return;
      }

      final message = e.toString();
      if (message.contains('RequestLimitExceededException') ||
          message.contains('rate limiting')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('YouTube 暫時限制請求，請稍後再試。')),
        );
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error playing audio: $e')));
      // Auto skip on regular source errors
      Future.delayed(const Duration(seconds: 2), _playNext);
    });
  }

  void _playAt(int index) {
    if (index < 0 || index >= _visibleVideos.length) return;
    setState(() => _currentIndex = index);
    _playCurrent();
  }

  void _playNext() {
    if (_visibleVideos.isEmpty) return;
    var nextIndex = _currentIndex + 1;
    if (nextIndex >= _visibleVideos.length) nextIndex = 0;
    _playAt(nextIndex);
  }

  void _playPrevious() {
    if (_visibleVideos.isEmpty) return;
    var previousIndex = _currentIndex - 1;
    if (previousIndex < 0) previousIndex = _visibleVideos.length - 1;
    _playAt(previousIndex);
  }

  void _toggleShuffle() {
    if (_allVideos.isEmpty) return;
    setState(() {
      _isShuffleMode = !_isShuffleMode;
      _visibleVideos.clear();
      _visibleVideos.addAll(_allVideos);
      if (_isShuffleMode) {
        _visibleVideos.shuffle(Random());
      }
      _currentIndex = 0;
    });
    _playCurrent();
  }

  void _search(String keyword) {
    final normalized = keyword.trim().toLowerCase();
    setState(() {
      if (normalized.isEmpty) {
        _visibleVideos
          ..clear()
          ..addAll(_allVideos);
      } else {
        _visibleVideos
          ..clear()
          ..addAll(
            _allVideos.where(
              (item) => item.title.toLowerCase().contains(normalized),
            ),
          );
      }
      if (_visibleVideos.isEmpty) {
        _currentIndex = -1;
      } else if (_currentIndex >= _visibleVideos.length || _currentIndex < 0) {
        _currentIndex = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final PlaylistVideo? currentVideo =
        _currentIndex >= 0 && _currentIndex < _visibleVideos.length
            ? _visibleVideos[_currentIndex]
            : null;

    if (!_isInit) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Youtube Random Player'),
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
                  border: const OutlineInputBorder(),
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
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: _search,
                      decoration: const InputDecoration(
                        hintText: 'Search video title',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _toggleShuffle,
                    icon:
                        Icon(_isShuffleMode ? Icons.shuffle_on : Icons.shuffle),
                    label: const Text('Random'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_playlistTitle.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Playlist: $_playlistTitle',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              if (_errorMessage.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorMessage,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 8),

              // Audio Player UI completely replacing the YoutubePlayerIFrame
              if (currentVideo != null)
                Card(
                    elevation: 6,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: currentVideo.thumbnailUrl.isEmpty
                                ? const Icon(Icons.music_note, size: 80)
                                : Image.network(
                                    currentVideo.thumbnailUrl,
                                    height: 180,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                  ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            currentVideo.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              IconButton(
                                onPressed: _playPrevious,
                                iconSize: 42,
                                icon: const Icon(Icons.skip_previous),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                onPressed: () {
                                  if (_isPlaying) {
                                    _audioPlayer.pause();
                                  } else {
                                    _audioPlayer.resume();
                                  }
                                },
                                iconSize: 64,
                                icon: Icon(_isPlaying
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill),
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                onPressed: _playNext,
                                iconSize: 42,
                                icon: const Icon(Icons.skip_next),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )),

              const SizedBox(height: 8),
              Expanded(
                child: _visibleVideos.isEmpty
                    ? const Center(child: Text('Playlist not loaded yet'))
                    : ListView.builder(
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
                      ),
              ),
            ],
          ),
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
            ExpansionTile(
              leading: const Icon(Icons.save),
              title: const Text('Saved Playlists'),
              children: _savedPlaylists.isEmpty
                  ? [
                      const ListTile(
                          title: Text('No saved playlists',
                              style: TextStyle(color: Colors.grey)))
                    ]
                  : _savedPlaylists
                      .map((name) => ListTile(
                            title: Text(name),
                            onTap: () {
                              Navigator.pop(context);
                              _fetchSavedPlaylist(name);
                            },
                          ))
                      .toList(),
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
                  _savedPlaylists.clear();
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
