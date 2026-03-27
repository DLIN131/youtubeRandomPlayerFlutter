
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/playlist_video.dart';

class AudioPlayerService {

  static const String _fallbackAudioBaseUrl =
      'https://ytdl-server-byvu.onrender.com/download';
  static const bool _enableBackendFallback = true;
  static const Duration _rateLimitCooldown = Duration(minutes: 20);

  final AudioPlayer player = AudioPlayer();
  ConcatenatingAudioSource? _activePlaylist;
  
  final YoutubeExplode _yt = YoutubeExplode();
  DateTime? _rateLimitedUntil;
  int _fetchSessionId = 0;

  MediaItem _createMediaItem(PlaylistVideo video) {
    return MediaItem(
      id: video.videoId,
      title: video.title,
      artist: 'YouTube Playlist',
      artUri: video.thumbnailUrl.isEmpty ? null : Uri.tryParse(video.thumbnailUrl),
    );
  }

  Future<void> playVideoAsCurrent(PlaylistVideo video) async {
    _fetchSessionId++; // Cancel any pending prefetch

    if (kIsWeb) {
      throw UnsupportedError('Web playback blocked by CORS.');
    }

    final limitedUntil = _rateLimitedUntil;
    if (limitedUntil != null && DateTime.now().isBefore(limitedUntil)) {
      throw RateLimitedPlaybackException(
          limitedUntil.difference(DateTime.now()));
    }

    final url = await _resolveStreamUrl(video);
    if (url == null) {
      throw Exception('Unable to extract playable stream for ${video.videoId}.');
    }

    _activePlaylist = ConcatenatingAudioSource(
      useLazyPreparation: false,
      children: [
        AudioSource.uri(Uri.parse(url), tag: _createMediaItem(video)),
      ],
    );

    await player.stop();
    await player.setAudioSource(_activePlaylist!);
    player.play(); // DO NOT AWAIT to unblock the caller
  }

  Future<void> enqueueNext(PlaylistVideo video) async {
    final sessionId = ++_fetchSessionId;
    
    final url = await _resolveStreamUrl(video);
    // If the session changed (user skipped while we were fetching), discard this prefetch
    if (url == null || _fetchSessionId != sessionId || _activePlaylist == null) return;

    // We only keep the currently playing item and 1 pre-queued item.
    if (_activePlaylist!.length > 1) {
      await _activePlaylist!.removeRange(1, _activePlaylist!.length);
    }
    await _activePlaylist!.add(AudioSource.uri(
      Uri.parse(url),
      tag: _createMediaItem(video),
    ));
    debugPrint('Native background prefetch complete for ${video.videoId}');
  }

  Future<void> shiftQueue() async {
    if (_activePlaylist != null && _activePlaylist!.length > 1) {
      // Removing index 0 natively drops it and shifts currentIndex from 1 down to 0 seamlessly
      await _activePlaylist!.removeAt(0);
    }
  }

  Future<void> pause() => player.pause();
  Future<void> resume() => player.play();
  
  Future<void> seekBy(Duration offset) async {
    final current = player.position;
    var nextPosition = current + offset;
    if (nextPosition < Duration.zero) nextPosition = Duration.zero;
    final duration = player.duration;
    if (duration != null && nextPosition > duration) nextPosition = duration;
    await player.seek(nextPosition);
  }

  Future<void> setVolume(double value) => player.setVolume(value);

  Future<void> dispose() async {
    _yt.close();
    await player.dispose();
  }

  Future<String?> _resolveStreamUrl(PlaylistVideo video) async {
    final clientsToTry = <YoutubeApiClient>[
      YoutubeApiClient.tv,
      YoutubeApiClient.androidVr,
      YoutubeApiClient.ios,
    ];

    for (final client in clientsToTry) {
      try {
        final manifest = await _yt.videos.streams.getManifest(
          video.videoId,
          ytClients: [client],
        );
        final audioStreams = manifest.audioOnly.toList()
          ..sort((a, b) =>
              b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

        if (audioStreams.isNotEmpty) {
          final stream = audioStreams.first;
          debugPrint('Resolved stream using ${client.runtimeType} for ${video.videoId}');
          return stream.url.toString();
        }
      } on RequestLimitExceededException {
        _rateLimitedUntil = DateTime.now().add(_rateLimitCooldown);
        debugPrint('Rate-limited by YouTube for ${video.videoId}. Cooldown until $_rateLimitedUntil');
        throw RateLimitedPlaybackException(_rateLimitCooldown);
      } catch (e) {
        debugPrint('Client ${client.runtimeType} failed for ${video.videoId}: $e');
      }
    }

    if (_enableBackendFallback) {
      debugPrint('Fallback to backend URI for ${video.videoId}');
      return '$_fallbackAudioBaseUrl/${video.videoId}';
    }

    return null;
  }
}

class RateLimitedPlaybackException implements Exception {
  const RateLimitedPlaybackException(this.retryAfter);

  final Duration retryAfter;

  @override
  String toString() {
    final minutes = retryAfter.inMinutes < 1 ? 1 : retryAfter.inMinutes;
    return 'YouTube is rate-limiting this IP. Retry after about $minutes minute(s).';
  }
}
