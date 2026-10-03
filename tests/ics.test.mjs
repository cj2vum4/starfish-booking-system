import test from 'node:test';
import assert from 'node:assert/strict';
import { parseIcsBusy } from '../supabase/functions/api/index.ts';

// Shaped like an Outlook published calendar (Windows TZID, BUSYSTATUS, folded lines).
const ics = (events) => ['BEGIN:VCALENDAR', 'VERSION:2.0',
  'BEGIN:VTIMEZONE', 'TZID:Taipei Standard Time', 'BEGIN:STANDARD', 'DTSTART:16010101T000000',
  'TZOFFSETFROM:+0800', 'TZOFFSETTO:+0800', 'END:STANDARD', 'END:VTIMEZONE',
  ...events.flatMap(e => ['BEGIN:VEVENT', ...e, 'END:VEVENT']), 'END:VCALENDAR'].join('\r\n');
const tpe = 'DTSTART;TZID=Taipei Standard Time';
const tpeEnd = 'DTEND;TZID=Taipei Standard Time';
const window = [new Date('2026-10-01T00:00:00+08:00'), new Date('2026-11-01T00:00:00+08:00')];
const busy = events => parseIcsBusy(ics(events), ...window);
const at = iso => new Date(iso).toISOString();

test('single events: Taipei, UTC and all-day, with titles never returned', () => {
  const out = busy([
    ['UID:a', 'SUMMARY:私人聚餐', `${tpe}:20261005T190000`, `${tpeEnd}:20261005T213000`, 'X-MICROSOFT-CDO-BUSYSTATUS:BUSY'],
    ['UID:b', 'DTSTART:20261006T110000Z', 'DTEND:20261006T120000Z'],
    ['UID:c', 'DTSTART;VALUE=DATE:20261010', 'DTEND;VALUE=DATE:20261011', 'X-MICROSOFT-CDO-BUSYSTATUS:BUSY'],
  ]);
  assert.deepEqual(out, [
    { start: at('2026-10-05T19:00:00+08:00'), end: at('2026-10-05T21:30:00+08:00') },
    { start: at('2026-10-06T11:00:00Z'), end: at('2026-10-06T12:00:00Z') },
    { start: at('2026-10-10T00:00:00+08:00'), end: at('2026-10-11T00:00:00+08:00') },
  ]);
  assert.ok(!JSON.stringify(out).includes('聚餐'));
});

test('free and show-as-available items are ignored; tentative still blocks', () => {
  const out = busy([
    ['UID:f', `${tpe}:20261005T090000`, `${tpeEnd}:20261005T100000`, 'X-MICROSOFT-CDO-BUSYSTATUS:FREE'],
    ['UID:t', `${tpe}:20261005T110000`, `${tpeEnd}:20261005T120000`, 'TRANSP:TRANSPARENT'],
    ['UID:x', `${tpe}:20261005T130000`, `${tpeEnd}:20261005T140000`, 'STATUS:CANCELLED'],
    ['UID:q', `${tpe}:20261005T150000`, `${tpeEnd}:20261005T160000`, 'X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE'],
  ]);
  assert.deepEqual(out, [{ start: at('2026-10-05T15:00:00+08:00'), end: at('2026-10-05T16:00:00+08:00') }]);
});

test('weekly, daily-interval and last-Monday-of-month series expand inside the window', () => {
  const weekly = busy([['UID:w', `${tpe}:20260907T193000`, `${tpeEnd}:20260907T203000`,
    'RRULE:FREQ=WEEKLY;UNTIL=20261231T113000Z;INTERVAL=1;BYDAY=MO;WKST=SU']]);
  assert.deepEqual(weekly.map(b => b.start), ['05', '12', '19', '26'].map(d => at(`2026-10-${d}T19:30:00+08:00`)));
  const daily = busy([['UID:d', `${tpe}:20261020T090000`, `${tpeEnd}:20261020T093000`,
    'RRULE:FREQ=DAILY;UNTIL=20261028T010000Z;INTERVAL=3']]);
  assert.deepEqual(daily.map(b => b.start), ['20', '23', '26'].map(d => at(`2026-10-${d}T09:00:00+08:00`)));
  const monthly = busy([['UID:m', `${tpe}:20250127T190000`, `${tpeEnd}:20250127T200000`,
    'RRULE:FREQ=MONTHLY;UNTIL=20271231T110000Z;INTERVAL=1;BYDAY=-1MO']]);
  assert.deepEqual(monthly.map(b => b.start), [at('2026-10-26T19:00:00+08:00')]);
  const counted = busy([['UID:c', `${tpe}:20261001T120000`, `${tpeEnd}:20261001T130000`, 'RRULE:FREQ=DAILY;COUNT=2']]);
  assert.equal(counted.length, 2);
});

test('a long-running series that began years ago still reaches the window', () => {
  const out = busy([['UID:old', `${tpe}:20100104T080000`, `${tpeEnd}:20100104T090000`, 'RRULE:FREQ=DAILY;INTERVAL=1']]);
  assert.equal(out.length, 31);
  assert.equal(out[0].start, at('2026-10-01T08:00:00+08:00'));
});

test('EXDATE removes an occurrence; a RECURRENCE-ID override moves or cancels one', () => {
  const out = busy([
    ['UID:s', `${tpe}:20261005T190000`, `${tpeEnd}:20261005T200000`, 'RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4',
      `EXDATE;TZID=Taipei Standard Time:20261012T190000`],
    ['UID:s', `RECURRENCE-ID;TZID=Taipei Standard Time:20261019T190000`, `${tpe}:20261020T100000`, `${tpeEnd}:20261020T110000`],
    ['UID:s', `RECURRENCE-ID;TZID=Taipei Standard Time:20261026T190000`, `${tpe}:20261026T190000`, `${tpeEnd}:20261026T200000`,
      'STATUS:CANCELLED'],
  ]);
  assert.deepEqual(out.map(b => b.start), [at('2026-10-05T19:00:00+08:00'), at('2026-10-20T10:00:00+08:00')]);
});

test('folded lines are unfolded; unknown recurrence rules fail closed', () => {
  const folded = ics([['UID:f', 'DTSTART;TZID=Taipei Stan', ' dard Time:20261005T190000', `${tpeEnd}:20261005T200000`]]);
  assert.equal(parseIcsBusy(folded, ...window).length, 1);
  assert.throws(() => busy([['UID:z', `${tpe}:20261005T190000`, `${tpeEnd}:20261005T200000`, 'RRULE:FREQ=WEEKLY;BYSETPOS=1']]),
    /ICS_UNSUPPORTED/);
  assert.throws(() => parseIcsBusy('<html>not a calendar</html>', ...window), /ICS_UNREADABLE/);
});
