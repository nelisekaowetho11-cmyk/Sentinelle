// Dashboard page — fetches /api/dashboard for real KPIs

const ACTION_META = {
  create_user:     { label: 'Created user',        icon: 'Users',    tone: 'accent' },
  delete_user:     { label: 'Deleted user',         icon: 'Trash',    tone: 'danger' },
  toggle_user:     { label: 'Toggled user',         icon: 'Power',    tone: 'warn'   },
  renew_user:      { label: 'Renewed user',         icon: 'Calendar', tone: 'accent' },
  bulk_suspend:    { label: 'Bulk suspended',       icon: 'Lock',     tone: 'warn'   },
  bulk_activate:   { label: 'Bulk activated',       icon: 'Power',    tone: 'accent' },
  bulk_reset_traffic: { label: 'Bulk reset traffic',icon: 'Refresh',  tone: 'warn'   },
  bulk_extend_expiry: { label: 'Bulk extended expiry', icon: 'Calendar', tone: 'info' },
  bulk_set_expiry: { label: 'Bulk set expiry',      icon: 'Calendar', tone: 'info'   },
  bulk_set_traffic:{ label: 'Bulk set traffic',     icon: 'Traffic',  tone: 'info'   },
  create_reseller: { label: 'Created reseller',     icon: 'Shield',   tone: 'accent' },
  delete_reseller: { label: 'Deleted reseller',     icon: 'Trash',    tone: 'danger' },
  update_reseller: { label: 'Updated reseller',     icon: 'Edit',     tone: 'info'   },
  toggle_reseller: { label: 'Toggled reseller',     icon: 'Lock',     tone: 'warn'   },
  reset_traffic:   { label: 'Reset traffic',        icon: 'Refresh',  tone: 'warn'   },
  create_admin:    { label: 'Created admin',        icon: 'Shield',   tone: 'accent' },
  delete_admin:    { label: 'Deleted admin',        icon: 'Trash',    tone: 'danger' },
};
const ROLE_COLOR = {
  superadmin: 'var(--accent)',
  admin:      'oklch(72% 0.14 240)',
  reseller:   'var(--warning,#f59e0b)',
};

// Mini progress bar
const Bar = ({ pct, danger, warn }) => (
  <div style={{height:4, borderRadius:2, background:'var(--border)', overflow:'hidden', width:'100%', marginTop:4}}>
    <div style={{
      height:'100%', borderRadius:2,
      width:`${Math.min(100, pct || 0)}%`,
      background: danger ? 'var(--danger)' : warn ? 'var(--warning,#f59e0b)' : 'var(--accent)',
      transition:'width 0.3s',
    }}/>
  </div>
);

