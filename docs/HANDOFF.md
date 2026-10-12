# 交接文件：海星劇本殺 LINE 預約系統

最後更新：2026-10-12（GAS 第 0／1 階段已部署、第 2 階段玩本記錄搬家程式完成；2026-10-05 之後的變動以 `docs/PROGRESS.md` 最上方為準，GAS 移除計畫見 `docs/GAS_MIGRATION.md`）。這份文件給接手的工程師／AI（例如 Codex）。先讀完這份，再看
`docs/PROGRESS.md`（逐階段施工紀錄）、`docs/SECURITY.md`（安全設計）、`docs/PLAYER_GUIDE.md`（玩家說明）。

店家（帳號持有人）只講中文，回覆請用繁體中文、白話、少術語。

---

## 1. 系統一覽

```
玩家 LINE ──► 海星 OA @825gdzws（圖文選單：新玩家／老玩家兩組）
                │
                ├─ LIFF 預約頁（GitHub Pages）  web/liff/index.html
                │     └─► Supabase Edge Function `api`  ──► Postgres（RPC，僅 service_role）
                │                                      ├─► Google Calendar（忙碌時段、寫入成團行程）
                │                                      ├─► Outlook 發布的 .ics（忙碌時段）
                │                                      ├─► Google Sheets（唯讀：一次性匯入店家共用的舊試算表）
                │                                      ├─► LINE Messaging API：玩家 OA（推播、圖文選單）＋管理員 OA（店家通知）
                │                                      └─► 網站 Apps Script（玩本記錄點數、回歸禮）
                └─ LINE webhook ──► Edge Function `line-webhook`（好友加入／封鎖入庫；玩家私訊提醒店家 LINE）

Postgres pg_cron（每 5 分鐘 `starfish-tick`）──pg_net──► api POST /hooks/tick（一次性通行碼）
                                                   └─ 取消過期揪團、分批重送待送／失敗的 LINE 通知

海星網站 cj2vum4/starfishlarp（GitHub Pages）
  ├─ scripts.js（劇本資料唯一來源）──push──► GitHub Action ──► api /hooks/catalog-sync
  ├─ 劇本頁最下方 CTA → LIFF 開團頁 `?view=create&game=<scripts.js id>`（2026-10-11 起；booking.js 浮動按鈕已於 10-06 移除）
  └─ GoogleAppsScript_玩本記錄.gs（手動部署到 Apps Script）：玩本記錄、集點、榮譽牆資料、回歸禮
       └─ 每次重算 → POST api /hooks/records-changed → api 更新 play_record_snapshot
          網站（points.js／reviews.js／play-record.js）與 LINE 會員卡讀 api GET /public/records（約 0.3 秒），讀不到才走 Apps Script
  第 2 階段（0036，2026-10-12）：玩本記錄與點數搬進 Postgres，由 record_state.source 切換（'gas'｜'supabase'）
       網站一律先問 api（/public/play-records、/public/likes、/public/records）；切換前 api 回 503 {live:false}，網站照舊走 Apps Script／CSV
       店家在 LIFF「玩本記錄與點數（搬家）」匯入 → 對帳 → 切換（docs/GAS_MIGRATION.md）
```

### 兩個 repo

| Repo | 本機路徑 | 用途 | 推送習慣 |
|---|---|---|---|
| `cj2vum4/starfish-booking-system`（公開） | `C:\Users\Michael.Huang\Desktop\line oa\starfish-booking-system` | 預約系統：migrations、Edge Functions、LIFF 頁、測試、文件 | 英文 commit；push main 即自動部署 LIFF 頁（`.github/workflows/pages.yml`） |
| `cj2vum4/starfishlarp`（公開） | `C:\Users\Michael.Huang\Desktop\starfishlarp`（**落後遠端很多，先 pull**） | 海星官網、劇本頁、榮譽牆、玩本記錄、Apps Script 原始碼 | 直接 push main，中文 `feat:`／`fix:` commit；推之前跑 `bash tests/run.sh`；有自己的 `AGENTS.md`／`CLAUDE.md` |

