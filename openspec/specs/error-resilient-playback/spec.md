## ADDED Requirements

### Requirement: Debounced auto-skip on playback error
系統 SHALL 在偵測到播放錯誤後，使用防抖機制確保在 3 秒時間窗口內只觸發一次自動跳過下一首。

#### Scenario: Single error triggers single skip
- **WHEN** 播放中途發生一次原生 playbackEventStream 錯誤
- **THEN** 系統在 2 秒後自動跳到下一首，且只跳一次

#### Scenario: Multiple concurrent errors are deduplicated
- **WHEN** playerStateStream 和 playbackEventStream 在 1 秒內都觸發
- **THEN** 系統只觸發一次 `_playNext()`，不重複切歌

#### Scenario: Normal play after error resets the debounce
- **WHEN** 錯誤跳過後下一首正常播放超過 3 秒
- **THEN** 防抖計時器重置，後續的錯誤可以再次觸發自動跳過

### Requirement: isChangingTrack safety timeout
系統 SHALL 為 `_isChangingTrack` 旗標提供 5 秒的安全逾時，防止旗標因競態條件或未捕捉例外而永久停留在 `true`。

#### Scenario: Flag auto-resets after timeout
- **WHEN** `_isChangingTrack` 被設為 `true` 但 5 秒後 `catchError` 沒有執行（或 Future 被取消）
- **THEN** 旗標自動重置為 `false`，使後續的播放請求得以執行

#### Scenario: Flag resets normally before timeout
- **WHEN** `playVideoAsCurrent` 正常完成（成功或錯誤）後 catchError/then 在 5 秒內執行
- **THEN** 旗標在正常流程中被重置，逾時計時器無副作用

### Requirement: Consecutive error limit stops auto-skip loop
系統 SHALL 追蹤連續播放錯誤次數，當連續錯誤超過 5 首時，停止自動跳過並通知使用者。

#### Scenario: Consecutive errors trigger warning
- **WHEN** 連續 5 首歌播放失敗並自動跳過
- **THEN** 系統顯示 SnackBar 通知「多首歌播放失敗，請檢查網路連線」，並停止自動跳過

#### Scenario: Successful playback resets error counter
- **WHEN** 發生 2 次連續錯誤後，第 3 首成功播放超過 3 秒
- **THEN** 連續錯誤計數器重置為 0

### Requirement: Player state reset before new track
`AudioPlayerService.playVideoAsCurrent()` SHALL 在設定新的 AudioSource 之前，先呼叫 `player.stop()` 以清除任何殘留的錯誤狀態。

#### Scenario: Player in error state can accept new source
- **WHEN** 上一首歌播放失敗，player 處於 error 狀態
- **THEN** 呼叫 `playVideoAsCurrent` 後，player 可成功載入並播放新的 AudioSource
