// Several choices from a long list, on React Aria's Autocomplete, SearchField and a multiple-selection
// ListBox (design/frontend-aria.md): a filter field above an inline list with a check on each chosen
// item. Arrow keys move through the list while typing, Enter or Space checks one, Escape clears the
// filter and never the choice. `max` caps the choice: once reached, the unchecked items are disabled.
// The choice keeps the order it was made in, and a line under the list names it, since the filter
// may hide some of it.
import type { Key, Selection } from 'react-aria-components';
import { Autocomplete, Button, Input, ListBox, ListBoxItem, SearchField, useFilter } from 'react-aria-components';

export interface Item { id: string; label: string }

export function MultiPick({ label, items, value, onChange, max, empty = 'None chosen' }: {
  /** The accessible name of the list. */
  label: string;
  items: Item[];
  value: string[];
  onChange: (v: string[]) => void;
  max?: number;
  /** The line under the list when nothing is chosen. */
  empty?: string;
}) {
  const { contains } = useFilter({ sensitivity: 'base' });
  const full = max !== undefined && value.length >= max;
  const change = (keys: Selection) => {
    const now = keys === 'all' ? items.map((i) => i.id) : [...keys].map(String);
    const next = [...value.filter((v) => now.includes(v)), ...now.filter((k) => !value.includes(k))];
    if (max === undefined || next.length <= max) onChange(next);
  };
  return (
    <div className="multi-pick">
      <Autocomplete filter={contains}>
        <SearchField className="search-field" aria-label={`Filter ${label.toLowerCase()}`}>
          <Input className="search-input" placeholder="Filter…" />
          <Button className="search-clear link">✕</Button>
        </SearchField>
        <ListBox<Item> className="listbox multi-list" aria-label={label} items={items} selectionMode="multiple"
                       selectedKeys={value} onSelectionChange={change} escapeKeyBehavior="none"
                       disabledKeys={full ? items.filter((i) => !value.includes(i.id)).map((i) => i.id as Key) : []}
                       renderEmptyState={() => <div className="muted pad">No match.</div>}>
          {(i) => (
            <ListBoxItem id={i.id} className="option multi-option" textValue={i.label}>
              {({ isSelected }) => <><span className="check-box" aria-hidden="true">{isSelected && '✓'}</span>{i.label}</>}
            </ListBoxItem>
          )}
        </ListBox>
      </Autocomplete>
      <div className="muted small multi-chosen">
        {value.length ? `${value.length}${max !== undefined ? ` of ${max}` : ''}: ${value.join(', ')}` : empty}
        {value.length > 0 && <> · <button type="button" className="link" onClick={() => onChange([])}>Clear</button></>}
      </div>
    </div>
  );
}