注意：starfishlarp 同時有其他 AI session 在改（例如 2026-10-05 的「每月任務」commit），推之前一定 `git pull --rebase`。

### 重要 ID（都不是秘密）

| 項目 | 值 |
|---|---|
| LINE OA | 海星劇本殺 `@825gdzws`；Messaging API channel `2011834134` |
| LINE Login channel | `2011840025`（Published）；LIFF ID `2011840025-6cuU9x8P`；Provider「劇本殺玩家通知」`2005594335` |
| LIFF 頁 | `https://cj2vum4.github.io/starfish-booking-system/` |
| Supabase 專案 | `starfishlarp`，ref `qrcpmxejhqrvvpnjehri`（東京） |
| API | `https://qrcpmxejhqrvvpnjehri.supabase.co/functions/v1/api` |
| Webhook | `https://qrcpmxejhqrvvpnjehri.supabase.co/functions/v1/line-webhook` |
| Google 服務帳戶 | `starfish-freebusy@larpyoutube.iam.gserviceaccount.com`（專案 `larpyoutube`） |
| 玩本記錄 Apps Script | `https://script.google.com/macros/s/AKfycbz2jFZhU9tSm-WvZaC_lLSovG2zy3Up2-HNlK6sO6xyfnFDQu8DxRUIKmhDBg1AHMDsDg/exec` |
| 玩本記錄試算表 | `1hjdPJQo5Z6nVICZsvljihSXoZAJ32DpiAEQikCaog-8` |
| 角色問卷總表（舊，過渡期備援） | `1NrmyrSq3UqoU0m-2JWVJsvF18VKwW18n-P-w-iyYb5M`；Apps Script `…/AKfycbx5Fyc528P0kL6sdNAdNcYElbQj8xhJb7dkIm0khATVeRizzouNcI04MGhcrmBUxiHM/exec`（starfishlarp `survey.js` 的 `LEGACY_ENDPOINT`，清空前不可停用） |
| 角色問卷網站送出 | starfishlarp `survey.js` → api `POST /public/role-survey`；問卷頁 `問卷/<劇本>.html`，`script` 必須＝reviewKey |
| 管理員 OA | 待店家提供 ID（須與玩家 OA 同一個 Provider 2005594335） |
| 圖文選單 | 新玩家 `richmenu-c3b5b2e5a18ccb4f3f35cdadb858d217`（預設）；老玩家 `richmenu-2f2565347ba9fde8a7184f4a53a38072`（2026-10-06 第二次重建） |

---

## 2. 秘密（只列名稱；值絕不寫進檔案、commit 或對話）

| 名稱 | 存放位置 | 用途 |
|---|---|---|
| `LINE_CHANNEL_SECRET` | Supabase Edge Function Secrets | webhook HMAC 驗證 |
| `LINE_CHANNEL_ACCESS_TOKEN` | Supabase Secrets | 玩家 OA：推播、圖文選單、好友即時確認 |
| `LINE_ADMIN_CHANNEL_ACCESS_TOKEN` | Supabase Secrets（api 與 line-webhook 都要讀到） | 管理員 OA：店家通知（新揪團、滿團、綁定申請、玩家私訊提醒）。沒設定或傳不到時改由玩家 OA 送出 |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Supabase Secrets | Calendar；唯讀讀取店家共用的試算表（一次性匯入） |
| `GOOGLE_CALENDAR_ID`、`GOOGLE_EVENTS_CALENDAR_ID` | Supabase Secrets | 店家行事曆、成團行程日曆（`GOOGLE_SHEET_ID` 已隨報表匯出移除，可從 Secrets 刪掉） |
| `BUSY_ICS_URLS` | Supabase Secrets | Outlook 發布網址（等同讀取權限） |
| `CATALOG_SYNC_SECRET` | Supabase Secrets ＝ starfishlarp GitHub Secret `BOOKING_SYNC_SECRET` ＝ 本機 `.env.sync-secret` | 維護用 hooks（劇本同步、圖文選單、壓測） |
| `PLAY_RECORD_SECRET` | Supabase Secrets ＝ Apps Script 指令碼屬性 `BOOKING_SECRET` ＝ 本機 `.env.play-record-secret` | 回歸禮 |
| `LINE_LOGIN_CHANNEL_ID`、`LIFF_ID`、`ALLOWED_ORIGINS` | Supabase Secrets | 非秘密設定 |

