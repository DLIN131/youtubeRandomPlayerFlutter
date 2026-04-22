## 1. AudioPlayerService 修正

- [x] 1.1 在 `playVideoAsCurrent` 方法中設定新的 `AudioSource` 前，加入 `try { await player.stop(); } catch (_) {}` 以確保清除殘留的錯誤狀態。

## 2. app.dart 狀態管理與防抖邏輯

- [x] 2.1 在 `_PlayerHomePageState` 新增狀態變數：`DateTime? _lastAutoSkipAt` 與 `int _consecutiveErrorCount = 0`。
- [x] 2.2 實作 `_triggerAutoSkip()` 方法，加入 3 秒防抖邏輯，並增加 `_consecutiveErrorCount`。若超過 5 次，顯示 SnackBar 警告並停止跳過；否則呼叫 `_playNext()`。
- [x] 2.3 修改 `initState()` 中的 `playerStateStream` 監聽器，將完成播放時的 `_playNext()` 替換為 `_triggerAutoSkip()`。
- [x] 2.4 修改 `initState()` 中的 `playbackEventStream` 錯誤監聽器，移除原有的 `Future.delayed` 延遲跳過，改為直接呼叫 `_triggerAutoSkip()`。

## 3. _playVideoObject 旗標安全機制

- [x] 3.1 在 `_playVideoObject` 方法中，設定 `_isChangingTrack = true` 的同時，啟動一個 `Future.delayed(const Duration(seconds: 5))` 的定時器。若時間到 `_isChangingTrack` 仍為 true，將其強制設為 false。
- [x] 3.2 在 `_playVideoObject` 的 `.catchError` 區塊中，將錯誤發生時的 `_playNext()` 替換為 `_triggerAutoSkip()`。
- [x] 3.3 在 `_playVideoObject` 的 `.then` 區塊中（正常播放開始），將 `_consecutiveErrorCount` 重置為 0。
