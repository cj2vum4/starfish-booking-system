# 安全檢查紀錄（P11）

檢查日期：2026-10-03。對象：正式資料庫 starfishlarp、`api` 與 `line-webhook` Edge Functions、LIFF 頁、公開 repo。

## 資料庫

| 項目 | 結果 |
|---|---|
| public 資料表 | 20 張，全部啟用 RLS |
| anon／authenticated 對資料表的權限 | 無 |
| anon／authenticated 可執行的函式 | 僅 Supabase 內建 `rls_auto_enable`（event trigger），0018 已收回。2026-10-11 起另有 pg_net 預設開放給 PUBLIC 的 `net.http_*`（見下方 `/hooks/tick`），不經 Data API 對外 |
| 未固定 search_path 的函式 | 無 |
| 序列對 API 角色開放 | 無 |
| Security Advisor | 0 errors；2 warnings 皆為 `rls_auto_enable`（0018 處理）；20 infos 為「RLS 開啟但無 policy」，屬刻意設計：資料只經後端以 service_role 存取 |

存取模型：瀏覽器不直接連資料庫。所有讀寫經 `api` Edge Function，以伺服器 session 決定操作者（`p_actor`），
再呼叫只授權 service_role 的 RPC；店家權限在資料庫函式內檢查 `admin_users`。

## 身分與 session

- LIFF ID token 由後端向 LINE 驗證（iss、aud、exp、sub），不採信前端傳入的 userId。
- session token 32 bytes 隨機值，資料庫只存 SHA-256，12 小時到期，存在分頁的 sessionStorage。
- 邀請與認領 token 只以 SHA-256 存放；預覽與認領走 POST body，不出現在 API 網址紀錄。

## Webhook 與維護網址

- `line-webhook`：以原始 bytes 驗證 LINE HMAC-SHA256，錯誤簽章 401，事件以 webhookEventId 去重。
- `/hooks/catalog-sync`、`/hooks/richmenu-setup`、`/hooks/selftest-race`：需 `X-Sync-Secret`（雜湊後定時比較）。
  自測只接受測試標記資料（LINE ID `Ufeedfacefeedface…`、劇本 `qa-stress-*`），且不產生通知。
- `/health/calendar` 公開，只回 ok 與錯誤代碼，不回任何行程資料。
- `/hooks/tick`（2026-10-11，0034）：只接受資料庫 pg_cron 每次產生的一次性通行碼（`X-Tick-Token`，64 個十六進位字元，
  兩個 gen_random_uuid 共 244 位元隨機）。資料庫只存 SHA-256，10 分鐘內有效、核銷即刪；格式不符不查資料庫，錯誤或重用回 401。
  通行碼在 pg_net 送出前會短暫（毫秒級）留在 `net.http_request_queue`；就算被拿到，也只能提早觸發本來就會做的工作
  （送出已排隊的通知、取消已過開場時間的揪團），不回傳任何資料。
  0034 是第一次啟用 pg_net：pg_net 安裝時把 `net` schema 的表（佇列與回應）的全部權限、以及 `net.http_get/post/delete` 的執行權
  開放給 PUBLIC（含 anon／authenticated），Supabase 官方說明收回也會被重新授權。目前碰不到的原因是 anon／authenticated 不能直接連資料庫、
  `net` 不在 Data API 的 Exposed schemas。規則：**絕對不要把 `net` 加進 Exposed schemas**；日後若新增可直接登入資料庫的帳號
  （例如唯讀報表帳號），要知道它能讀改 pg_net 佇列並從資料庫發出任意 HTTP 請求。
  排程指令（`cron.job.command`、`cron.job_run_details`）只有 `select public._sf_tick()`，沒有任何密碼。
  發碼與呼叫函式只有 postgres（排程擁有者）能執行；service_role 對 `tick_tokens` 只有 select／delete（0034 先 revoke all，
  避免 Supabase 預設權限讓它能自己寫入通行碼），只能核銷。`tests/tick_schedule.sql` 檢查這些權限。

## 外部資料