- 本機 `.env.*` 已被 `.gitignore` 忽略。**不要印出檔案內容**（2026-10-05 曾不慎印出舊維護密碼，已全部輪替）。
  用法範例：`curl -H "X-Sync-Secret: $(tr -d '\r\n' < .env.sync-secret)" ...`
- 秘密由店家本人貼到 Supabase／GitHub／Apps Script。要換密碼：產生新值寫進本機檔案（不顯示），請店家貼到兩邊，再實測新的可用、舊的被拒。

---

## 3. 現況（2026-10-05）

### 已上線並驗收
- 好友入庫（webhook）、LIFF 登入、伺服器 session。
- 開團（人數 → 劇本〔依人數與標籤篩選、玩過的排後〕→ 時間（一次一個月，最遠 6 個月）→ 場地〔南港／北車／新竹交大／自選〕→ 備註／公開或私人）；分享到 LINE 或複製邀請訊息（日期、時間、劇本、價格、人數、地址與導航、劇本介紹、影片、邀請連結；地址對照在 LIFF 的 `VENUE_INFO`）、邀請連結、幫朋友保留與認領、加入、退出、解散。
- 可預約時段：週一二四五 19–24、週六 9–24、週日 13–24（台北），最遠 6 個月；同一時間只能一場；扣除店家 Google 日曆與 Outlook .ics 忙碌；讀不到日曆一律不給時段。
- 店家確認成團（價格預設 400、場地下拉：南港／北車／新竹交大／自選、DM 預設海星）並寫入 Google 日曆；取消已成團場次；記錄出席 → 玩家遊戲紀錄。
- LINE 通知（新揪團、有人加入、滿團〔全員〕、成團、取消、解散、綁定申請／結果），outbox＋重試；只送得到 OA 好友。
- 開團／加入／認領必須是 OA 好友（前端面板＋後端即時問 LINE）。
- 缺人場次（公開揪團）、主揪可切換公開／私人。
- 店家後台、安全檢查（docs/SECURITY.md）。Google Sheets 報表匯出店家沒在用，2026-10-11 移除（後台直接看場次）。
- 劇本自動同步（starfishlarp scripts.js push → hook）。
- **圖文選單 v2**：新玩家（認識海星、劇本介紹、劇本預約、缺人場次、新手指南、我是老玩家）／老玩家（劇本預約、缺人場次、玩本記錄、會員卡・兌換、劇本介紹、榮譽牆）。有出席紀錄或綁定核准的玩家自動換老玩家選單。
- **網站預約入口**：2026-10-06 starfishlarp 移除劇本頁「📅 預約這本」浮動按鈕與 booking.js；2026-10-11 店家同意後，57 頁最下方 CTA 改連 `https://liff.line.me/2011840025-6cuU9x8P?view=create&game=<id>`，直接打開開團頁並選好劇本（該 repo CLAUDE.md 規定不要再加預約浮動按鈕；`tests/cta.test.js` 檢查每頁連結）。
- **第 2 階段：老玩家綁定＋50 點回歸禮＋會員卡**。綁定只能選點數總覽裡的名字、一名一 LINE、店家核准；回歸禮由 Apps Script 發（每名一次、資格日 2026/10/06 前加入、重算不消失）。
- 2026-10-05 店家回報「老玩家綁定 LINE OA 已測試成功」；50 點實際入帳、會員卡餘額與老玩家選單切換尚未在本次回報中逐項確認。
- LINE Login channel 2011840025：Add friend option 已確認為 On (aggressive)，Linked OA 原本空白，已儲存為 @825gdzws／海星劇本殺（依聊天「Update aggressive channel option」完成紀錄）。
- 玩本記錄點數總覽：Apps Script 端 10 分鐘快取（重算即清）；預約系統另存資料庫副本 `play_record_snapshot`；榮譽牆逾時重試。部署後實測讀取 1–1.8 秒。

