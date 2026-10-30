// The Activity Bar and the side bar (design/frontend.md §5), as in an editor: an icon per view, the
// view in a resizable bar beside the page, and the icon of the open view closes it. Find, Categories
// and Starred choose a node for the open dashboard; below the divider, Reference looks up a node, a
// device or a quantity, on any page of the site.
import type { PointerEvent as ReactPointerEvent, ReactNode } from 'react';
import { useStars } from '../api/hooks';
import { useDashboard } from '../dashboards/store';
import { CategoriesIcon, FindIcon, ReferenceIcon, StarIcon } from './icons';
import { CategoryTree, ChannelTarget, Find, Starred } from './Pickers';
import { Reference } from './reference/Reference';
import type { ViewId } from './sideBarStore';
import { useSideBar, WIDTH } from './sideBarStore';

const VIEWS: { id: ViewId; label: string; icon: () => ReactNode }[] = [
  { id: 'find', label: 'Find', icon: FindIcon },
  { id: 'categories', label: 'Categories', icon: CategoriesIcon },
  { id: 'starred', label: 'Starred', icon: StarIcon },
  { id: 'reference', label: 'Reference', icon: ReferenceIcon },
];

export function ActivityBar() {
  const { view, open, press } = useSideBar();
  const stars = useStars();
  return (
    <nav className="activity-bar" role="tablist" aria-label="Side bar" aria-orientation="vertical">
      {VIEWS.map((v) => {
        const on = open && view === v.id;
        return (
          <div key={v.id} className="activity-slot">
            {v.id === 'reference' && <hr />}
            <button type="button" role="tab" aria-selected={on} className={on ? 'on' : undefined} onClick={() => press(v.id)}
                    title={on ? `Hide ${v.label}` : v.label} aria-label={v.label}>
              <v.icon />
              {v.id === 'starred' && stars.ids.length > 0 && <span className="count">{stars.ids.length}</span>}
            </button>
          </div>
        );
      })}
    </nav>
  );
}

/** The bar's right edge: drag to resize, double-click for the initial width. */
function Resizer() {
  const setWidth = useSideBar((s) => s.setWidth);
  const down = (e: ReactPointerEvent<HTMLDivElement>) => {
    const from = e.clientX;
    const start = useSideBar.getState().width;
    const el = e.currentTarget;
    el.setPointerCapture(e.pointerId);
    const move = (m: PointerEvent) => setWidth(start + m.clientX - from);
    const up = () => { el.removeEventListener('pointermove', move); el.removeEventListener('pointerup', up); };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
  };
  return (
    <div className="resizer" role="separator" aria-orientation="vertical" aria-label="Resize the side bar"
         title="Drag to resize; double-click to reset" onPointerDown={down} onDoubleClick={() => setWidth(WIDTH.initial)} />
  );
}

export function SideBar() {
  const view = useSideBar((s) => s.view);
  const press = useSideBar((s) => s.press);
  const onDashboard = useDashboard((s) => s.doc !== null);
  const channel = useSideBar((s) => s.channel);
  const setChannel = useSideBar((s) => s.setChannel);
  const stars = useStars();
  const target = onDashboard ? channel : null;
  const label = VIEWS.find((v) => v.id === view)!.label;
  return (
    <aside className="side-bar" aria-label={label}>
      <header>
        <span>{label}{view === 'starred' && stars.ids.length > 0 && <span className="muted"> {stars.ids.length}</span>}</span>
        <button type="button" className="close" onClick={() => press(view)} title="Hide the side bar" aria-label="Hide the side bar">×</button>
      </header>
      <div className="side-body">
        {view !== 'reference' && onDashboard && <ChannelTarget value={channel} onChange={setChannel} />}
        {view !== 'reference' && !onDashboard && <div className="muted small pad">A click looks the node up in Reference.</div>}
        {view !== 'reference' && stars.error && <div className="error pad small">{(stars.error as Error).message}</div>}
        {view === 'find' && <Find stars={stars} target={target} />}
        {view === 'categories' && <CategoryTree stars={stars} target={target} />}
        {view === 'starred' && <Starred stars={stars} target={target} />}
        {view === 'reference' && <Reference stars={stars} />}
      </div>
      <Resizer />
    </aside>
  );
}
