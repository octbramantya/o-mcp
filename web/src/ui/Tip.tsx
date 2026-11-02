// A tooltip on React Aria (design/frontend-aria.md), for the few hints that carry content a `title`
// hides from the keyboard and touch: the trigger is a button styled as its text, so it takes focus,
// and the tip shows on hover or focus and goes on Escape. Line breaks in the tip are kept. Its empty
// `title` keeps an ancestor's from showing beside the tip.
import type { ReactNode } from 'react';
import { Focusable, Tooltip, TooltipTrigger } from 'react-aria-components';

export function Tip({ tip, className, children }: { tip: ReactNode; className?: string; children: ReactNode }) {
  return (
    <TooltipTrigger delay={400}>
      <Focusable>
        <button type="button" title="" className={['tip-trigger', className].filter(Boolean).join(' ')}>{children}</button>
      </Focusable>
      <Tooltip className="popover-surface tooltip" placement="top" offset={6}>{tip}</Tooltip>
    </TooltipTrigger>
  );
}
