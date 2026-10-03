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

## P3 LIFF 登入（已部署）

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

## P3 LIFF 實機登入通過

- LINE Login Channel 2011840025、LIFF 2011840025-6cuU9x8P（Endpoint 為 GitHub Pages），scopes openid、profile。
- Supabase Secrets 新增 LINE_LOGIN_CHANNEL_ID、ALLOWED_ORIGINS（https://cj2vum4.github.io）。
- 線上檢查：未登入 /me 401、允許來源 preflight 204、其他來源 403、偽造 ID token 401。
- 帳號持有人以手機 LINE 開啟 LIFF，顯示「你好」已登入。
- 資料庫：users_total=1（與加好友時同一筆，未重複）、active、暱稱已存、session 12 小時、登入 2 次同一人。
- 證據：docs/evidence/liff-login-live.jpg（本機，只含統計數字）。

## P4 開團畫面（已部署）

- 202610030006_group_views.sql：get_group、list_my_groups、preview_invite、list_active_games；私人團非成員看不到，
  只拿到邀請的人只看到摘要（時間、主揪、人數），看不到座位名字。
- API：GET /games、/me/groups、/groups/:id；POST /groups/:id/share-link、reserve、join、cancel；
  POST /seats/:id/leave；POST /invites/preview、/invites/claim（token 只放在 POST body，不進網址紀錄）。
- LIFF 單頁：首頁、選日期與時間、人數（依劇本限制）、劇本或店家推薦與偏好、備註、公開與否；
  揪團頁座位、分享到 LINE（shareTargetPicker，不可用時改用 line.me 分享）、幫朋友保留位子、退出、解散；邀請落地頁。
- 0006 已套用雲端並 PASS；api 已重新部署（commit e58089a，SHA-256 一致），新路由上線。
- 本機以模擬 LIFF 與 API 逐一操作所有畫面；LINE 暱稱含 HTML 時以純文字顯示。npm test 31 passed。

## 劇本目錄（已部署，57 本已匯入）

- 劇本唯一來源：GitHub cj2vum4/starfishlarp 的 scripts.js（window.SCRIPTS，57 本）。
- 202610030007_game_catalog.sql：admin_sync_games（僅店家、整批驗證、GitHub 移除者只停用不刪除）；
  價格可空（GitHub 無價格），成團時必須填價格（PRICE_REQUIRED）。
- API POST /admin/games/sync：只以 JSON 解析 scripts.js，不執行任何程式碼；人數區間取自 playersLabel（如 7-10人）。
- 開團流程改為：人數 → 該人數可玩的劇本（類型篩選、海報、時長、難度、介紹連結）→ 依劇本時長列出時間 → 備註。
- 長本（如 6 小時）自動只出現在可容納的時段（週末）；店家推薦先保留 4 小時。
- 0007 已上雲；api 已重新部署（commit 732a3fc）。雲端 game_catalog、slots、booking_rpc、group_views 測試均 PASS。
- 雲端測試改為在回滾交易中清空忙碌鏡像並跳過已有場次的日期，真實資料（13 筆忙碌時段、店家的揪團）未受影響。
- 2026-10-03 以 SQL Editor 從 GitHub scripts.js 首次匯入 57 本（與 admin_sync_games 相同的轉換與驗證規則）：
  active 57、範圍人數 2、無海報 5。
- 待辦：店家帳號尚未設為 admin（需店家自行執行 SQL）；設定後可在 LIFF 首頁按「從 GitHub 同步劇本」更新。
- npm test 35 passed；實際 57 本解析全數有效（5 人 6 本、6 人 27 本、7 人 17 本、8 人 6 本、9 人 2 本、10 人 3 本）。

## 劇本自動同步（已啟用並驗證）

- 202610030008_catalog_autosync.sql：system_sync_games（無 LINE 使用者，須帶 40 碼 commit，稽核來源 github:<commit>）。
- API POST /hooks/catalog-sync：以 X-Sync-Secret 比對 CATALOG_SYNC_SECRET（雜湊後定時比較），
  讀取該 commit 的 scripts.js（避免 raw.githubusercontent 對 main 的快取）。
- starfishlarp 新增 .github/workflows/sync-booking-catalog.yml（commit 86fc1b4）：push 到 main 且 scripts.js 變動時觸發。
- 0008 已上雲並 PASS；api 重新部署（commit d6ce3dc）；未設密碼前 hook 回 503（fail closed）。
- 店家已設定 CATALOG_SYNC_SECRET／BOOKING_SYNC_SECRET；2026-10-03 12:53 手動執行 workflow 成功，
  稽核紀錄來源 github:35e0aa4…，同步 57 本、停用 0 本。
