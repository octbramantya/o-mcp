// A heading that shows or hides what is under it, on React Aria's Disclosure (design/frontend-aria.md),
// in place of <details>: the heading is a button that reads as expanded or not, Enter or Space toggles
// it, and the content stays mounted while hidden. `.fold[data-expanded]` while open.
import type { ReactNode } from 'react';
import { Button, Disclosure, DisclosurePanel, Heading } from 'react-aria-components';

export function Fold({ title, defaultOpen = false, className, children }: {
  title: ReactNode;
  /** Open at first; the caller remounts it (a `key`) to open or close it again from outside. */
  defaultOpen?: boolean;
  className?: string;
  children: ReactNode;
}) {
  return (
    <Disclosure className={['fold', className].filter(Boolean).join(' ')} defaultExpanded={defaultOpen}>
      <Heading level={4} className="fold-heading">
        <Button slot="trigger" className="fold-trigger"><span className="fold-chevron" aria-hidden="true">▸</span>{title}</Button>
      </Heading>
      <DisclosurePanel className="fold-panel">{children}</DisclosurePanel>
    </Disclosure>
  );
}
