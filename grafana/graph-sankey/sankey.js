// graph.sankey for Grafana Business Charts (Apache ECharts).
// Query: sankey.sql. Setup: README.md.
//
// Draws whatever graph.sankey returns and names no node, category or colour: labels, colours and
// order all come from the rows. A node inserted into the graph appears without editing this code.
//
//   colour  a node takes the `color` of the link that ends at it (its category's display_color);
//           a source, which nothing feeds, takes the colour of its link to Supply
//   order   each column is one level of the tree (nodeAlign left). Within a column, nodes follow a
//           walk of the tree from the sources, taking children in row order (the category tree by
//           its sort order, then nodes by value), so branches never cross; layoutIterations is 0
//   ≈       a link with is_ambiguous = true was solved, not metered (the gas engine today), and is
//           drawn fainter with a note in its tooltip
//
// Energy only: the sankey shows energy flow, and graph.sankey has no cost mode (062, README.md).

const series = context.panel.data.series[0];
const field = (name) => series && series.fields.find((f) => f.name === name);
const fSource = field('source'), fTarget = field('target'), fValue = field('value');
const fColor = field('color'), fKind = field('link_kind'), fAmb = field('is_ambiguous');

const theme = context.grafana.theme;
const textColor = (theme && theme.colors && theme.colors.text && theme.colors.text.primary) || '#d8d9da';
const mutedColor = (theme && theme.colors && theme.colors.text && theme.colors.text.secondary) || '#8e8e8e';

if (!fSource || !fTarget || !fValue || fSource.values.length === 0) {
  return {
    title: { text: 'No data for this range', left: 'center', top: 'middle',
             textStyle: { fontSize: 16, color: mutedColor } },
  };
}

// ----- links and nodes, in row order -----
const links = [];
const order = [];                 // node names in first-seen order
const colorOf = {};               // node -> colour
const seen = new Set();
const see = (name) => { if (!seen.has(name)) { seen.add(name); order.push(name); } };

for (let i = 0; i < fSource.values.length; i++) {
  const source = fSource.values[i];
  const target = fTarget.values[i];
  const value = Number(fValue.values[i]);
  const color = fColor ? fColor.values[i] : null;
  const ambiguous = fAmb ? Boolean(fAmb.values[i]) : false;
  if (!(value > 0)) continue;
  see(source); see(target);
  if (color) {
    colorOf[target] = color;                        // a target is coloured by the link into it
    if (!(source in colorOf)) colorOf[source] = color;  // provisional; a later inflow overrides
  }
  links.push({
    source, target, value,
    kind: fKind ? fKind.values[i] : null,
    ambiguous,
    lineStyle: ambiguous ? { opacity: 0.12 } : undefined,
  });
}

const inflow = {}, outflow = {};
for (const l of links) {
  outflow[l.source] = (outflow[l.source] || 0) + l.value;
  inflow[l.target] = (inflow[l.target] || 0) + l.value;
}
const supply = links.filter((l) => l.kind === 'SUPPLY').reduce((s, l) => s + l.value, 0);
const total = (name) => inflow[name] || outflow[name] || 0;
const pct = (v) => (supply > 0 ? (100 * v / supply).toFixed(1) : '0.0');
// Negative residuals are not drawn (graph.sankey §3), so what leaves Supply can exceed what enters
const supplyNode = links.find((l) => l.kind === 'SUPPLY');
const hidden = supplyNode ? (outflow[supplyNode.target] || 0) - supply : 0;

// Walk the tree from the sources, children in row order
const children = {};
for (const l of links) (children[l.source] = children[l.source] || []).push(l.target);
const walked = [], done = new Set();
const walk = (n) => { if (done.has(n)) return; done.add(n); walked.push(n); (children[n] || []).forEach(walk); };
order.filter((n) => !inflow[n]).forEach(walk);
order.forEach(walk);              // anything unreachable from a source, in row order

// Labels under 0.1% of Supply would pile on top of each other; those nodes keep their bar and tooltip
const nodes = walked.map((name) => ({
  name,
  itemStyle: { color: colorOf[name] || '#9E9E9E', borderColor: colorOf[name] || '#9E9E9E' },
  label: { show: supply > 0 && total(name) / supply >= 0.001 },
}));

// ----- formatting -----
const full = (v) => v.toLocaleString('en-US', { maximumFractionDigits: 0 }) + ' kWh';
const short = (v) => (v >= 1e6 ? (v / 1e6).toFixed(2) + ' GWh' : v >= 1e3 ? (v / 1e3).toFixed(1) + ' MWh'
                    : v.toFixed(0) + ' kWh');

// graph.sankey works in whole days, site time; say which days are drawn
const tz = 'Asia/Jakarta';
const from = new Date(parseInt(context.grafana.replaceVariables('${__from}'), 10));
const to = new Date(parseInt(context.grafana.replaceVariables('${__to}'), 10) - 1);
const day = (d, withYear) => d.toLocaleDateString('en-GB', { timeZone: tz, day: 'numeric', month: 'short',
                                                             year: withYear ? 'numeric' : undefined });
const sameDay = day(from, true) === day(to, true);
const range = sameDay ? day(from, true) : `${day(from, false)} – ${day(to, true)}`;

return {
  backgroundColor: 'transparent',
  title: {
    text: 'Energy flow',
    subtext: `${range} (whole days, site time) · Supply ${short(supply)}`
      + (hidden > supply * 0.001 ? ` · categories exceed it by ${short(hidden)}: negative residuals, see diagnostics` : ''),
    left: 'center', top: 4,
    textStyle: { fontSize: 15, fontWeight: 'bold', color: textColor },
    subtextStyle: { fontSize: 12, color: mutedColor },
  },
  tooltip: {
    trigger: 'item',
    triggerOn: 'mousemove',
    confine: true,
    formatter: (p) => {
      if (p.dataType === 'edge') {
        const l = p.data;
        const ofSource = outflow[l.source] > 0 ? (100 * l.value / outflow[l.source]).toFixed(1) : '0.0';
        return `<b>${l.source} → ${l.target}</b><br/>`
          + `${full(l.value)}<br/>`
          + `${ofSource}% of ${l.source} · ${pct(l.value)}% of Supply`
          + (l.ambiguous ? '<br/><i>≈ solved, not metered: an estimate</i>' : '');
      }
      const n = p.data.name;
      let s = `<b>${n}</b><br/>`;
      if (inflow[n]) s += `In: ${full(inflow[n])}<br/>`;
      if (outflow[n]) s += `Out: ${full(outflow[n])}<br/>`;
      return s + `${pct(total(n))}% of Supply`;
    },
  },
  series: [{
    type: 'sankey',
    data: nodes,
    links,
    top: 56, bottom: 12, left: 8, right: 240,
    nodeWidth: 16,
    nodeGap: 8,
    nodeAlign: 'left',              // a column per tree level
    layoutIterations: 0,            // keep the walk order: branches don't cross
    draggable: true,
    emphasis: { focus: 'adjacency' },
    lineStyle: { color: 'gradient', curveness: 0.5, opacity: 0.3 },
    label: {
      color: textColor,
      fontSize: 11,
      position: 'right',
      formatter: (p) => {
        const v = total(p.data.name);
        return v / supply >= 0.002 ? `${p.data.name}  ${short(v)} (${pct(v)}%)` : p.data.name;
      },
    },
  }],
};