### 線上資料（2026-10-05 先前查詢快照，早於本次綁定成功回報）
- 使用者 4 位（OA 好友 active 2、unknown 2）；揪團招募中 3 團（其中 10/4 16:00 那團已過時間仍顯示招募中，見待辦 2）；尚無成團場次；綁定申請 0 筆。
- 通知全部送達、無失敗（新揪團 1、加入 3、解散 2）。
- 點數總覽 53 位玩家、9 項獎勵。

### 測試
- 預約系統：`npm test`（Node 24；含 PGlite 跑全部 migration 與 tests/*.sql）→ **92 passed**。
- 網站：`bash tests/run.sh`（starfishlarp）→ **172 passed**（前端 playwright 測試未安裝時自動跳過）。
- 雲端：每個 migration 套用後，在 SQL Editor 跑對應 `tests/*.sql`，必須 PASS（測試資料全部 ROLLBACK）。

---

## 4. 待辦（依優先順序）

1. **真人實測**（不能用合成測試代替）：
   - 老玩家綁定與回歸禮、各類 LINE 通知：2026-10-06 店家回報真人實測皆正常（已結案）。若審核頁出現 `BONUS_SECRET_MISMATCH`，代表 Supabase 的 `PLAY_RECORD_SECRET` 與 Apps Script `BOOKING_SECRET` 不一致。測完不想領點：帳本那列狀態改「作廢」並重算。
   - LINE 外的一般瀏覽器登入、session 過期自動重登（P3）。
2. **過期揪團（2026-10-06 店家定案並上線）**：開場時間到了仍未成團（招募中／待店家確認）→ 直接取消，不發 LINE 通知。由 api 在讀取或操作揪團前呼叫 `expire_stale_groups()`（0029），不需排程。
3. **玩本心得一律走網站玩後問卷（2026-10-06 店家定案）**：曾在 LINE 做過心得表單與補登（0025／0026），
   店家判定與網站問卷重疊、又沒有各劇本的角色選單，已由 0027 移除，**不要再在 LINE 做填寫或補登**。
   - 店家劇本結束後現場給玩後問卷 QR code；LINE **不發**玩後通知（0028 移除出席觸發的提醒）。老玩家圖文選單第 3 格「玩後問卷」直接開網站 `新增玩本記錄.html`。
   - 補登規則：試算表「設定」`LINE上線日`＝2026/10/06、`補登寬限天數`＝7（未列出時預設 7）。上線日後送出、且送出日比遊玩日晚超過 7 個日曆天 → 只記錄 0 點，不佔首探／新手好運／介紹人／互動點數；上線日前的紀錄不受影響。
   - 保留：`line_record_accounts`（已有 1 筆由舊流程建立的歸戶名，會員卡會讀）。Apps Script 已移除 `line_record`；試算表的「LINE身分」分頁是舊流程留下的，可保留或刪除。
   - 會員卡：有存檔副本就先顯示並標「點數更新中」，背景再讀 Apps Script（Apps Script 讀取實測 2–60 秒）。
4. LIFF 加好友設定已完成：依 2026-10-05 聊天「Update aggressive channel option」紀錄，Add friend option 為 On (aggressive)，Linked OA 已儲存為 @825gdzws；不再列為待設定。
5. P12 試營運：20–50 位真人、10 團、5 場成團；招募文案與說明在 `docs/PLAYER_GUIDE.md`（2026-10-06 已補上新舊選單、玩後問卷、7 天補登、老玩家綁定與會員卡、過期揪團）。
6. 已知限制：沒有每位使用者的請求頻率限制；Supabase CLI migration history 未同步（見第 5 節）。
7. **同一天不接不同地區（2026-10-11 店家定案，尚未做進系統）**：只有一位主持人；南港與台北車站同一天可以，新竹交大不能和台北的場次同一天。
   目前場地在選時間之後才選，且成團前可改；實作時需在開團、改場地、店家確認成團三處檢查同日其他場次的地區。
8. LINE 訊息額度：兩個 OA 各自是輕用量（每月各 200 則）。玩家 OA：每月最多成團 4 場約 72 則；管理員 OA：新揪團、滿團、綁定申請、
   玩家私訊提醒。管理員 OA 用完時會改由玩家 OA 送出（占用玩家 OA 額度）。新增任何推播（例如開場前提醒）前先估算。
9. （已修，2026-10-11）《天才在左我在右》的「線上遊玩入口」原本固定在右下角，會蓋住預約與玩家評價按鈕；已移進內容、放在預約按鈕上方。

---

## 5. 部署方式與注意事項

### 資料庫 migration
- **一律新增檔案**（`supabase/migrations/YYYYMMDDNNNN_name.sql`，以 `begin; … commit;` 包住），不改已套用的檔案。
- 0001–0033 在 **Supabase Dashboard SQL Editor 手動套用**；0034、0035 於 2026-10-12 由 Claude 透過 Supabase 連接器（MCP `execute_sql`）套用（含 `delete` 的那段需店家在 SQL Editor 補）。0036 尚未套用。CLI 的 migration history 是空的：
  若改用 `supabase db push`，必須先 `supabase migration repair --status applied <每個版本>`，否則會重跑 CREATE 而失敗。
- **新資料表要明確授權**：`grant select,insert,update,delete on public.<table> to service_role;`
  （Supabase 新表不再預設授權 service_role；`tests/database.test.mjs` 已模擬這個行為，漏了會在本機測試失敗。）
- 新表一律 `enable row level security` 並 `revoke all … from public,anon,authenticated`；RPC 只 `grant execute … to service_role`。
- 業務錯誤用 `raise exception 'CODE'`（P0001 + 大寫代碼），API `statusForCode` 對應 HTTP 狀態，LIFF `ERRORS` 對應中文訊息。三處要一起加。
- 每個 migration 配一份 `tests/<name>.sql`（以 rollback 結束），並登記到 `tests/database.test.mjs` 的清單。

### 定時排程（0034，2026-10-11）
- pg_cron 工作 `starfish-tick`（`*/5 * * * *`）執行 `public._sf_tick()`：產生一次性通行碼（只存 SHA-256、10 分鐘有效），
  以 pg_net 呼叫 `https://qrcpmxejhqrvvpnjehri.supabase.co/functions/v1/api/hooks/tick`（網址寫在函式裡，換專案要改）。
  api 以 `consume_tick_token` 核銷後回 202，背景執行 `runScheduledWork`。排程指令裡沒有密碼，不必放 Vault。
