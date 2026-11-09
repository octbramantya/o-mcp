// The box around every widget (design/frontend.md §4): header with the drag handle, the channel and,
// while editing, settings (the quick edit, in place of the widget's body), full screen and remove, and
// otherwise an Edit shown on hover that puts the whole dashboard in edit mode, and full screen; an error
// boundary, so one widget failing never blanks the canvas. In full screen (`full`, decision 31) the
// header holds only the title: the settings panel beside it holds the rest.
import { useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Select } from '../ui/Select';
import { ErrorBoundary } from 'react-error-boundary';
import { byType, retired } from '../widgets/registry';
import type { View } from '../widgets/contract';
import type { ChannelId, Widget } from './document';
import { CHANNELS } from './document';
import { useDashboard } from './store';

export function WidgetFrame({ widget, view, full = false }: { widget: Widget; view: View; full?: boolean }) {
  const editing = useDashboard((s) => s.editing);
  const readOnly = useDashboard((s) => s.readOnly);
  const entity = useDashboard((s) => (widget.channel ? s.doc?.channels[widget.channel] : undefined));
  const updateWidget = useDashboard((s) => s.updateWidget);
  const removeWidget = useDashboard((s) => s.removeWidget);
  const setChannel = useDashboard((s) => s.setChannel);
  const setEditing = useDashboard((s) => s.setEditing);
  const zoomTo = useDashboard((s) => s.zoom);
  const [showSettings, setShowSettings] = useState(false);
  const [, setParams] = useSearchParams();
  // `fromGrid` tells Back it may step back in history rather than replace the entry
  const expand = () => setParams({ widget: widget.id }, { state: { fromGrid: true } });
  const type = byType.get(widget.type);
  const channel = CHANNELS.find((c) => c.id === widget.channel);
  const setSettings = (settings: object) => updateWidget(widget.id, { settings });
  const settings = { ...type?.defaults, ...widget.settings };
  const select = widget.channel ? (e: Parameters<typeof setChannel>[1]) => setChannel(widget.channel as ChannelId, e) : null;

  return (
    <div className="widget" style={channel ? { borderTopColor: channel.color } : undefined}>
      <header className={editing && !full ? 'drag editing' : undefined}>
        {channel && <span className="dot" style={{ background: channel.color }} title={`Channel ${channel.id}`} />}
        {editing && !readOnly && !full ? (
          <input className="no-drag title-input" value={widget.title ?? ''} placeholder={type?.label ?? widget.type}
                 onChange={(e) => updateWidget(widget.id, { title: e.target.value || null })} />
        ) : (
          <span className="title">{widget.title ?? type?.label ?? widget.type}</span>
        )}
        {editing && !readOnly && !full && (
          <span className="no-drag actions">
            <Select label="Channel" title="Channel: widgets on one channel show the same node" value={widget.channel ?? 'none'}
                    options={[{ id: 'none', label: 'No channel' }, ...CHANNELS.map((c) => ({ id: c.id, label: `Channel ${c.id}` }))]}
                    onChange={(v) => updateWidget(widget.id, { channel: (v === 'none' ? null : v) as Widget['channel'] })} />
            {type?.Settings && <button type="button" onClick={() => setShowSettings(!showSettings)}>{showSettings ? 'Done' : 'Settings'}</button>}
            <FullScreenButton onPress={expand} />
            <button type="button" onClick={() => removeWidget(widget.id)}>Remove</button>
          </span>
        )}
        {!editing && !full && (
          <span className="actions hover-only">
            {!readOnly && <button type="button" title="Edit the dashboard" onClick={() => setEditing(true)}>Edit</button>}
            <FullScreenButton onPress={expand} />
          </span>
        )}
      </header>
      <div className="body">
        {!type ? (
          <div className="muted pad">{retired.get(widget.type) ?? `This dashboard has a "${widget.type}" widget, which this version of the frontend doesn't know.`}</div>
        ) : showSettings && editing && !full && type.Settings ? (
          <div className="settings scroll"><type.Settings settings={settings} setSettings={setSettings} /></div>
        ) : (
          <ErrorBoundary resetKeys={[widget.settings, view.tick]} fallbackRender={({ error, resetErrorBoundary }) => (
            <div className="error pad">
              This widget failed: {(error as Error).message} <button type="button" onClick={resetErrorBoundary}>Retry</button>
            </div>
          )}>
            <type.View settings={settings} setSettings={setSettings} entity={entity}
                       select={select} view={view} editing={editing} zoom={(from, to) => zoomTo({ from, to })} />
          </ErrorBoundary>
        )}
      </div>
    </div>
  );
}

function FullScreenButton({ onPress }: { onPress: () => void }) {
  return <button type="button" className="expand" aria-label="Full screen" title="Show this widget on its own" onClick={onPress}>⤢</button>;
}
