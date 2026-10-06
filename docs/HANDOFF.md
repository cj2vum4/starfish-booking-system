# 交接文件：海星劇本殺 LINE 預約系統

最後更新：2026-10-05。這份文件給接手的工程師／AI（例如 Codex）。先讀完這份，再看
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
                │                                      ├─► Google Sheets（店家報表匯出）
                │                                      ├─► LINE Messaging API（推播、圖文選單）
                │                                      └─► 網站 Apps Script（玩本記錄點數、回歸禮）
                └─ LINE webhook ──► Edge Function `line-webhook`（好友加入／封鎖入庫）

海星網站 cj2vum4/starfishlarp（GitHub Pages）
  ├─ scripts.js（劇本資料唯一來源）──push──► GitHub Action ──► api /hooks/catalog-sync
  ├─ 劇本頁最下方 CTA → LINE OA（2026-10-06 起 booking.js 已移除，不再直接帶劇本進 LIFF）
  └─ GoogleAppsScript_玩本記錄.gs（手動部署到 Apps Script）：玩本記錄、集點、榮譽牆資料、回歸禮
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
| 圖文選單 | 新玩家 `richmenu-cf8b578ed4a0a9c59899757a90958acd`（預設）；老玩家 `richmenu-8c98d3ab576c7cf76804a81813c41f83` |

---

## 2. 秘密（只列名稱；值絕不寫進檔案、commit 或對話）

| 名稱 | 存放位置 | 用途 |
|---|---|---|
| `LINE_CHANNEL_SECRET` | Supabase Edge Function Secrets | webhook HMAC 驗證 |
| `LINE_CHANNEL_ACCESS_TOKEN` | Supabase Secrets | 推播、圖文選單、好友即時確認 |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Supabase Secrets | Calendar／Sheets |
| `GOOGLE_CALENDAR_ID`、`GOOGLE_EVENTS_CALENDAR_ID`、`GOOGLE_SHEET_ID` | Supabase Secrets | 店家行事曆、成團行程日曆、報表試算表 |
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
- 開團（人數 → 劇本〔依人數與標籤篩選、玩過的排後〕→ 時間 → 備註／公開或私人）、邀請連結、幫朋友保留與認領、加入、退出、解散。
- 可預約時段：週一二四五 19–24、週六 9–24、週日 13–24（台北）；同一時間只能一場；扣除店家 Google 日曆與 Outlook .ics 忙碌；讀不到日曆一律不給時段。
- 店家確認成團（價格預設 400、場地下拉：南港／北車／新竹交大／自選、DM 預設海星）並寫入 Google 日曆；取消已成團場次；記錄出席 → 玩家遊戲紀錄。
- LINE 通知（新揪團、有人加入、滿團〔全員〕、成團、取消、解散、綁定申請／結果），outbox＋重試；只送得到 OA 好友。
- 開團／加入／認領必須是 OA 好友（前端面板＋後端即時問 LINE）。
- 缺人場次（公開揪團）、主揪可切換公開／私人。
- 店家後台、Google Sheets 匯出、安全檢查（docs/SECURITY.md）。
- 劇本自動同步（starfishlarp scripts.js push → hook）。
- **圖文選單 v2**：新玩家（認識海星、劇本介紹、劇本預約、缺人場次、新手指南、我是老玩家）／老玩家（劇本預約、缺人場次、玩本記錄、會員卡・兌換、劇本介紹、榮譽牆）。有出席紀錄或綁定核准的玩家自動換老玩家選單。
- **網站預約入口**：2026-10-06 starfishlarp 移除劇本頁「📅 預約這本」浮動按鈕與 booking.js，57 頁最下方 CTA 一律連 LINE OA（該 repo CLAUDE.md 規定不要再加預約浮動按鈕）。LIFF `?game=` 參數仍可用。
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
   - 老玩家綁定：店家於 2026-10-05 回報實測成功，綁定本身已驗收；剩餘確認為回歸禮 50 點入帳、會員卡餘額、老玩家選單切換，以及申請／結果通知實際收到。若審核頁出現 `BONUS_SECRET_MISMATCH`，代表 Supabase 的 `PLAY_RECORD_SECRET` 與 Apps Script `BOOKING_SECRET` 不一致。測完不想領點：帳本那列狀態改「作廢」並重算。
   - 實際收到「滿團」「成團」「取消」通知（P7）。
   - LINE 外的一般瀏覽器登入、session 過期自動重登（P3）。