- `starfish-tick-cleanup` 每天台北 03:17 刪除本專案工作 7 天前的 `cron.job_run_details`（pg_cron 不會自己清）。
- 檢查：Dashboard → Integrations → Cron；或 `select * from cron.job_run_details order by start_time desc limit 5;`、
  `select status_code, timed_out, error_msg, created from net._http_response order by created desc limit 5;`（回應保留約 6 小時）。
- 停用：`select cron.unschedule('starfish-tick'); select cron.unschedule('starfish-tick-cleanup');`。
- 恢復：只在 SQL Editor 執行 migration 最後那兩行 `cron.schedule(...)`（同名會更新、不會重複）。
  **不要重跑整個 0034**：`create table tick_tokens` 會報 42P07 而整批回滾，排程也不會建立。
- 啟用 pg_net 後，`net` schema 的表與 `net.http_*` 函式依 pg_net 預設開放給 PUBLIC（含 anon／authenticated）；因為 `net` 不在 Data API 的 Exposed schemas、這兩個角色也不能直接連資料庫，所以外部碰不到。**絕對不要把 `net` 加進 Exposed schemas**（見 SECURITY.md）。
- 本機 PGlite 沒有 pg_cron／pg_net：migration 會略過排程（NOTICE），`tests/tick_schedule.sql` 只在雲端檢查排程是否存在。