// ── Admin Overview panel ──────────────────────────────────────────────────────
const AdminOverview = ({ admins }) => (
  <div className="card" style={{display:'flex', flexDirection:'column'}}>
    <div className="section-head">
      <div>
        <div className="section-title">Admin Overview</div>
        <div className="section-sub">Quota usage per admin</div>
      </div>
      <span className="badge ok"><span className="dot"/>{admins.length} admins</span>
    </div>
    <div style={{flex:1, overflowY:'auto', maxHeight:340}}>
      {admins.length === 0 && (
        <div style={{padding:40, textAlign:'center', color:'var(--muted)', fontSize:13}}>No admins yet</div>
      )}
      {admins.map(a => {
        const rPct  = a.resellers_max > 0 ? a.resellers_count / a.resellers_max * 100 : 0;
        const uPct  = a.users_max     > 0 ? a.users_total     / a.users_max     * 100 : 0;
        const dPct  = a.data_limit_gb > 0 ? a.data_used_gb    / a.data_limit_gb * 100 : 0;
        return (
          <div key={a.id} style={{padding:'12px 18px', borderBottom:'1px solid var(--border)'}}>
            <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:8}}>
              <div style={{
                width:28, height:28, borderRadius:6, display:'flex', alignItems:'center', justifyContent:'center',
                background:'var(--accent-tint)', color:'var(--accent)', flexShrink:0,
              }}><Icons.Shield size={13}/></div>
              <div style={{fontWeight:600, fontSize:13.5}}>{a.username}</div>
              <div style={{marginLeft:'auto', fontSize:11.5, color:'var(--muted)'}}>
                {a.created_at ? a.created_at.slice(0,10) : ''}
              </div>
            </div>
            <div style={{display:'grid', gridTemplateColumns:'1fr 1fr 1fr', gap:12}}>
              {[
                { label:'Resellers', cur: a.resellers_count, max: a.resellers_max, pct: rPct },
                { label:'Users',     cur: a.users_total,     max: a.users_max,     pct: uPct },
                { label:'Data used', cur: `${a.data_used_gb} GB`, max: `${a.data_limit_gb} GB`, pct: dPct },
              ].map(item => (
                <div key={item.label}>
                  <div style={{display:'flex', justifyContent:'space-between', fontSize:11, color:'var(--muted)', marginBottom:2}}>
                    <span>{item.label}</span>
                    <span style={{fontFamily:'var(--font-mono)', color: item.pct >= 90 ? 'var(--danger)' : 'var(--text)'}}>
                      {item.cur}<span style={{color:'var(--muted)'}}>/{item.max}</span>
                    </span>
                  </div>
                  <Bar pct={item.pct} danger={item.pct >= 90} warn={item.pct >= 70}/>
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  </div>
);

// ── Reseller Overview panel ───────────────────────────────────────────────────
const ResellerOverview = ({ resellers }) => (
  <div className="card" style={{display:'flex', flexDirection:'column'}}>
    <div className="section-head">
      <div>
        <div className="section-title">Reseller Overview</div>
        <div className="section-sub">Traffic & status per reseller</div>
      </div>
      <span className="badge ok">
        <span className="dot"/>
        {resellers.filter(r => r.active).length} active
      </span>
    </div>
    <div style={{flex:1, overflowY:'auto', maxHeight:340}}>
      {resellers.length === 0 && (
        <div style={{padding:40, textAlign:'center', color:'var(--muted)', fontSize:13}}>No resellers yet</div>
      )}
      {resellers.map(r => {
        const uPct    = (r.used_limit_gb  || 0) > 0 ? r.data_used_gb / r.used_limit_gb  * 100 : 0;
        const aPct    = (r.data_limit_gb  || 0) > 0 ? (r.data_allocated_gb || 0) / r.data_limit_gb * 100 : 0;
        const overUsed  = uPct >= 100;
        const overAlloc = aPct >= 100;
        const nearUsed  = !overUsed  && uPct >= 80;
        const nearAlloc = !overAlloc && aPct >= 80;
        return (
          <div key={r.id} style={{
            padding:'11px 18px', borderBottom:'1px solid var(--border)',
            opacity: r.active ? 1 : 0.55,
          }}>
            <div style={{display:'flex', alignItems:'center', gap:8}}>
              <div style={{fontWeight:600, fontSize:13, flex:1}}>
                {r.username}
                {!r.active && (
                  <span style={{
                    marginLeft:6, fontSize:10, padding:'1px 5px', borderRadius:3,
                    background:'var(--danger-tint)', color:'var(--danger)', fontWeight:700,
                  }}>SUSPENDED</span>
                )}
              </div>
              <span style={{fontSize:11.5, fontFamily:'var(--font-mono)', color:'var(--muted)'}}>
                {r.users_active}/{r.users_total} users
              </span>
            </div>
            <div style={{marginTop:6}}>
              <div style={{display:'flex', justifyContent:'space-between', fontSize:11, color:'var(--muted)', marginBottom:2}}>
                <span>Used</span>
                <span style={{fontFamily:'var(--font-mono)', color: overUsed ? 'var(--danger)' : nearUsed ? 'var(--warning,#f59e0b)' : 'var(--text)'}}>
                  {r.data_used_gb.toFixed(2)} / {r.used_limit_gb} GB
                </span>
              </div>
              <Bar pct={uPct} danger={overUsed} warn={nearUsed}/>
              <div style={{display:'flex', justifyContent:'space-between', fontSize:11, color:'var(--muted)', marginBottom:2, marginTop:5}}>
                <span>Allocated</span>
                <span style={{fontFamily:'var(--font-mono)', color: overAlloc ? 'var(--danger)' : nearAlloc ? 'var(--warning,#f59e0b)' : 'var(--text)'}}>
                  {(r.data_allocated_gb || 0).toFixed(2)} / {r.data_limit_gb} GB
                </span>
              </div>
              <Bar pct={aPct} danger={overAlloc} warn={nearAlloc}/>
            </div>
          </div>
        );
      })}
    </div>
  </div>
);

// ── Activity Feed ─────────────────────────────────────────────────────────────
const ActivityFeed = ({ activity }) => (
  <div className="card" style={{display:'flex', flexDirection:'column'}}>
    <div className="section-head">
      <div>
        <div className="section-title">Recent Activity</div>
        <div className="section-sub">All admin &amp; reseller actions</div>
      </div>
    </div>
    <div className="feed" style={{flex:1, overflowY:'auto', maxHeight:400}}>
      {activity.length === 0 && (
        <div style={{padding:32, textAlign:'center', color:'var(--muted)', fontSize:13}}>
          No activity yet — actions will appear here
        </div>
      )}
      {activity.map((a, i) => {
        const meta = ACTION_META[a.action] || { label: a.action, icon: 'Activity', tone: 'accent' };
        const Icon = Icons[meta.icon] || Icons.Activity;
        const roleColor = ROLE_COLOR[a.actor_role] || 'var(--accent)';
        const toneStyle = meta.tone === 'danger'
          ? { background:'var(--danger-tint)',  color:'var(--danger)' }
          : meta.tone === 'warn'
          ? { background:'rgba(245,158,11,0.12)', color:'var(--warning,#f59e0b)' }
          : meta.tone === 'info'
          ? { background:'rgba(59,130,246,0.12)', color:'oklch(72% 0.14 240)' }
          : { background:'var(--accent-tint)',  color:'var(--accent)' };
        return (
          <div key={i} className="feed-item">
            <div className="feed-icon" style={toneStyle}><Icon size={14}/></div>
            <div className="feed-text" style={{flex:1, minWidth:0}}>
              <div style={{display:'flex', alignItems:'center', gap:6, flexWrap:'wrap'}}>
                <span style={{
                  fontSize:11, fontWeight:700, padding:'1px 6px', borderRadius:3,
                  background:'var(--surface-2)', color: roleColor,
                  textTransform:'uppercase', letterSpacing:'0.04em',
                }}>{a.actor}</span>
                <span style={{fontSize:12.5, color:'var(--text)'}}>
                  {meta.label}
                  {a.target ? <span style={{fontWeight:600}}> "{a.target}"</span> : null}
                </span>
              </div>
              {a.detail && (
                <div style={{fontSize:11.5, color:'var(--muted)', marginTop:2}}>{a.detail}</div>
              )}
              <div className="feed-meta">{a.time}</div>
            </div>
          </div>
        );
      })}
    </div>
  </div>
);

// ── Reseller Quota Panel ──────────────────────────────────────────────────────
const QuotaCard = ({ label, icon, cur, max, unit, pct, tone }) => {
  const Icon = Icons[icon] || Icons.Activity;
  const isOver  = pct >= 100;
  const isWarn  = !isOver && pct >= 80;
  const barColor = isOver ? 'var(--danger)' : isWarn ? 'var(--warning,#f59e0b)' : 'var(--accent)';
  const textColor = isOver ? 'var(--danger)' : isWarn ? 'var(--warning,#f59e0b)' : 'var(--text)';
  const bgTint = isOver ? 'var(--danger-tint)' : isWarn ? 'rgba(245,158,11,0.12)' : 'var(--accent-tint)';
  const iconColor = isOver ? 'var(--danger)' : isWarn ? 'var(--warning,#f59e0b)' : 'var(--accent)';
  const remaining = Math.max(0, max - cur);
  return (
    <div className="card" style={{padding:'20px 22px', display:'flex', flexDirection:'column', gap:14}}>
      <div style={{display:'flex', alignItems:'center', gap:10}}>
        <div style={{
          width:34, height:34, borderRadius:8, display:'flex', alignItems:'center', justifyContent:'center',
          background: bgTint, color: iconColor, flexShrink:0,
        }}><Icon size={16}/></div>
        <div>
          <div style={{fontSize:12, fontWeight:700, color:'var(--muted)', textTransform:'uppercase', letterSpacing:'.05em'}}>{label}</div>
          <div style={{fontSize:11, color:'var(--muted)', marginTop:1}}>
            {remaining > 0 ? `${unit === 'GB' ? remaining.toFixed(1) : remaining} ${unit} remaining` : <span style={{color:'var(--danger)', fontWeight:600}}>Limit reached</span>}
          </div>
        </div>
        <div style={{marginLeft:'auto', textAlign:'right'}}>
          <div style={{
            fontSize:22, fontWeight:700, fontFamily:'var(--font-mono)', color: textColor, lineHeight:1,
          }}>{unit === 'GB' ? cur.toFixed(1) : cur}</div>
          <div style={{fontSize:11, color:'var(--muted)', marginTop:2}}>
            of {unit === 'GB' ? max.toFixed(0) : max} {unit}
          </div>
        </div>
      </div>
      {/* Progress bar */}
      <div>
        <div style={{display:'flex', justifyContent:'space-between', fontSize:11, color:'var(--muted)', marginBottom:5}}>
          <span>{Math.round(pct)}% used</span>
          <span style={{fontFamily:'var(--font-mono)', fontWeight:600, color: textColor}}>
            {unit === 'GB' ? cur.toFixed(2) : cur} / {unit === 'GB' ? max.toFixed(0) : max} {unit}
          </span>
        </div>
        <div style={{height:6, borderRadius:3, background:'var(--border)', overflow:'hidden'}}>
          <div style={{
            height:'100%', borderRadius:3,
            width:`${Math.min(100, pct)}%`,
            background: barColor,
            transition:'width 0.4s ease',
          }}/>
        </div>
      </div>
    </div>
  );
};

const ResellerQuotaPanel = ({ quota }) => {
  if (!quota) return (
    <div style={{padding:40, textAlign:'center', color:'var(--muted)'}}>Loading quota…</div>
  );
  const {
    data_used_gb = 0, used_limit_gb = 0,
    data_allocated_gb = 0, data_limit_gb = 0,
    users_total = 0, user_count = 0,
    users_active = 0, active_user_count = 0,
  } = quota;

  const usedPct   = used_limit_gb   > 0 ? data_used_gb      / used_limit_gb   * 100 : 0;
  const allocPct  = data_limit_gb   > 0 ? data_allocated_gb / data_limit_gb   * 100 : 0;
  const totalPct  = user_count      > 0 ? users_total        / user_count      * 100 : 0;
  const activePct = active_user_count > 0 ? users_active     / active_user_count * 100 : 0;

  return (
    <div style={{display:'flex', flexDirection:'column', gap:20}}>
      {/* Section header */}
      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', padding:'0 2px'}}>
        <div>
          <div style={{fontSize:16, fontWeight:700, color:'var(--text)'}}>My Quota</div>
          <div style={{fontSize:12.5, color:'var(--muted)', marginTop:2}}>Your current limits and usage across all users</div>
        </div>
        {(usedPct >= 90 || allocPct >= 90 || totalPct >= 90 || activePct >= 90) && (
          <span style={{
            fontSize:11, fontWeight:700, padding:'4px 10px', borderRadius:6,
            background:'var(--danger-tint)', color:'var(--danger)', letterSpacing:'.04em',
          }}>⚠ Approaching limit</span>
        )}
      </div>

      {/* 4 quota cards in 2×2 grid */}
      <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fill, minmax(260px, 1fr))', gap:14}}>
        <QuotaCard
          label="Traffic Used"
          icon="Activity"
          cur={data_used_gb}
          max={used_limit_gb}
          unit="GB"
          pct={usedPct}
        />
        <QuotaCard
          label="Traffic Allocated"
          icon="Traffic"
          cur={data_allocated_gb}
          max={data_limit_gb}
          unit="GB"
          pct={allocPct}
        />
        <QuotaCard
          label="Total Users"
          icon="Users"
          cur={users_total}
          max={user_count}
          unit="users"
          pct={totalPct}
        />
        <QuotaCard
          label="Active Users"
          icon="Power"
          cur={users_active}
          max={active_user_count}
          unit="users"
          pct={activePct}
        />
      </div>
    </div>
  );
};

// ── Admin Quota Panel ─────────────────────────────────────────────────────────
const AdminQuotaPanel = ({ quota }) => {
  if (!quota) return null;
  const { reseller_count = 0, resellers_total = 0, data_limit_gb = 0, data_used_gb = 0, user_count = 0, users_total = 0, users_active = 0 } = quota;
  const rPct = reseller_count > 0 ? resellers_total / reseller_count * 100 : 0;
  const dPct = data_limit_gb  > 0 ? data_used_gb   / data_limit_gb  * 100 : 0;
  const uPct = user_count     > 0 ? users_total    / user_count     * 100 : 0;
  const items = [
    { label: 'Resellers', icon: 'Shield', cur: resellers_total, max: reseller_count, unit: '',   pct: rPct },
    { label: 'Data Used',  icon: 'Activity', cur: data_used_gb,   max: data_limit_gb,  unit: 'GB', pct: dPct },
    { label: 'Total Users',icon: 'Users',  cur: users_total,     max: user_count,     unit: '',   pct: uPct },
  ];
  return (
    <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fill, minmax(220px, 1fr))', gap:14}}>
      {items.map(item => {
        const Icon = Icons[item.icon] || Icons.Activity;
        const isOver = item.pct >= 100, isWarn = !isOver && item.pct >= 80;
        const barColor  = isOver ? 'var(--danger)' : isWarn ? 'var(--warning,#f59e0b)' : 'var(--accent)';
        const textColor = isOver ? 'var(--danger)' : isWarn ? 'var(--warning,#f59e0b)' : 'var(--text)';
        const bgTint    = isOver ? 'var(--danger-tint)' : isWarn ? 'rgba(245,158,11,0.12)' : 'var(--accent-tint)';
        const remaining = Math.max(0, item.max - item.cur);
        return (
          <div key={item.label} className="card" style={{padding:'18px 20px', display:'flex', flexDirection:'column', gap:12}}>
            <div style={{display:'flex', alignItems:'center', gap:10}}>
              <div style={{width:32, height:32, borderRadius:8, display:'flex', alignItems:'center', justifyContent:'center', background:bgTint, color: isOver?'var(--danger)':isWarn?'var(--warning,#f59e0b)':'var(--accent)', flexShrink:0}}>
                <Icon size={15}/>
              </div>
              <div>
                <div style={{fontSize:11.5, fontWeight:700, color:'var(--muted)', textTransform:'uppercase', letterSpacing:'.05em'}}>{item.label}</div>
                <div style={{fontSize:11, color:'var(--muted)', marginTop:1}}>
                  {remaining > 0
                    ? `${item.unit === 'GB' ? remaining.toFixed(1) : remaining} ${item.unit || 'remaining'}`
                    : <span style={{color:'var(--danger)', fontWeight:600}}>Limit reached</span>}
                </div>
              </div>
              <div style={{marginLeft:'auto', textAlign:'right'}}>
                <div style={{fontSize:22, fontWeight:700, fontFamily:'var(--font-mono)', color:textColor, lineHeight:1}}>
                  {item.unit === 'GB' ? item.cur.toFixed(1) : item.cur}
                </div>
                <div style={{fontSize:11, color:'var(--muted)', marginTop:2}}>
                  of {item.unit === 'GB' ? item.max.toFixed(0) : item.max}{item.unit ? ` ${item.unit}` : ''}
                </div>
              </div>
            </div>
            <div style={{height:5, borderRadius:3, background:'var(--border)', overflow:'hidden'}}>
              <div style={{height:'100%', borderRadius:3, width:`${Math.min(100, item.pct)}%`, background:barColor, transition:'width 0.4s ease'}}/>
            </div>
          </div>
        );
      })}
    </div>
  );
};

// ── Main Dashboard ────────────────────────────────────────────────────────────
const Dashboard = ({ onAddUser, pushToast }) => {
  const [data, setData] = React.useState(null);
  const [range, setRange] = React.useState('7d');
  const role = window.__BRIDGE__?.role || 'superadmin';
  const isSuperAdmin = role === 'superadmin';
  const isReseller   = role === 'reseller';

  React.useEffect(() => {
    fetch('/api/dashboard')
      .then(r => r.json())
      .then(setData)
      .catch(() => {});
  }, []);

  const kpis = data ? [
    { label: 'Active Users',  value: data.active_users,  suffix: '',     delta: `${data.total_users} total`,  trend: 'up', icon: 'Users',    tone: 'accent',
      spark: [22,28,26,31,35,40,38,42,49,51,55,60,64,68,data.active_users > 0 ? data.active_users : 72] },
    { label: 'Total Users',   value: data.total_users,   suffix: '',     delta: `${data.active_users} active`,trend: 'up', icon: 'Activity', tone: 'info',
      spark: [40,35,42,48,45,52,58,55,60,62,68,71,74,80,data.total_users > 0 ? data.total_users : 84] },
    { label: 'Inbounds',      value: data.inbounds,      suffix: '',     delta: `${data.enabled_inbounds} enabled`, trend:'up', icon: 'Inbound', tone: 'warn',
      spark: [5,5,6,6,7,7,8,8,data.inbounds,data.inbounds,data.inbounds,data.enabled_inbounds,data.enabled_inbounds,data.enabled_inbounds,data.enabled_inbounds] },
    { label: 'Servers',       value: data.servers,       suffix: '',     delta: `${data.online_servers} online`, trend:'up', icon: 'Server', tone: 'accent',
      spark: [2,2,3,3,4,4,5,5,6,6,data.servers,data.servers,data.servers,data.online_servers,data.online_servers] },
  ] : [];

  const adminList      = data?.admin_list     || [];
  const resellerList   = data?.reseller_list  || [];
  const activity       = data?.activity       || [];
  const resellerQuota  = data?.reseller_quota || null;

  return (
    <div className="page" data-screen-label="dashboard">
      {!data && (
        <div style={{display:'flex', alignItems:'center', justifyContent:'center', height:200, color:'var(--muted)'}}>
          Loading…
        </div>
      )}

      {data && isReseller && (
        <div style={{display:'flex', flexDirection:'column', gap:24}}>
          {/* Quota cards */}
          <ResellerQuotaPanel quota={resellerQuota}/>

          {/* Network Traffic chart */}
          <div className="card">
            <div className="section-head">
              <div>
                <div className="section-title">Network Traffic</div>
                <div className="section-sub">Live bandwidth across all inbounds (30 s intervals)</div>
              </div>
              <div className="dash-chart-controls">
                <div style={{display:'flex', alignItems:'center', gap:12, fontSize:11.5, color:'var(--muted)'}}>
                  <span style={{display:'flex', alignItems:'center', gap:5}}><span style={{width:8, height:8, borderRadius:'50%', background:'var(--accent)'}}/>Download</span>
                  <span style={{display:'flex', alignItems:'center', gap:5}}><span style={{width:8, height:8, borderRadius:'50%', background:'oklch(72% 0.14 240)'}}/>Upload</span>
                </div>
                <div className="tab-pill">
                  {['24h','7d','30d','All'].map(r => (
                    <button key={r} className={range === r ? 'active' : ''} onClick={() => setRange(r)}>{r}</button>
                  ))}
                </div>
              </div>
            </div>
            <div style={{padding:'4px 18px 18px'}}>
              {data.bw_history && data.bw_history.down.length > 0
                ? <AreaChart down={data.bw_history.down} up={data.bw_history.up} h={220}/>
                : <div style={{height:220, display:'flex', alignItems:'center', justifyContent:'center', color:'var(--muted)', fontSize:13}}>
                    No traffic data yet — collected every 30 s while Xray is running
                  </div>
              }
            </div>
          </div>
        </div>
      )}

      {data && !isReseller && isSuperAdmin && (
        <>
          <div className="kpi-grid">
            {kpis.map((k, i) => {
              const Icon = Icons[k.icon];
              return (
                <div key={k.label} className="card kpi hover" style={{animationDelay: `${i * 60}ms`}}>
                  <div className="kpi-head">
                    <div className={`kpi-icon ${k.tone}`}><Icon size={15}/></div>
                    <span>{k.label}</span>
                  </div>
                  <div className="kpi-value num-rise">
                    <Ticker value={k.value} decimals={0}/>
                    <span style={{fontSize: 16, color: 'var(--muted)', marginLeft: 4, fontWeight: 500}}>{k.suffix}</span>
                  </div>
                  <div className="kpi-meta">
                    <span className="delta up"><Icons.Up size={10}/>{k.delta}</span>
                  </div>
                  <div className="spark">
                    <Sparkline data={k.spark} h={50}/>
                  </div>
                </div>
              );
            })}
          </div>

          <div className="main-grid">
            <div className="card">
              <div className="section-head">
                <div>
                  <div className="section-title">Network Traffic</div>
                  <div className="section-sub">Actual bytes across all inbounds (30 s intervals)</div>
                </div>
                <div className="dash-chart-controls">
                  <div style={{display:'flex', alignItems:'center', gap:12, fontSize:11.5, color:'var(--muted)'}}>
                    <span style={{display:'flex', alignItems:'center', gap:5}}><span style={{width:8, height:8, borderRadius:'50%', background:'var(--accent)'}}/>Download</span>
                    <span style={{display:'flex', alignItems:'center', gap:5}}><span style={{width:8, height:8, borderRadius:'50%', background:'oklch(72% 0.14 240)'}}/>Upload</span>
                  </div>
                  <div className="tab-pill">
                    {['24h','7d','30d','All'].map(r => (
                      <button key={r} className={range === r ? 'active' : ''} onClick={() => setRange(r)}>{r}</button>
                    ))}
                  </div>
                </div>
              </div>
              <div style={{padding: '4px 18px 18px'}}>
                {data.bw_history && data.bw_history.down.length > 0
                  ? <AreaChart down={data.bw_history.down} up={data.bw_history.up} h={260}/>
                  : <div style={{height:260, display:'flex', alignItems:'center', justifyContent:'center', color:'var(--muted)', fontSize:13}}>
                      No traffic data yet — collected every 30 s while Xray is running
                    </div>
                }
              </div>
            </div>
            <AdminOverview admins={adminList}/>
          </div>

          <div className="secondary-grid">
            <ResellerOverview resellers={resellerList}/>
            <ActivityFeed activity={activity}/>
          </div>
        </>
      )}

      {data && !isReseller && role === 'admin' && (
        <>
          {/* Admin KPIs — only users (inbounds/servers not applicable) */}
          <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fill, minmax(200px, 1fr))', gap:14, marginBottom:18}}>
            {[
              { label:'Active Users', value: data.active_users, delta:`${data.total_users} total`,   icon:'Users',    tone:'accent',
                spark:[22,28,26,31,35,40,38,42,49,51,55,60,64,68,data.active_users>0?data.active_users:72] },
              { label:'Total Users',  value: data.total_users,  delta:`${data.active_users} active`, icon:'Activity', tone:'info',
                spark:[40,35,42,48,45,52,58,55,60,62,68,71,74,80,data.total_users>0?data.total_users:84] },
              { label:'Resellers',    value: (data.admin_quota?.resellers_total||0), delta:`of ${data.admin_quota?.reseller_count||0} quota`, icon:'Shield', tone:'warn',
                spark:[1,1,2,2,3,3,4,4,5,5,6,6,data.admin_quota?.resellers_total||0,data.admin_quota?.resellers_total||0,data.admin_quota?.resellers_total||0] },
            ].map((k, i) => {
              const Icon = Icons[k.icon];
              return (
                <div key={k.label} className="card kpi hover" style={{animationDelay:`${i*60}ms`}}>
                  <div className="kpi-head">
                    <div className={`kpi-icon ${k.tone}`}><Icon size={15}/></div>
                    <span>{k.label}</span>
                  </div>
                  <div className="kpi-value num-rise">
                    <Ticker value={k.value} decimals={0}/>
                  </div>
                  <div className="kpi-meta">
                    <span className="delta up"><Icons.Up size={10}/>{k.delta}</span>
                  </div>
                  <div className="spark"><Sparkline data={k.spark} h={50}/></div>
                </div>
              );
            })}
          </div>

          {/* Admin quota panel */}
          <div style={{marginBottom:18}}>
            <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:12, padding:'0 2px'}}>
              <div>
                <div style={{fontSize:16, fontWeight:700, color:'var(--text)'}}>My Quota</div>
                <div style={{fontSize:12.5, color:'var(--muted)', marginTop:2}}>Your current limits across all resellers</div>
              </div>
            </div>
            <AdminQuotaPanel quota={data.admin_quota}/>
          </div>

          {/* Resellers + Activity side by side */}
          <div style={{display:'grid', gridTemplateColumns:'1fr 1fr', gap:14}}>
            <ResellerOverview resellers={resellerList}/>
            <ActivityFeed activity={activity}/>
          </div>
        </>
      )}
    </div>
  );
};

Object.assign(window, { Dashboard });
