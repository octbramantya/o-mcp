// Search fields, on React Aria (design/frontend-aria.md):
// - `SearchField`: a text field with a clear button; Escape clears it.
// - `SearchArea` + `SearchField` + `SearchResults`: the field and a list of results grouped in sections,
//   apart from each other in the page. Arrow keys move through the results while typing (the field
//   keeps focus), Enter or a click acts on one. The caller filters and groups; the area does neither.
import type { ReactNode } from 'react';
import type { Key } from 'react-aria-components';
import { Autocomplete, Button, Header, Input, ListBox, ListBoxItem, ListBoxSection, SearchField as AriaSearchField } from 'react-aria-components';

export function SearchField({ label, placeholder, value, onChange, className }: {
  /** The accessible name. */
  label: string;
  placeholder?: string;
  /** Held by the caller, or by the `SearchArea` around it. */
  value?: string;
  onChange?: (v: string) => void;
  className?: string;
}) {
  return (
    <AriaSearchField className={['search-field', className].filter(Boolean).join(' ')} aria-label={label}
                     value={value} onChange={onChange}>
      <Input className="search-input" placeholder={placeholder} />
      <Button className="search-clear link" aria-label="Clear">✕</Button>
    </AriaSearchField>
  );
}

/** Holds a `SearchField` and the `SearchResults` it moves through, wherever each sits inside it. */
export function SearchArea({ value, onChange, children }: { value: string; onChange: (v: string) => void; children: ReactNode }) {
  return <Autocomplete inputValue={value} onInputChange={onChange}>{children}</Autocomplete>;
}

export interface Hit { id: string; text: string; label: ReactNode }
export interface HitSection { id: string; title: ReactNode; hits: Hit[] }

export function SearchResults({ label, sections, onAction, className }: {
  label: string;
  sections: HitSection[];
  onAction: (id: string) => void;
  className?: string;
}) {
  return (
    <ListBox className={['listbox', 'search-results', className].filter(Boolean).join(' ')} aria-label={label}
             onAction={(k: Key) => onAction(String(k))}>
      {sections.filter((s) => s.hits.length).map((s) => (
        <ListBoxSection key={s.id} id={s.id} className="search-section">
          <Header className="search-header">{s.title}</Header>
          {s.hits.map((h) => <ListBoxItem key={h.id} id={h.id} className="option search-hit" textValue={h.text}>{h.label}</ListBoxItem>)}
        </ListBoxSection>
      ))}
    </ListBox>
  );
}
