---
name: youtube_random_player_dev
description: Development and maintenance guide for the Flutter YouTube Random Player Background Audio app.
---

# YouTube Random Player Skill

This skill provides domain-specific knowledge for maintaining and extending the Flutter YouTube Random Player. It focuses on background audio stability, high-performance stream extraction, and large-list UI optimizations.

## 核心架構 (Core Architecture)

### 1. 播放引擎 (Playback Engine)
- **套件**: `just_audio` + `just_audio_background`.
- **關鍵機制**:
  - 使用 `ConcatenatingAudioSource` 並維持一個 2-track 佇列 (目前 + 下一首)。
  - 這能確保 Android 背景播放時不會因為歌曲切換而被系統回收進程 (Wakelock 保持)。
  - 當 `currentIndexStream` 偵測到跳轉至索引 `1` 時，應立即進行 `shiftQueue()` 並抓取新歌網址進行 `enqueueNext()`。

### 2. YouTube 串流解析 (Stream Extraction)
- **套件**: `youtube_explode_dart`.
- **優化策略**:
  - 優先順序: `YoutubeApiClient.tv` > `androidVr` > `ios`.
  - 此順序提供了穩定的 pre-signed URLs 且較少受到流量限制。
  - **URL 暫存**: 在 `AudioPlayerService` 中使用 `_urlCache` 做記憶體級快取，實現「秒開」同首歌曲的效果。

### 3. Google 登入與權限 (Auth)
- **權限 Scopes**: 必須包含 `https://www.googleapis.com/auth/youtube.readonly` 以抓取「喜歡的影片 (LL)」。
- **GCP 設定**: 必須在 OAuth Consent Screen 的 Test Users 加入測試者，並在後端啟用 YouTube Data API v3。

## 效能與 UI (Performance & UI)

### 1. 超大清單優化 (Large List Optimization)
- 當播放清單達到 2000+ 首歌時，`ListView.builder` **必須** 使用 `itemExtent`。
- 目前設定 `itemExtent: 85.0`。
- **絕對禁止** 在清單中進行動態高度計算，否則快速滾動或程式化定位時會導致 App 卡死 (Jank)。

### 2. 自動捲動定位 (Auto-Scroll)
- 使用 `ScrollController` 配合 `itemExtent` 進行數學計算。
- 公式: `targetOffset = (index * 85.0) - (viewportHeight / 2) + (85.0 / 2)` (將目標置中)。

## 常見問題與除錯 (Troubleshooting)

- **Login Fail**: 檢查 SHA-1 是否與 GCP 匹配。注意 Android 8.0 以上的 Scopes 授權通常需要 Test Users 權限。
- **403 Forbidden**: 通常是 YouTube 偵測到機器人。解決方案是切換 `YoutubeApiClient` 或是使用者手動登入觸發新 Cookie (若有實作)。
- **App 被系統殺掉**: 檢查 `just_audio_background` 的 `androidNotificationIcon` 與 `androidShowNotificationBadge` 設定。

## 快速入口 (Quick Links)
- 主要畫面: [app.dart](file:///d:/proj_bk\personal\youtube_random_player_flutter_bg\lib\app.dart)
- 音訊核心: [audio_player_service.dart](file:///d:/proj_bk\personal\youtube_random_player_flutter_bg\lib\services\audio_player_service.dart)
- 登入核心: [auth_service.dart](file:///d:/proj_bk\personal\youtube_random_player_flutter_bg\lib\services\auth_service.dart)
