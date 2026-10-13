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
- Google Sheets：2026-10-11 起不再寫入（報表匯出移除），api 向 Google 只申請 `spreadsheets.readonly` 範圍，只讀店家共用的舊試算表做匯入。
  注意：服務帳戶實際能動哪些試算表由 Google 的「共用」決定；舊報表試算表仍共用給服務帳戶（編輯者）的話，請店家移除或改成檢視者，
  角色問卷總表在最後一次匯入後也可移除共用。
- Outlook 已發布行事曆網址等同讀取權限，只存放在 Supabase Secrets（`BUSY_ICS_URLS`）。

## 角色分配問卷（2026-10-11，0035）

- 回覆含性別、戀愛取向、感情狀況、「同行玩家中你喜歡的人」等敏感個資，存在 `role_survey_responses`：RLS 開啟、
  anon／authenticated 無任何權限；讀、改、刪、匯入只有 `admin_*` RPC，函式內檢查 `admin_users`。
- 網站送出走 `POST /public/role-survey`（不需登入，與原本 Apps Script 相同）。這條路由的回應對任何來源開放 CORS：
  簡單 POST 本來就不受 CORS 保護，開放是為了讓送出成功的頁面一定讀得到結果、不會改送舊 Apps Script 造成重複；回應只有 `{ok:true}`。
  防濫用：只收劇本目錄（`games.review_key`）裡有的名稱、單次 16 KB、蜜罐欄位有值就丟棄；全站 10 分鐘 30 份、一天 200 份或 5 MB
  為上限（429，店家實際每月約數十份）。內容在資料庫清理（最多 80 題、題目 200 字、答案 5000 字），只存純文字，畫面一律 `esc()`。
  沒有依 IP 限流（Supabase 前的轉送標頭無法確認來源，未採用），有人刻意灌爆時會暫停收件，需店家刪除垃圾回覆。
- 每次送出帶「送出編號」：同一份重送、或網站改送舊 Apps Script 的副本，都靠它認出是同一份。
- 稽核只記「哪一筆被改／刪、分配了什麼角色、匯入幾筆」，不記答案內容。
- 刪除（玩家要求刪除個資時用）：刪掉回覆並留下不含內容的記號（送出編號／試算表列的雜湊），重送或重新匯入都不會帶回來。
  **舊試算表裡的那一列要店家自己刪**；確認視窗會提醒。
- 過渡期：網站在預約系統連不上時會把回覆送到舊的「角色問卷總表」（Google 試算表，能看到的人以 Google 共用為準，不在 `admin_users`
  控管內）。店家把總表共用給服務帳戶（檢視者）後，api 每 6 小時自動匯入新列（只讀、不寫回 Google）；清空 `survey.js` 的
  `LEGACY_ENDPOINT` 後這條路就關閉。

## 管理員 OA（2026-10-11）

- 店家通知可改由第二個 LINE OA 發送（`LINE_ADMIN_CHANNEL_ACCESS_TOKEN`）。兩個 OA 的 Messaging API channel 須在同一個
  Provider，同一人的 LINE user ID 才相同。管理員 OA 傳不到（不是好友或不同 Provider：400／403／404；token 失效：401；
  每月免費則數用完：429）時，系統改用玩家 OA 送給**同一個** user ID，不會送到別人，並記錄 `VIA_PLAYER_OA_<狀態碼>`。
  店家後台「LINE 通知」以 LINE profile API 檢查兩個 OA 是否傳得到自己。

## 老玩家綁定與點數

- 綁定只能選網站點數總覽裡已存在的名字；每個名字只能綁一個 LINE（資料庫唯一索引），須由店家核准。
- 回歸禮由網站 Apps Script 發放：預約系統以 `PLAY_RECORD_SECRET`（= Apps Script 指令碼屬性 `BOOKING_SECRET`）呼叫，
  Apps Script 以鎖避免同時重算、以去重鍵確保每個名字只發一次，並檢查「回歸禮資格日」。密碼只存在兩邊的 Secrets，不經前端。
- 會員卡只顯示自己已核准綁定的名字；名字清單只回傳網站榮譽牆本來就公開的名字、探員編號與場次，不回傳別人的點數。

