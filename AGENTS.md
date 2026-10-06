# AGENTS.md

海星劇本殺 LINE 預約系統。接手前先讀 `docs/HANDOFF.md`（系統一覽、秘密、現況、待辦、部署方式）。

## 規則

- 與店家溝通用繁體中文、白話；需要店家操作的步驟寫清楚。
- 不讀出、不印出、不提交任何秘密（`.env.*` 檔案、Supabase／GitHub／Apps Script 的 Secrets）。秘密由店家本人輸入。
- 資料庫變更一律新增 migration（`begin; … commit;`），不改已套用的檔案；新表要 RLS、revoke public/anon/authenticated、
  明確 `grant … to service_role`；RPC 只給 service_role。每個 migration 配一份 `tests/*.sql` 並登記到 `tests/database.test.mjs`。
- 業務錯誤代碼要同時加在 SQL（`raise exception 'CODE'`）、`statusForCode`（api）與 LIFF 的 `ERRORS`。
- 推之前跑 `npm test`（Node 24），必須全過；套用 migration 後在 Supabase SQL Editor 跑對應測試 SQL，必須 PASS。
- 改到 `cj2vum4/starfishlarp`（網站、`points.js`、`booking.js`、Apps Script）時遵守該 repo 的 `AGENTS.md`，推之前跑 `bash tests/run.sh`；
  Apps Script 要店家手動部署新版本。
- 寫檔用 LF；Windows 上 Python 寫檔加 `newline='\n'`。
- 完成一段工作後更新 `docs/PROGRESS.md`，並回報店家需要真人實測的項目。

## 指令

```sh
npm test                      # 全部測試（含 PGlite 本機資料庫）
node --test tests/xxx.test.mjs
python scripts/richmenu_image.py web/liff <starfishlarp>/pwa/icon-512.png
```
