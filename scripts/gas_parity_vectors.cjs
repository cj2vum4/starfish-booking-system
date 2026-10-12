// Generates tests/fixtures/gas_parity.json: random 玩本記錄 spreadsheets scored by the real Apps Script
// (starfishlarp/GoogleAppsScript_玩本記錄.gs, run in starfishlarp/tests/gas-mock.js), so tests/gas_parity.test.mjs
// can check that the Supabase port gives the same points.
//   node scripts/gas_parity_vectors.cjs <path to starfishlarp>
// Two kinds of case:
//   import  — the sheet as the Apps Script left it (aliases, likes, featured, manual rows, voided rows, 回歸禮):
//             importing it must reproduce the Apps Script's 點數總覽 exactly.
//   replay  — records sent in play order with referrers who already played: scoring them one by one at
//             submit time must give every player the same points as the Apps Script's full recalculation.
'use strict';
process.env.TZ = 'Asia/Taipei';
const path = require('path');
const fs = require('fs');
const site = path.resolve(process.argv[2] || '../starfishlarp');
const mock = require(path.join(site, 'tests', 'gas-mock.js'));

let seed = 20261012;
const rand = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const pick = (a) => a[Math.floor(rand() * a.length)];
const NAMES = ['海星', '小明', '阿華', 'Amy', '小美', '阿傑', '老王', 'Kiki', '雨晴', '大頭'];
const SPELLINGS = { Amy: ['Amy', 'amy', ' AMY ', 'A my'], 海星: ['海星', '海 星'] };
const SCRIPTS = ['年輪', '瘋兔子', '春晝短', '王座', '上路', '左左'];
const LONG = '這是一段超過十五個字的心得內容真的好玩';

