// The grid (design/frontend.md §4): 24 columns that follow the screen's width, rows of a fixed
// height, vertical compaction and no overlap, as Grafana's. Minimum sizes come from the registry
// when drawn. Below 768 px the widgets stack in one column, and nothing is moved or saved there.
import { useMemo, useState } from 'react';
import type { Layout } from 'react-grid-layout';
import { Responsive, WidthProvider } from 'react-grid-layout';
import 'react-grid-layout/css/styles.css';
import 'react-resizable/css/styles.css';
import { byType } from '../widgets/registry';
import type { View } from '../widgets/contract';
import type { Dashboard } from './document';
import { COLUMNS, ROW_HEIGHT } from './document';
import { useDashboard } from './store';
import { WidgetFrame } from './WidgetFrame';

const Grid = WidthProvider(Responsive);

export function Canvas({ doc, view }: { doc: Dashboard; view: View }) {
  const editing = useDashboard((s) => s.editing && !s.readOnly);
  const change = useDashboard((s) => s.change);
  const [wide, setWide] = useState(true);
  const layout: Layout[] = useMemo(() => doc.widgets.map((w) => {
    const t = byType.get(w.type);
    const minW = Math.min(t?.minW ?? 2, COLUMNS), minH = t?.minH ?? 2;
    return { i: w.id, x: w.x, y: w.y, w: Math.max(w.w, minW), h: Math.max(w.h, minH), minW, minH };
  }), [doc.widgets]);
  // one column, in reading order (top to bottom, then left to right), each at its own height
  const stacked: Layout[] = useMemo(() => [...layout].sort((a, b) => a.y - b.y || a.x - b.x)
    .map((l, i) => ({ i: l.i, x: 0, y: i, w: 1, h: l.h, minW: 1, minH: l.minH })), [layout]);

  const moved = (l: Layout[]) => wide && change((d) => ({
    ...d,
    widgets: d.widgets.map((w) => {
      const p = l.find((x) => x.i === w.id);
      return p ? { ...w, x: p.x, y: p.y, w: p.w, h: p.h } : w;
    }),
  }));

  if (!doc.widgets.length) {
    return <div className="empty">This dashboard is empty. {editing ? 'Add a widget from the toolbar.' : 'Choose Edit to add widgets.'}</div>;
  }
  return (
    <Grid className="canvas" layouts={{ lg: layout, xs: stacked }} breakpoints={{ lg: 768, xs: 0 }} cols={{ lg: COLUMNS, xs: 1 }}
          rowHeight={ROW_HEIGHT} margin={[8, 8]} compactType="vertical" preventCollision={false}
          isDraggable={editing && wide} isResizable={editing && wide}
          onBreakpointChange={(b) => setWide(b === 'lg')} draggableHandle=".drag" draggableCancel=".no-drag"
          onDragStop={(l) => moved(l)} onResizeStop={(l) => moved(l)}>
      {doc.widgets.map((w) => (
        <div key={w.id}><WidgetFrame widget={w} view={view} /></div>
      ))}
    </Grid>
  );
}
