## Why

播放器在遇到音訊串流錯誤時（例如 YouTube URL 過期、後端 fallback 失敗、或背景播放時被系統中斷），會卡死並無法自動或手動切換下一首。這個問題在背景播放模式下更加明顯，因為 `just_audio_background` 的原生媒體 session 可能在 UI 層不可見的情況下產生額外的錯誤事件，與 UI 層的錯誤處理邏輯相互競爭，導致狀態機 (`_isChangingTrack`) 永久鎖死。

## What Changes

- **修正 `_isChangingTrack` 死鎖問題**：加入安全逾時 (safety timeout) 機制，確保旗標不會因為競態條件 (race condition) 而永久停留在 `true` 狀態。
- **統一錯誤處理入口**：目前錯誤處理分散在 `playerStateStream`、`playbackEventStream`、以及 `_playVideoObject.catchError` 三處，且可能同時觸發多次 `_playNext()`，造成重複切歌。重構為單一防抖 (debounced) 的錯誤/完成處理函數。
- **修正 `playbackEventStream` 與 `playerStateStream` 的競態條件**：兩個監聽器可能在同一錯誤事件時都觸發，導致 `_playNext` 被呼叫兩次，使 `_isChangingTrack` 被設為 `true` 後立刻被第二次呼叫的檢查擋住。
- **修正背景播放後 `player` 物件狀態殘留問題**：在呼叫 `playVideoAsCurrent` 之前，確保先停止並重置 player，避免錯誤狀態持續影響後續播放。
- **增加連續錯誤保護**：加入連續跳過計數器，若短時間內連續錯誤超過閾值（如 5 首），暫停自動跳過並通知使用者，避免無限迴圈。

## Capabilities

### New Capabilities
- `error-resilient-playback`: 具備防死鎖、防競態、防無限迴圈的錯誤恢復播放機制

### Modified Capabilities
- (none — 這是實作層面的修正，不改變對外的播放功能規格)

## Impact

- **主要修改**: `lib/app.dart` — `initState()` 的串流監聽器重構、`_playVideoObject()` 的旗標管理
- **次要修改**: `lib/services/audio_player_service.dart` — 可能需要在 `playVideoAsCurrent()` 前加入 `player.stop()` 確保乾淨的初始狀態
- **依賴**: 無新增依賴
- **API 變更**: 無
