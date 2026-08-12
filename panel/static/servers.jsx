// Servers & Tunnels page

const TUNNEL_METHODS = [
  { value: 'haproxy',          label: 'HAProxy',          desc: 'TCP load-balancer, battle-tested',                    reverse: false },
  { value: 'xray',             label: 'Xray',             desc: 'Dokodemo-door TCP/UDP relay',                         reverse: false },
  { value: 'gost',             label: 'GOST',             desc: 'Go Simple Tunnel — TCP + UDP',                        reverse: false },
  { value: 'backhaul',         label: 'Backhaul',         desc: 'Reverse tunnel — great for filtered IPs',             reverse: true  },
  { value: 'backhaul_premium', label: 'Backhaul Premium', desc: 'High-perf reverse tunnel with ICMP/BIP IPX support',  reverse: true  },
  { value: 'socat',            label: 'Socat',            desc: 'Simple TCP relay, works everywhere',                  reverse: false },
  { value: 'iptables',         label: 'iptables',         desc: 'Kernel-level DNAT — zero overhead',                  reverse: false },
  { value: 'nginx',            label: 'Nginx',            desc: 'Stream proxy — if already installed',                 reverse: false },
  { value: 'frp',              label: 'FRP',              desc: 'Fast Reverse Proxy by fatedier',                      reverse: true  },
  { value: 'rathole',          label: 'Rathole',          desc: 'Rust reverse proxy — very lightweight',               reverse: true  },
  { value: 'chisel',           label: 'Chisel',           desc: 'HTTP tunnel over WebSocket',                          reverse: true  },
];

const BH_TRANSPORTS  = ['tcp','tls','ws','wss','tcpmux','wssmux'];
const BHP_TRANSPORTS = ['tcp','tcpmux','wss','wssmux','tls','tlsmux'];
const BHP_IPX_PROFILES = ['icmp','bip','ipip','udp','gre','tcp'];
const BHP_TUNING_PROFILES = ['balanced','fast','latency','resource'];
const FRP_PROTOCOLS  = ['tcp','kcp','ws','wss'];
const RH_TRANSPORTS  = ['tcp','tls','noise'];

const METHOD_COLOR = {
  haproxy:          'oklch(70% 0.16 30)',  xray:             'oklch(72% 0.14 240)',
  gost:             'oklch(72% 0.16 175)', backhaul:         'oklch(70% 0.18 300)',
  backhaul_premium: 'oklch(72% 0.20 315)', socat:            'oklch(72% 0.14 60)',
  iptables:         'oklch(70% 0.14 200)', nginx:            'oklch(74% 0.13 130)',
  frp:              'oklch(72% 0.16 80)',  rathole:          'oklch(70% 0.16 20)',
  chisel:           'oklch(72% 0.14 280)',
};

const SERVER_TYPE_COLORS = {
  in: 'oklch(70% 0.18 300)', out: 'oklch(72% 0.14 175)', both: 'oklch(70% 0.18 30)',
};

