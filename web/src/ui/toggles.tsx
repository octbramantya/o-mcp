// Buttons that stay pressed, and a checkbox, on React Aria (design/frontend-aria.md):
// - `ToggleGroup` + `Toggle`: at most one of a set pressed, pressing it again releases it (the Activity
//   Bar, Find's utility filter). Arrow keys move between them, Tab leaves the group.
// - `Choices`: exactly one of a set, as radios; arrow keys change the choice (the channel a click fills).
// - `Star`: one button that stays pressed. `Check`: a checkbox with its label.
// React Aria passes no `title` to its elements, so a hover hint sits on a `display: contents` span around them.
import type { CSSProperties, ReactNode } from 'react';
import { Checkbox, Label, Radio, RadioGroup, ToggleButton, ToggleButtonGroup } from 'react-aria-components';

export function Titled({ title, children }: { title?: string; children: ReactNode }) {
  return title ? <span className="titled" title={title}>{children}</span> : <>{children}</>;
}

export function ToggleGroup<K extends string>({ label, value, onChange, orientation, className, children }: {
  label: string;
  value: K | null;
  onChange: (v: K | null) => void;
  orientation?: 'horizontal' | 'vertical';
  className?: string;
  children: ReactNode;
}) {
  return (
    <ToggleButtonGroup className={className} aria-label={label} selectionMode="single" orientation={orientation}
                       selectedKeys={value === null ? [] : [value]}
                       onSelectionChange={(keys) => onChange(([...keys][0] ?? null) as K | null)}>
      {children}
    </ToggleButtonGroup>
  );
}

/** One button of a `ToggleGroup`; `.on` while pressed. */
export function Toggle({ id, label, title, className, children }: {
  id: string; label?: string; title?: string; className?: string; children: ReactNode;
}) {
  return (
    <Titled title={title}>
      <ToggleButton id={id} aria-label={label} className={({ isSelected }) => cls(className, isSelected && 'on')}>
        {children}
      </ToggleButton>
    </Titled>
  );
}

export function Choices<K extends string>({ label, value, onChange, options, className }: {
  /** Shown before the choices, and their accessible name. */
  label: ReactNode;
  value: K;
  onChange: (v: K) => void;
  options: { id: K; label: ReactNode; style?: (selected: boolean) => CSSProperties }[];
  className?: string;
}) {
  return (
    <RadioGroup className={cls('choices', className)} orientation="horizontal" value={value} onChange={(v) => onChange(v as K)}>
      <Label>{label}</Label>
      {options.map((o) => (
        <Radio key={o.id} value={o.id} className={({ isSelected }) => cls('choice', isSelected && 'on')}
               style={o.style ? ({ isSelected }) => o.style!(isSelected) : undefined}>
          {o.label}
        </Radio>
      ))}
    </RadioGroup>
  );
}

/** Stars or unstars a node; the button is named "Star" and reads as pressed when starred. */
export function Star({ on, onToggle, className }: { on: boolean; onToggle: () => void; className?: string }) {
  return (
    <Titled title={on ? 'Unstar' : 'Star'}>
      <ToggleButton aria-label="Star" isSelected={on} onChange={onToggle} className={cls('star', className, on && 'on')}>
        {on ? '★' : '☆'}
      </ToggleButton>
    </Titled>
  );
}

export function Check({ checked, onChange, className, children }: {
  checked: boolean; onChange: (v: boolean) => void; className?: string; children: ReactNode;
}) {
  return (
    <Checkbox isSelected={checked} onChange={onChange} className={cls('check', className)}>
      {({ isSelected }) => <><span className="check-box" aria-hidden="true">{isSelected && '✓'}</span>{children}</>}
    </Checkbox>
  );
}

function cls(...c: (string | false | undefined)[]) {
  return c.filter(Boolean).join(' ');
}