- 劇本：GitHub `scripts.js` 只以 JSON 解析，不執行程式碼；固定讀取推送的 commit。
- Google 日曆／Outlook：只存忙碌起訖，不存標題或內容；讀不到時列時段與開團一律拒絕（fail closed）。
  列時段可沿用 60 秒內涵蓋相同區間的同步結果（避免灌請求耗盡 Google 配額）；開團一律即時查詢。
- Google Sheets：2026-10-11 起不再寫入（報表匯出移除），服務帳戶權限降為 `spreadsheets.readonly`，只用來讀店家共用的舊試算表做一次性匯入。

## 角色分配問卷（2026-10-11，0035）

- 回覆含性別、戀愛取向、感情狀況、「同行玩家中你喜歡的人」等敏感個資，存在 `role_survey_responses`：RLS 開啟、
  anon／authenticated 無任何權限；讀、改、刪、匯入只有 `admin_*` RPC，函式內檢查 `admin_users`。
- 網站送出走 `POST /public/role-survey`（不需登入，與原本 Apps Script 相同）：CORS 只回應網站來源；內容在資料庫清理
  （最多 80 題、題目 200 字、答案 5000 字、多選以「, 」串接），只存純文字、畫面一律 `esc()`；蜜罐欄位有值就丟棄；
  10 分鐘內全站超過 200 份暫停收件（429）。
- 稽核只記「哪一筆被改／刪、分配了什麼角色、匯入幾筆」，不記答案內容。店家可刪除單份回覆（玩家要求刪除個資時用）。
- 匯入舊「角色問卷總表」：店家把試算表共用給服務帳戶（檢視者），由店家在 LINE 後台按匯入；不會寫回 Google。

## 管理員 OA（2026-10-11）

- 店家通知可改由第二個 LINE OA 發送（`LINE_ADMIN_CHANNEL_ACCESS_TOKEN`）。兩個 OA 的 Messaging API channel 須在同一個
  Provider，同一人的 LINE user ID 才相同；不同時管理員 OA 推不到（400/403/404），系統自動改用玩家 OA 送給**同一個** user ID，
  不會送到別人。店家後台「LINE 通知」以 LINE profile API 檢查兩個 OA 是否傳得到自己。
- Outlook 已發布行事曆網址等同讀取權限，只存放在 Supabase Secrets（`BUSY_ICS_URLS`）。

## 老玩家綁定與點數

- 綁定只能選網站點數總覽裡已存在的名字；每個名字只能綁一個 LINE（資料庫唯一索引），須由店家核准。
- 回歸禮由網站 Apps Script 發放：預約系統以 `PLAY_RECORD_SECRET`（= Apps Script 指令碼屬性 `BOOKING_SECRET`）呼叫，
  Apps Script 以鎖避免同時重算、以去重鍵確保每個名字只發一次，並檢查「回歸禮資格日」。密碼只存在兩邊的 Secrets，不經前端。
- 會員卡只顯示自己已核准綁定的名字；名字清單只回傳網站榮譽牆本來就公開的名字、探員編號與場次，不回傳別人的點數。

## 前端

- 所有使用者輸入與 LINE 暱稱以 `esc()` 輸出，不以 HTML 解讀；`tests/liff.test.mjs` 檢查頁面程式可解析且只載入 LINE SDK 與自身設定。
- API 的 CORS 只允許 `https://cj2vum4.github.io`。

## 公開 repo

- 追蹤檔案與完整歷史掃描：無 JWT、Supabase secret key、私鑰、GitHub token、Outlook 發布網址、真實 LINE userId。
- `.env.sync-secret` 只在本機且被 git 忽略；`docs/evidence`、`docs/backups` 不上傳。

## 已知限制與建議

- 沒有每位使用者的請求頻率限制；目前以 Google 同步快取降低影響。若日後流量大，可在 Supabase 前加 rate limit。
- 通知只送得到已加海星 OA 好友的玩家（LINE 規定）。因此開團、加入、認領位子必須是好友：
  前端先問 `liff.getFriendship()`；後端也擋，資料庫沒有好友紀錄時即時呼叫 LINE profile API 確認（404 → `NOT_FRIEND`）。
  LINE 暫時連不上時放行，不讓 LINE 故障擋住預約。
- 正式營運前建議：Supabase 專案開啟 Point-in-Time Recovery 或定期備份；Supabase 帳號與 GitHub 帳號啟用兩步驟驗證。