// ── ServersPage ───────────────────────────────────────────────────────────────
const ServersPage = ({ pushToast }) => {
  const [tab,     setTab]     = React.useState('tunnels');
  const [servers, setServers] = React.useState([]);
  const [tunnels, setTunnels] = React.useState([]);
  const [loading, setLoading] = React.useState(true);
  const [filter,  setFilter]  = React.useState('all');
  const [showAdd,       setShowAdd]       = React.useState(false);
  const [showAddTunnel, setShowAddTunnel] = React.useState(false);
  const [editTunnel,    setEditTunnel]    = React.useState(null);
  const [editServer,    setEditServer]    = React.useState(null);
  const [expandedTunnel,setExpandedTunnel]= React.useState(null);
  const load = () => {
    setLoading(true);
    Promise.all([
      fetch('/api/servers').then(r => r.json()),
      fetch('/api/tunnels').then(r => r.json()),
    ]).then(([sd, td]) => {
      setServers(sd.servers || []);
      setTunnels(td.tunnels || []);
      setLoading(false);
    }).catch(() => setLoading(false));
  };

  React.useEffect(() => { load(); }, []);

  const panelOrigin = window.location.origin;

  const scriptUrl = (t, side, action='install') =>
    `${panelOrigin}/setup/tunnel/${t.id}/${side}/${t.secret}?action=${action}`;

  const curlCmd = (t, side, action='install') =>
    `bash <(curl -fsSL "${scriptUrl(t, side, action)}")`;

  const deleteServer = (id) => {
    if (!confirm('Remove this server?')) return;
    fetch(`/api/servers/${id}`, { method: 'DELETE' })
      .then(() => { load(); pushToast('Server removed'); });
  };

  const deleteTunnel = (id) => {
    if (!confirm('Delete this tunnel?')) return;
    fetch(`/api/tunnels/${id}`, { method: 'DELETE' })
      .then(() => { load(); pushToast('Tunnel deleted'); });
  };

  const toggleTunnel = (t) => {
    fetch(`/api/tunnels/${t.id}`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: !t.enabled }),
    }).then(() => load());
  };

  const visibleServers = filter === 'all'
    ? servers
    : servers.filter(s => (s.server_type || 'out') === filter);

  return (
    <div className="page" data-screen-label="servers">
      {/* header */}
      <div className="section-head" style={{ marginBottom: 14 }}>
        <div>
          <div className="section-title">Servers &amp; Tunnels</div>
          <div className="section-sub">{servers.length} servers · {tunnels.length} tunnels</div>
        </div>
        <div className="srv-header-actions">
          {tab === 'servers' && (
            <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
              <Icons.Plus size={14}/> Add server
            </button>
          )}
          {tab === 'tunnels' && (
            <button className="btn btn-primary" onClick={() => setShowAddTunnel(true)}>
              <Icons.Plus size={14}/> Add tunnel
            </button>
          )}
        </div>
      </div>

      {/* tab bar */}
      <div className="srv-tab-bar">
        {[['tunnels','Tunnels'],['servers','Servers'],['guide','How it works']].map(([k, label]) => (
          <button key={k} onClick={() => setTab(k)} style={{
            padding: '6px 16px', borderRadius: 'var(--r-md)', fontSize: 13, fontWeight: 500,
            cursor: 'pointer', border: '1px solid var(--border)',
            background: tab === k ? 'var(--accent)' : 'var(--surface-2)',
            color: tab === k ? '#fff' : 'var(--text-2)', transition: 'all 0.12s',
          }}>{label}</button>
        ))}
      </div>

      {loading && (
        <div style={{ padding: 40, textAlign: 'center', color: 'var(--muted)' }}>Loading…</div>
      )}

      {/* ══════════ HOW IT WORKS ══════════ */}
      {tab === 'guide' && <HowItWorksGuide/>}

      {/* ══════════ TUNNELS TAB ══════════ */}
      {!loading && tab === 'tunnels' && (
        <>
          {tunnels.length === 0 && (
            <div className="card" style={{ padding: 40, textAlign: 'center', color: 'var(--muted)' }}>
              <Icons.Network size={32} style={{ marginBottom: 12, opacity: 0.4 }}/>
              <div style={{ fontWeight: 500, fontSize: 14 }}>No tunnels yet</div>
              <div style={{ fontSize: 12.5, marginTop: 6, maxWidth: 480, margin: '8px auto 0' }}>
                A tunnel forwards connections from an IN server (entry point) to this panel server (where Xray runs).
                Once created, you get a one-line install command to paste on each server.
              </div>
              <div style={{ marginTop: 14, display: 'flex', gap: 8, justifyContent: 'center' }}>
                <button className="btn btn-ghost" onClick={() => setTab('guide')}>📖 How it works</button>
                <button className="btn btn-primary" onClick={() => setShowAddTunnel(true)}>
                  <Icons.Plus size={13}/> Create first tunnel
                </button>
              </div>
            </div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            {tunnels.map((t, i) => {
              const mc = METHOD_COLOR[t.method] || 'var(--accent)';
              const mi = TUNNEL_METHODS.find(m => m.value === t.method) || {};
              const expanded = expandedTunnel === t.id;
              const isReverse = mi.reverse;

              return (
                <div key={t.id} className="card" style={{ overflow: 'hidden', animationDelay: `${i*30}ms` }}>
                  {/* ── summary row ── */}
                  <div style={{
                    display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px',
                    flexWrap: 'wrap', cursor: 'pointer',
                  }} onClick={() => setExpandedTunnel(expanded ? null : t.id)}>
                    {/* method */}
                    <div style={{
                      padding: '4px 10px', borderRadius: 'var(--r-sm)', fontSize: 11.5, fontWeight: 700,
                      background: mc + '22', color: mc, letterSpacing: '0.04em', flexShrink: 0,
                    }}>{mi.label || t.method.toUpperCase()}</div>

                    {isReverse && (
                      <div style={{
                        padding: '2px 7px', borderRadius: 'var(--r-sm)', fontSize: 10, fontWeight: 600,
                        background: 'oklch(70% 0.18 300 / 0.15)', color: 'oklch(70% 0.18 300)',
                        flexShrink: 0,
                      }}>REVERSE</div>
                    )}

                    {/* name & route */}
                    <div style={{ flex: 1, minWidth: 180 }}>
                      <div style={{ fontWeight: 600, fontSize: 13.5 }}>{t.name}</div>
                      <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 2, fontFamily: 'var(--font-mono)' }}>
                        <span style={{ color: SERVER_TYPE_COLORS.in }}>
                          {t.in_server ? t.in_server.ip : 'IN'}
                        </span>
                        <span>:{t.in_port}</span>
                        <span style={{ color: 'var(--muted)', margin: '0 4px' }}>→</span>
                        <span style={{ color: SERVER_TYPE_COLORS.out }}>Panel</span>
                        <span>:{t.out_port}</span>
                      </div>
                    </div>

                    {/* enabled toggle */}
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}
                         onClick={e => { e.stopPropagation(); toggleTunnel(t); }}>
                      <div className={`switch ${t.enabled ? 'on' : ''}`}/>
                      <span style={{ fontSize: 11.5, color: 'var(--muted)', width: 22 }}>
                        {t.enabled ? 'on' : 'off'}
                      </span>
                    </div>

                    {/* expand arrow */}
                    <Icons.ChevDown size={14} style={{
                      color: 'var(--muted)', transition: 'transform 0.2s',
                      transform: expanded ? 'rotate(180deg)' : 'none', flexShrink: 0,
                    }}/>
                  </div>

                  {/* ── expanded: install commands ── */}
                  {expanded && (
                    <ExpandedTunnel
                      t={t}
                      isReverse={isReverse}
                      curlCmd={curlCmd}
                      scriptUrl={scriptUrl}
                      pushToast={pushToast}
                      onEdit={() => setEditTunnel(t)}
                      onDelete={() => deleteTunnel(t.id)}
                      onInboundCreated={() => { load(); pushToast('Inbound created for tunnel'); }}
                    />
                  )}
                </div>
              );
            })}
          </div>
        </>
      )}

      {/* ══════════ SERVERS TAB ══════════ */}
      {!loading && tab === 'servers' && (
        <>
          {/* Active outbound summary */}
          {servers.filter(s => s.is_active_outbound).length > 0 && (
            <div style={{
              marginBottom: 14, padding: '10px 14px', borderRadius: 'var(--r-md)',
              background: 'oklch(72% 0.18 140 / 0.07)',
              border: '1px solid oklch(72% 0.18 140 / 0.35)',
              display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap',
            }}>
              <div style={{ width: 8, height: 8, borderRadius: '50%', background: 'oklch(72% 0.18 140)', flexShrink: 0 }}/>
              <div style={{ flex: 1, fontSize: 12.5, color: 'oklch(60% 0.18 140)', fontWeight: 600 }}>
                {servers.filter(s => s.is_active_outbound).length} active outbound(s):&nbsp;
                {servers.filter(s => s.is_active_outbound).map(s => `${s.name} (${s.ip})`).join(' · ')}
              </div>
              <button className="btn btn-ghost" style={{ fontSize: 11, padding: '3px 10px', color: 'var(--danger)' }}
                onClick={() => {
                  fetch('/api/servers/clear-active-outbound', { method: 'POST' })
                    .then(() => { load(); pushToast('All outbounds cleared'); });
                }}>
                Clear all
              </button>
            </div>
          )}

          {/* type filter */}
          <div style={{ display: 'flex', gap: 6, marginBottom: 14, flexWrap: 'wrap' }}>
            {[['all','All'],['in','IN (entry)'],['out','OUT (exit)'],['both','Both']].map(([k,l]) => (
              <button key={k} onClick={() => setFilter(k)} style={{
                padding: '4px 12px', borderRadius: 'var(--r-sm)', fontSize: 12, fontWeight: 500,
                cursor: 'pointer',
                border: `1px solid ${filter===k ? 'var(--accent)' : 'var(--border)'}`,
                background: filter===k ? 'var(--accent-tint)' : 'var(--surface-2)',
                color: filter===k ? 'var(--accent)' : 'var(--text-2)',
              }}>{l}</button>
            ))}
          </div>

          {visibleServers.length === 0 && (
            <div className="card" style={{ padding: 48, textAlign: 'center', color: 'var(--muted)' }}>
              <Icons.Server size={32} style={{ marginBottom: 12, opacity: 0.4 }}/>
              <div>No servers found.</div>
              <div style={{ fontSize: 12.5, marginTop: 6 }}>
                Add an IN server (relay/entry) and an OUT server (exit node / panel host).
              </div>
            </div>
          )}

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(290px, 1fr))', gap: 14 }}>
            {visibleServers.map((s, i) => {
              const offline  = s.status === 'down';
              const degraded = s.status === 'degraded';
              const r = fakeRand(s.id * 13 + 7);
              const spark = Array.from({ length: 24 }, () =>
                offline ? 0 : Math.max(5, (s.load||0) + (r()-0.5)*25));
              const stype = s.server_type || 'out';
              const scolor = SERVER_TYPE_COLORS[stype] || 'var(--accent)';
              const stypeLabel = { in: 'IN', out: 'OUT', both: 'IN+OUT' }[stype] || 'OUT';

              return (
                <div key={s.id} className="card hover" style={{ padding: 16, animationDelay: `${i*40}ms` }}>
                  <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', marginBottom: 10 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <div className="srv-flag" style={{ width: 42, height: 32, fontSize: 11.5 }}>
                        {(s.code||'XX').slice(0,2).toUpperCase()}
                      </div>
                      <div>
                        <div style={{ fontFamily: 'var(--font-mono)', fontWeight: 500, fontSize: 13.5 }}>{s.name}</div>
                        <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 2 }}>{s.region}</div>
                      </div>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 4 }}>
                      <Badge kind={s.status==='online' ? 'online' : s.status==='degraded' ? 'degraded' : 'down'}>
                        {s.status==='online' ? 'Online' : s.status==='degraded' ? 'Degraded' : 'Offline'}
                      </Badge>
                      <span style={{
                        fontSize: 10, fontWeight: 700, padding: '2px 6px',
                        borderRadius: 'var(--r-sm)',
                        background: scolor + '22', color: scolor, letterSpacing: '0.04em',
                      }}>{stypeLabel}</span>
                    </div>
                  </div>

                  <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '12px 0', borderTop: '1px dashed var(--border)', borderBottom: '1px dashed var(--border)' }}>
                    {!offline ? <Ring value={s.load||0} size={62}/> : (
                      <div style={{ width: 62, height: 62, display: 'grid', placeItems: 'center', color: 'var(--muted)' }}>
                        <Icons.Power size={20}/>
                      </div>
                    )}
                    <div style={{ flex: 1 }}>
                      <SRow label="IP"    val={s.ip||'—'}     mono/>
                      <SRow label="Ping"  val={offline ? '—' : `${s.ping||0} ms`}/>
                      <SRow label="Users" val={s.users||0}/>
                    </div>
                  </div>

                  <div style={{ marginTop: 12, height: 40 }}>
                    {!offline && <Sparkline data={spark} h={40} stroke={degraded ? 'var(--warn)' : 'var(--accent)'}/>}
                  </div>

                  {s.notes && (
                    <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 8, fontStyle: 'italic' }}>
                      {s.notes}
                    </div>
                  )}

                  <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                    <button className="btn btn-ghost" style={{ padding: '5px 10px', fontSize: 12, flex: 1 }}
                      onClick={() => setEditServer(s)}><Icons.Settings size={12}/> Edit</button>
                    <button className="btn btn-ghost" style={{ padding: '5px 10px', fontSize: 12, flex: 1 }}
                      onClick={() => pushToast(`Pinging ${s.name}…`)}><Icons.Activity size={12}/> Ping</button>
                    <button className="btn btn-ghost" style={{ padding: '5px 10px', fontSize: 12, color: 'var(--danger)' }}
                      onClick={() => deleteServer(s.id)}><Icons.Trash size={12}/></button>
                  </div>
                  {/* Xray bridge section for OUT servers */}
                  {(stype === 'out' || stype === 'both') && (
                    <OutProxyCard
                      server={s}
                      isActive={s.is_active_outbound}
                      onActivate={() => load()}
                      onDeactivate={() => load()}
                      pushToast={pushToast}
                    />
                  )}
                </div>
              );
            })}
          </div>
        </>
      )}

      {/* modals */}
      {showAdd && (
        <ServerModal onClose={() => setShowAdd(false)}
          onSave={() => { load(); setShowAdd(false); pushToast('Server added'); }}/>
      )}
      {editServer && (
        <ServerModal server={editServer} onClose={() => setEditServer(null)}
          onSave={() => { load(); setEditServer(null); pushToast('Server updated'); }}/>
      )}
      {showAddTunnel && (
        <TunnelModal servers={servers} onClose={() => setShowAddTunnel(false)}
          onSave={() => { load(); setShowAddTunnel(false); pushToast('Tunnel created'); }}
          pushToast={pushToast}/>
      )}
      {editTunnel && (
        <TunnelModal tunnel={editTunnel} servers={servers}
          onClose={() => setEditTunnel(null)}
          onSave={() => { load(); setEditTunnel(null); pushToast('Tunnel updated'); }}
          pushToast={pushToast}/>
      )}
    </div>
  );
};

