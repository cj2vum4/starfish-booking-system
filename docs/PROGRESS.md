# 施工紀錄 2026-10-02

## 已完成並驗證

- Supabase starfishlarp：Healthy、Tokyo，原有 public schema 無資料表。
- 本機建立獨立 starfish-booking-system 專案與 Git repository。
- 透過 SQL Editor 套用 202610020001_line_identity.sql。
- 建立 users、players、line_webhook_events；RLS 全部開啟。
- ingestion RPC 僅 service_role 可執行，anon/authenticated 無讀写權限。
- 在雲端執行 tests/database.sql：PASS；所有 synthetic records 均 ROLLBACK。
- npm test：9 passed，0 failed。
- 透過 Dashboard 部署 line-webhook，Settings 顯示部署成功及正式 endpoint。

## LINE 連線設定已完成

- 帳號持有人已儲存 LINE_CHANNEL_SECRET，並明確同意改用 LINE HMAC 驗證。
- 已關閉 line-webhook 的 legacy JWT gate；本機 config.toml 與雲端一致。
- 線上無簽章及錯誤簽章測試均回傳 401 invalid_signature。
- LINE Console 已儲存 webhook URL，Verify 顯示 Success。
- Use webhook 與 Webhook redelivery 都已開啟並核對 checked=true。
- Channel access token 尚未發行，現階段接收好友事件不需要此 token。
- Messaging API 的 Provider 為「劇本殺玩家通知」，ID 2005594335。

## 實機驗收通過

- 帳號持有人已用手機完成封鎖／解除封鎖。
- 實際資料庫查詢：users_total=1、active_users=1、blocked_users=0。
- follow_events=1、unfollow_events=1，兩個事件沒有產生重複使用者。
- 最後處理時間：2026-10-02 16:55:13.421292（Asia/Taipei）。
- 此結果驗證 LINE → HMAC webhook → Postgres RPC → users 的真實入庫路徑。
- 實際好友事件和玩家紀錄保留；沒有刪除或回滾真實資料。

## P2 核心資料模型（已套用雲端並驗收）

- 新增 202610020002_booking_core.sql：games、groups、group_members、events、bookings、
  booking_participants、payments、payment_allocations、player_game_history、invite_tokens、
  notification_logs、app_sessions、admin_users、audit_logs，全部開啟 RLS、只授權 service_role。
- 席位上限由資料庫 trigger 鎖定 events 列後檢查（SOLD_OUT／EVENT_CLOSED），不可降容量低於已佔位。
- 新增 tests/booking_core.sql，並以 PGlite（模擬 Supabase 預設權限）於本機執行兩個 migration 與兩份 SQL 測試。
- 本機測試抓到 audit_logs_id_seq 會被 Supabase 預設權限開放給 anon/authenticated，已在 migration 中 revoke。
- npm test：11 passed，0 failed。
- 透過 SQL Editor 套用 202610020002_booking_core.sql（內容 SHA-256 3d7a20bc…a836e，與本機檔一致）：Success。
- 雲端 tests/database.sql 與 tests/booking_core.sql 均 PASS，合成資料全部 ROLLBACK。
- 套用後核對：public 表 17 張、users_total=1、active_users=1、測試殘留 0；真實資料未變動。
- 20 個 concurrent request 搶最後 1 席屬 P6，需在雲端以多連線實測；PGlite 為單連線，無法代替。

## 開團／加入／預約／取消 RPC（已套用雲端並驗收）

- 新增 202610020003_booking_rpc.sql，12 個 RPC 僅 service_role 可執行；p_actor 由後端 session 決定。
- 開團：create_group、create_group_invite、reserve_group_seat、join_group、claim_invite、leave_group_seat、cancel_group。
- 成場：admin_confirm_group_event（僅 admin_users）。
- 預約：create_booking（多人代報）、join_event、create_participant_claim、cancel_participant（單人取消）。
- 所有寫入先鎖 group／event 列再檢查名額；request_id 重送冪等；每個操作寫 audit_logs。
- tests/booking_rpc.sql 涵蓋 P2／P4／P6 手冊驗收項；npm test 12 passed。
- 透過 SQL Editor 套用 202610020003_booking_rpc.sql（SHA-256 fd99cf23…40903，與本機檔一致）：Success。
- 雲端 tests/booking_rpc.sql PASS；套用後核對 RPC 12 個、users_total=1、active_users=1、測試殘留 0。
- 突變測試：移除售完檢查、允許 token 重用、略過私人團檢查、允許任何人取消，均被測試抓到。