### 2026-10-08 成團日曆修正
- 0032 已套用並通過 tests/confirm_calendar_recheck.sql 雲端回滾驗收；確認成團前即時查完整時段，資料庫檢查同長／縮短／延長的整段撞期。
- 新 RPC：admin_group_confirmation_window、admin_confirm_group_event_checked，只授權 service_role；已確認重送不再讀 free/busy。
- API 已部署；精確 release LF SHA-256：2dd7839d94fbc9a8795eaa7cc8c5b5fd1b53aa0494e6d97b784de4d206ab456e。
- 注意：雲端原先未包含 HEAD f2e7d3b 的兩處會員頁效能調整，本次只部署成團修正，因此會員差異仍存在。本機精確 release：docs/backups/api-confirm-recheck-release.ts，前版：api-before-confirm-recheck-cloud.ts；皆為本機忽略檔。未來部署完整主 source 時會一併帶上會員調整。

### Edge Function `api`
- 單一檔案 `supabase/functions/api/index.ts`，無外部相依，可直接在 Node 24 測試（`handleApi(req, settings)`）。`verify_jwt` 關閉（自己驗 session）。
- 部署：目前是在 Dashboard → Edge Functions → api → Code，把 GitHub 上該 commit 的檔案貼進編輯器並 Deploy，
  部署前後比對 SHA-256（以 LF 換行計算）確認雲端與 GitHub 一致。也可改用 `supabase functions deploy api --no-verify-jwt`。
- 2026-10-12 起也可由 Claude 透過 Supabase 連接器部署（MCP `deploy_edge_function`，`verify_jwt:false`）。
  api 已超過 110 KB，整份貼進一次工具呼叫會被截斷（v43 就是這樣壞掉、約 1 分鐘、期間沒有請求），所以改部署一行「入口檔」：
  `import 'https://raw.githubusercontent.com/cj2vum4/starfish-booking-system/<完整 commit>/supabase/functions/api/index.ts';`
  （repo 公開；commit 網址內容永遠不變；部署時 Supabase 把它打包進去，執行時不依賴 GitHub）。
  部署前先 `curl` 這個網址，和本機檔案比對 SHA-256；部署後用 pg_net 從資料庫打 `/public/records`、`/me` 確認活著。
  目前雲端：api v44＝`038058a` 的 index.ts（c7da505d…），line-webhook v14＝`630b995`。
  Dashboard 手動貼整份檔案的方式仍然可用。
- 連接器的 `execute_sql` 遇到含 `delete`／某些修改的 SQL 會要求店家在 Claude App 按確認，60 秒內沒按就逾時（資料庫會整批回滾，不會半套）；
  這類 SQL 改請店家在 SQL Editor 貼上執行。整份測試 SQL（`tests/*.sql`）同理。
- 成功的 POST（`/hooks/*`、`/public/*` 除外）結束後會在背景送通知；另外每 5 分鐘的排程也會送（0034）。

### LIFF 頁
- `web/liff/index.html` 單頁應用，所有輸出經 `esc()`。push main 即由 GitHub Actions 發布。
- `tests/liff.test.mjs` 檢查頁面腳本可解析、只載入 LINE SDK 與 config.js、每個圖文選單 `?view=` 都有對應路由。
- Rich Menu 網址參數：`?view=open|create|history|guide|veteran|card|bindings|survey|surveys`（bindings、surveys 只限店家）、`?game=<scripts.js id>`、`?invite=`、`?group=`。

### 圖文選單
- 圖片：`python scripts/richmenu_image.py web/liff <starfishlarp>/pwa/icon-512.png` → `richmenu-new.jpg`、`richmenu-member.jpg`（2500×1686）。
- 格子順序與連結在 `richMenuDefinition()`；改完先 push（等 Pages 上線），再 `POST /hooks/richmenu-setup`（帶 `X-Sync-Secret`）。會建立兩組選單、設新玩家為預設、連結老玩家、刪除舊版。

### 網站 Apps Script
- 原始碼在 starfishlarp `GoogleAppsScript_玩本記錄.gs`；**push 不會自動部署**。店家需：貼上新版 Code.gs → 部署 → 管理部署作業 → 鉛筆 → 新版本 → 部署（不可「新增部署作業」，網址會變）。
- 改之前讀 `tests/README.md`，改完跑 `bash tests/run.sh`。

