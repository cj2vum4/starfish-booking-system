# 安全檢查紀錄（P11）

檢查日期：2026-10-03。對象：正式資料庫 starfishlarp、`api` 與 `line-webhook` Edge Functions、LIFF 頁、公開 repo。

## 資料庫

| 項目 | 結果 |
|---|---|
| public 資料表 | 20 張，全部啟用 RLS |
| anon／authenticated 對資料表的權限 | 無 |
| anon／authenticated 可執行的函式 | 僅 Supabase 內建 `rls_auto_enable`（event trigger），0018 已收回 |
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

## 外部資料

- 劇本：GitHub `scripts.js` 只以 JSON 解析，不執行程式碼；固定讀取推送的 commit。
- Google 日曆／Outlook：只存忙碌起訖，不存標題或內容；讀不到時列時段與開團一律拒絕（fail closed）。
  列時段可沿用 60 秒內涵蓋相同區間的同步結果（避免灌請求耗盡 Google 配額）；開團一律即時查詢。
- Google Sheets：以 RAW 寫入，玩家名字不會被當成公式執行。
- Outlook 已發布行事曆網址等同讀取權限，只存放在 Supabase Secrets（`BUSY_ICS_URLS`）。

## 前端

- 所有使用者輸入與 LINE 暱稱以 `esc()` 輸出，不以 HTML 解讀；`tests/liff.test.mjs` 檢查頁面程式可解析且只載入 LINE SDK 與自身設定。
- API 的 CORS 只允許 `https://cj2vum4.github.io`。

## 公開 repo

- 追蹤檔案與完整歷史掃描：無 JWT、Supabase secret key、私鑰、GitHub token、Outlook 發布網址、真實 LINE userId。
- `.env.sync-secret` 只在本機且被 git 忽略；`docs/evidence`、`docs/backups` 不上傳。

## 已知限制與建議

- 沒有每位使用者的請求頻率限制；目前以 Google 同步快取降低影響。若日後流量大，可在 Supabase 前加 rate limit。
- 通知只送得到已加海星 OA 好友的玩家（LINE 規定）。
- 正式營運前建議：Supabase 專案開啟 Point-in-Time Recovery 或定期備份；Supabase 帳號與 GitHub 帳號啟用兩步驟驗證。
