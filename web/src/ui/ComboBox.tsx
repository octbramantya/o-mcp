// A text field that offers matches below it as you type, on React Aria's ComboBox
// (design/frontend-aria.md): arrow keys move through the matches, Enter picks one, Escape or leaving
// the field closes the list and clears it. The caller filters; picking reports the item and empties the field,
// so the box is for choosing, not for holding a value.
import type { ReactNode } from 'react';
import type { Key } from 'react-aria-components';
import { useState } from 'react';
import { ComboBox as AriaComboBox, Input, ListBox, ListBoxItem, Popover } from 'react-aria-components';

export interface Match<K extends Key = number> {
  id: K;
  /** What a screen reader reads for the match. */
  text: string;
  label: ReactNode;
}

export function ComboBox<K extends Key = number>({ matches, onPick, label, placeholder, text, setText }: {
  /** The matches for the current text, filtered by the caller. */
  matches: (t: string) => Match<K>[];
  onPick: (id: K) => void;
  label: string;
  placeholder?: string;
  /** The field's text, when the caller holds it; otherwise held here. */
  text?: string;
  setText?: (t: string) => void;
}) {
  const [own, setOwn] = useState('');
  const value = text ?? own;
  const set = setText ?? setOwn;
  const items = value.trim() ? matches(value) : [];
  return (
    <AriaComboBox className="combobox" aria-label={label} items={items} inputValue={value} onInputChange={set}
                  selectedKey={null} menuTrigger="input"
                  onSelectionChange={(k) => {
                    // null is Escape or leaving the field: with both text and selection held outside, React
                    // Aria leaves resetting the text to us, and reopens the list if we don't
                    if (k !== null) onPick(k as K);
                    set('');
                  }}>
      <Input className="combobox-input" placeholder={placeholder} />
      <Popover className="popover-surface list-popover" placement="bottom start">
        <ListBox<Match<K>> className="listbox">
          {(m) => <ListBoxItem id={m.id} className="option" textValue={m.text}>{m.label}</ListBoxItem>}
        </ListBox>
      </Popover>
    </AriaComboBox>
  );
}
