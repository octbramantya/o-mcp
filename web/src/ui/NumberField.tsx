// A whole number in a range, on React Aria's NumberField (design/frontend-aria.md): − and + step it,
// as do the arrow keys, and a number typed outside the range is brought into it when the field is
// left. An emptied field reports nothing, so the value stays what it was.
import { Button, Group, Input, NumberField as AriaNumberField } from 'react-aria-components';

export function NumberField({ label, value, onChange, min, max }: {
  /** The accessible name. */
  label: string;
  value: number;
  onChange: (v: number) => void;
  min?: number;
  max?: number;
}) {
  return (
    <AriaNumberField className="number-field" aria-label={label} value={value} minValue={min} maxValue={max} step={1}
                     onChange={(v) => { if (!Number.isNaN(v)) onChange(v); }}>
      <Group className="number-group">
        <Button slot="decrement" className="number-step" aria-label={`Fewer ${label.toLowerCase()}`}>−</Button>
        <Input className="number-input" />
        <Button slot="increment" className="number-step" aria-label={`More ${label.toLowerCase()}`}>+</Button>
      </Group>
    </AriaNumberField>
  );
}
