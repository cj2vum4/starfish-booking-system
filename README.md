# 海星劇本殺預約系統

本專案依《Starfish LINE OA 預約系統建置手冊 v1.0》建置。
第一階段提供 LINE 好友身分入庫；開團、預約、LIFF 與付款尚未實作。

## 已確認資源

- LINE OA：海星劇本殺，`@825gdzws`。
- Messaging API Channel ID：`2011834134`。
- Supabase 專案：`starfishlarp`，ref `qrcpmxejhqrvvpnjehri`，東京區域。
- 現有 Supabase GitHub integration 指向 `cj2vum4/starfishlarp`；本次未修改該 repository。
- 本專案在本機獨立保存，尚未建立新的 GitHub remote。

## 程式結構

- `supabase/migrations/202610020001_line_identity.sql`：users、players、line_webhook_events 及批次交易 RPC。
- `supabase/functions/line-webhook/index.ts`：無第三方 runtime 套件的 webhook。
- `tests/webhook.test.mjs`：Node 24 原生測試。
- `supabase/migrations/202610020002_booking_core.sql`：開團、場次、預約、多人代報、付款、邀請、通知、稽核等核心表與席位 trigger。
- `supabase/migrations/202610020003_booking_rpc.sql`：開團、邀請、認領、加入、成場、多人預約、取消 RPC（僅 service_role）。
- `tests/database.sql`、`tests/booking_core.sql`、`tests/booking_rpc.sql`：實際 Postgres 行為與權限測試；以 ROLLBACK 結束。
- `tests/database.test.mjs`：以 PGlite 在本機套用所有 migration 並執行上述 SQL 測試。
- `.env.example`：只有變數名稱，不放秘密值。

## 驗證方式

```sh
npm test
```

`npm test` 已包含本機 PGlite 資料庫測試。雲端驗收時在 Supabase SQL Editor 依序執行 `tests/database.sql`、`tests/booking_core.sql` 與 `tests/booking_rpc.sql`。必須出現 PASS；
所有測試身分與事件在同一筆交易內建立，結束後回滾。

## Webhook 設計

1. 只接受 POST，限制 request body 為 1 MiB。
2. 使用原始 bytes 和 LINE Channel Secret 驗證 HMAC-SHA256；缺少或錯誤簽章回傳 401。
3. 支援 LINE 空 events 的驗證請求與一次多個 follow/unfollow。
4. 同一交易記錄 webhookEventId 並 upsert users，失敗時整批回滾。
5. 事件依 timestamp（同時刻再依 event ID）決定新舊，避免舊重送覆蓋新狀態。
6. 封鎖不刪玩家；重新加好友恢復 active。
7. 不保存聊天文字、reply token 或完整 webhook payload。
8. 三張表均啟用 RLS；anon/authenticated 無表權限或 ingestion RPC 執行權。
   目前只開放既有 service_role 從 server 端操作。

目前僅追蹤 follow/unfollow，不取得頭像暱稱、不發訊息、不建立玩家遊戲履歷。
`players` 是後續真人玩家／代報模型的基礎，尚不自動認領或綁定。

## LINE 設定

已部署並通過 LINE Verify 的 webhook：
`https://qrcpmxejhqrvvpnjehri.supabase.co/functions/v1/line-webhook`

Supabase Edge Function Secrets 中已由帳號持有人填入 `LINE_CHANNEL_SECRET`。
不需要把它寫入本機檔案或貼到聊天。SUPABASE_URL 和 SUPABASE_SERVICE_ROLE_KEY
由 Supabase runtime 提供，不應放到網站前端。

LINE webhook 使用 HMAC 驗證；不會附 Supabase JWT。
`config.toml` 因此設 `verify_jwt = false`，雲端設定已同步。
LINE Console 的 Use webhook 與 redelivery 已開啟，Verify 顯示 Success。
真實手機封鎖／解除封鎖入庫測試已通過：1 筆 users、active 狀態，
follow/unfollow 各 1 筆，詳見 docs/PROGRESS.md。

## 部署與恢復

首次 migration 已透過 Dashboard 手動套用；CLI migration history 尚未同步，
未來改用 CLI 前必須先核對並修復 migration history，不能直接重跑 CREATE TABLE。
每次修改應新增 migration，不覆蓋已套用檔案。

目前尚未開始正式收玩家資料。若需暫停 webhook，先在 LINE Console 關閉 Use webhook；
保留資料表與事件紀錄。恢復函式可重新部署本機保存的上一版本，勿刪玩家資料。

## 接續工作

1. LINE 身分入庫階段已完成實機驗收；保留真實玩家資料，後續以新增 migration 擴充。
2. LINE Login Channel 必須與 Messaging API 在同一個 Provider，建立 LIFF。
3. 開團、加入、預約、取消 RPC 已套用雲端並通過驗收。業務錯誤以 P0001 + 固定代碼回傳，API 對應：
   `*_NOT_FOUND`→404、`SOLD_OUT`/`GROUP_FULL`/`ALREADY_*`/`INVITE_USED`→409、`NOT_ADMIN`→403、其餘→400。
4. LIFF server token 驗證與 session；再建立開團、加入、預約及通知介面。
5. 建立獨立 GitHub repo／部署流程，再處理現有 GitHub integration 的歸屬。

參考：
- https://developers.line.biz/en/docs/messaging-api/verify-webhook-signature/
- https://developers.line.biz/en/docs/messaging-api/receiving-messages/
- https://supabase.com/docs/guides/functions/quickstart-dashboard
- https://supabase.com/docs/guides/functions/secrets
