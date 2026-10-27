// The box around every widget (design/frontend.md §4): header with the drag handle, the channel and,
// while editing, settings and remove, and otherwise an Edit shown on hover that puts the whole dashboard
// in edit mode; an error boundary, so one widget failing never blanks the canvas.
import { useState } from 'react';
import { ErrorBoundary } from 'react-error-boundary';
import { byType } from '../widgets/registry';
import type { View } from '../widgets/contract';
import type { ChannelId, Widget } from './document';
import { CHANNELS } from './document';
import { useDashboard } from './store';

export function WidgetFrame({ widget, view }: { widget: Widget; view: View }) {
  const editing = useDashboard((s) => s.editing);
  const readOnly = useDashboard((s) => s.readOnly);
  const entity = useDashboard((s) => (widget.channel ? s.doc?.channels[widget.channel] : undefined));
  const updateWidget = useDashboard((s) => s.updateWidget);
  const removeWidget = useDashboard((s) => s.removeWidget);
  const setChannel = useDashboard((s) => s.setChannel);
  const setEditing = useDashboard((s) => s.setEditing);
  const [showSettings, setShowSettings] = useState(false);
  const type = byType.get(widget.type);
  const channel = CHANNELS.find((c) => c.id === widget.channel);
  const setSettings = (settings: object) => updateWidget(widget.id, { settings });
  const settings = { ...type?.defaults, ...widget.settings };
  const select = widget.channel ? (e: Parameters<typeof setChannel>[1]) => setChannel(widget.channel as ChannelId, e) : null;

  return (
    <div className="widget" style={channel ? { borderTopColor: channel.color } : undefined}>
      <header className={editing ? 'drag editing' : undefined}>
        {channel && <span className="dot" style={{ background: channel.color }} title={`Channel ${channel.id}`} />}
        {editing && !readOnly ? (
          <input className="no-drag title-input" value={widget.title ?? ''} placeholder={type?.label ?? widget.type}
                 onChange={(e) => updateWidget(widget.id, { title: e.target.value || null })} />
        ) : (
          <span className="title">{widget.title ?? type?.label ?? widget.type}</span>
        )}
        {editing && !readOnly && (
          <span className="no-drag actions">
            <select value={widget.channel ?? ''} title="Channel: widgets on one channel show the same node"
                    onChange={(e) => updateWidget(widget.id, { channel: (e.target.value || null) as Widget['channel'] })}>
              <option value="">No channel</option>
              {CHANNELS.map((c) => <option key={c.id} value={c.id}>Channel {c.id}</option>)}
            </select>
            {type?.Settings && <button type="button" onClick={() => setShowSettings(!showSettings)}>{showSettings ? 'Done' : 'Settings'}</button>}
            <button type="button" onClick={() => removeWidget(widget.id)}>Remove</button>
          </span>
        )}
        {!editing && !readOnly && (
          <span className="actions hover-only">
            <button type="button" title="Edit the dashboard" onClick={() => setEditing(true)}>Edit</button>
          </span>
        )}
      </header>
      <div className="body">
        {!type ? (
          <div className="muted pad">This dashboard has a "{widget.type}" widget, which this version of the frontend doesn't know.</div>
        ) : showSettings && editing && type.Settings ? (
          <div className="settings scroll"><type.Settings settings={settings} setSettings={setSettings} /></div>
        ) : (
          <ErrorBoundary resetKeys={[widget.settings, view.tick]} fallbackRender={({ error, resetErrorBoundary }) => (
            <div className="error pad">
              This widget failed: {(error as Error).message} <button type="button" onClick={resetErrorBoundary}>Retry</button>
            </div>
          )}>
            <type.View settings={settings} setSettings={setSettings} entity={entity}
                       select={select} view={view} editing={editing} />
          </ErrorBoundary>
        )}
      </div>
    </div>
  );
}
