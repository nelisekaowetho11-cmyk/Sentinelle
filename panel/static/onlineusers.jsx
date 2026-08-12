// Online users live view — polls /api/online every 15s
// Two presentations, both driven by the same payload:
//   grid   → presence cards (avatar halo, live throughput, quota bar)
//   stream → activity timeline bucketed by recency

// ── formatting helpers ───────────────────────────────────────────────────────
const ouAgo = (s) => {
  if (s == null) return '—';
  if (s < 60)   return `${Math.max(0, Math.round(s))}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  return `${Math.floor(s / 3600)}h`;
};

const ouDuration = (s) => {
  if (s == null) return '—';
  if (s < 60)   return `${Math.max(0, Math.round(s))}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${h}h ${String(m).padStart(2, '0')}m`;
};

const ouInitials = (name = '') => {
  const letters = name.replace(/[^a-zA-Z]/g, '');
  return (letters.slice(0, 2) || name.slice(0, 2) || '?').toUpperCase();
};

// Stable colour per user so tiles don't reshuffle hues as the list re-sorts
const ouHash = (s = '') => {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h;
};

// < 10s = live, < 60s = recent, otherwise idling
const ouTone = (secs) => (secs < 10 ? 'live' : secs < 60 ? 'warm' : 'cool');
const OU_TONE_COLOR = {
  live: 'var(--accent)',
  warm: 'var(--warn)',
  cool: 'var(--muted-2)',
};

// ── tiny sparkline over the real Mbps history returned by the API ────────────
const OuSpark = ({ data = [], w = 62, h = 22, color = 'var(--accent)' }) => {
  const id = React.useMemo(() => `ous${Math.random().toString(36).slice(2, 8)}`, []);
  const pts = (data || []).filter(v => typeof v === 'number' && isFinite(v));

  if (pts.length < 2) {
    // Not enough samples yet — a flat baseline is honest, a fake curve isn't.
    return (
      <svg viewBox={`0 0 ${w} ${h}`} width={w} height={h} preserveAspectRatio="none" style={{display:'block'}}>
        <line x1="0" y1={h - 1.5} x2={w} y2={h - 1.5}
              stroke={color} strokeWidth="1.4" strokeLinecap="round" opacity="0.35"/>
      </svg>
    );
  }

  const min   = Math.min(...pts);
  const max   = Math.max(...pts);
  const range = (max - min) || 1;
  const stepX = w / (pts.length - 1);
  const coords = pts.map((v, i) => [i * stepX, h - ((v - min) / range) * (h - 3) - 1.5]);
  const d    = coords.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ');
  const area = `${d} L${w},${h} L0,${h} Z`;

  return (
    <svg viewBox={`0 0 ${w} ${h}`} width={w} height={h} preserveAspectRatio="none" style={{display:'block'}}>
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%"   stopColor={color} stopOpacity="0.3"/>
          <stop offset="100%" stopColor={color} stopOpacity="0"/>
        </linearGradient>
      </defs>
      <path d={area} fill={`url(#${id})`}/>
      <path d={d} fill="none" stroke={color} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
};

// ── B · presence card ────────────────────────────────────────────────────────
const OuTile = ({ u, i }) => {
  const [c1, c2] = gradFor(ouHash(u.uuid || u.name || ''));
  const tone     = ouTone(u.age);
  const quota    = u.quota_pct;
  const barClass = quota == null ? '' : quota >= 100 ? 'full' : quota >= 75 ? 'high' : '';

  return (
    <div className="ou-tile ou-rise" style={{animationDelay: `${Math.min(i, 12) * 40}ms`}}>
      <div className="ou-tile-glow"/>
      <div style={{display:'flex', alignItems:'center', gap:11, position:'relative'}}>
        <div className={`ou-halo${tone === 'live' ? '' : ' idle'}`}>
          <div className="user-avatar" style={{
            width:38, height:38, fontSize:13,
            background:`linear-gradient(135deg, ${c1}, ${c2})`,
          }}>{ouInitials(u.name)}</div>
        </div>
        <div style={{minWidth:0, flex:1}}>
          <div style={{display:'flex', alignItems:'center', gap:6, flexWrap:'wrap'}}>
            <span className="ou-tile-name">{u.name || '—'}</span>
            {u.owner && <span style={{fontSize:11, color:'var(--muted)'}}>· {u.owner}</span>}
            {u.proto && <span className={`proto-chip xs ${u.proto}`}>{u.proto.slice(0, 2).toUpperCase()}</span>}
          </div>
          <div className="ou-tile-meta" title={u.ip}>{u.ip || '?'}</div>
        </div>
        {u.cc && <div className="ou-flag" title={`Resolved from ${u.ip}`}>{u.cc}</div>}
      </div>

      <div style={{display:'flex', alignItems:'flex-end', justifyContent:'space-between', gap:10, marginTop:11}}>
        <div className="ou-rate">
          {u.rate_mbps != null ? u.rate_mbps.toFixed(u.rate_mbps >= 10 ? 1 : 2) : '0.00'}
          <span>Mbps</span>
        </div>
        <div style={{width:62, height:22, opacity:0.95}}>
          <OuSpark data={u.spark} w={62} h={22} color={OU_TONE_COLOR[tone]}/>
        </div>
      </div>

      <div className="ou-bar">
        <i className={barClass} style={{width: `${quota == null ? 0 : Math.min(100, quota)}%`}}/>
      </div>
      <div className="ou-tstat">
        <span>{ouDuration(u.session)} session</span>
        <span>{quota == null ? `${u.traffic_used} GB used` : `${quota}% quota`}</span>
      </div>
    </div>
  );
};

// ── C · timeline row ─────────────────────────────────────────────────────────
const OuEvent = ({ u, i }) => {
  const [c1, c2] = gradFor(ouHash(u.uuid || u.name || ''));
  const tone     = ouTone(u.age);

  return (
    <div className="ou-ev ou-rise" style={{animationDelay: `${Math.min(i, 12) * 45}ms`}}>
      <div className={`ou-node ${tone === 'live' ? '' : tone}`}><i/></div>
      <div style={{minWidth:0}}>
        <div style={{display:'flex', alignItems:'center', gap:7, flexWrap:'wrap'}}>
          <div className="user-avatar" style={{
            width:20, height:20, fontSize:8.5,
            background:`linear-gradient(135deg, ${c1}, ${c2})`,
          }}>{ouInitials(u.name)}</div>
          <span className="ou-ev-name">{u.name || '—'}</span>
          {u.owner && <span style={{fontSize:11, color:'var(--muted)'}}>· {u.owner}</span>}
          {u.proto && <span className={`proto-chip xs ${u.proto}`}>{u.proto.toUpperCase()}</span>}
        </div>
        <div className="ou-ev-line">
          <span className="ou-ev-ip">{u.ip || '?'}</span>
          {u.cc && <React.Fragment><span>·</span><span>{u.cc}</span></React.Fragment>}
          <span>·</span>
          <span>{ouDuration(u.session)} session</span>
          {u.quota_pct != null && <React.Fragment><span>·</span><span>{u.quota_pct}% quota</span></React.Fragment>}
        </div>
      </div>
      <div style={{display:'flex', alignItems:'center', gap:10, justifyContent:'flex-end'}}>
        <div style={{width:46, height:20}}>
          <OuSpark data={u.spark} w={46} h={20} color={OU_TONE_COLOR[tone]}/>
        </div>
        <span className={`ou-pill${tone === 'live' ? ' live' : ''}`}>{ouAgo(u.age)}</span>
      </div>
    </div>
  );
};

// ── page ─────────────────────────────────────────────────────────────────────
const OnlineUsersPage = ({ pushToast, role }) => {
  const [rows,    setRows]    = React.useState([]);
  const [total,   setTotal]   = React.useState(0);
  const [windowM, setWindowM] = React.useState(5);
  const [loading, setLoading] = React.useState(true);
  const [failed,  setFailed]  = React.useState(false);
  const [lastUpdate, setLastUpdate] = React.useState(null);
  const [view, setView] = React.useState(() => localStorage.getItem('bridge-online-view') || 'grid');

  // Seconds since the last successful poll — lets the counters tick between fetches
  const fetchedAt = React.useRef(Date.now());
  const [, forceTick] = React.useReducer(n => n + 1, 0);

  const load = React.useCallback(() => {
    fetch('/api/online')
      .then(r => r.json())
      .then(d => {
        setRows(d.online || []);
        setTotal(d.total_users || 0);
        if (d.window_min) setWindowM(d.window_min);
        fetchedAt.current = Date.now();
        setLastUpdate(new Date());
        setFailed(false);
        setLoading(false);
      })
      .catch(() => { setFailed(true); setLoading(false); });
  }, []);

  React.useEffect(() => {
    load();
    const poll = setInterval(load, 15000);
    const tick = setInterval(forceTick, 1000);
    return () => { clearInterval(poll); clearInterval(tick); };
  }, [load]);

  React.useEffect(() => { localStorage.setItem('bridge-online-view', view); }, [view]);

  const manualRefresh = () => {
    setLoading(true);
    load();
    if (pushToast) pushToast('Online list refreshed');
  };

  // Age the server-side numbers locally so the UI stays live between polls
  const drift = Math.max(0, Math.floor((Date.now() - fetchedAt.current) / 1000));
  const users = React.useMemo(() => rows.map(r => ({
    ...r,
    age:     (r.last_seen_s || 0) + drift,
    session: (r.session_s   || 0) + drift,
  })).sort((a, b) => a.age - b.age), [rows, drift]);

  const buckets = [
    ['Live · under 10s',          users.filter(u => u.age < 10)],
    ['Recent · under a minute',   users.filter(u => u.age >= 10 && u.age < 60)],
    ['Idling · over a minute',    users.filter(u => u.age >= 60)],
  ].filter(([, list]) => list.length > 0);

  let evIndex = 0;

  const hasAny = users.length > 0;

  return (
    <div className="page">
      <div className="card" style={{overflow:'hidden'}}>

        {/* Header */}
        <div className="ou-head">
          <div className={`live-dot${hasAny ? '' : ' idle'}`}><i/><span/><span/></div>
          <div style={{minWidth:0}}>
            <div className="ou-title">Online now</div>
            <div className="ou-sub">
              {view === 'grid'
                ? `${users.length} of ${total.toLocaleString()} user${total === 1 ? '' : 's'} connected`
                : 'Ordered by last packet seen'}
            </div>
          </div>

          <div style={{flex:1}}/>

          {lastUpdate && (
            <span className="mono" style={{fontSize:11, color:'var(--muted)'}}>
              {lastUpdate.toLocaleTimeString()}
            </span>
          )}
          <span className="ou-count">{users.length}{view === 'grid' ? ' connected' : ''}</span>

          <div className="tab-pill">
            <button className={view === 'grid'   ? 'active' : ''} onClick={() => setView('grid')}>Grid</button>
            <button className={view === 'stream' ? 'active' : ''} onClick={() => setView('stream')}>List</button>
          </div>

          <button className="icon-btn" onClick={manualRefresh} title="Refresh now" aria-label="Refresh now">
            <Icons.Refresh size={14}/>
          </button>
        </div>

        <div className="ou-sweep"><i/></div>

        {/* Body */}
        {loading && !hasAny ? (
          <div className="ou-grid">
            {[0,1,2,3].map(i => (
              <div key={i} className="skel" style={{height:118, borderRadius:'var(--r-lg)'}}/>
            ))}
          </div>
        ) : failed && !hasAny ? (
          <div style={{padding:48, textAlign:'center', color:'var(--muted)'}}>
            <div style={{marginBottom:10, display:'flex', justifyContent:'center', color:'var(--danger)'}}>
              <Icons.Wifi size={26}/>
            </div>
            <div style={{fontWeight:600, marginBottom:4, color:'var(--text)'}}>Couldn't reach the panel API</div>
            <div style={{fontSize:12.5}}>Retrying automatically every 15 seconds</div>
          </div>
        ) : !hasAny ? (
          <div style={{padding:48, textAlign:'center', color:'var(--muted)'}}>
            <div style={{marginBottom:10, display:'flex', justifyContent:'center', color:'var(--muted-2)'}}>
              <Icons.Wifi size={26}/>
            </div>
            <div style={{fontWeight:600, marginBottom:4, color:'var(--text)'}}>No active connections</div>
            <div style={{fontSize:12.5}}>Online users appear here within ~15 seconds of connecting</div>
          </div>
        ) : view === 'grid' ? (
          <div className="ou-grid">
            {users.map((u, i) => <OuTile key={u.uuid || u.id} u={u} i={i}/>)}
          </div>
        ) : (
          <div className="ou-stream">
            <div className="ou-rail"/>
            {buckets.map(([label, list]) => (
              <div key={label} style={{padding:'4px 0 2px'}}>
                <div className="ou-bucket-label">{label}</div>
                {list.map(u => <OuEvent key={u.uuid || u.id} u={u} i={evIndex++}/>)}
              </div>
            ))}
          </div>
        )}

        {/* Footer */}
        <div className="ou-foot">
          <Icons.Clock size={12}/>
          Refreshing every 15s · visible up to {windowM} min after last activity
        </div>
      </div>
    </div>
  );
};