- 店家 LINE Login Channel 已 Publish，朋友可開啟邀請連結。

## 店家確認成團與寫入 Google 日曆（已啟用並驗證）

- 202610030009_confirm_and_calendar.sql：確認時依劇本時長延長（須不撞場次與日曆）或縮短保留時段；
  驗證人數、場地、DM、價格；event_calendar_payload、mark_event_calendar_synced、admin_list_groups。
- API：GET /admin/groups、POST /admin/groups/:id/confirm（價格以元輸入）、POST /admin/events/:id/calendar（重試）。
- 先在資料庫成團，再寫 Google 日曆；Google 事件 ID 由場次 ID 推導，重試不重複，409 視為已寫入。
- 只寫入專用店家日曆（GOOGLE_EVENTS_CALENDAR_ID），從不寫入店家主日曆。
- LIFF：店家首頁「近期揪團」、揪團頁「店家確認成團」表單、成團後顯示場地／DM／價格與日曆狀態。
- npm test 41 passed；模擬環境操作含日曆寫入失敗後重試。
- 0009 已上雲；雲端 confirm、booking_rpc、game_catalog、slots 測試 PASS；api 重新部署（commit 6944d8a）。
- 店家已建立「海星劇本殺預約」日曆並設定 GOOGLE_EVENTS_CALENDAR_ID；實測成團後已出現在 Google 日曆。
- 確認成團預設：每人 400 元、DM「海星」、場地下拉（南港／北車／新竹交大／自選場地）。

## Outlook 行事曆忙碌時間（已啟用）

- API 讀取 BUSY_ICS_URLS 內的已發布 .ics（Outlook），與 Google free/busy 合併後寫入忙碌鏡像；只存起訖。
- 規則：BUSY 與 TENTATIVE 視為忙碌；FREE、TRANSPARENT、CANCELLED 略過；展開 DAILY／WEEKLY／MONTHLY／YEARLY
  （INTERVAL、COUNT、UNTIL、BYDAY 含 -1MO、BYMONTHDAY），處理 EXDATE 與 RECURRENCE-ID；不支援的規則 fail closed。
- 下載結果暫存 5 分鐘；讀不到時列時段與開團一律 503。
- 以店家實際 Outlook 檔驗證：224 筆、60 天內 3 筆忙碌，與另一種計算交叉核對一致（未輸出任何行程內容）。
- npm test 47 passed；api 已重新部署（commit 46a8e88），店家已設定 BUSY_ICS_URLS，health 回 publishedCalendars=1。
- Google 預約頁勾選的「日历」即此 Outlook 行事曆；店家決定不需「至少提前 4 小時」。

## 取消已成團的場次（已部署）

- 202610030010_cancel_event.sql：admin_cancel_event（僅店家；場次、揪團、座位、報名、邀請一併取消；時段釋出；
  未付款分攤作廢、已付款回報需退款；可重複呼叫）；取消原因與時間保存；成員仍可看到取消與原因。
- API POST /admin/events/:id/cancel；之後刪除店家日曆上的 Google 行程（404/410 視為已刪除），失敗可由
  POST /admin/events/:id/calendar 重試。
- LIFF：已成團頁「取消這場」（可填原因）、取消後顯示原因與日曆狀態、「重試刪除 Google 日曆行程」。
- 新增 tests/liff.test.mjs：每次 npm test 檢查 LIFF 頁面程式可被解析（本次開發中曾抓到一個換行字元錯誤）。
- npm test 51 passed；0010 已上雲，雲端 cancel_event、group_views、confirm 測試 PASS；api 重新部署（commit 7f9b09c）。

## LINE 通知（程式完成，待發行 Channel access token）

- 202610030011_notifications.sql：outbox——觸發器在同一交易內寫入 notification_logs（成功才通知、失敗不通知）：
  新揪團→店家；有人加入→主揪；滿團→店家；成團→全體成員（場地、DM、價格）；店家取消→全體（含原因）；主揪解散→其他成員。
- claim_notifications（skip locked、2 分鐘鎖定、超過 1 天視為過期不送）、complete_notification（1/2/4/8 分鐘退避、5 次後放棄）。
- API：成功的 POST 之後於背景送出（EdgeRuntime.waitUntil），LINE push 帶 X-Line-Retry-Key 防重複；
  封鎖者不送、4xx 放棄、429/5xx 重試。通知連結 ?group=<id> 直接開啟揪團頁。
- npm test 55 passed。

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
