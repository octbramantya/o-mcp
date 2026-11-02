// A single choice from a list, on React Aria's Select (design/frontend-aria.md): a button showing the
// choice, and a list that opens below it, with arrow keys, type-ahead and Escape. Options may come in
// titled groups. Pages and widgets import this, never react-aria-components directly.
import type { ReactNode } from 'react';
import type { Key } from 'react-aria-components';
import { Button, Header, ListBox, ListBoxItem, ListBoxSection, Popover, Select as AriaSelect, SelectValue } from 'react-aria-components';

export interface Option<K extends Key = string> {
  id: K;
  label: ReactNode;
  /** What type-ahead matches and a screen reader reads; required when `label` isn't a string. */
  text?: string;
}

export interface OptionGroup<K extends Key = string> { title: string; options: Option<K>[] }

export function Select<K extends Key = string>({ value, onChange, options, groups, label, placeholder, className, isDisabled }: {
  value: K | null;
  onChange: (v: K) => void;
  options?: Option<K>[];
  groups?: OptionGroup<K>[];
  /** The accessible name; the visible one is the Field around it. */
  label: string;
  placeholder?: string;
  className?: string;
  isDisabled?: boolean;
}) {
  const item = (o: Option<K>) => (
    <ListBoxItem key={o.id} id={o.id} className="option" textValue={o.text ?? (typeof o.label === 'string' ? o.label : String(o.id))}>
      {o.label}
    </ListBoxItem>
  );
  return (
    <AriaSelect className={`select${className ? ` ${className}` : ''}`} aria-label={label} placeholder={placeholder}
                value={value} onChange={(k) => { if (k !== null) onChange(k as K); }} isDisabled={isDisabled}>
      <Button className="select-button">
        <SelectValue className="select-value" />
        <span className="chevron" aria-hidden="true">▾</span>
      </Button>
      <Popover className="popover-surface list-popover" placement="bottom start">
        <ListBox className="listbox">
          {options?.map(item)}
          {groups?.map((g) => (
            <ListBoxSection key={g.title} id={g.title} className="listbox-section">
              <Header className="listbox-header">{g.title}</Header>
              {g.options.map(item)}
            </ListBoxSection>
          ))}
        </ListBox>
      </Popover>
    </AriaSelect>
  );
}