const ymd = (d) => `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
// What the Sheets API returns with valueRenderOption=UNFORMATTED_VALUE and dateTimeRenderOption=SERIAL_NUMBER:
// date cells as serial numbers (days since 1899-12-30, spreadsheet wall time), other cells as they are.
// The Apps Script writes dates as 'Y/M/D' text, which Google Sheets usually turns into date cells; half of them
// are kept as text so both kinds are read.
const serial = (d) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds()) / 86400000 + 25569;
const DATE_TEXT = /^\d{4}\/\d{1,2}\/\d{1,2}$/;
const raw = (v) => v instanceof Date ? serial(v)
  : typeof v === 'string' && DATE_TEXT.test(v) && rand() < 0.5 ? serial(new Date(v)) : v;
const TABS = ['表單回應 1', '點數帳本', '玩家', '設定', '獎勵', '任務', '心得互動'];
function sheetValues() {
  return Object.fromEntries(TABS.map((name) => {
    const sheet = mock.spreadsheet.getSheetByName(name);
    const rows = sheet.getLastRow() ? sheet.getRange(1, 1, sheet.getLastRow(), Math.max(sheet.getLastColumn(), 1)).getValues() : [];
    return [name, rows.map((r, i) => i === 0 ? r : r.map(raw))];
  }));
}

function expected() {
  const p = global.buildPublicPayload_();
  return { summary: p.summary.map(({ questProgress, monthEarned, ...rest }) => rest), interactions: p.interactions, mystery: p.mystery,
    quests: p.quests, rules: p.rules, rewards: p.rewards, doubleDayNote: p.doubleDayNote };
}

function makeRows(n, { replay }) {
  const out = [];
  const played = [];
  for (let i = 0; i < n; i++) {
    const base = new Date(2026, 4 + Math.floor(rand() * 5), 1 + Math.floor(rand() * 28));
    const lag = replay ? 0 : pick([0, 0, 1, 3, 8, 12]);
    const stamp = new Date(base.getTime() + lag * 86400000 + Math.floor(rand() * 20) * 3600000);
    const who = pick(NAMES);
    const name = SPELLINGS[who] ? pick(SPELLINGS[who]) : who;
    const referrer = !replay && rand() < 0.3 ? pick([...NAMES, '路人甲', name, ' ' + name]) : '';
    out.push([stamp, name, ymd(base), pick(SCRIPTS), '角色' + Math.floor(rand() * 3), String(1 + Math.floor(rand() * 5)),
      rand() < 0.4 ? LONG.slice(0, 10 + Math.floor(rand() * 10)) : pick(['', '短心得', '好玩']), referrer]);
  }
  // Replay cases: rows arrive in play order (then time), so 首玩/首探/新手好運 cannot move between players,
  // and a referrer is someone who already played (the new rule only accepts existing players).
  if (replay) {
    out.sort((a, b) => new Date(a[2]) - new Date(b[2]) || a[0] - b[0]);
    out.forEach((row) => {
      if (played.length && rand() < 0.3) row[7] = pick(played);
      played.push(row[1]);
    });
  }
  return out;
}

const cases = [];
for (let c = 0; c < 14; c++) {
  const replay = c >= 8;
  const doubleDay = pick(['', '平日', '假日', '二,四', '2026/6/6', '星期六、週日']);
  const rows = makeRows(25 + Math.floor(rand() * 40), { replay });
  mock.freshEnv(rows, { doubleDay, quests: rand() < 0.8 });
  if (!replay) {
    mock.setConfig('LINE上線日', pick(['', '2026/7/1', '2026/8/15']));
    if (rand() < 0.5) mock.setConfig('每日上限筆數', pick([1, 2, 0]));
    // Aliases, honours and a GM-added player row.
    const players = mock.spreadsheet.getSheetByName('玩家');
    const list = mock.sheetRows('玩家');
    list.forEach((r, i) => {
      if (r[0] === '海星') players.getRange(i + 2, 2).setValue('海星⭐, starfish');
      if (rand() < 0.2) players.getRange(i + 2, 6).setValue('TRUE');
      if (rand() < 0.2) players.getRange(i + 2, 7).setValue('稱號' + i);
      if (rand() < 0.1) players.getRange(i + 2, 8).setValue(true);
    });
    players.appendRow(['阿華', '華仔', '', '', '店家加的', '', '', '']);
  }
  global.rebuildPoints_();
  // Likes (some on reviews that do not exist, as the Apps Script allowed), featured, manual rows, voids, 回歸禮.
  const reviews = mock.sheetRows('表單回應 1').filter((r) => String(r[6] ?? '').trim());
  for (let k = 0; k < 6 && reviews.length; k++) {
    const r = pick(reviews);
    const times = 1 + Math.floor(rand() * 7);
    for (let t = 0; t < times; t++) global.recordLike_({ script: r[3], date: r[2], author: r[1] });
  }
  if (!replay) {
    global.recordLike_({ script: '不存在的本', date: '2026/5/5', author: '海星' });
    const inter = mock.spreadsheet.getSheetByName('心得互動');
    if (inter.getLastRow() > 1 && rand() < 0.7) inter.getRange(2, 5).setValue('TRUE');
    const ledger = mock.spreadsheet.getSheetByName('點數帳本');
    ledger.appendRow([new Date(2026, 8, 20), '小明', '小明', 'redeem', -30, '神秘盒', '', '2026/9/20', '手動', '有效', '開出：免費飲料一杯', '']);
    ledger.appendRow([new Date(2026, 8, 21), '小美', '小美', 'adjust', 15, '補點', '', '2026/9/21', '手動', '有效', '', '']);
    ledger.appendRow([new Date(2026, 8, 22), '阿傑', '阿傑', 'adjust', 99, '打錯', '', '2026/9/22', '手動', '作廢', '', '']);
    global.rebuildPoints_();
    const lrows = mock.sheetRows('點數帳本');
    const earnIdx = lrows.findIndex((r) => r[8] === '表單' && r[3] === 'earn');
    if (earnIdx >= 0 && rand() < 0.7) ledger.getRange(earnIdx + 2, 10).setValue('作廢');
    mock.setScriptProperty('BOOKING_SECRET', 'S'.repeat(43));
    global.grantReturnBonus_({ secret: 'S'.repeat(43), name: pick(NAMES), points: '50' });
  }
  global.rebuildPoints_();
  cases.push({ kind: replay ? 'replay' : 'import', doubleDay, sheet: sheetValues(), expected: expected() });
}
const out = path.join(__dirname, '..', 'tests', 'fixtures', 'gas_parity.json');
fs.writeFileSync(out, JSON.stringify({ generatedFrom: 'starfishlarp/GoogleAppsScript_玩本記錄.gs', cases }, null, 0) + '\n');
console.log('wrote', out, cases.length, 'cases', cases.map((c) => c.kind + ':' + c.sheet['表單回應 1'].length + '/' + c.sheet['點數帳本'].length).join(' '));