### 其他
- Windows 環境：Python 寫檔要 `newline='\n'`（starfishlarp 的 .gs 是 CRLF，維持原樣）；比對雜湊前先轉 LF。
- 自測資料標記：LINE ID `Ufeedfacefeedface…`、劇本 slug `qa-stress-*`；這些不產生通知、不進報表與選單。
- 店家權限：`admin_users` 表；授權新店家帳號請店家本人在 SQL Editor 執行。

---

## 6. API 一覽

玩家（需 session）：`POST /auth/line`、`GET /me`、`POST /auth/logout`、`GET /slots?days&minutes`、`POST /groups`、
`GET /games`、`GET /me/groups`、`GET /me/history`、`GET /groups/public`、`GET|POST /groups/:id[/share-link|reserve|join|cancel|visibility|played]`、
`POST /seats/:id/leave`、`POST /invites/preview|claim`、`GET /records/names`、`GET|POST /me/binding`。

店家（session＋admin）：`GET /admin/groups`、`POST /admin/groups/:id/confirm`、`POST /admin/events/:id/cancel|calendar|complete`、
`GET /admin/events/:id/participants`、`GET /admin/report`、`GET /admin/google-account`、`GET /admin/line-health`、
`POST /admin/games/sync`、`GET /admin/bindings`、`POST /admin/bindings/:userId/approve|reject|bonus`、
`GET /admin/role-surveys`、`GET /admin/role-surveys/responses?script=&before=`、`POST /admin/role-surveys/responses/:id[/delete]`、
`POST /admin/role-surveys/import`（服務帳戶唯讀讀「角色問卷總表」）。

維護（`X-Sync-Secret`）：`POST /hooks/catalog-sync`、`/hooks/richmenu-setup`、`/hooks/selftest-race`。

排程（`X-Tick-Token`，資料庫每次產生的一次性通行碼）：`POST /hooks/tick`，回 202 後在背景取消過期揪團、分批送通知。

公開健康檢查（只回狀態與代碼）：`GET /health/calendar`、`GET /health/records`。

網站角色問卷（公開，CORS 只限網站來源）：`POST /public/role-survey`（text/plain JSON，蜜罐欄位 `website`）。

公開資料：`GET /public/records`（點數總覽：切換前是 Apps Script 的副本，切換後由資料庫產生；任何來源可讀，快取 30 秒）。Apps Script 專用：`POST /hooks/records-changed`（`X-Play-Record-Secret`）。

網站玩本記錄（第 2 階段，公開、任何來源；切換前回 503 `{live:false,error:'RECORDS_NOT_LIVE'}`）：`POST /public/play-records`（text/plain JSON，`id`＝送出編號、蜜罐 `website`）、
`POST /public/likes`（`liker`＝瀏覽器編號）、`GET /public/play-records?script=`（心得清單，快取 30 秒）。
切換後資料庫出錯回 503 `RECORDS_UNAVAILABLE`（不帶 `live:false`，網站不會改用舊資料）；只有函式不存在（0036 未套用，PostgREST 404）才當作還沒切換。
`GET /public/records` 的回應帶 `live`（true＝資料庫算的、false＝Apps Script 副本）。排程每 10 分鐘補匯入（`records-catch-up`），結果存在 `record_state.catch_up_*`。

店家玩本記錄搬家（session＋admin）：`GET /admin/records`、`POST /admin/records/import|import-new`、`GET /admin/records/reconcile`、`POST /admin/records/source`（`{source:'gas'|'supabase', force?}`）。

---

## 7. 和店家合作的原則（這段對話累積的偏好）

- 中文溝通；先給結論，再列步驟；需要店家操作的步驟寫清楚點哪裡。
- 秘密只由店家本人輸入；需要時產生在本機檔案讓店家複製。
- 不要在系統內做付款紀錄（P8 店家決定不做）；劇本價格不用做（成團時才填每人費用）。
- 重大設計（選單內容、點數規則、補登規則）先和店家討論再做；店家重視選單六格的內容。
- 每做完一段：本機測試 → 雲端測試 → 部署 → 比對版本 → 更新 `docs/PROGRESS.md` → 回報店家需要實測的項目。
