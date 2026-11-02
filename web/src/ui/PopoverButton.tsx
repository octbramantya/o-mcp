// A button that opens a panel beside it, on React Aria's DialogTrigger, Popover and Dialog
// (design/frontend-aria.md): Escape or a click outside closes it and focus returns to the button.
// The panel renders at the end of body, so style it by `className`, not by where the button sits.
import type { ReactNode } from 'react';
import type { PopoverProps } from 'react-aria-components';
import { Button, Dialog, DialogTrigger, Popover } from 'react-aria-components';

export function PopoverButton({ button, buttonClassName, buttonLabel, title, className, placement = 'bottom end', isOpen, onOpenChange, children }: {
  button: ReactNode;
  buttonClassName?: string;
  /** The button's accessible name, when its content is only an icon. */
  buttonLabel?: string;
  /** The panel's accessible name. */
  title: string;
  className?: string;
  placement?: PopoverProps['placement'];
  /** Open state, when the caller holds it (to close on a choice, or to reset a form on opening). */
  isOpen?: boolean;
  onOpenChange?: (open: boolean) => void;
  children: ReactNode;
}) {
  return (
    <DialogTrigger isOpen={isOpen} onOpenChange={onOpenChange}>
      <Button className={buttonClassName} aria-label={buttonLabel}>{button}</Button>
      <Popover className="popover-surface panel-popover" placement={placement} offset={4}>
        <Dialog className={`popover-dialog${className ? ` ${className}` : ''}`} aria-label={title}>{children}</Dialog>
      </Popover>
    </DialogTrigger>
  );
}
