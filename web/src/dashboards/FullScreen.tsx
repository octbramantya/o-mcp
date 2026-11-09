// One widget on its own, in place of the grid (design/frontend.md §4, decision 31): Grafana's "view
// panel", at `?widget=<id>`, so Back closes it, a reload keeps it, and a link opens it. The toolbar
// stays, with the range, Refresh and Save. In edit mode a settings panel lies on the right, resizable,
// with the title, the channel, the widget's own settings and Remove, and the widget redraws as they
// change: the place to tune one widget. Viewing, or read-only, it is the widget alone. Below 768 px the
// panel goes under the widget. The quick edit in the grid's cell stays as it was.
import type { CSSProperties } from 'react';
import { useState } from 'react';
import { Field } from '../widgets/common';
import type { View } from '../widgets/contract';
import { byType } from '../widgets/registry';
import { Resizer } from '../ui/Resizer';
import { Select } from '../ui/Select';
import type { Widget } from './document';
import { CHANNELS } from './document';
import { useDashboard } from './store';
import { WidgetFrame } from './WidgetFrame';

const WIDTH = { min: 280, max: 720, initial: 380 };
const KEY = 'o-mcp.widget-panel';

function clamp(w: number) {
  const max = Math.min(WIDTH.max, Math.max(WIDTH.min, Math.round(window.innerWidth / 2)));
  return Math.round(Math.min(max, Math.max(WIDTH.min, w)));
}

/** The panel's width, remembered per browser as a convenience: storage may fail. */
function stored(): number {
  try {
    const w = Number(localStorage.getItem(KEY));
    return w ? clamp(w) : WIDTH.initial;
  } catch {
    return WIDTH.initial;
  }
}

export function FullScreen({ widget, view }: { widget: Widget; view: View }) {
  const editing = useDashboard((s) => s.editing && !s.readOnly);
  const [width, setWidthState] = useState(stored);
  const setWidth = (w: number) => {
    const c = clamp(w);
    setWidthState(c);
    try { localStorage.setItem(KEY, String(c)); } catch { /* not remembered */ }
  };
  return (
    <div className={`full-body${editing ? ' with-panel' : ''}`} style={{ '--panel-w': `${width}px` } as CSSProperties}>
      <div className="full-widget"><WidgetFrame widget={widget} view={view} full /></div>
      {editing && (
        <aside className="widget-panel" aria-label="Widget settings">
          <Resizer label="Resize the settings panel" edge="left" width={() => width} setWidth={setWidth} initial={WIDTH.initial} />
          <Panel widget={widget} />
        </aside>
      )}
    </div>
  );
}

function Panel({ widget }: { widget: Widget }) {
  const updateWidget = useDashboard((s) => s.updateWidget);
  const removeWidget = useDashboard((s) => s.removeWidget);
  const type = byType.get(widget.type);
  const settings = { ...type?.defaults, ...widget.settings };
  return (
    <div className="panel-body">
      <section className="settings">
        <h4>{type?.label ?? widget.type}</h4>
        <Field label="Title">
          <input value={widget.title ?? ''} placeholder={type?.label ?? widget.type}
                 onChange={(e) => updateWidget(widget.id, { title: e.target.value || null })} />
        </Field>
        <Field label="Channel">
          <Select label="Channel" value={widget.channel ?? 'none'}
                  options={[{ id: 'none', label: 'No channel' }, ...CHANNELS.map((c) => ({ id: c.id, label: `Channel ${c.id}` }))]}
                  onChange={(v) => updateWidget(widget.id, { channel: (v === 'none' ? null : v) as Widget['channel'] })} />
        </Field>
      </section>
      {type?.Settings && (
        <section className="settings">
          <h4>Settings</h4>
          <type.Settings settings={settings} setSettings={(s: object) => updateWidget(widget.id, { settings: s })} />
        </section>
      )}
      <section className="settings">
        <button type="button" className="danger" onClick={() => removeWidget(widget.id)}>Remove the widget</button>
      </section>
    </div>
  );
}
