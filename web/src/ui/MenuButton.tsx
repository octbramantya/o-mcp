// A button that opens a list of actions, on React Aria's MenuTrigger, Menu and MenuItem
// (design/frontend-aria.md): arrow keys and type-ahead move through it, Enter runs one and closes it,
// Escape closes it with focus back on the button. Each action may carry a line describing it.
import type { ReactNode } from 'react';
import { Button, Menu, MenuItem, MenuTrigger, Popover, Text } from 'react-aria-components';

export interface Action { id: string; label: string; description?: string }

export function MenuButton({ button, actions, onAction, className }: {
  button: ReactNode; actions: Action[]; onAction: (id: string) => void; className?: string;
}) {
  return (
    <MenuTrigger>
      <Button className={className}>{button}</Button>
      <Popover className="popover-surface list-popover menu-popover" placement="bottom end">
        <Menu className="menu" items={actions} onAction={(k) => onAction(String(k))}>
          {(a) => (
            <MenuItem id={a.id} className="option menu-item" textValue={a.label}>
              <Text slot="label" className="menu-label">{a.label}</Text>
              {a.description && <Text slot="description" className="menu-description">{a.description}</Text>}
            </MenuItem>
          )}
        </Menu>
      </Popover>
    </MenuTrigger>
  );
}