2. **過期揪團處理**（店家尚未決定）：開場時間到仍未成團 → 自動結束招募＋通知主揪？開場前一天提醒「還缺 N 人」？兩者都做？**先問店家再做**。
3. **第 3 階段（2026-10-06 已上線：0025、api、Apps Script、LIFF；LINE上線日＝2026/10/06；待真人實測）**：migration 0025、api `/me/reviews/:id`、`/me/records`、LIFF `#/review/<id>`、`#/record`，以及 Apps Script `line_record`、`LINE上線日` 補登規則都已寫好。
   上線順序：雲端套用 0025 並跑 `tests/review_context.sql` → 部署 api → 店家部署新版 Apps Script，並在「設定」填 `LINE上線日` → 最後 push 這個 repo 發布 LIFF 頁。
   **注意**：`LINE上線日` 留空時補登規則不生效，補登會照常給點。原始需求如下：
   - LINE 版玩本記錄：身分取自 LINE（綁定的歸戶名；新玩家以 LINE 名稱建立），不再手打名字；店家記錄出席後推播「填心得拿點數」，日期與劇本預先帶入。
   - 補登規則（店家選 A）：遊玩日期在上線日前、上線後才填的紀錄 → 只記錄、0 點、不參與首探／新手好運計算；上線日前已填的舊紀錄不受影響。需改 Apps Script `rebuildPoints_`（依遊玩日期排序重算，補登若不排除會搶走別人的首探），並補 `tests/gas.test.js`。
   - 上線日與回歸禮資格日請和店家確認（目前資格日預設 2026/10/06，可在試算表「設定」分頁覆寫）。
4. LIFF 加好友設定已完成：依 2026-10-05 聊天「Update aggressive channel option」紀錄，Add friend option 為 On (aggressive)，Linked OA 已儲存為 @825gdzws；不再列為待設定。
5. P12 試營運：20–50 位真人、10 團、5 場成團；招募文案在 `docs/PLAYER_GUIDE.md`（需補上老玩家綁定與會員卡的說明）。
6. 已知限制：沒有每位使用者的請求頻率限制；Supabase CLI migration history 未同步（見第 5 節）。

---

## 5. 部署方式與注意事項

### 資料庫 migration
- **一律新增檔案**（`supabase/migrations/YYYYMMDDNNNN_name.sql`，以 `begin; … commit;` 包住），不改已套用的檔案。
- 目前全部 25 個 migration 都是在 **Supabase Dashboard SQL Editor 手動套用**。CLI 的 migration history 是空的：
  若改用 `supabase db push`，必須先 `supabase migration repair --status applied <每個版本>`，否則會重跑 CREATE 而失敗。
- **新資料表要明確授權**：`grant select,insert,update,delete on public.<table> to service_role;`
  （Supabase 新表不再預設授權 service_role；`tests/database.test.mjs` 已模擬這個行為，漏了會在本機測試失敗。）
- 新表一律 `enable row level security` 並 `revoke all … from public,anon,authenticated`；RPC 只 `grant execute … to service_role`。
- 業務錯誤用 `raise exception 'CODE'`（P0001 + 大寫代碼），API `statusForCode` 對應 HTTP 狀態，LIFF `ERRORS` 對應中文訊息。三處要一起加。
- 每個 migration 配一份 `tests/<name>.sql`（以 rollback 結束），並登記到 `tests/database.test.mjs` 的清單。

### Edge Function `api`
- 單一檔案 `supabase/functions/api/index.ts`，無外部相依，可直接在 Node 24 測試（`handleApi(req, settings)`）。`verify_jwt` 關閉（自己驗 session）。
- 部署：目前是在 Dashboard → Edge Functions → api → Code，把 GitHub 上該 commit 的檔案貼進編輯器並 Deploy，
  部署前後比對 SHA-256（以 LF 換行計算）確認雲端與 GitHub 一致。也可改用 `supabase functions deploy api --no-verify-jwt`。
- 成功的 POST（`/hooks/*` 除外）結束後會在背景送通知。

### LIFF 頁
- `web/liff/index.html` 單頁應用，所有輸出經 `esc()`。push main 即由 GitHub Actions 發布。
- `tests/liff.test.mjs` 檢查頁面腳本可解析、只載入 LINE SDK 與 config.js、每個圖文選單 `?view=` 都有對應路由。
- Rich Menu 網址參數：`?view=open|create|history|guide|veteran|card|bindings`、`?game=<scripts.js id>`、`?invite=`、`?group=`。

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
`GET /admin/events/:id/participants`、`GET /admin/report`、`POST /admin/sheets/export`、`GET /admin/google-account`、
`POST /admin/games/sync`、`GET /admin/bindings`、`POST /admin/bindings/:userId/approve|reject|bonus`。

維護（`X-Sync-Secret`）：`POST /hooks/catalog-sync`、`/hooks/richmenu-setup`、`/hooks/selftest-race`。

公開健康檢查（只回狀態與代碼）：`GET /health/calendar`、`GET /health/records`。

---

## 7. 和店家合作的原則（這段對話累積的偏好）

- 中文溝通；先給結論，再列步驟；需要店家操作的步驟寫清楚點哪裡。
- 秘密只由店家本人輸入；需要時產生在本機檔案讓店家複製。
- 不要在系統內做付款紀錄（P8 店家決定不做）；劇本價格不用做（成團時才填每人費用）。
- 重大設計（選單內容、點數規則、補登規則）先和店家討論再做；店家重視選單六格的內容。
- 每做完一段：本機測試 → 雲端測試 → 部署 → 比對版本 → 更新 `docs/PROGRESS.md` → 回報店家需要實測的項目。
