// The dashboard's time range and refresh (design/frontend.md §3), on the dashboard's own toolbar.
import { useRef, useState } from 'react';
import type { TimeRange } from './range';
import { describe, isValid, pickerValue, PRESETS, siteNow } from './range';

/** A text field for absolute or relative times, with a calendar that writes an absolute one (site time). */
function TimeField({ label, edge, value, onChange, placeholder, tz }: {
  label: string; edge: 'from' | 'to'; value: string; onChange: (s: string) => void; placeholder: string; tz: string;
}) {
  const cal = useRef<HTMLInputElement>(null);
  const open = () => {
    const el = cal.current;
    if (!el) return;
    el.value = pickerValue(value, edge, siteNow(tz));
    try { el.showPicker(); } catch { el.focus(); }
  };
  return (
    <label>{label}
      <span className="time-field">
        <input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} />
        <button type="button" onClick={open} title="Pick a date and time" aria-label={`Pick ${label} date and time`}>📅</button>
        <input ref={cal} type="datetime-local" className="calendar" tabIndex={-1} aria-hidden="true"
               onChange={(e) => { if (e.target.value) onChange(e.target.value); }} />
      </span>
    </label>
  );
}

export function TimePicker({ value, onChange, tz }: { value: TimeRange; onChange: (t: TimeRange) => void; tz: string }) {
  const [open, setOpen] = useState(false);
  const [from, setFrom] = useState(value.from);
  const [to, setTo] = useState(value.to);
  const ok = isValid(from) && isValid(to);
  const pick = (t: TimeRange) => { onChange(t); setOpen(false); };
  return (
    <div className="popover-anchor">
      <button type="button" onClick={() => { setFrom(value.from); setTo(value.to); setOpen(!open); }}>{describe(value)}</button>
      {open && (
        <div className="popover time-picker">
          <div className="presets">
            {PRESETS.map((p) => (
              <button key={p.label} type="button" className={p.from === value.from && p.to === value.to ? 'on' : undefined}
                      onClick={() => pick({ from: p.from, to: p.to })}>{p.label}</button>
            ))}
          </div>
          <div className="custom">
            <TimeField label="From" edge="from" value={from} onChange={setFrom} placeholder="2026-09-01 or now-7d" tz={tz} />
            <TimeField label="To" edge="to" value={to} onChange={setTo} placeholder="2026-10-01 or now" tz={tz} />
            <p className="muted">Site time. A date is its midnight; the end is excluded. now-6h, now/d (start of today; as To, its end).</p>
            <button type="button" disabled={!ok} onClick={() => pick({ from, to })}>Apply</button>
          </div>
        </div>
      )}
    </div>
  );
}

const REFRESH = [null, 30, 60, 300, 900, 3600];

function label(s: number | null) {
  if (s === null) return 'Refresh off';
  return s < 60 ? `Every ${s} s` : s < 3600 ? `Every ${s / 60} min` : `Every ${s / 3600} h`;
}

export function RefreshPicker({ value, onChange }: { value: number | null; onChange: (s: number | null) => void }) {
  return (
    <select value={value ?? ''} onChange={(e) => onChange(e.target.value ? Number(e.target.value) : null)}>
      {REFRESH.map((s) => <option key={s ?? 'off'} value={s ?? ''}>{label(s)}</option>)}
    </select>
  );
}