// ── ExpandedTunnel: expanded view with install/uninstall/reinstall tabs ──────
const ExpandedTunnel = ({ t, isReverse, curlCmd, scriptUrl, pushToast, onEdit, onDelete, onInboundCreated }) => {
  const [scriptAction, setScriptAction] = React.useState('install');
  const [creating, setCreating] = React.useState(false);

  const createInbound = () => {
    const inIp = t.in_server?.ip || '';
    const tag  = `tunnel-${(t.name||'').toLowerCase().replace(/\s+/g,'-').slice(0,20)}`;
    setCreating(true);
    fetch('/api/inbounds', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tag, proto: 'vless', protocol: 'vless', network: 'tcp', tls: 'none',
        port: t.out_port, server_addr: inIp, server_port: t.in_port,
      }),
    })
      .then(r => r.json())
      .then(d => {
        setCreating(false);
        if (d.error) { pushToast('Error: ' + d.error); return; }
        onInboundCreated();
      })
      .catch(() => { setCreating(false); pushToast('Failed to create inbound'); });
  };

  const ACTION_TABS = [
    { key: 'install',   label: '⬇ Install',   color: 'var(--accent)' },
    { key: 'uninstall', label: '🗑 Uninstall', color: 'var(--danger)' },
    { key: 'reinstall', label: '↺ Reinstall',  color: 'var(--warn)'   },
  ];

  return (
    <div style={{ borderTop: '1px solid var(--border)', background: 'var(--surface-2)', padding: '16px 18px' }}>
      {/* Action tabs */}
      <div style={{ display: 'flex', gap: 6, marginBottom: 14 }}>
        {ACTION_TABS.map(a => (
          <button key={a.key} onClick={() => setScriptAction(a.key)} style={{
            padding: '4px 12px', borderRadius: 'var(--r-sm)', fontSize: 11.5, fontWeight: 600,
            cursor: 'pointer', border: `1px solid ${scriptAction === a.key ? a.color : 'var(--border)'}`,
            background: scriptAction === a.key ? a.color + '18' : 'var(--surface)',
            color: scriptAction === a.key ? a.color : 'var(--muted)', transition: 'all 0.12s',
          }}>{a.label}</button>
        ))}
        {scriptAction !== 'install' && (
          <div style={{ marginLeft: 4, fontSize: 11.5, color: 'var(--muted)', alignSelf: 'center' }}>
            {scriptAction === 'uninstall' ? 'Removes services/configs from server' : 'Removes then reinstalls from scratch'}
          </div>
        )}
      </div>

      {isReverse ? (
        <>
          <StepInstall
            step={1}
            label={`Run on Panel server (${scriptAction})`}
            hint={`this panel server — ${scriptAction === 'install' ? 'installs server component' : scriptAction}`}
            cmd={curlCmd(t, 'out', scriptAction)}
            url={scriptUrl(t, 'out', scriptAction)}
            color={SERVER_TYPE_COLORS.out}
            pushToast={pushToast}
          />
          <div style={{ margin: '14px 0', borderTop: '1px dashed var(--border)' }}/>
          <StepInstall
            step={2}
            label={`Run on IN server (${scriptAction})`}
            hint={`${t.in_server?.ip || 'IN server'} — ${scriptAction === 'install' ? 'installs client component' : scriptAction}`}
            cmd={curlCmd(t, 'in', scriptAction)}
            url={scriptUrl(t, 'in', scriptAction)}
            color={SERVER_TYPE_COLORS.in}
            pushToast={pushToast}
          />
        </>
      ) : (
        <>
          <StepInstall
            step={1}
            label={`Run on IN server (${scriptAction})`}
            hint={`${t.in_server?.ip || 'IN server'} — ${scriptAction === 'install' ? 'installs and configures tunnel' : scriptAction}`}
            cmd={curlCmd(t, 'in', scriptAction)}
            url={scriptUrl(t, 'in', scriptAction)}
            color={SERVER_TYPE_COLORS.in}
            pushToast={pushToast}
          />
          <StepInstall
            step={2}
            label={`Run on Panel server (${scriptAction})`}
            hint={`this panel server — ${scriptAction === 'install' ? 'ensures Xray is installed' : scriptAction}`}
            cmd={curlCmd(t, 'out', scriptAction)}
            url={scriptUrl(t, 'out', scriptAction)}
            color={SERVER_TYPE_COLORS.out}
            pushToast={pushToast}
          />
        </>
      )}

      {/* Footer: token + buttons */}
      <div style={{ marginTop: 14, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
        <div style={{ fontSize: 11.5, color: 'var(--muted)' }}>
          <span>Auth token: </span>
          <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--text-2)' }}>{t.secret}</span>
        </div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '5px 10px', color: 'oklch(72% 0.18 140)' }}
            onClick={createInbound} disabled={creating}
            title="Create a VLESS/TCP inbound on the IN server port for this tunnel">
            <Icons.Plus size={12}/> {creating ? 'Creating…' : 'Create inbound'}
          </button>
          <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '5px 10px' }} onClick={onEdit}>
            <Icons.Settings size={12}/> Edit
          </button>
          <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '5px 10px', color: 'var(--danger)' }} onClick={onDelete}>
            <Icons.Trash size={12}/> Delete
          </button>
        </div>
      </div>

      {/* Hint about IP in inbound */}
      {scriptAction === 'install' && t.in_server?.ip && (
        <div style={{
          marginTop: 10, padding: '8px 12px', borderRadius: 'var(--r-md)',
          background: 'oklch(72% 0.14 240 / 0.08)', border: '1px solid oklch(72% 0.14 240 / 0.25)',
          fontSize: 11.5, color: 'oklch(72% 0.14 240)', lineHeight: 1.6,
        }}>
          💡 After setup, click <strong>Create inbound</strong> above (or edit an existing inbound) and set
          the <em>Server address</em> to <code style={{ fontFamily: 'var(--font-mono)' }}>{t.in_server.ip}</code> so
          user configs point to the IN server IP.
        </div>
      )}
    </div>
  );
};

// ── StepInstall: one install step with copy button ────────────────────────────
const StepInstall = ({ step, label, hint, cmd, url, color, pushToast }) => (
  <div>
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
      <div style={{
        width: 22, height: 22, borderRadius: '50%', display: 'flex', alignItems: 'center',
        justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0,
        background: color + '33', color: color,
      }}>{step}</div>
      <div>
        <div style={{ fontSize: 12.5, fontWeight: 600, color: color }}>{label}</div>
        {hint && <div style={{ fontSize: 11.5, color: 'var(--muted)' }}>{hint}</div>}
      </div>
    </div>
    {/* install command */}
    <div style={{
      display: 'flex', alignItems: 'center', gap: 0,
      background: 'var(--surface)', border: '1px solid var(--border)',
      borderRadius: 'var(--r-md)', overflow: 'hidden',
    }}>
      <div style={{
        flex: 1, padding: '9px 12px', fontFamily: 'var(--font-mono)',
        fontSize: 11.5, color: 'var(--text-2)', wordBreak: 'break-all',
        userSelect: 'all',
      }}>{cmd}</div>
      <button
        onClick={() => copyText(cmd).then(() => pushToast('Command copied!'))}
        style={{
          padding: '0 14px', height: '100%', minHeight: 38,
          background: 'var(--surface-2)', border: 'none', borderLeft: '1px solid var(--border)',
          cursor: 'pointer', color: 'var(--text-2)', flexShrink: 0, display: 'flex',
          alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 500,
        }}
        title="Copy command"
      >
        <Icons.Copy size={13}/> Copy
      </button>
    </div>
    {/* or download link */}
    <div style={{ marginTop: 5, fontSize: 11.5, color: 'var(--muted)' }}>
      Or{' '}
      <a href={url} download style={{ color: 'var(--accent)', textDecoration: 'none' }}>
        download the .sh file
      </a>
      {' '}and inspect before running.
    </div>
  </div>
);

// ── tiny stat row ─────────────────────────────────────────────────────────────
const SRow = ({ label, val, mono }) => (
  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 4 }}>
    <span style={{ color: 'var(--muted)' }}>{label}</span>
    <span style={{ fontWeight: 500, fontFamily: mono ? 'var(--font-mono)' : undefined }}>{val}</span>
  </div>
);