## P3 LIFF 登入（資料庫已上雲；API 與 LIFF 頁尚未部署）

- 202610020004_app_sessions.sql：login_line_user、resolve_session、logout_session；session 只存 SHA-256，12 小時到期。
- supabase/functions/api：POST /auth/line 向 LINE 驗證 ID token（iss、aud、exp、sub），GET /me、POST /auth/logout。
- web/liff：LIFF 登入頁；GitHub Actions 只發布 web/liff 到 GitHub Pages。
- 公開 repo：github.com/cj2vum4/starfish-booking-system（乾淨歷史，不含 docs/evidence 與 docs/backups；
  完整本機歷史保留在 full-history-local 分支）。

## 可預約時段（已套用雲端並驗收）

- 202610020005_time_slots.sql：slot_rules 為每週開放區間（Asia/Taipei）：週一二四五 19–24、週六 9–24、週日 13–24。
- 每場 240 分鐘，整點開場且須於區間內結束（平日 19:00／20:00；週六 09:00–20:00；週日 13:00–20:00）。
- 同一時間只能一場：time_slots 以 exclusion constraint 禁止重疊；開團即佔住，解散釋出，成場轉 booked。
- Google 日曆有活動的時間不顯示有空：API 在列出時段與開團前即時呼叫 Google free/busy，
  查不到或出錯一律回 503，不提供也不保留任何時段。只存忙碌起訖，不存行程內容。
- 店家 admin_create_event 可開在區間外，但仍不可撞到日曆或其他場次。
- 0004、0005 已透過 SQL Editor 套用（內容取自 GitHub commit 3ed9eb4，SHA-256 與本機一致）；
  雲端 tests/sessions.sql、tests/slots.sql、tests/booking_rpc.sql 均 PASS；核對 20 張表、開放區間 6 筆、users=1、殘留 0。
- 測試以 UTC session 執行（與 Supabase 相同）；npm test 24 passed；突變測試均被抓到。

## Google 日曆連線（已驗證）

- 店家建立服務帳戶並以「僅查看空閒/忙碌」共用日曆；GOOGLE_SERVICE_ACCOUNT_JSON、GOOGLE_CALENDAR_ID 已存入 Supabase Secrets。
- api Edge Function 已透過 Dashboard 部署（程式取自 GitHub commit 91b0358，SHA-256 一致），Verify JWT 已關閉。
- GET /functions/v1/api/health/calendar 回傳 200 {"ok":true}：金鑰有效、Calendar API 已啟用、日曆已共用。

## 未完成，不能宣稱可供營運


- 20 個 concurrent request 搶最後 1 席的多連線實測（P6）。

- HTTP API（P3 session 後包裝上述 RPC）與 LIFF 畫面。

- 新 GitHub remote、CI 與 migration history 同步。
- LINE Login / LIFF、其餘 P2–P12 功能。

## 已留存證據

- docs/evidence/database-tests.png
- docs/evidence/webhook-deployed.png
- docs/evidence/secret-handoff.png（空白 Value，無秘密值）
- docs/evidence/line-verify-success.png
- docs/evidence/line-webhook-enabled.png
- docs/evidence/live-follow-test.png（只含統計數量，不含 LINE userId）
- docs/evidence/identity-regression-after-p2.jpg、booking-core-tests.jpg、booking-core-post-check.jpg
- docs/evidence/booking-rpc-tests.jpg、booking-rpc-post-check.jpg

目前 Supabase 已連至舊的 cj2vum4/starfishlarp repository；本次沒有修改、推送、
解除連結或更換該 repo。下一階段再處理獨立預約系統的 GitHub 管理方式。
