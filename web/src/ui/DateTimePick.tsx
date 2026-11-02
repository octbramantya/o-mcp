// A calendar and a time of day behind a 📅 button, on React Aria's Calendar and TimeField
// (design/frontend-aria.md), for a field that also takes text React Aria's date fields can't (now-7d).
// It opens on the instant the caller names and writes YYYY-MM-DDTHH:MM on every change: a day picked
// in the calendar (arrow keys move, Enter picks), or the hour and minute typed or stepped with the
// arrow keys. Plain wall-clock values: the caller says whose time it is.
import type { TimeValue } from 'react-aria-components';
import { useState } from 'react';
import { CalendarDate, parseDate, Time } from '@internationalized/date';
import { Button, Calendar, CalendarCell, CalendarGrid, DateInput, DateSegment, Heading, Label, TimeField } from 'react-aria-components';
import { PopoverButton } from './PopoverButton';

const two = (n: number) => String(n).padStart(2, '0');

export function DateTimePick({ label, initial, onPick }: {
  /** What is picked, as "From"; names the button and the panel. */
  label: string;
  /** The instant to open on, YYYY-MM-DDTHH:MM, or '' for none; read on each opening. */
  initial: () => string;
  onPick: (v: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState<CalendarDate | null>(null);
  const [time, setTime] = useState(new Time(0, 0));
  const onOpenChange = (o: boolean) => {
    if (o) {
      const v = initial();
      const ok = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v);
      setDate(ok ? parseDate(v.slice(0, 10)) : null);
      setTime(ok ? new Time(Number(v.slice(11, 13)), Number(v.slice(14, 16))) : new Time(0, 0));
    }
    setOpen(o);
  };
  const write = (d: CalendarDate | null, t: Time) => { if (d) onPick(`${d.toString()}T${two(t.hour)}:${two(t.minute)}`); };
  return (
    <PopoverButton button="📅" buttonLabel={`Pick ${label} date and time`} title={`${label} date and time`}
                   className="date-time" isOpen={open} onOpenChange={onOpenChange}>
      <Calendar className="calendar" aria-label={`${label} date`} value={date}
                onChange={(d) => { const c = new CalendarDate(d.year, d.month, d.day); setDate(c); write(c, time); }}>
        <header className="calendar-head">
          <Button slot="previous" className="calendar-nav" aria-label="Previous month">‹</Button>
          <Heading className="calendar-title" />
          <Button slot="next" className="calendar-nav" aria-label="Next month">›</Button>
        </header>
        <CalendarGrid className="calendar-grid" weekdayStyle="short">
          {(d) => <CalendarCell date={d} className="calendar-cell" />}
        </CalendarGrid>
      </Calendar>
      <div className="date-time-foot">
        <TimeField className="time-input" value={time} granularity="minute" hourCycle={24} shouldForceLeadingZeros
                   onChange={(t: TimeValue | null) => { if (t) { const c = new Time(t.hour, t.minute); setTime(c); write(date, c); } }}>
          <Label>Time</Label>
          <DateInput className="date-input">{(s) => <DateSegment segment={s} className="date-segment" />}</DateInput>
        </TimeField>
        <button type="button" onClick={() => setOpen(false)}>Done</button>
      </div>
    </PopoverButton>
  );
}
