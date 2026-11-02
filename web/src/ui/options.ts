// Option lists more than one widget offers, for `ui/Select`.

/** A chart's interval: Readings and Compare. */
export const INTERVALS: { id: 'auto' | '15min' | 'hour' | 'day'; label: string }[] = [
  { id: 'auto', label: 'Automatic (minutes for 6 hours or less)' },
  { id: '15min', label: '15 minutes' },
  { id: 'hour', label: 'Hour' },
  { id: 'day', label: 'Day' },
];