## 玩本記錄與點數（2026-10-12，0036）

- 新表 `record_state`、`record_settings`、`record_rewards`、`record_quests`、`record_players`、`record_aliases`、`play_records`、
  `review_interactions`、`review_likes`、`point_ledger` 全部 RLS、anon／authenticated 無權限；內部函式（`_sf_*`，含計分與匯入）
  anon／authenticated 不能呼叫。函式都以呼叫者身分執行（不是 SECURITY DEFINER），所以內部函式要授權給 service_role
  （和以前的 migration 一樣；`tests/play_records.sql` 以 service_role 執行，漏授權會失敗）。店家 RPC（`admin_*`）在函式內檢查 `admin_users`。
- 點數帳本只增不改：觸發器擋住任何修改（只能填作廢欄位，作廢後也不能改回）；刪除只在「從來沒切換過」時的整批重新匯入允許
  （`record_state.went_live_at`，緊急切回也一樣）。
  每件事有去重鍵（例：每月任務＝玩家＋月份＋任務、回歸禮＝玩家），同一件事只會發一次。所有寫帳本的動作先鎖同一列，同時送出不會互相蓋掉。
- 網站公開路由（不需登入，與原本 Apps Script 相同）：`POST /public/play-records`、`POST /public/likes`、`GET /public/play-records`、
  `GET /public/records`，回應對任何來源開放 CORS（簡單請求本來就不受 CORS 保護；開放是為了讓頁面讀得到結果、不會重送到舊 Apps Script）。
  防濫用：單次 8 KB／4 KB；全站 10 分鐘 30 筆、一天 200 筆記錄，按讚每小時 300 個；同一筆送出編號只記一次；同一個瀏覽器編號對同一則心得只算一次讚；
  對不存在的心得按讚會被拒絕（以前也會加點，現在也先查再鎖，亂按不會卡住別人）；介紹人必須是已有玩家（以前亂填也拿點）；
  新送出的記錄劇本必須在劇本目錄、日期不在未來（點數固定、沒有人工重算，否則能用假劇本與未來日期無限拿首探、首玩）；
  送出的回應只有狀態與點數，不帶歸戶名（以前可用別名查出是榜上哪位）；名字去空白、大小寫後撞到既有玩家或別名，
  新玩家在 LINE 取名時會被擋（避免把點數記到別人身上）。沒有依 IP 限流（理由同角色問卷）；按讚與送出不需登入是店家定案，
  有人刻意灌讚最多讓一則心得拿到上限 10 點。
- 公開的心得清單只給榮譽牆本來就公開的欄位（名字、日期、劇本、角色、評價、心得），不給填寫時間與介紹人；點數總覽格式與以前相同。
- 匯入：api 以服務帳戶**唯讀**讀店家共用的「玩本記錄」試算表；只有店家能觸發，切換後不能整批覆蓋（只能補新列）。
- 切換開關只有店家能動（`admin_set_records_source`）；對帳不一致時要店家確認才能強制切換。切換前所有公開寫入一律回 `RECORDS_NOT_LIVE`，不會寫進資料庫。
- 回歸禮切換後由資料庫發放，不再呼叫 Apps Script，也不再需要 `PLAY_RECORD_SECRET`（第 4 階段移除）。
  讀不到切換狀態（資料庫暫時出錯）時一律 503 重試，不猜「還沒切換」——否則回歸禮會送去 Apps Script、新名字會用舊名單判斷。
- 第 3 階段（0039）：店家可隱藏惡意記錄（點數一併作廢、可取消）、作廢任一筆點數、補扣點；每個店家寫入都在函式內檢查 `admin_users`
  並記錄 `audit_logs`。玩家只能申請、取消**自己的**兌換（以 LINE 綁定的名字找玩家；沒綁定回 `BINDING_REQUIRED`），可用點數要扣掉申請中的保留，
  同時最多 5 筆申請中；申請與核准都鎖 `record_state`，不會兩筆同時通過而透支。重送用 `request_key` 只記一次。
- 全站流量上限可被刻意灌滿（之後的送出改走 Apps Script 再補匯入，不會遺失；按讚會失敗）。

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