// ── How it works guide ────────────────────────────────────────────────────────
const HowItWorksGuide = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
    {/* Overview */}
    <div className="card" style={{ padding: '18px 20px' }}>
      <div className="section-title" style={{ marginBottom: 10 }}>Overview</div>
      <div style={{ fontSize: 13.5, lineHeight: 1.7, color: 'var(--text-2)' }}>
        A tunnel relays traffic between an <strong style={{ color: SERVER_TYPE_COLORS.in }}>IN server</strong> (where
        users connect) and an <strong style={{ color: SERVER_TYPE_COLORS.out }}>OUT server</strong> (where Xray and
        this panel run). This is useful when the main server's IP is blocked in the user's country — users connect to
        a clean IP in another region, and the traffic is forwarded to the main server.
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 14, flexWrap: 'wrap' }}>
        {[
          { label: 'User', color: 'var(--muted)' },
          { label: '→', color: 'var(--muted)', plain: true },
          { label: 'IN server\n(relay)', color: SERVER_TYPE_COLORS.in },
          { label: '→', color: 'var(--muted)', plain: true },
          { label: 'OUT server\n(panel+Xray)', color: SERVER_TYPE_COLORS.out },
          { label: '→', color: 'var(--muted)', plain: true },
          { label: 'Internet', color: 'var(--muted)' },
        ].map((b, i) => b.plain ? (
          <span key={i} style={{ color: 'var(--muted)', fontSize: 16, fontWeight: 300 }}>{b.label}</span>
        ) : (
          <div key={i} style={{
            padding: '6px 14px', borderRadius: 'var(--r-md)', textAlign: 'center',
            background: b.color + '20', border: `1px solid ${b.color}44`, color: b.color,
            fontWeight: 600, fontSize: 12, whiteSpace: 'pre-line',
          }}>{b.label}</div>
        ))}
      </div>
    </div>

    {/* Step-by-step */}
    <div className="card" style={{ padding: '18px 20px' }}>
      <div className="section-title" style={{ marginBottom: 14 }}>Step-by-step setup</div>
      {[
        {
          n: 1, title: 'Add your IN servers',
          body: 'Go to the Servers tab. Add each relay/entry server with role IN. Set its IP address. The OUT side is always this panel server — no need to add it separately.',
        },
        {
          n: 2, title: 'Create a tunnel',
          body: 'Click "Add tunnel". Choose a method (HAProxy is simple and reliable; Backhaul/FRP/Rathole/Chisel are reverse tunnels — best when IN server can\'t accept inbound connections). Select the IN server and set the ports.',
        },
        {
          n: 3, title: 'Run the install command',
          body: 'Click a tunnel row to expand it. Copy the install command and paste it into an SSH session on the target server. The script installs the software, writes config files, and sets up a systemd service that starts automatically.',
        },
        {
          n: 4, title: 'Point your inbound to the IN server IP',
          body: 'In the Inbounds tab, edit your inbound and set "Server address (for links)" to the IN server\'s IP or domain. User subscription links will then point to the IN server.',
        },
      ].map(s => (
        <div key={s.n} style={{ display: 'flex', gap: 14, marginBottom: 16 }}>
          <div style={{
            width: 28, height: 28, borderRadius: '50%', background: 'var(--accent)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 13, fontWeight: 700, flexShrink: 0,
          }}>{s.n}</div>
          <div>
            <div style={{ fontWeight: 600, fontSize: 13.5, marginBottom: 4 }}>{s.title}</div>
            <div style={{ fontSize: 12.5, color: 'var(--text-2)', lineHeight: 1.65 }}>{s.body}</div>
          </div>
        </div>
      ))}
    </div>

    {/* Method comparison */}
    <div className="card" style={{ padding: '18px 20px' }}>
      <div className="section-title" style={{ marginBottom: 12 }}>Tunnel method comparison</div>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
          <thead>
            <tr style={{ borderBottom: '1px solid var(--border)' }}>
              {['Method','Type','Complexity','UDP','Notes'].map(h => (
                <th key={h} style={{ padding: '6px 10px', textAlign: 'left', color: 'var(--muted)', fontWeight: 600 }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {[
              ['HAProxy',  'Forward', '⭐',    '❌', 'Mature, TCP only, minimal overhead'],
              ['Xray',     'Forward', '⭐',    '✅', 'Uses dokodemo-door, TCP+UDP'],
              ['GOST',     'Forward', '⭐⭐',  '✅', 'Single binary, TCP+UDP'],
              ['iptables', 'Forward', '⭐',    '✅', 'Kernel-level, zero overhead'],
              ['socat',    'Forward', '⭐',    '❌', 'Simplest possible relay'],
              ['Nginx',    'Forward', '⭐⭐',  '✅', 'Good if Nginx already installed'],
              ['Backhaul', 'Reverse', '⭐⭐',  '✅', 'IN server connects out; good for filtered IPs'],
              ['FRP',      'Reverse', '⭐⭐',  '✅', 'Popular, stable, TOML config'],
              ['Rathole',  'Reverse', '⭐⭐',  '✅', 'Rust binary, very lightweight'],
              ['Chisel',   'Reverse', '⭐⭐',  '✅', 'Tunnels over HTTP/WebSocket'],
            ].map(([name, type, cx, udp, note]) => {
              const mc = METHOD_COLOR[name.toLowerCase()] || 'var(--accent)';
              return (
                <tr key={name} style={{ borderBottom: '1px solid var(--border-soft)' }}>
                  <td style={{ padding: '7px 10px' }}>
                    <span style={{
                      padding: '2px 8px', borderRadius: 'var(--r-sm)',
                      background: mc + '20', color: mc, fontWeight: 600, fontSize: 11.5,
                    }}>{name}</span>
                  </td>
                  <td style={{ padding: '7px 10px', color: type==='Reverse' ? 'oklch(70% 0.18 300)' : 'var(--text-2)' }}>
                    {type}
                  </td>
                  <td style={{ padding: '7px 10px' }}>{cx}</td>
                  <td style={{ padding: '7px 10px' }}>{udp}</td>
                  <td style={{ padding: '7px 10px', color: 'var(--muted)' }}>{note}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div style={{
        marginTop: 14, padding: '10px 14px', borderRadius: 'var(--r-md)',
        background: 'oklch(70% 0.18 300 / 0.08)', border: '1px solid oklch(70% 0.18 300 / 0.3)',
        fontSize: 12, color: 'var(--text-2)', lineHeight: 1.6,
      }}>
        <strong>When to use Reverse tunnels</strong>: If the IN server's IP is clean but it can't receive inbound
        connections (due to NAT or a strict firewall), use a reverse method. The IN server calls OUT — no
        inbound ports need to be open on IN.
      </div>
    </div>
  </div>
);

// ── OutProxyCard — Xray bridge on an OUT server ───────────────────────────────
const OutProxyCard = ({ server, isActive, onActivate, onDeactivate, pushToast }) => {
  const [open,    setOpen]    = React.useState(false);
  const [cfg,     setCfg]     = React.useState(null);
  const [loading, setLoading] = React.useState(false);
  const [port,    setPort]    = React.useState('');
  const [proto,   setProto]   = React.useState('vless');
  const [saving,  setSaving]  = React.useState(false);
  const [toggling,setToggling]= React.useState(false);

  const loadCfg = () => {
    setLoading(true);
    fetch(`/api/servers/${server.id}/out-proxy`)
      .then(r => r.json())
      .then(d => {
        setCfg(d);
        setPort(String(d.out_proxy_port || 10001));
        setProto(d.out_proxy_protocol || 'vless');
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  React.useEffect(() => { if (open) loadCfg(); }, [open]);

  const save = () => {
    setSaving(true);
    fetch(`/api/servers/${server.id}/out-proxy`, {
      method:'PUT', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({out_proxy_port: Number(port), out_proxy_protocol: proto}),
    }).then(r=>r.json()).then(d=>{setCfg(d);setSaving(false); pushToast('Bridge settings saved');});
  };

  const activate = () => {
    setToggling(true);
    // Save port/protocol first, then activate
    fetch(`/api/servers/${server.id}/out-proxy`, {
      method:'PUT', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({out_proxy_port: Number(port || cfg?.out_proxy_port || 10001), out_proxy_protocol: proto}),
    }).then(() =>
      fetch(`/api/servers/${server.id}/set-active-outbound`, {method:'POST'})
    ).then(r => r.json()).then(d => {
      setToggling(false);
      if (d.ok) { pushToast('Added to active outbounds — Xray restarted'); onActivate(); }
      else pushToast('Failed: ' + (d.error||''));
    }).catch(() => setToggling(false));
  };

  const deactivate = () => {
    setToggling(true);
    fetch(`/api/servers/${server.id}/remove-active-outbound`, {method:'POST'})
      .then(r => r.json())
      .then(d => {
        setToggling(false);
        if (d.ok) { pushToast('Removed from active outbounds — Xray restarted'); onDeactivate(); }
        else pushToast('Failed');
      }).catch(() => setToggling(false));
  };

  const scriptUrl = cfg ? cfg.script_url : '';
  const curlCmd   = scriptUrl ? `bash <(curl -fsSL "${scriptUrl}")` : '';

  return (
    <div style={{
      marginTop: 10, borderTop: '1px dashed var(--border)',
      paddingTop: 8,
    }}>
      {/* Header row */}
      <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', cursor:'pointer' }}
           onClick={() => setOpen(v => !v)}>
        <div style={{ display:'flex', alignItems:'center', gap:6 }}>
          <div style={{
            width:8, height:8, borderRadius:'50%',
            background: isActive ? 'oklch(72% 0.18 140)' : 'var(--muted)',
          }}/>
          <span style={{ fontSize:12, fontWeight:600, color: isActive ? 'oklch(72% 0.18 140)' : 'var(--muted)' }}>
            Xray bridge {isActive ? '— ACTIVE OUTBOUND' : ''}
          </span>
        </div>
        <Icons.ChevDown size={12} style={{ color:'var(--muted)', transform: open?'rotate(180deg)':'none', transition:'0.2s' }}/>
      </div>

      {open && (
        <div style={{ marginTop: 10, display:'flex', flexDirection:'column', gap:10 }}>
          {loading && <div style={{color:'var(--muted)',fontSize:12}}>Loading…</div>}

          {cfg && !loading && (
            <>
              {/* Port + Protocol */}
              <div style={{display:'flex',gap:8}}>
                <div style={{flex:1}}>
                  <div style={{fontSize:11, color:'var(--muted)', marginBottom:3}}>Bridge port</div>
                  <input className="input mono" type="number" value={port}
                    onChange={e=>setPort(e.target.value)} style={{fontSize:12}}/>
                </div>
                <div style={{flex:1}}>
                  <div style={{fontSize:11, color:'var(--muted)', marginBottom:3}}>Protocol</div>
                  <div style={{display:'flex',gap:4}}>
                    {['vless','vmess'].map(p=>(
                      <button key={p} onClick={()=>setProto(p)} style={{
                        flex:1, padding:'5px 0', borderRadius:'var(--r-sm)', fontSize:11, fontWeight:600,
                        cursor:'pointer', border:`1.5px solid ${proto===p?'var(--accent)':'var(--border)'}`,
                        background:proto===p?'var(--accent-tint)':'var(--surface)',
                        color:proto===p?'var(--accent)':'var(--muted)',
                      }}>{p.toUpperCase()}</button>
                    ))}
                  </div>
                </div>
                <div style={{alignSelf:'flex-end'}}>
                  <button className="btn btn-ghost" style={{fontSize:11,padding:'5px 8px'}}
                    onClick={save} disabled={saving}>
                    {saving?'…':'Save'}
                  </button>
                </div>
              </div>

              {/* UUID */}
              <div style={{
                padding:'7px 10px', background:'var(--surface-2)',
                border:'1px solid var(--border)', borderRadius:'var(--r-md)',
                fontSize:11, fontFamily:'var(--font-mono)', color:'var(--muted)',
                display:'flex', alignItems:'center', gap:8,
              }}>
                <span style={{flex:1, wordBreak:'break-all'}}>{cfg.out_proxy_uuid}</span>
                <button className="icon-btn-sm" title="Copy UUID"
                  onClick={()=>copyText(cfg.out_proxy_uuid).then(()=>pushToast('UUID copied'))}>
                  <Icons.Copy size={11}/>
                </button>
              </div>

              {/* Install command */}
              <div>
                <div style={{fontSize:11, color:'var(--muted)', marginBottom:4}}>
                  Step 1 — Run on <strong>{server.name} ({server.ip})</strong> to install bridge:
                </div>
                <div style={{
                  display:'flex', alignItems:'center', gap:0,
                  background:'var(--surface)', border:'1px solid var(--border)',
                  borderRadius:'var(--r-md)', overflow:'hidden',
                }}>
                  <div style={{
                    flex:1, padding:'8px 10px', fontFamily:'var(--font-mono)',
                    fontSize:10.5, color:'var(--text-2)', wordBreak:'break-all', userSelect:'all',
                  }}>{curlCmd || '— select server first —'}</div>
                  {curlCmd && (
                    <button onClick={()=>copyText(curlCmd).then(()=>pushToast('Command copied!'))}
                      style={{
                        padding:'0 12px', height:'100%', minHeight:36,
                        background:'var(--surface-2)', border:'none',
                        borderLeft:'1px solid var(--border)', cursor:'pointer',
                        color:'var(--text-2)', flexShrink:0, display:'flex', alignItems:'center', gap:4,
                        fontSize:11, fontWeight:500,
                      }}>
                      <Icons.Copy size={12}/> Copy
                    </button>
                  )}
                </div>
              </div>

              {/* Active outbound toggle — add/remove from list */}
              <div style={{
                display:'flex', alignItems:'center', justifyContent:'space-between',
                padding:'8px 10px', borderRadius:'var(--r-md)',
                border:`1px solid ${isActive?'oklch(72% 0.18 140 / 0.4)':'var(--border)'}`,
                background: isActive?'oklch(72% 0.18 140 / 0.07)':'var(--surface-2)',
              }}>
                <div>
                  <div style={{fontSize:12, fontWeight:600}}>
                    {isActive
                      ? '✓ Active outbound — traffic exits via this server'
                      : 'Step 2 — Add as active outbound'}
                  </div>
                  <div style={{fontSize:11, color:'var(--muted)', marginTop:1}}>
                    {isActive
                      ? 'This server is in the active exit pool. Multiple servers = load balanced.'
                      : 'Adds this server to the exit IP pool. Panel supports multiple simultaneous outbounds.'}
                  </div>
                </div>
                <button
                  className={`btn ${isActive ? 'btn-ghost' : 'btn-primary'}`}
                  style={{fontSize:11, padding:'5px 12px', flexShrink:0, ...(isActive?{color:'var(--danger)'}:{})}}
                  onClick={isActive ? deactivate : activate}
                  disabled={toggling}>
                  {toggling ? '⏳' : isActive ? 'Remove' : 'Activate'}
                </button>
              </div>

              {isActive && (
                <div style={{
                  fontSize:11.5, color:'oklch(72% 0.18 140)', lineHeight:1.6,
                  padding:'8px 10px', background:'oklch(72% 0.18 140 / 0.07)',
                  border:'1px solid oklch(72% 0.18 140 / 0.3)', borderRadius:'var(--r-md)',
                }}>
                  Flow: User → [IN relay] → tunnel → Xray → [{server.ip}:{cfg.out_proxy_port}] → Internet 🌍
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
};


// ── Server modal ──────────────────────────────────────────────────────────────
const ServerModal = ({ server, onClose, onSave }) => {
  const editing = !!server;
  const [name,       setName]       = React.useState(server?.name        || '');
  const [ip,         setIp]         = React.useState(server?.ip          || '');
  const [region,     setRegion]     = React.useState(server?.region      || '');
  const [code,       setCode]       = React.useState(server?.code        || '');
  const [serverType, setServerType] = React.useState(server?.server_type || 'out');
  const [status,     setStatus]     = React.useState(server?.status      || 'online');
  const [notes,      setNotes]      = React.useState(server?.notes       || '');
  const [saving,     setSaving]     = React.useState(false);

  const save = () => {
    if (!name || !ip) return;
    setSaving(true);
    const url = editing ? `/api/servers/${server.id}` : '/api/servers';
    fetch(url, {
      method: editing ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, ip, region, code, server_type: serverType, status, notes }),
    })
      .then(r => r.json())
      .then(() => { setSaving(false); onSave(); })
      .catch(() => setSaving(false));
  };

  const typeOpts = [
    { value: 'in',   label: 'IN — entry',  desc: 'Users connect here', color: SERVER_TYPE_COLORS.in  },
    { value: 'out',  label: 'OUT — exit',  desc: 'Xray + panel run here', color: SERVER_TYPE_COLORS.out },
    { value: 'both', label: 'Both',        desc: 'Dual-role', color: SERVER_TYPE_COLORS.both },
  ];

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">{editing ? 'Edit server' : 'Add server'}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              {editing ? server.ip : 'Register a new server node'}
            </div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          <div className="field">
            <label className="field-label">Server role</label>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 8 }}>
              {typeOpts.map(opt => (
                <div key={opt.value} onClick={() => setServerType(opt.value)} style={{
                  padding: '10px 12px', borderRadius: 'var(--r-md)', cursor: 'pointer',
                  border: `1.5px solid ${serverType === opt.value ? opt.color : 'var(--border)'}`,
                  background: serverType === opt.value ? opt.color + '18' : 'var(--surface-2)',
                  transition: 'all 0.12s',
                }}>
                  <div style={{ fontSize: 12.5, fontWeight: 600, color: serverType===opt.value ? opt.color : 'var(--text)' }}>
                    {opt.label}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>{opt.desc}</div>
                </div>
              ))}
            </div>
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Name / hostname</label>
              <input className="input mono" placeholder="sg-01.example.com" value={name}
                onChange={e => setName(e.target.value)} autoFocus/>
            </div>
            <div className="field">
              <label className="field-label">IP address</label>
              <input className="input mono" placeholder="192.0.2.1" value={ip}
                onChange={e => setIp(e.target.value)}/>
            </div>
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Region / city</label>
              <input className="input" placeholder="Singapore" value={region}
                onChange={e => setRegion(e.target.value)}/>
            </div>
            <div className="field" style={{ maxWidth: 90 }}>
              <label className="field-label">Code</label>
              <input className="input mono" placeholder="SG" maxLength={2} value={code}
                onChange={e => setCode(e.target.value.toUpperCase())}/>
            </div>
            <div className="field">
              <label className="field-label">Status</label>
              <select className="input" value={status} onChange={e => setStatus(e.target.value)}>
                <option value="online">Online</option>
                <option value="degraded">Degraded</option>
                <option value="down">Offline</option>
              </select>
            </div>
          </div>
          <div className="field">
            <label className="field-label">Notes (optional)</label>
            <input className="input" placeholder="Any notes…" value={notes}
              onChange={e => setNotes(e.target.value)}/>
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={saving || !name || !ip}>
            <Icons.Check size={14}/> {saving ? 'Saving…' : (editing ? 'Save changes' : 'Add server')}
          </button>
        </div>
      </div>
    </div>
  );
};

// ── Tunnel modal ──────────────────────────────────────────────────────────────
const TunnelModal = ({ tunnel, servers, onClose, onSave, pushToast }) => {
  const editing = !!tunnel;
  const ts      = tunnel?.tunnel_settings || {};
  const genSecret = () => {
    const arr = new Uint8Array(16);
    crypto.getRandomValues(arr);
    return Array.from(arr).map(b => b.toString(16).padStart(2,'0')).join('');
  };

  const [name,          setName]          = React.useState(tunnel?.name         || '');
  const [inServerId,    setInServerId]    = React.useState(String(tunnel?.in_server_id  || ''));
  const [method,        setMethod]        = React.useState(tunnel?.method        || 'haproxy');
  const [inPort,        setInPort]        = React.useState(tunnel?.in_port       || '');
  const [outPort,       setOutPort]       = React.useState(tunnel?.out_port      || '');
  const [secret,        setSecret]        = React.useState(tunnel?.secret        || genSecret());
  const [notes,         setNotes]         = React.useState(tunnel?.notes         || '');
  const [saving,        setSaving]        = React.useState(false);
  const [createInbound, setCreateInbound] = React.useState(false);

  // Method-specific settings — regular backhaul
  const [bhTransport,   setBhTransport]   = React.useState(ts.backhaul_transport  || 'tcp');
  const [bhNodelay,     setBhNodelay]     = React.useState(ts.backhaul_nodelay    !== false);
  const [bhKeepalive,   setBhKeepalive]   = React.useState(ts.backhaul_keepalive  || 40);
  const [bhMuxCon,      setBhMuxCon]      = React.useState(ts.backhaul_mux_con    || 8);
  const [bhChanSize,    setBhChanSize]    = React.useState(ts.backhaul_chan_size   || 4096);
  // Backhaul Premium
  const [bhpTransport,   setBhpTransport]   = React.useState(ts.bhp_transport      || 'tcp');
  const [bhpNodelay,     setBhpNodelay]     = React.useState(ts.bhp_nodelay        !== false);
  const [bhpKeepalive,   setBhpKeepalive]   = React.useState(ts.bhp_keepalive      || 40);
  const [bhpWorkers,     setBhpWorkers]     = React.useState(ts.bhp_workers        ?? 0);
  const [bhpChannel,     setBhpChannel]     = React.useState(ts.bhp_channel_size   || 4096);
  const [bhpTuning,      setBhpTuning]      = React.useState(ts.bhp_tuning_profile || 'balanced');
  const [bhpAutoTuning,  setBhpAutoTuning]  = React.useState(ts.bhp_auto_tuning    !== false);
  const [bhpPool,        setBhpPool]        = React.useState(ts.bhp_conn_pool      || 8);
  const [bhpMux,         setBhpMux]         = React.useState(!!ts.bhp_mux);
  const [bhpMuxVer,      setBhpMuxVer]      = React.useState(ts.bhp_mux_version    || 2);
  const [bhpMuxFsize,    setBhpMuxFsize]    = React.useState(ts.bhp_mux_framesize  || 32768);
  const [bhpIpx,         setBhpIpx]         = React.useState(!!ts.bhp_ipx);
  const [bhpIpxProfile,  setBhpIpxProfile]  = React.useState(ts.bhp_ipx_profile   || 'icmp');
  const [bhpIpxLip,      setBhpIpxLip]      = React.useState(ts.bhp_ipx_listen_ip || '0.0.0.0');
  const [bhpIpxIface,    setBhpIpxIface]    = React.useState(ts.bhp_ipx_interface  || 'eth0');
  const [bhpIpxIcmpType, setBhpIpxIcmpType] = React.useState(ts.bhp_ipx_icmp_type ?? 0);
  const [bhpIpxIcmpCode, setBhpIpxIcmpCode] = React.useState(ts.bhp_ipx_icmp_code ?? 0);
  const [bhpTlsSni,      setBhpTlsSni]      = React.useState(ts.bhp_tls_sni        || '');
  const [bhpTlsCert,     setBhpTlsCert]     = React.useState(ts.bhp_tls_cert       || '');
  const [bhpTlsKey,      setBhpTlsKey]      = React.useState(ts.bhp_tls_key        || '');
  // Other methods
  const [frpProto,      setFrpProto]      = React.useState(ts.frp_protocol        || 'tcp');
  const [ratholeTransp, setRatholeTransp] = React.useState(ts.rathole_transport   || 'tcp');

  const inCandidates  = servers.filter(s => ['in', 'both'].includes(s.server_type||'out'));
  const selectedMethod = TUNNEL_METHODS.find(m => m.value === method) || TUNNEL_METHODS[0];
  const needsSecret = ['backhaul','backhaul_premium','frp','rathole','chisel'].includes(method);

  const save = () => {
    if (!name || !inPort || !outPort) return;
    setSaving(true);
    const url  = editing ? `/api/tunnels/${tunnel.id}` : '/api/tunnels';
    const meth = editing ? 'PUT' : 'POST';
    fetch(url, {
      method: meth, headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name, method,
        in_server_id:  inServerId ? Number(inServerId) : null,
        out_server_id: null,
        in_port: Number(inPort), out_port: Number(outPort),
        secret, notes,
        create_inbound: createInbound && !editing,
        // Regular backhaul
        backhaul_transport: bhTransport, backhaul_nodelay: bhNodelay,
        backhaul_keepalive: Number(bhKeepalive), backhaul_mux_con: Number(bhMuxCon),
        backhaul_chan_size:  Number(bhChanSize),
        // Backhaul Premium
        bhp_transport: bhpTransport, bhp_nodelay: bhpNodelay,
        bhp_keepalive: Number(bhpKeepalive), bhp_workers: Number(bhpWorkers),
        bhp_channel_size: Number(bhpChannel), bhp_tuning_profile: bhpTuning,
        bhp_auto_tuning: bhpAutoTuning, bhp_conn_pool: Number(bhpPool),
        bhp_mux: bhpMux, bhp_mux_version: Number(bhpMuxVer), bhp_mux_framesize: Number(bhpMuxFsize),
        bhp_ipx: bhpIpx, bhp_ipx_profile: bhpIpxProfile, bhp_ipx_listen_ip: bhpIpxLip,
        bhp_ipx_interface: bhpIpxIface, bhp_ipx_icmp_type: Number(bhpIpxIcmpType),
        bhp_ipx_icmp_code: Number(bhpIpxIcmpCode),
        bhp_tls_sni: bhpTlsSni, bhp_tls_cert: bhpTlsCert, bhp_tls_key: bhpTlsKey,
        // Others
        frp_protocol: frpProto, rathole_transport: ratholeTransp,
      }),
    })
      .then(r => r.json())
      .then(d => {
        setSaving(false);
        if (d.auto_inbound) pushToast(`Inbound "${d.auto_inbound.tag}" created on port ${d.auto_inbound.port}`);
        onSave();
      })
      .catch(() => setSaving(false));
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{ maxWidth: 540 }} onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">{editing ? 'Edit tunnel' : 'Create tunnel'}</div>
            <div style={{ fontSize: 12, color: 'var(--muted)', marginTop: 2 }}>
              {selectedMethod.desc}
            </div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          <div className="field">
            <label className="field-label">Tunnel name</label>
            <input className="input" placeholder="e.g. sg-relay" value={name}
              onChange={e => setName(e.target.value)} autoFocus/>
          </div>

          {/* Method grid */}
          <div className="field">
            <label className="field-label">Method</label>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill,minmax(100px,1fr))', gap: 6 }}>
              {TUNNEL_METHODS.map(m => {
                const mc = METHOD_COLOR[m.value] || 'var(--accent)';
                const sel = method === m.value;
                return (
                  <div key={m.value} onClick={() => setMethod(m.value)} style={{
                    padding: '7px 8px', borderRadius: 'var(--r-md)', cursor: 'pointer', textAlign: 'center',
                    border: `1.5px solid ${sel ? mc : 'var(--border)'}`,
                    background: sel ? mc + '18' : 'var(--surface-2)', transition: 'all 0.1s',
                  }}>
                    <div style={{ fontSize: 12, fontWeight: 600, color: sel ? mc : 'var(--text)' }}>
                      {m.label}
                    </div>
                    {m.reverse && (
                      <div style={{ fontSize: 9, color: sel ? mc : 'var(--muted)', marginTop: 1 }}>REVERSE</div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {/* Server picker — IN only; OUT is always the panel server */}
          <div className="field">
            <label className="field-label" style={{ color: SERVER_TYPE_COLORS.in }}>
              IN server (entry point)
            </label>
            <select className="input" value={inServerId} onChange={e => setInServerId(e.target.value)}>
              <option value="">— select (optional) —</option>
              {inCandidates.map(s => (
                <option key={s.id} value={s.id}>{s.name} ({s.ip})</option>
              ))}
            </select>
            {inCandidates.length === 0 && (
              <div style={{ fontSize: 11, color: 'var(--warn)', marginTop: 3 }}>
                No IN servers — add one in the Servers tab first.
              </div>
            )}
            <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
              OUT side is always <strong>this panel server</strong>.
            </div>
          </div>

          {/* Ports */}
          <div className="field-row">
            <div className="field">
              <label className="field-label">
                Listen port
                <span style={{ marginLeft: 5, fontWeight: 400, color: 'var(--muted)' }}>(on IN server)</span>
              </label>
              <input className="input mono" type="number" min={1} max={65535} placeholder="443"
                value={inPort} onChange={e => setInPort(e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">
                Forward to port
                <span style={{ marginLeft: 5, fontWeight: 400, color: 'var(--muted)' }}>(Xray on panel)</span>
              </label>
              <input className="input mono" type="number" min={1} max={65535} placeholder="443"
                value={outPort} onChange={e => setOutPort(e.target.value)}/>
            </div>
          </div>

          {/* Secret (for reverse tunnels) */}
          {needsSecret && (
            <div className="field">
              <label className="field-label">Auth secret</label>
              <div style={{ display: 'flex', gap: 6 }}>
                <input className="input mono" value={secret} onChange={e => setSecret(e.target.value)}
                  style={{ flex: 1 }}/>
                <button className="btn btn-ghost" style={{ padding: '6px 10px', fontSize: 12 }}
                  onClick={() => setSecret(genSecret())}>↻ New</button>
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 3 }}>
                Both sides use this token to authenticate with each other.
              </div>
            </div>
          )}

          {/* ── Method-specific settings ── */}
          {method === 'backhaul' && (
            <div className="field" style={{ padding: '12px 14px', background: 'var(--surface-2)', border: '1px solid var(--border)', borderRadius: 'var(--r-md)' }}>
              <div style={{ fontSize: 12.5, fontWeight: 600, marginBottom: 10, color: 'var(--text-2)' }}>Backhaul settings</div>
              <div className="field">
                <label className="field-label">Transport protocol</label>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6,1fr)', gap: 5 }}>
                  {BH_TRANSPORTS.map(t => {
                    const sel = bhTransport === t;
                    return (
                      <button key={t} onClick={() => setBhTransport(t)} style={{
                        padding: '5px', borderRadius: 'var(--r-sm)', fontSize: 11, fontWeight: 600,
                        cursor: 'pointer', border: `1.5px solid ${sel ? 'var(--accent)' : 'var(--border)'}`,
                        background: sel ? 'var(--accent-tint)' : 'var(--surface)', color: sel ? 'var(--accent)' : 'var(--text-2)',
                      }}>{t.toUpperCase()}</button>
                    );
                  })}
                </div>
              </div>
              <div className="field-row" style={{ marginTop: 8 }}>
                <div className="field">
                  <label className="field-label">Keepalive (s)</label>
                  <input className="input mono" type="number" value={bhKeepalive} onChange={e => setBhKeepalive(e.target.value)}/>
                </div>
                <div className="field">
                  <label className="field-label">Connections</label>
                  <input className="input mono" type="number" value={bhMuxCon} onChange={e => setBhMuxCon(e.target.value)}/>
                </div>
                <div className="field">
                  <label className="field-label">Chan size</label>
                  <input className="input mono" type="number" value={bhChanSize} onChange={e => setBhChanSize(e.target.value)}/>
                </div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 6 }}>
                <div className={`switch ${bhNodelay ? 'on' : ''}`} style={{ transform: 'scale(0.8)' }} onClick={() => setBhNodelay(v => !v)}/>
                <span style={{ fontSize: 12, color: 'var(--text-2)' }}>nodelay</span>
              </div>
            </div>
          )}

          {method === 'backhaul_premium' && (
            <div className="field" style={{ padding: '12px 14px', background: 'var(--surface-2)', border: '1px solid var(--border)', borderRadius: 'var(--r-md)', display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--text-2)' }}>Backhaul Premium settings</div>

              {/* IPX (ICMP/BIP raw-socket tunnel) toggle */}
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 10px', background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 'var(--r-md)' }}>
                <div>
                  <div style={{ fontSize: 12.5, fontWeight: 600 }}>IPX mode (ICMP / BIP bypass)</div>
                  <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 1 }}>Tunnel over raw ICMP or BIP packets — bypasses TCP/UDP port filters</div>
                </div>
                <div className={`switch ${bhpIpx ? 'on' : ''}`} onClick={() => setBhpIpx(v => !v)}/>
              </div>

              {bhpIpx ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: '10px 12px', border: '1px solid oklch(72% 0.20 315 / 0.4)', borderRadius: 'var(--r-md)', background: 'oklch(72% 0.20 315 / 0.05)' }}>
                  <div style={{ fontSize: 12, fontWeight: 600, color: 'oklch(72% 0.20 315)' }}>IPX configuration</div>
                  <div className="field">
                    <label className="field-label">Profile</label>
                    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6,1fr)', gap: 4 }}>
                      {BHP_IPX_PROFILES.map(p => {
                        const sel = bhpIpxProfile === p;
                        return (
                          <button key={p} onClick={() => setBhpIpxProfile(p)} style={{
                            padding: '4px', borderRadius: 'var(--r-sm)', fontSize: 10.5, fontWeight: 700,
                            cursor: 'pointer', border: `1.5px solid ${sel ? 'oklch(72% 0.20 315)' : 'var(--border)'}`,
                            background: sel ? 'oklch(72% 0.20 315 / 0.15)' : 'var(--surface)', color: sel ? 'oklch(72% 0.20 315)' : 'var(--text-2)',
                          }}>{p.toUpperCase()}</button>
                        );
                      })}
                    </div>
                  </div>
                  <div className="field-row">
                    <div className="field">
                      <label className="field-label">Listen IP</label>
                      <input className="input mono" value={bhpIpxLip} onChange={e => setBhpIpxLip(e.target.value)} placeholder="0.0.0.0"/>
                    </div>
                    <div className="field">
                      <label className="field-label">Interface</label>
                      <input className="input mono" value={bhpIpxIface} onChange={e => setBhpIpxIface(e.target.value)} placeholder="eth0"/>
                    </div>
                  </div>
                  {bhpIpxProfile === 'icmp' && (
                    <div className="field-row">
                      <div className="field">
                        <label className="field-label">ICMP type</label>
                        <input className="input mono" type="number" value={bhpIpxIcmpType} onChange={e => setBhpIpxIcmpType(e.target.value)}/>
                      </div>
                      <div className="field">
                        <label className="field-label">ICMP code</label>
                        <input className="input mono" type="number" value={bhpIpxIcmpCode} onChange={e => setBhpIpxIcmpCode(e.target.value)}/>
                      </div>
                    </div>
                  )}
                </div>
              ) : (
                <div className="field">
                  <label className="field-label">Transport</label>
                  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6,1fr)', gap: 5 }}>
                    {BHP_TRANSPORTS.map(t => {
                      const sel = bhpTransport === t;
                      return (
                        <button key={t} onClick={() => setBhpTransport(t)} style={{
                          padding: '4px', borderRadius: 'var(--r-sm)', fontSize: 10.5, fontWeight: 600,
                          cursor: 'pointer', border: `1.5px solid ${sel ? 'var(--accent)' : 'var(--border)'}`,
                          background: sel ? 'var(--accent-tint)' : 'var(--surface)', color: sel ? 'var(--accent)' : 'var(--text-2)',
                        }}>{t.toUpperCase()}</button>
                      );
                    })}
                  </div>
                </div>
              )}

              {/* TLS (for wss/tls transports) */}
              {(bhpTransport === 'tls' || bhpTransport === 'tlsmux' || bhpTransport === 'wss' || bhpTransport === 'wssmux') && !bhpIpx && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '8px 10px', border: '1px solid var(--border)', borderRadius: 'var(--r-md)' }}>
                  <div style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--text-2)' }}>TLS</div>
                  <div className="field">
                    <label className="field-label">SNI</label>
                    <input className="input mono" value={bhpTlsSni} onChange={e => setBhpTlsSni(e.target.value)} placeholder="domain.com"/>
                  </div>
                  <div className="field-row">
                    <div className="field">
                      <label className="field-label">Cert path (server)</label>
                      <input className="input mono" value={bhpTlsCert} onChange={e => setBhpTlsCert(e.target.value)} placeholder="/root/backhaul-core/cert_files/cert.crt"/>
                    </div>
                    <div className="field">
                      <label className="field-label">Key path (server)</label>
                      <input className="input mono" value={bhpTlsKey} onChange={e => setBhpTlsKey(e.target.value)} placeholder="/root/backhaul-core/cert_files/cert.key"/>
                    </div>
                  </div>
                </div>
              )}

              {/* Performance */}
              <div className="field-row">
                <div className="field">
                  <label className="field-label">Keepalive (s)</label>
                  <input className="input mono" type="number" value={bhpKeepalive} onChange={e => setBhpKeepalive(e.target.value)}/>
                </div>
                <div className="field">
                  <label className="field-label">Conn pool</label>
                  <input className="input mono" type="number" value={bhpPool} onChange={e => setBhpPool(e.target.value)}/>
                </div>
                <div className="field">
                  <label className="field-label">Workers (0=auto)</label>
                  <input className="input mono" type="number" value={bhpWorkers} onChange={e => setBhpWorkers(e.target.value)}/>
                </div>
                <div className="field">
                  <label className="field-label">Chan size</label>
                  <input className="input mono" type="number" value={bhpChannel} onChange={e => setBhpChannel(e.target.value)}/>
                </div>
              </div>
              <div className="field">
                <label className="field-label">Tuning profile</label>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 5 }}>
                  {BHP_TUNING_PROFILES.map(p => {
                    const sel = bhpTuning === p;
                    return (
                      <button key={p} onClick={() => setBhpTuning(p)} style={{
                        padding: '4px', borderRadius: 'var(--r-sm)', fontSize: 11, fontWeight: 600,
                        cursor: 'pointer', border: `1.5px solid ${sel ? 'var(--accent)' : 'var(--border)'}`,
                        background: sel ? 'var(--accent-tint)' : 'var(--surface)', color: sel ? 'var(--accent)' : 'var(--text-2)',
                      }}>{p}</button>
                    );
                  })}
                </div>
              </div>
              <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <div className={`switch ${bhpNodelay ? 'on' : ''}`} style={{ transform: 'scale(0.8)' }} onClick={() => setBhpNodelay(v => !v)}/>
                  <span style={{ fontSize: 12, color: 'var(--text-2)' }}>nodelay</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <div className={`switch ${bhpAutoTuning ? 'on' : ''}`} style={{ transform: 'scale(0.8)' }} onClick={() => setBhpAutoTuning(v => !v)}/>
                  <span style={{ fontSize: 12, color: 'var(--text-2)' }}>auto tuning</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <div className={`switch ${bhpMux ? 'on' : ''}`} style={{ transform: 'scale(0.8)' }} onClick={() => setBhpMux(v => !v)}/>
                  <span style={{ fontSize: 12, color: 'var(--text-2)' }}>mux</span>
                </div>
              </div>
              {bhpMux && (
                <div className="field-row">
                  <div className="field">
                    <label className="field-label">Mux version</label>
                    <div style={{ display: 'flex', gap: 5 }}>
                      {[1,2].map(v => {
                        const sel = bhpMuxVer === v;
                        return <button key={v} onClick={() => setBhpMuxVer(v)} style={{ flex:1, padding:'5px', borderRadius:'var(--r-sm)', fontSize:12, fontWeight:600, cursor:'pointer', border:`1.5px solid ${sel?'var(--accent)':'var(--border)'}`, background:sel?'var(--accent-tint)':'var(--surface)', color:sel?'var(--accent)':'var(--text-2)' }}>v{v}</button>;
                      })}
                    </div>
                  </div>
                  <div className="field">
                    <label className="field-label">Frame size</label>
                    <input className="input mono" type="number" value={bhpMuxFsize} onChange={e => setBhpMuxFsize(e.target.value)}/>
                  </div>
                </div>
              )}
            </div>
          )}
          {method === 'frp' && (
            <div className="field">
              <label className="field-label">FRP transport protocol</label>
              <div style={{ display: 'flex', gap: 5 }}>
                {FRP_PROTOCOLS.map(p => {
                  const sel = frpProto === p;
                  return (
                    <button key={p} onClick={() => setFrpProto(p)} style={{
                      padding: '5px 10px', borderRadius: 'var(--r-sm)', fontSize: 11.5, fontWeight: 600,
                      cursor: 'pointer', border: `1.5px solid ${sel ? 'var(--accent)' : 'var(--border)'}`,
                      background: sel ? 'var(--accent-tint)' : 'var(--surface)', color: sel ? 'var(--accent)' : 'var(--text-2)',
                    }}>{p.toUpperCase()}</button>
                  );
                })}
              </div>
            </div>
          )}
          {method === 'rathole' && (
            <div className="field">
              <label className="field-label">Rathole transport</label>
              <div style={{ display: 'flex', gap: 5 }}>
                {RH_TRANSPORTS.map(p => {
                  const sel = ratholeTransp === p;
                  return (
                    <button key={p} onClick={() => setRatholeTransp(p)} style={{
                      padding: '5px 10px', borderRadius: 'var(--r-sm)', fontSize: 11.5, fontWeight: 600,
                      cursor: 'pointer', border: `1.5px solid ${sel ? 'var(--accent)' : 'var(--border)'}`,
                      background: sel ? 'var(--accent-tint)' : 'var(--surface)', color: sel ? 'var(--accent)' : 'var(--text-2)',
                    }}>{p.toUpperCase()}</button>
                  );
                })}
              </div>
            </div>
          )}

          {/* Auto-create inbound option (create only) */}
          {!editing && (
            <div style={{
              display: 'flex', alignItems: 'center', justifyContent: 'space-between',
              padding: '10px 12px', background: 'var(--surface-2)', border: '1px solid var(--border)',
              borderRadius: 'var(--r-md)',
            }}>
              <div>
                <div style={{ fontSize: 12.5, fontWeight: 500 }}>Auto-create VLESS inbound</div>
                <div style={{ fontSize: 11.5, color: 'var(--muted)', marginTop: 2 }}>
                  Creates a VLESS/TCP inbound on port {inPort || '…'} with the IN server IP pre-filled
                </div>
              </div>
              <div className={`switch ${createInbound ? 'on' : ''}`} onClick={() => setCreateInbound(v => !v)}/>
            </div>
          )}

          {/* Notes */}
          <div className="field">
            <label className="field-label">Notes (optional)</label>
            <input className="input" placeholder="Any notes…" value={notes}
              onChange={e => setNotes(e.target.value)}/>
          </div>

          {/* How-to note for reverse tunnels */}
          {selectedMethod.reverse && (
            <div style={{
              padding: '10px 14px', borderRadius: 'var(--r-md)', fontSize: 12, color: 'var(--text-2)',
              background: 'oklch(70% 0.18 300 / 0.08)', border: '1px solid oklch(70% 0.18 300 / 0.3)',
              lineHeight: 1.6,
            }}>
              <strong>Reverse tunnel</strong>: run the <em>Panel script first</em> (starts the server component on this panel server),
              then the <em>IN script</em> (client connects to panel). The IN server doesn't need any open
              inbound ports.
            </div>
          )}
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={saving || !name || !inPort || !outPort}>
            <Icons.Check size={14}/> {saving ? 'Saving…' : (editing ? 'Save changes' : 'Create tunnel')}
          </button>
        </div>
      </div>
    </div>
  );
};

Object.assign(window, { ServersPage, ServerModal, TunnelModal, HowItWorksGuide, ExpandedTunnel, OutProxyCard });
