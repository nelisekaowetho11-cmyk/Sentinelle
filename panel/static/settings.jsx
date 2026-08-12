// Settings page

const SettingsPage = ({ pushToast }) => {
  const [section, setSection] = React.useState('Workspace');
  const [settings, setSettings] = React.useState({});
  const [xrayStatus, setXrayStatus] = React.useState('unknown');
  const [xrayBinaryExists, setXrayBinaryExists] = React.useState(false);
  const [xrayMsg, setXrayMsg] = React.useState('');
  const [saving, setSaving] = React.useState(false);

  // Password change state
  const [oldPw, setOldPw] = React.useState('');
  const [newPw, setNewPw] = React.useState('');
  const [confirmPw, setConfirmPw] = React.useState('');

  const loadSettings = () => {
    fetch('/api/settings').then(r => r.json()).then(d => setSettings(d.settings || {})).catch(()=>{});
  };

  const loadStatus = () => {
    fetch('/api/xray/status').then(r => r.json()).then(d => {
      setXrayStatus(d.status || 'stopped');
      setXrayBinaryExists(!!d.binary_exists);
      if (d.binary) setSettings(prev => ({...prev, xray_binary: d.binary}));
    }).catch(()=>{});
  };

  React.useEffect(() => {
    loadSettings();
    loadStatus();
  }, []);

  const saveSettings = () => {
    setSaving(true);
    fetch('/api/settings', {
      method: 'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify(settings)
    })
      .then(r => r.json())
      .then(d => {
        setSaving(false);
        setXrayBinaryExists(!!d.binary_exists);
        pushToast('Settings saved');
        loadStatus();
      })
      .catch(() => setSaving(false));
  };

  const xrayAction = (action) => {
    setXrayMsg('');
    fetch(`/api/xray/${action}`, {method:'POST'})
      .then(r => r.json())
      .then(d => {
        setXrayStatus(d.status || (action === 'stop' ? 'stopped' : 'running'));
        if (d.message) setXrayMsg(d.message);
        pushToast(d.ok ? `Xray ${action} OK` : (d.message || `${action} failed`));
      })
      .catch(() => pushToast(`${action} failed`));
  };

  const changePassword = () => {
    if (!oldPw || !newPw) return pushToast('Fill in all password fields');
    if (newPw !== confirmPw) return pushToast('Passwords do not match');
    fetch('/api/settings/password', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({old_password: oldPw, new_password: newPw})
    })
      .then(r => r.json())
      .then(d => {
        if (d.ok) { pushToast('Password changed'); setOldPw(''); setNewPw(''); setConfirmPw(''); }
        else pushToast(d.error || 'Wrong password');
      })
      .catch(() => pushToast('Password change failed'));
  };

  const downloadConfig = () => { window.open('/api/config/download', '_blank'); };

  const SECTIONS = ['Workspace', 'Subscription', 'Client Apps', 'TLS / Certs', 'Xray Control', 'Xray Core', 'Telegram Backup', 'System Service', 'Security', 'Console', 'Danger zone'];

  return (
    <div className="page" data-screen-label="settings">
      <div className="settings-layout">
        <nav className="settings-nav">
          {SECTIONS.map(s => (
            <div key={s} className={`nav-item ${section === s ? 'active' : ''}`} onClick={() => setSection(s)}>
              <span>{s}</span>
            </div>
          ))}
        </nav>

        <div style={{display:'flex', flexDirection:'column', gap:14}}>

          {/* ── Workspace ── */}
          {section === 'Workspace' && (
            <div className="card">
              <div className="section-head">
                <div>
                  <div className="section-title">Workspace</div>
                  <div className="section-sub">Panel identity and defaults</div>
                </div>
              </div>
              <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:14}}>
                <div className="field-row">
                  <div className="field">
                    <label className="field-label">Panel name</label>
                    <input className="input" value={settings.panel_name || ''} onChange={e => setSettings({...settings, panel_name: e.target.value})} placeholder="Bridge Panel"/>
                  </div>
                  <div className="field">
                    <label className="field-label">Default protocol</label>
                    <select className="select" value={settings.default_proto || 'VLESS'} onChange={e => setSettings({...settings, default_proto: e.target.value})}>
                      {PROTOCOLS.map(p => <option key={p}>{p}</option>)}
                    </select>
                  </div>
                </div>
                <div className="field-row">
                  <div className="field">
                    <label className="field-label">Default quota (GB)</label>
                    <input className="input mono" type="number" value={settings.default_quota || ''} onChange={e => setSettings({...settings, default_quota: e.target.value})} placeholder="100"/>
                  </div>
                  <div className="field">
                    <label className="field-label">Default expiry (days)</label>
                    <input className="input mono" type="number" value={settings.default_expiry || ''} onChange={e => setSettings({...settings, default_expiry: e.target.value})} placeholder="30"/>
                  </div>
                </div>
                <div className="field">
                  <label className="field-label">Server IP / domain</label>
                  <input className="input mono" value={settings.server_ip || ''} onChange={e => setSettings({...settings, server_ip: e.target.value})} placeholder="e.g. 193.176.243.160 or vpn.example.com"/>
                  <span className="field-hint">Used in generated client vless:// / vmess:// links</span>
                </div>
                {/* Sub info entry */}
                <div style={{
                  display:'flex', alignItems:'center', justifyContent:'space-between',
                  padding:'12px 14px', background:'var(--surface-2)', border:'1px solid var(--border)',
                  borderRadius:'var(--r-md)',
                }}>
                  <div>
                    <div style={{fontSize:13, fontWeight:500}}>Subscription info entry</div>
                    <div style={{fontSize:11.5, color:'var(--muted)', marginTop:2}}>
                      Prepend a non-connectable entry in each user's subscription showing remaining data &amp; days
                    </div>
                  </div>
                  <div
                    className={`switch ${(settings.sub_info_entry === 'true' || settings.sub_info_entry === undefined) ? 'on' : ''}`}
                    onClick={() => setSettings({
                      ...settings,
                      sub_info_entry: (settings.sub_info_entry === 'false') ? 'true' : 'false'
                    })}
                  />
                </div>
                <div style={{display:'flex', justifyContent:'flex-end'}}>
                  <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
                    <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save settings'}
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* ── Subscription ── */}
          {section === 'Subscription' && (
            <SubscriptionSection settings={settings} setSettings={setSettings} saveSettings={saveSettings} saving={saving} pushToast={pushToast}/>
          )}

          {/* ── Client Apps ── */}
          {section === 'Client Apps' && (
            <ClientAppsSection settings={settings} setSettings={setSettings}
              saveSettings={saveSettings} saving={saving} pushToast={pushToast}/>
          )}

          {/* ── TLS / Certs ── */}
          {section === 'TLS / Certs' && (
            <div className="card">
              <div className="section-head">
                <div>
                  <div className="section-title">TLS certificates</div>
                  <div className="section-sub">Global cert used by all WS / gRPC inbounds with TLS enabled</div>
                </div>
                {settings.tls_cert_file && settings.tls_key_file
                  ? <span className="badge ok"><span className="dot"/>Configured</span>
                  : <span className="badge warn"><span className="dot"/>Not set</span>}
              </div>
              <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:14}}>

                {/* Info banner */}
                <div style={{
                  display:'flex', gap:10, alignItems:'flex-start',
                  padding:'10px 12px', borderRadius:'var(--r-md)',
                  background:'oklch(72% 0.14 240 / 0.08)', border:'1px solid oklch(72% 0.14 240 / 0.25)',
                  fontSize:12.5, color:'oklch(72% 0.14 240)'
                }}>
                  <Icons.Shield size={14} style={{marginTop:1, flexShrink:0}}/>
                  <div>
                    These paths are used when a WS or gRPC inbound has <b>TLS</b> selected but no
                    per-inbound cert is configured. Typically your Let's Encrypt <code style={{fontFamily:'var(--font-mono)'}}>fullchain.pem</code> and <code style={{fontFamily:'var(--font-mono)'}}>privkey.pem</code>.
                  </div>
                </div>

                <div className="field">
                  <label className="field-label">Certificate file path (.crt / .pem)</label>
                  <input
                    className="input mono"
                    placeholder="/etc/letsencrypt/live/yourdomain.com/fullchain.pem"
                    value={settings.tls_cert_file || ''}
                    onChange={e => setSettings({...settings, tls_cert_file: e.target.value})}
                  />
                </div>
                <div className="field">
                  <label className="field-label">Private key file path (.key / .pem)</label>
                  <input
                    className="input mono"
                    placeholder="/etc/letsencrypt/live/yourdomain.com/privkey.pem"
                    value={settings.tls_key_file || ''}
                    onChange={e => setSettings({...settings, tls_key_file: e.target.value})}
                  />
                </div>

                {/* File existence feedback */}
                {(settings.tls_cert_file || settings.tls_key_file) && (
                  <div style={{
                    display:'grid', gridTemplateColumns:'1fr 1fr', gap:8, fontSize:12
                  }}>
                    {[
                      {label:'Certificate file', val: settings.tls_cert_file},
                      {label:'Key file', val: settings.tls_key_file},
                    ].map(f => (
                      <div key={f.label} style={{
                        padding:'8px 10px', borderRadius:'var(--r-md)',
                        background:'var(--surface-2)', border:'1px solid var(--border)',
                        display:'flex', alignItems:'center', gap:8
                      }}>
                        <Icons.Shield size={12} style={{color: f.val ? 'var(--accent)' : 'var(--muted)'}}/>
                        <div>
                          <div style={{color:'var(--muted)', fontSize:11}}>{f.label}</div>
                          <div style={{fontFamily:'var(--font-mono)', fontSize:11, marginTop:2, wordBreak:'break-all'}}>
                            {f.val || <span style={{color:'var(--muted)'}}>not set</span>}
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                )}

                <div style={{display:'flex', justifyContent:'flex-end', marginTop:4}}>
                  <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
                    <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save certificates'}
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* ── Xray Control ── */}
          {section === 'Xray Control' && (
            <>
              {/* Binary path card */}
              <div className="card">
                <div className="section-head">
                  <div>
                    <div className="section-title">Xray binary path</div>
                    <div className="section-sub">Full path to the xray executable on this machine</div>
                  </div>
                  {xrayBinaryExists
                    ? <span className="badge ok"><span className="dot"/>Found</span>
                    : <span className="badge danger"><span className="dot"/>Not found</span>}
                </div>
                <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:10}}>
                  <div className="field">
                    <label className="field-label">Binary path</label>
                    <input
                      className="input mono"
                      value={settings.xray_binary || ''}
                      onChange={e => setSettings({...settings, xray_binary: e.target.value})}
                      placeholder="/usr/local/bin/xray  or  C:\xray\xray.exe"
                    />
                    <span className="field-hint">
                      Linux example: <code style={{fontFamily:'var(--font-mono)'}}>/root/xray/xray-linux-amd64</code>&nbsp;&nbsp;
                      Windows example: <code style={{fontFamily:'var(--font-mono)'}}>C:\xray\xray.exe</code>
                    </span>
                  </div>
                  <div style={{display:'flex', justifyContent:'flex-end'}}>
                    <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
                      <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save path'}
                    </button>
                  </div>
                </div>
              </div>

              {/* Process control card */}
              <div className="card">
                <div className="section-head">
                  <div>
                    <div className="section-title">Process control</div>
                    <div className="section-sub">Start, stop and restart the Xray core</div>
                  </div>
                  <Badge kind={xrayStatus === 'running' ? 'online' : 'down'}>
                    {xrayStatus === 'running' ? 'Running' : 'Stopped'}
                  </Badge>
                </div>
                <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:12}}>
                  <div style={{display:'flex', gap:8, flexWrap:'wrap'}}>
                    <button className="btn btn-primary" onClick={() => xrayAction('start')} disabled={xrayStatus === 'running' || !xrayBinaryExists}>
                      <Icons.Power size={13}/> Start
                    </button>
                    <button className="btn btn-ghost" onClick={() => xrayAction('restart')} disabled={!xrayBinaryExists}>
                      <Icons.Refresh size={13}/> Restart
                    </button>
                    <button className="btn btn-ghost" style={{color:'var(--danger)'}} onClick={() => xrayAction('stop')} disabled={xrayStatus !== 'running'}>
                      <Icons.Power size={13}/> Stop
                    </button>
                    <button className="btn btn-ghost" onClick={downloadConfig}>
                      <Icons.Download size={13}/> Download config.json
                    </button>
                  </div>
                  {xrayMsg && (
                    <div style={{
                      fontFamily:'var(--font-mono)', fontSize:12, padding:'8px 10px',
                      background:'var(--surface-2)', border:'1px solid var(--border)',
                      borderRadius:'var(--r-md)', color: xrayStatus === 'running' ? 'var(--accent)' : 'var(--danger)',
                      wordBreak:'break-all'
                    }}>
                      {xrayMsg}
                    </div>
                  )}
                  {!xrayBinaryExists && (
                    <div style={{
                      display:'flex', alignItems:'center', gap:8, padding:'8px 10px',
                      background:'oklch(68% 0.20 25 / 0.10)', border:'1px solid oklch(68% 0.20 25 / 0.3)',
                      borderRadius:'var(--r-md)', fontSize:12.5, color:'var(--danger)'
                    }}>
                      <Icons.Zap size={13}/>
                      Binary not found at the path above. Set the correct path and click Save.
                    </div>
                  )}
                </div>
              </div>

              {/* Binary cache manager */}
              <BinaryCacheManager pushToast={pushToast}/>

              {/* Speed limiting (tc) */}
              <SpeedLimiterSection settings={settings} setSettings={setSettings} saveSettings={saveSettings} saving={saving} pushToast={pushToast}/>

              {/* Live log viewer */}
              <XrayLogViewer/>
            </>
          )}

          {/* ── Xray Core ── */}
          {section === 'Xray Core' && (
            <XrayCoreSection pushToast={pushToast}/>
          )}

          {/* ── Telegram Backup ── */}
          {section === 'Telegram Backup' && (
            <TelegramBackupSection settings={settings} setSettings={setSettings} saveSettings={saveSettings} saving={saving} pushToast={pushToast}/>
          )}

          {/* ── System Service ── */}
          {section === 'System Service' && (
            <SystemServiceSection pushToast={pushToast}/>
          )}

          {/* ── Security ── */}
          {section === 'Security' && (
            <div className="card">
              <div className="section-head">
                <div>
                  <div className="section-title">Change password</div>
                  <div className="section-sub">Update your admin password</div>
                </div>
              </div>
              <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:14}}>
                <div className="field">
                  <label className="field-label">Current password</label>
                  <input className="input" type="password" value={oldPw} onChange={e => setOldPw(e.target.value)} placeholder="••••••••"/>
                </div>
                <div className="field">
                  <label className="field-label">New password</label>
                  <input className="input" type="password" value={newPw} onChange={e => setNewPw(e.target.value)} placeholder="••••••••"/>
                </div>
                <div className="field">
                  <label className="field-label">Confirm new password</label>
                  <input className="input" type="password" value={confirmPw} onChange={e => setConfirmPw(e.target.value)} placeholder="••••••••"/>
                </div>
                <div style={{display:'flex', justifyContent:'flex-end'}}>
                  <button className="btn btn-primary" onClick={changePassword}>
                    <Icons.Lock size={14}/> Update password
                  </button>
                </div>
              </div>
            </div>
          )}

          {/* ── Console ── */}
          {section === 'Console' && (
            <ConsoleSection pushToast={pushToast}/>
          )}

          {/* ── Danger zone ── */}
          {section === 'Danger zone' && (
            <div className="card">
              <div className="section-head">
                <div>
                  <div className="section-title">Danger zone</div>
                  <div className="section-sub">Irreversible actions</div>
                </div>
              </div>
              <div style={{padding:'0 18px 18px', display:'flex', gap:8, flexWrap:'wrap'}}>
                <button className="btn btn-ghost" onClick={downloadConfig}><Icons.Download size={13}/> Export config.json</button>
                <button className="btn btn-ghost" onClick={() => {
                  fetch('/api/generate-keys').then(r=>r.json()).then(d => pushToast(d.error || `New pub key: ${d.public_key.slice(0,16)}…`));
                }}><Icons.Refresh size={13}/> Generate new keys</button>
                <button className="btn btn-danger" onClick={() => {
                  if (confirm('This will delete all user sessions. Continue?')) pushToast('Sessions wiped');
                }}><Icons.Trash size={13}/> Wipe sessions</button>
              </div>
            </div>
          )}

        </div>
      </div>
    </div>
  );
};


// ── Live Xray log viewer ──────────────────────────────────────────────────────
const XrayLogViewer = () => {
  const [logs, setLogs] = React.useState([]);
  const [paused, setPaused] = React.useState(false);
  const [filter, setFilter] = React.useState('');
  const bottomRef = React.useRef(null);
  const pausedRef = React.useRef(false);

  pausedRef.current = paused;

  const fetchLogs = () => {
    if (pausedRef.current) return;
    fetch('/api/xray/logs?n=200')
      .then(r => r.json())
      .then(d => setLogs(d.logs || []))
      .catch(() => {});
  };

  React.useEffect(() => {
    fetchLogs();
    const id = setInterval(fetchLogs, 2000);
    return () => clearInterval(id);
  }, []);

  // Auto-scroll to bottom when new logs arrive (unless paused)
  React.useEffect(() => {
    if (!paused && bottomRef.current) {
      bottomRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [logs]);

  const levelColor = (line) => {
    const l = line.toLowerCase();
    if (l.includes('error') || l.includes('failed') || l.includes('fatal')) return 'var(--danger)';
    if (l.includes('warn') || l.includes('warning')) return 'var(--warn)';
    if (l.includes('[panel]')) return 'oklch(72% 0.14 240)';
    return 'var(--text)';
  };

  const visible = filter
    ? logs.filter(e => e.line.toLowerCase().includes(filter.toLowerCase()))
    : logs;

  return (
    <div className="card">
      <div className="section-head">
        <div>
          <div className="section-title">Xray logs</div>
          <div className="section-sub">Live output · last 200 lines · refreshes every 2 s</div>
        </div>
        <div style={{display:'flex', gap:8, alignItems:'center'}}>
          <div className="toolbar-search" style={{width:180}}>
            <Icons.Search size={13}/>
            <input
              value={filter}
              onChange={e => setFilter(e.target.value)}
              placeholder="Filter…"
              style={{fontSize:12}}
            />
          </div>
          <button
            className={`btn btn-ghost`}
            style={{padding:'5px 10px', fontSize:12, color: paused ? 'var(--accent)' : 'var(--muted)'}}
            onClick={() => setPaused(p => !p)}
          >
            {paused ? <><Icons.Power size={12}/> Resume</> : <><Icons.Hash size={12}/> Pause</>}
          </button>
          <button className="btn btn-ghost" style={{padding:'5px 10px', fontSize:12}} onClick={() => setLogs([])}>
            <Icons.Trash size={12}/> Clear
          </button>
        </div>
      </div>

      <div style={{
        fontFamily:'var(--font-mono)', fontSize:11.5, lineHeight:1.6,
        background:'var(--bg)', borderTop:'1px solid var(--border-soft)',
        maxHeight:380, overflowY:'auto', padding:'8px 0'
      }}>
        {visible.length === 0 && (
          <div style={{padding:'32px 18px', color:'var(--muted)', textAlign:'center'}}>
            {logs.length === 0 ? 'No logs yet — start Xray above.' : 'No lines match the filter.'}
          </div>
        )}
        {visible.map((entry, i) => (
          <div key={i} style={{
            display:'grid', gridTemplateColumns:'64px 1fr', gap:12,
            padding:'3px 18px',
            background: i % 2 === 0 ? 'transparent' : 'rgba(255,255,255,0.012)'
          }}>
            <span style={{color:'var(--muted)', flexShrink:0, userSelect:'none'}}>{entry.ts}</span>
            <span style={{color: levelColor(entry.line), wordBreak:'break-all'}}>{entry.line}</span>
          </div>
        ))}
        <div ref={bottomRef}/>
      </div>
    </div>
  );
};


// ── OUT proxy (exit-IP) status & management ──────────────────────────────────
const OutProxyStatus = ({ pushToast }) => {
  const [status,   setStatus]   = React.useState(null);
  const [servers,  setServers]  = React.useState([]);
  const [loading,  setLoading]  = React.useState(false);
  const [checking, setChecking] = React.useState(false);
  const [selSrv,   setSelSrv]   = React.useState('');
  const [port,     setPort]     = React.useState('10001');
  const [proto,    setProto]    = React.useState('vless');
  const [saving,   setSaving]   = React.useState(false);

  const load = () => {
    fetch('/api/xray/outbound-status').then(r=>r.json()).then(d=>{ setStatus(d); }).catch(()=>{});
    fetch('/api/servers').then(r=>r.json()).then(d=>{
      const out = (d.servers||[]).filter(s => ['out','both'].includes(s.server_type||'out'));
      setServers(out);
      if (!selSrv && out.length > 0) setSelSrv(String(out[0].id));
    }).catch(()=>{});
  };

  React.useEffect(()=>{ load(); }, []);

  const check = () => {
    setChecking(true);
    fetch('/api/xray/outbound-status').then(r=>r.json()).then(d=>{ setStatus(d); setChecking(false); });
  };

  const activate = () => {
    if (!selSrv) return;
    setSaving(true);
    // Save port/protocol first
    fetch(`/api/servers/${selSrv}/out-proxy`, {
      method:'PUT', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({out_proxy_port: Number(port), out_proxy_protocol: proto}),
    }).then(()=>
      fetch(`/api/servers/${selSrv}/set-active-outbound`, {method:'POST'})
    ).then(r=>r.json()).then(d=>{
      setSaving(false);
      if (d.ok) { pushToast('Outbound activated — Xray restarted'); load(); }
      else pushToast('Failed: ' + (d.error||''));
    }).catch(()=>setSaving(false));
  };

  const deactivate = () => {
    fetch('/api/servers/clear-active-outbound',{method:'POST'})
      .then(r=>r.json()).then(d=>{ if(d.ok){pushToast('Outbound cleared'); load();} });
  };

  const getScriptUrl = () => {
    if (!selSrv) return '';
    const srv = servers.find(s=>String(s.id)===selSrv);
    if (!srv || !srv.out_proxy_token) return '';
    return `${window.location.origin}/setup/out-proxy/${selSrv}/${srv.out_proxy_token}`;
  };

  const scriptUrl  = getScriptUrl();
  const installCmd = scriptUrl ? `bash <(curl -fsSL "${scriptUrl}")` : '— select a server first —';

  return (
    <div className="card">
      <div className="section-head">
        <div>
          <div className="section-title">OUT proxy (exit IP)</div>
          <div className="section-sub">Route all VPN traffic through a remote Xray bridge — changes the exit IP</div>
        </div>
        {status?.active ? (
          <span className="badge ok"><span className="dot"/> Active</span>
        ) : (
          <span className="badge" style={{background:'var(--surface-2)',color:'var(--muted)'}}>Inactive</span>
        )}
      </div>

      <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:14}}>

        {/* Architecture diagram */}
        <div style={{
          padding:'10px 14px', borderRadius:'var(--r-md)', fontSize:12, lineHeight:1.7,
          background:'var(--surface-2)', border:'1px solid var(--border)', color:'var(--text-2)',
          fontFamily:'var(--font-mono)',
        }}>
          User → [IN relay] → tunnel → [TR Xray] → <span style={{color:'var(--accent)'}}>VLESS outbound</span> → [OUT server Xray bridge] → Internet 🌍
        </div>

        {/* Current active outbound */}
        {status?.active && (
          <div style={{
            padding:'12px 14px', borderRadius:'var(--r-md)',
            background:'oklch(72% 0.18 140 / 0.07)',
            border:'1px solid oklch(72% 0.18 140 / 0.35)',
          }}>
            <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', flexWrap:'wrap', gap:8}}>
              <div>
                <div style={{fontSize:13, fontWeight:600, color:'oklch(60% 0.18 140)'}}>
                  Active: {status.server?.name} ({status.server?.ip})
                </div>
                <div style={{fontSize:11.5, color:'var(--muted)', marginTop:2, fontFamily:'var(--font-mono)'}}>
                  {status.protocol?.toUpperCase()} :{status.port} · UUID: {status.uuid?.slice(0,18)}…
                </div>
                <div style={{
                  marginTop:6, fontSize:12, fontWeight:600,
                  color: status.reachable ? 'oklch(60% 0.18 140)' : 'var(--danger)',
                }}>
                  {status.message}
                </div>
              </div>
              <div style={{display:'flex', gap:6}}>
                <button className="btn btn-ghost" style={{fontSize:11, padding:'5px 10px'}}
                  onClick={check} disabled={checking}>
                  {checking ? '⏳' : '↺'} Check
                </button>
                <button className="btn btn-ghost" style={{fontSize:11, padding:'5px 10px', color:'var(--danger)'}}
                  onClick={deactivate}>
                  Disable
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Setup new outbound */}
        <div style={{padding:'14px', borderRadius:'var(--r-md)', border:'1px solid var(--border)', background:'var(--surface-2)'}}>
          <div style={{fontSize:13, fontWeight:600, marginBottom:12}}>
            {status?.active ? 'Change outbound server' : 'Set up outbound proxy'}
          </div>

          {/* Step 1 — pick server */}
          <div className="field">
            <label className="field-label">Step 1 — select OUT server</label>
            <select className="input" value={selSrv} onChange={e=>setSelSrv(e.target.value)}>
              <option value="">— select —</option>
              {servers.map(s=>(
                <option key={s.id} value={s.id}>{s.name} ({s.ip})</option>
              ))}
            </select>
            {servers.length === 0 && (
              <div style={{fontSize:11,color:'var(--warn)',marginTop:3}}>
                No OUT servers — add one in the Servers tab first.
              </div>
            )}
          </div>

          {/* Step 2 — port + protocol */}
          <div className="field-row">
            <div className="field">
              <label className="field-label">Step 2 — bridge port</label>
              <input className="input mono" type="number" value={port} onChange={e=>setPort(e.target.value)}/>
              <span className="field-hint">Must be open on the OUT server's firewall</span>
            </div>
            <div className="field">
              <label className="field-label">Protocol</label>
              <div style={{display:'flex',gap:5}}>
                {['vless','vmess'].map(p=>(
                  <button key={p} onClick={()=>setProto(p)} style={{
                    flex:1, padding:'7px 0', borderRadius:'var(--r-sm)', fontSize:12, fontWeight:600,
                    cursor:'pointer', border:`1.5px solid ${proto===p?'var(--accent)':'var(--border)'}`,
                    background:proto===p?'var(--accent-tint)':'var(--surface)',
                    color:proto===p?'var(--accent)':'var(--muted)',
                  }}>{p.toUpperCase()}</button>
                ))}
              </div>
            </div>
          </div>

          {/* Step 3 — install script */}
          <div className="field">
            <label className="field-label">Step 3 — install Xray bridge on the OUT server</label>
            <div style={{
              display:'flex', alignItems:'center', gap:0,
              background:'var(--surface)', border:'1px solid var(--border)',
              borderRadius:'var(--r-md)', overflow:'hidden',
            }}>
              <div style={{
                flex:1, padding:'9px 12px', fontFamily:'var(--font-mono)',
                fontSize:11, color:'var(--text-2)', wordBreak:'break-all', userSelect:'all',
              }}>{installCmd}</div>
              {scriptUrl && (
                <button onClick={()=>copyText(installCmd).then(()=>pushToast('Copied!'))}
                  style={{
                    padding:'0 14px', height:'100%', minHeight:38,
                    background:'var(--surface-2)', border:'none', borderLeft:'1px solid var(--border)',
                    cursor:'pointer', color:'var(--text-2)', flexShrink:0,
                    display:'flex', alignItems:'center', gap:5, fontSize:12, fontWeight:500,
                  }}>
                  <Icons.Copy size={13}/> Copy
                </button>
              )}
            </div>
            <span className="field-hint">Run this on the OUT server (Germany VPS) — installs Xray + opens the port</span>
          </div>

          {/* Step 4 — activate */}
          <div style={{display:'flex', justifyContent:'flex-end', marginTop:4}}>
            <button className="btn btn-primary" onClick={activate} disabled={saving || !selSrv}>
              <Icons.Power size={13}/> {saving ? 'Activating…' : 'Step 4 — Activate outbound'}
            </button>
          </div>
        </div>

      </div>
    </div>
  );
};


// ── Binary cache manager ─────────────────────────────────────────────────────
const TOOLS = ['rathole','backhaul','gost','frp','chisel'];
const TOOL_NOTES = {
  rathole:  'Reverse tunnel (Rust)',
  backhaul: 'Reverse tunnel (Go)',
  gost:     'Forward tunnel (Go)',
  frp:      'Reverse proxy (Go) — stores frps + frpc',
  chisel:   'HTTP tunnel (Go)',
};

const BinaryCacheManager = ({ pushToast }) => {
  const [binaries,  setBinaries]  = React.useState([]);
  const [fetching,  setFetching]  = React.useState({});
  const [arch,      setArch]      = React.useState('amd64');

  const load = () => {
    fetch('/api/binaries').then(r => r.json()).then(d => setBinaries(d.binaries || [])).catch(()=>{});
  };

  React.useEffect(() => { load(); }, []);

  const fetchTool = (tool) => {
    setFetching(prev => ({...prev, [tool]: true}));
    fetch('/api/binaries/fetch', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({tool, arch}),
    })
      .then(r => r.json())
      .then(d => {
        setFetching(prev => ({...prev, [tool]: false}));
        if (d.ok) { pushToast(`${tool} cached: ${d.saved?.join(', ')}`); load(); }
        else pushToast(`${tool} failed: ${d.message}`);
      })
      .catch(() => { setFetching(prev => ({...prev, [tool]: false})); pushToast(`${tool} fetch failed`); });
  };

  const deleteBin = (name) => {
    if (!confirm(`Delete ${name}?`)) return;
    fetch(`/api/binaries/${name}`, {method:'DELETE'})
      .then(() => { load(); pushToast(`${name} deleted`); })
      .catch(() => pushToast('Delete failed'));
  };

  const cached = new Set(binaries.map(b => b.name));

  return (
    <div className="card">
      <div className="section-head">
        <div>
          <div className="section-title">Binary cache</div>
          <div className="section-sub">
            Store tool binaries on the panel server — install scripts load from here instead of GitHub
          </div>
        </div>
        <div style={{display:'flex', gap:6, alignItems:'center'}}>
          <span style={{fontSize:12, color:'var(--muted)'}}>Arch:</span>
          {['amd64','arm64'].map(a => (
            <button key={a} onClick={() => setArch(a)} style={{
              padding:'3px 10px', borderRadius:'var(--r-sm)', fontSize:11.5, fontWeight:600,
              cursor:'pointer', border:`1px solid ${arch===a?'var(--accent)':'var(--border)'}`,
              background: arch===a?'var(--accent-tint)':'var(--surface)',
              color: arch===a?'var(--accent)':'var(--muted)',
            }}>{a}</button>
          ))}
        </div>
      </div>

      <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:8}}>
        <div style={{
          fontSize:11.5, color:'var(--muted)', padding:'8px 10px',
          background:'oklch(72% 0.14 240 / 0.08)', border:'1px solid oklch(72% 0.14 240 / 0.2)',
          borderRadius:'var(--r-md)', lineHeight:1.6,
        }}>
          Click <strong>Cache</strong> to download a binary from GitHub and store it on this server.
          Install scripts will serve it from <code style={{fontFamily:'var(--font-mono)'}}>
          {window.location.origin}/setup/binaries/TOOL-ARCH</code> — no GitHub calls on the remote server.
        </div>

        {/* Tool rows */}
        {TOOLS.map(tool => {
          const cachedNames = binaries.filter(b => b.name.startsWith(tool) && b.name.includes(arch));
          const isCached = cachedNames.length > 0;
          const isLoading = !!fetching[tool];
          return (
            <div key={tool} style={{
              display:'flex', alignItems:'center', gap:10, padding:'10px 12px',
              border:'1px solid var(--border)', borderRadius:'var(--r-md)',
              background: isCached ? 'oklch(72% 0.18 140 / 0.05)' : 'var(--surface-2)',
            }}>
              <div style={{flex:1}}>
                <div style={{display:'flex', alignItems:'center', gap:8}}>
                  <span style={{fontWeight:600, fontSize:13}}>{tool}</span>
                  {isCached && (
                    <span style={{
                      fontSize:10, fontWeight:700, padding:'1px 6px',
                      borderRadius:'var(--r-sm)', background:'oklch(72% 0.18 140 / 0.18)',
                      color:'oklch(60% 0.18 140)',
                    }}>CACHED</span>
                  )}
                </div>
                <div style={{fontSize:11, color:'var(--muted)', marginTop:1}}>{TOOL_NOTES[tool]}</div>
                {isCached && cachedNames.map(b => (
                  <div key={b.name} style={{
                    fontSize:10.5, fontFamily:'var(--font-mono)', color:'var(--muted)',
                    marginTop:2, display:'flex', alignItems:'center', gap:6,
                  }}>
                    <span>{b.name}</span>
                    <span style={{color:'var(--border)'}}>·</span>
                    <span>{b.size_kb} KB</span>
                    <span style={{color:'var(--border)'}}>·</span>
                    <span>{b.modified}</span>
                  </div>
                ))}
              </div>
              <div style={{display:'flex', gap:5, flexShrink:0}}>
                <button className="btn btn-ghost" style={{fontSize:11.5, padding:'4px 10px'}}
                  onClick={() => fetchTool(tool)} disabled={isLoading}>
                  {isLoading ? '⏳ Caching…' : (isCached ? '↺ Refresh' : '⬇ Cache')}
                </button>
                {isCached && cachedNames.map(b => (
                  <button key={b.name} className="btn btn-ghost"
                    style={{fontSize:11.5, padding:'4px 8px', color:'var(--danger)'}}
                    onClick={() => deleteBin(b.name)} title={`Delete ${b.name}`}>
                    <Icons.Trash size={11}/>
                  </button>
                ))}
              </div>
            </div>
          );
        })}

        {/* Cached files that aren't in the TOOLS list */}
        {binaries.filter(b => !TOOLS.some(t => b.name.startsWith(t))).map(b => (
          <div key={b.name} style={{
            display:'flex', alignItems:'center', gap:10, padding:'8px 12px',
            border:'1px dashed var(--border)', borderRadius:'var(--r-md)',
          }}>
            <div style={{flex:1, fontFamily:'var(--font-mono)', fontSize:12}}>{b.name}
              <span style={{marginLeft:8, fontSize:11, color:'var(--muted)'}}>{b.size_kb} KB</span>
            </div>
            <button className="btn btn-ghost" style={{fontSize:11, color:'var(--danger)', padding:'3px 8px'}}
              onClick={() => deleteBin(b.name)}><Icons.Trash size={11}/></button>
          </div>
        ))}
      </div>
    </div>
  );
};


// ── Subscription section ──────────────────────────────────────────────────────
const SubscriptionSection = ({ settings, setSettings, saveSettings, saving, pushToast }) => {
  const panelOrigin = window.location.origin;
  const subPath     = settings.sub_path || 'sub';
  const subDomain   = settings.sub_domain || '';
  const subPort     = settings.sub_port || '5000';
  const extraUrls   = Array.isArray(settings.sub_extra_urls) ? settings.sub_extra_urls : [];

  const subScheme    = settings.sub_scheme || 'http';

  const exampleToken = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
  const primaryUrl   = subDomain
    ? `${subScheme}://${subDomain}/${subPath}/${exampleToken}`
    : `${panelOrigin}/${subPath}/${exampleToken}`;

  const downloadSubScript = (port) => {
    window.open(`/api/sub-server-script?port=${port}`, '_blank');
  };

  const [newUrlName, setNewUrlName] = React.useState('');
  const [newUrlBase, setNewUrlBase] = React.useState('');
  const [subScriptPort, setSubScriptPort] = React.useState(80);

  const addExtraUrl = () => {
    if (!newUrlBase) return;
    const updated = [...extraUrls, { name: newUrlName || newUrlBase, base_url: newUrlBase }];
    setSettings({ ...settings, sub_extra_urls: updated });
    setNewUrlName(''); setNewUrlBase('');
  };

  const removeExtraUrl = (i) => {
    setSettings({ ...settings, sub_extra_urls: extraUrls.filter((_, j) => j !== i) });
  };

  return (
    <>
      {/* URL structure */}
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Subscription URL</div>
            <div className="section-sub">Configure how subscription links are generated</div>
          </div>
        </div>
        <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:14}}>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Sub domain / IP override</label>
              <input className="input mono"
                placeholder="leave blank to use Server IP"
                value={subDomain}
                onChange={e => setSettings({...settings, sub_domain: e.target.value})}/>
              <span className="field-hint">Override hostname in subscription URLs (separate from Xray server IP)</span>
            </div>
            <div className="field" style={{ maxWidth: 110 }}>
              <label className="field-label">Scheme</label>
              <div style={{display:'flex', borderRadius:'var(--r-md)', overflow:'hidden', border:'1px solid var(--border)', height:36}}>
                {['http','https'].map(s => (
                  <button key={s} onClick={() => setSettings({...settings, sub_scheme: s})}
                    style={{
                      flex:1, border:'none', cursor:'pointer', fontSize:11.5, fontWeight:600,
                      background: subScheme === s ? 'var(--accent)' : 'var(--surface-2)',
                      color: subScheme === s ? '#fff' : 'var(--text-2)',
                      transition:'background 0.15s',
                    }}>{s}</button>
                ))}
              </div>
            </div>
            <div className="field" style={{ maxWidth: 110 }}>
              <label className="field-label">Port</label>
              <input className="input mono" type="number" value={subPort}
                onChange={e => setSettings({...settings, sub_port: e.target.value})}/>
            </div>
          </div>
          <div className="field">
            <label className="field-label">Path keyword</label>
            <input className="input mono" placeholder="sub"
              value={subPath}
              onChange={e => setSettings({...settings, sub_path: e.target.value})}/>
            <span className="field-hint">The URL path prefix — default is <code style={{fontFamily:'var(--font-mono)'}}>sub</code></span>
          </div>

          {/* Preview */}
          <div style={{
            padding: '10px 12px', borderRadius: 'var(--r-md)',
            background: 'var(--surface-2)', border: '1px solid var(--border)', fontSize: 11.5,
          }}>
            <div style={{ color: 'var(--muted)', marginBottom: 4 }}>Preview URL</div>
            <div style={{ fontFamily: 'var(--font-mono)', color: 'var(--accent)', wordBreak: 'break-all' }}>{primaryUrl}</div>
          </div>

          <div style={{display:'flex', justifyContent:'flex-end'}}>
            <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
              <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save'}
            </button>
          </div>
        </div>
      </div>

      {/* Extra subscription servers */}
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Additional sub servers</div>
            <div className="section-sub">Relay servers that proxy subscription requests to this panel</div>
          </div>
        </div>
        <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:10}}>
          {extraUrls.length === 0 && (
            <div style={{ fontSize: 12.5, color: 'var(--muted)', padding: '8px 0' }}>
              No extra sub servers. Add one below, then run the install script on that server.
            </div>
          )}
          {extraUrls.map((u, i) => (
            <div key={i} style={{
              display:'flex', alignItems:'center', gap:8, padding:'8px 10px',
              background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:'var(--r-md)',
            }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 12.5, fontWeight: 500 }}>{u.name}</div>
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--muted)' }}>{u.base_url}</div>
              </div>
              <button className="icon-btn-sm danger" onClick={() => removeExtraUrl(i)}><Icons.Trash size={12}/></button>
            </div>
          ))}
          <div className="field-row" style={{ marginTop: 4 }}>
            <div className="field">
              <label className="field-label">Name</label>
              <input className="input" placeholder="e.g. Frankfurt relay" value={newUrlName} onChange={e => setNewUrlName(e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">Base URL</label>
              <input className="input mono" placeholder="http://relay.example.com" value={newUrlBase} onChange={e => setNewUrlBase(e.target.value)}/>
            </div>
            <div className="field" style={{ maxWidth: 80, alignSelf: 'flex-end' }}>
              <button className="btn btn-primary" style={{ width: '100%' }} onClick={addExtraUrl} disabled={!newUrlBase}>
                <Icons.Plus size={13}/> Add
              </button>
            </div>
          </div>
          {extraUrls.length > 0 && (
            <div style={{display:'flex', justifyContent:'flex-end'}}>
              <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
                <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save servers'}
              </button>
            </div>
          )}
        </div>
      </div>

      {/* Install script */}
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Sub server install script</div>
            <div className="section-sub">Run this on another server to set up a subscription relay</div>
          </div>
        </div>
        <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:12}}>
          <div style={{ fontSize: 12.5, color: 'var(--text-2)', lineHeight: 1.6 }}>
            This script installs nginx on a remote server and configures it to proxy
            <code style={{ fontFamily: 'var(--font-mono)', margin: '0 4px' }}>/{subPath}/TOKEN</code>
            requests back to this panel. Users can then use that server's IP in their subscription URL.
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Listen port (on relay server)</label>
              <input className="input mono" type="number" value={subScriptPort} onChange={e => setSubScriptPort(e.target.value)}/>
            </div>
            <div className="field" style={{ alignSelf: 'flex-end' }}>
              <button className="btn btn-primary" onClick={() => downloadSubScript(subScriptPort)}>
                <Icons.Download size={13}/> Download install script
              </button>
            </div>
          </div>
          <div style={{ fontSize: 11.5, color: 'var(--muted)' }}>
            On the relay server: <code style={{ fontFamily: 'var(--font-mono)' }}>bash bridge-sub-server.sh</code>
          </div>
        </div>
      </div>
    </>
  );
};


// ── Xray Core install/update section ─────────────────────────────────────────
const XrayCoreSection = ({ pushToast }) => {
  const [current,      setCurrent]      = React.useState(null);   // {version, binary, exists}
  const [releases,     setReleases]     = React.useState([]);
  const [loadingRels,  setLoadingRels]  = React.useState(false);
  const [version,      setVersion]      = React.useState('latest');
  const [installPath,  setInstallPath]  = React.useState('');
  const [installing,   setInstalling]   = React.useState(false);
  const [result,       setResult]       = React.useState(null);   // last install result

  const loadCurrent = () => {
    fetch('/api/xray/core-version').then(r => r.json()).then(d => {
      setCurrent(d);
      if (!installPath) setInstallPath(d.binary || '');
    }).catch(() => {});
  };

  const loadReleases = () => {
    setLoadingRels(true);
    fetch('/api/xray/releases').then(r => r.json()).then(d => {
      setReleases(d.releases || []);
      setLoadingRels(false);
    }).catch(() => setLoadingRels(false));
  };

  React.useEffect(() => {
    loadCurrent();
    loadReleases();
  }, []);

  const install = () => {
    setInstalling(true);
    setResult(null);
    fetch('/api/xray/install', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ version, install_path: installPath }),
    })
      .then(r => r.json())
      .then(d => {
        setInstalling(false);
        setResult(d);
        if (d.ok) {
          pushToast(`Xray ${d.version} installed`);
          loadCurrent();
        } else {
          pushToast('Install failed: ' + (d.error || 'Unknown error'));
        }
      })
      .catch(e => { setInstalling(false); pushToast('Install request failed'); });
  };

  const isLatest = version === 'latest';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>

      {/* Current version card */}
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Xray Core</div>
            <div className="section-sub">Install or update the Xray-core binary from GitHub releases</div>
          </div>
          {current?.exists
            ? <span className="badge ok"><span className="dot"/>Installed</span>
            : <span className="badge danger"><span className="dot"/>Not found</span>}
        </div>

        <div style={{ padding: '0 18px 18px', display: 'flex', flexDirection: 'column', gap: 14 }}>

          {/* Current info */}
          {current && (
            <div style={{
              padding: '10px 14px', borderRadius: 'var(--r-md)',
              background: 'var(--surface-2)', border: '1px solid var(--border)',
              display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap',
            }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 3 }}>Current version</div>
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 13, fontWeight: 600 }}>
                  {current.version || '— binary not found —'}
                </div>
                <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--muted)', marginTop: 2 }}>
                  {current.binary}
                </div>
              </div>
              <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '5px 10px' }}
                onClick={loadCurrent}>
                ↺ Refresh
              </button>
            </div>
          )}

          {/* Version picker */}
          <div className="field">
            <label className="field-label">Version to install</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1, position: 'relative' }}>
                <select className="select" value={version} onChange={e => setVersion(e.target.value)}>
                  <option value="latest">latest (auto-detect newest)</option>
                  {releases.map(r => (
                    <option key={r.tag} value={r.tag}>
                      {r.tag}{r.prerelease ? ' (pre-release)' : ''}
                    </option>
                  ))}
                </select>
              </div>
              {/* Or type a custom version */}
              <input
                className="input mono"
                style={{ width: 130, flexShrink: 0 }}
                placeholder="e.g. v1.8.21"
                value={isLatest ? '' : version}
                onChange={e => setVersion(e.target.value || 'latest')}
              />
            </div>
            <span className="field-hint">
              Select from the dropdown or type a tag (e.g. <code style={{fontFamily:'var(--font-mono)'}}>v1.8.21</code>).
              Architecture is auto-detected (amd64 / arm64).
              {loadingRels && ' Loading release list…'}
            </span>
          </div>

          {/* Install path */}
          <div className="field">
            <label className="field-label">Install path</label>
            <input
              className="input mono"
              placeholder="/usr/local/bin/xray"
              value={installPath}
              onChange={e => setInstallPath(e.target.value)}
            />
            <span className="field-hint">
              Where to write the binary. Defaults to the path configured in Xray Control.
            </span>
          </div>

          {/* Install result */}
          {result && (
            <div style={{
              padding: '10px 14px', borderRadius: 'var(--r-md)', fontSize: 12.5,
              background: result.ok ? 'oklch(72% 0.18 140 / 0.07)' : 'oklch(68% 0.20 25 / 0.08)',
              border: `1px solid ${result.ok ? 'oklch(72% 0.18 140 / 0.35)' : 'oklch(68% 0.20 25 / 0.3)'}`,
              color:  result.ok ? 'oklch(55% 0.18 140)' : 'var(--danger)',
              lineHeight: 1.6,
            }}>
              {result.ok ? (
                <>
                  ✅ <strong>{result.version}</strong> installed at <code style={{fontFamily:'var(--font-mono)'}}>{result.install_path}</code>
                  {result.restarted && <><br/>↺ Xray restarted: {result.xray_message}</>}
                </>
              ) : (
                <>❌ {result.error}</>
              )}
            </div>
          )}

          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <button
              className="btn btn-primary"
              onClick={install}
              disabled={installing}>
              {installing
                ? <><span style={{marginRight:6}}>⏳</span>Installing…</>
                : <><Icons.Download size={13}/> {isLatest ? 'Install latest' : `Install ${version}`}</>}
            </button>
          </div>
        </div>
      </div>

      {/* Available releases table */}
      {releases.length > 0 && (
        <div className="card">
          <div className="section-head">
            <div>
              <div className="section-title">Recent releases</div>
              <div className="section-sub">Last 10 Xray-core releases from GitHub</div>
            </div>
            <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '4px 10px' }}
              onClick={loadReleases} disabled={loadingRels}>
              {loadingRels ? '⏳' : '↺'} Refresh
            </button>
          </div>
          <div style={{ padding: '0 18px 18px', display: 'flex', flexDirection: 'column', gap: 6 }}>
            {releases.map(r => (
              <div key={r.tag} style={{
                display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px',
                borderRadius: 'var(--r-md)', border: '1px solid var(--border)',
                background: version === r.tag ? 'var(--accent-tint)' : 'var(--surface-2)',
                cursor: 'pointer',
              }} onClick={() => setVersion(r.tag)}>
                <div style={{
                  fontFamily: 'var(--font-mono)', fontSize: 13, fontWeight: 600, flex: 1,
                  color: version === r.tag ? 'var(--accent)' : 'var(--text)',
                }}>{r.tag}</div>
                {r.prerelease && (
                  <span style={{
                    fontSize: 10, fontWeight: 700, padding: '1px 6px', borderRadius: 'var(--r-sm)',
                    background: 'oklch(72% 0.16 80 / 0.18)', color: 'oklch(60% 0.16 80)',
                  }}>pre</span>
                )}
                {version === r.tag && (
                  <span style={{ fontSize: 11, color: 'var(--accent)', fontWeight: 600 }}>selected</span>
                )}
                <button className="btn btn-ghost" style={{ fontSize: 11, padding: '3px 8px', flexShrink: 0 }}
                  onClick={e => { e.stopPropagation(); setVersion(r.tag); install(); }}>
                  Install
                </button>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};


// ── Telegram Backup section ──────────────────────────────────────────────────
const TelegramBackupSection = ({ settings, setSettings, saveSettings, saving, pushToast }) => {
  const [sending,  setSending]  = React.useState(false);
  const [testing,  setTesting]  = React.useState(false);

  const sendNow = () => {
    setSending(true);
    fetch('/api/backup/send', { method: 'POST' })
      .then(r => r.json())
      .then(d => {
        setSending(false);
        pushToast(d.ok ? 'Backup sent to Telegram!' : ('Error: ' + (d.error || d.message || 'Failed')));
      })
      .catch(() => { setSending(false); pushToast('Backup request failed'); });
  };

  const testBot = () => {
    setTesting(true);
    fetch('/api/backup/test', { method: 'POST' })
      .then(r => r.json())
      .then(d => {
        setTesting(false);
        pushToast(d.ok ? 'Test message sent!' : ('Error: ' + (d.error || d.message)));
      })
      .catch(() => { setTesting(false); pushToast('Test failed'); });
  };

  const intervalOpts = [
    { value: '0',  label: 'Disabled' },
    { value: '1',  label: 'Every 1 hour' },
    { value: '3',  label: 'Every 3 hours' },
    { value: '6',  label: 'Every 6 hours' },
    { value: '12', label: 'Every 12 hours' },
    { value: '24', label: 'Every 24 hours' },
  ];

  const configured = settings.telegram_bot_token && settings.telegram_chat_id;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Telegram Backup</div>
            <div className="section-sub">Automatically send panel files + database to Telegram</div>
          </div>
          {configured
            ? <span className="badge ok"><span className="dot"/>Configured</span>
            : <span className="badge warn"><span className="dot"/>Not configured</span>}
        </div>
        <div style={{ padding: '0 18px 18px', display: 'flex', flexDirection: 'column', gap: 14 }}>

          {/* Info banner */}
          <div style={{
            display: 'flex', gap: 10, alignItems: 'flex-start', padding: '10px 12px',
            borderRadius: 'var(--r-md)', background: 'oklch(72% 0.14 240 / 0.08)',
            border: '1px solid oklch(72% 0.14 240 / 0.25)', fontSize: 12.5,
            color: 'oklch(72% 0.14 240)',
          }}>
            <Icons.Shield size={14} style={{ marginTop: 1, flexShrink: 0 }}/>
            <div>
              Create a bot via <strong>@BotFather</strong> on Telegram, then get your chat ID by messaging
              <strong> @userinfobot</strong>. The backup includes <code style={{fontFamily:'var(--font-mono)'}}>panel.db</code>,
              <code style={{fontFamily:'var(--font-mono)'}}> app.py</code>, and the generated Xray config.
            </div>
          </div>

          <div className="field-row">
            <div className="field">
              <label className="field-label">Bot token</label>
              <input className="input mono" type="password"
                placeholder="123456789:AAxxxxxxxxxxxxxx"
                value={settings.telegram_bot_token || ''}
                onChange={e => setSettings({...settings, telegram_bot_token: e.target.value})}/>
              <span className="field-hint">From @BotFather — starts with a number</span>
            </div>
            <div className="field">
              <label className="field-label">Admin chat ID</label>
              <input className="input mono"
                placeholder="e.g. 123456789"
                value={settings.telegram_chat_id || ''}
                onChange={e => setSettings({...settings, telegram_chat_id: e.target.value})}/>
              <span className="field-hint">Your personal Telegram user ID</span>
            </div>
          </div>

          <div className="field">
            <label className="field-label">Backup schedule</label>
            <select className="select" value={settings.backup_interval_hours || '6'}
              onChange={e => setSettings({...settings, backup_interval_hours: e.target.value})}>
              {intervalOpts.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </div>

          {settings.backup_last_sent && (
            <div style={{
              fontSize: 11.5, color: 'var(--muted)', padding: '6px 10px',
              background: 'var(--surface-2)', border: '1px solid var(--border)',
              borderRadius: 'var(--r-md)',
            }}>
              Last backup sent: {settings.backup_last_sent}
            </div>
          )}

          {/* What gets backed up */}
          <div style={{
            fontSize: 12, color: 'var(--muted)', padding: '8px 12px',
            background: 'var(--surface-2)', border: '1px solid var(--border)',
            borderRadius: 'var(--r-md)', lineHeight: 1.7,
          }}>
            <strong>Telegram backup contains:</strong> panel.db (all users, inbounds, servers, tunnels, settings) ·
            generated-config.json · .secret_key · app.py<br/>
            <strong>Full download backup</strong> also includes templates and static files.
          </div>

          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', flexWrap: 'wrap' }}>
            <button className="btn btn-ghost" onClick={testBot} disabled={testing || !configured}>
              {testing ? '⏳ Testing…' : '🔔 Test bot'}
            </button>
            <button className="btn btn-ghost" onClick={sendNow} disabled={sending || !configured}>
              <Icons.Download size={13}/> {sending ? 'Sending…' : 'Send to Telegram'}
            </button>
            <button className="btn btn-ghost" onClick={() => window.open('/api/backup/download', '_blank')}>
              <Icons.Download size={13}/> Download full backup
            </button>
            <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
              <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save settings'}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};


// ── System Service section ────────────────────────────────────────────────────
const SystemServiceSection = ({ pushToast }) => {
  const [svcContent, setSvcContent] = React.useState('');

  React.useEffect(() => {
    fetch('/api/systemd-service')
      .then(r => r.text())
      .then(t => setSvcContent(t))
      .catch(() => {});
  }, []);

  const downloadService = () => { window.open('/api/systemd-service', '_blank'); };

  const installSteps = [
    'sudo cp xray-panel.service /etc/systemd/system/',
    'sudo systemctl daemon-reload',
    'sudo systemctl enable xray-panel',
    'sudo systemctl start xray-panel',
    'sudo systemctl status xray-panel',
  ];

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Systemd Service</div>
            <div className="section-sub">Run the panel as a Linux system service that auto-starts on boot</div>
          </div>
        </div>
        <div style={{ padding: '0 18px 18px', display: 'flex', flexDirection: 'column', gap: 14 }}>

          {/* Service file preview */}
          <div>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
              <label className="field-label" style={{ margin: 0 }}>Service file content</label>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '4px 10px' }}
                  onClick={() => copyText(svcContent).then(() => pushToast('Service file copied!'))}>
                  <Icons.Copy size={12}/> Copy
                </button>
                <button className="btn btn-ghost" style={{ fontSize: 11.5, padding: '4px 10px' }}
                  onClick={downloadService}>
                  <Icons.Download size={12}/> Download
                </button>
              </div>
            </div>
            <pre style={{
              fontFamily: 'var(--font-mono)', fontSize: 11.5, lineHeight: 1.6,
              background: 'var(--bg)', border: '1px solid var(--border)',
              borderRadius: 'var(--r-md)', padding: '12px 14px',
              overflowX: 'auto', color: 'var(--text-2)', margin: 0,
            }}>{svcContent || 'Loading…'}</pre>
          </div>

          {/* Install steps */}
          <div>
            <div style={{ fontSize: 12.5, fontWeight: 600, marginBottom: 8 }}>Install steps</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {installSteps.map((cmd, i) => (
                <div key={i} style={{
                  display: 'flex', alignItems: 'center', gap: 0,
                  background: 'var(--surface)', border: '1px solid var(--border)',
                  borderRadius: 'var(--r-md)', overflow: 'hidden',
                }}>
                  <div style={{
                    padding: '6px 10px', background: 'var(--surface-2)',
                    borderRight: '1px solid var(--border)', fontSize: 10.5,
                    color: 'var(--muted)', flexShrink: 0, minWidth: 24, textAlign: 'center',
                  }}>{i + 1}</div>
                  <div style={{
                    flex: 1, padding: '6px 10px', fontFamily: 'var(--font-mono)',
                    fontSize: 11.5, color: 'var(--text-2)', userSelect: 'all',
                  }}>{cmd}</div>
                  <button onClick={() => copyText(cmd).then(() => pushToast('Copied!'))}
                    style={{
                      padding: '0 10px', height: '100%', minHeight: 32,
                      background: 'var(--surface-2)', border: 'none',
                      borderLeft: '1px solid var(--border)', cursor: 'pointer',
                      color: 'var(--muted)', display: 'flex', alignItems: 'center',
                    }}>
                    <Icons.Copy size={11}/>
                  </button>
                </div>
              ))}
            </div>
          </div>

          {/* Useful commands */}
          <div style={{
            padding: '10px 12px', borderRadius: 'var(--r-md)', fontSize: 12,
            background: 'oklch(72% 0.14 240 / 0.06)', border: '1px solid oklch(72% 0.14 240 / 0.2)',
            color: 'var(--text-2)', lineHeight: 1.7,
          }}>
            <strong>Useful commands after setup:</strong><br/>
            <code style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>
              journalctl -u xray-panel -f</code> — live logs<br/>
            <code style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>
              systemctl restart xray-panel</code> — restart panel
          </div>
        </div>
      </div>
    </div>
  );
};


// --- Traffic page (real data) ---
const TrafficPage = () => {
  const [range, setRange] = React.useState('24h');
  const [data, setData] = React.useState({ ts: [], down: [], up: [], users: [] });
  const [loading, setLoading] = React.useState(true);

  const load = (r) => {
    setLoading(true);
    fetch(`/api/traffic?range=${r}`)
      .then(res => res.json())
      .then(d => {
        setData({ ts: d.ts || [], down: d.down || [], up: d.up || [], users: d.users || [] });
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  React.useEffect(() => { load(range); }, [range]);

  const handleRange = (r) => { setRange(r); };

  const totalDown = data.down.reduce((a, b) => a + b, 0);
  const totalUp   = data.up.reduce((a, b) => a + b, 0);

  return (
    <div className="page" data-screen-label="traffic">
      <div className="card" style={{marginBottom:16}}>
        <div className="section-head">
          <div>
            <div className="section-title">Bandwidth overview</div>
            <div className="section-sub">
              Aggregated traffic across all inbounds
              {!loading && (
                <span style={{marginLeft:10, color:'var(--text-2)'}}>
                  · <span style={{color:'var(--accent)'}}>↓ {totalDown.toFixed(3)} GB</span>
                  {' '}
                  <span style={{color:'var(--info)'}}>↑ {totalUp.toFixed(3)} GB</span>
                </span>
              )}
            </div>
          </div>
          <div className="tab-pill">
            {['24h','7d','30d'].map(r => (
              <button key={r} className={range === r ? 'active' : ''} onClick={() => handleRange(r)}>{r}</button>
            ))}
          </div>
        </div>
        <div style={{padding:'4px 18px 18px'}}>
          {loading ? (
            <div style={{height:300, display:'flex', alignItems:'center', justifyContent:'center', color:'var(--muted)', fontSize:13}}>
              Loading traffic data…
            </div>
          ) : data.down.length === 0 ? (
            <div style={{height:300, display:'flex', alignItems:'center', justifyContent:'center', color:'var(--muted)', fontSize:13}}>
              No traffic data recorded yet. Data is sampled every 30 seconds once Xray is running.
            </div>
          ) : (
            <AreaChart down={data.down} up={data.up} h={300}/>
          )}
        </div>
      </div>

      {/* Per-user breakdown */}
      {data.users.length > 0 && (
        <div className="card">
          <div className="section-head">
            <div className="section-title">Top users by traffic</div>
          </div>
          <div style={{overflowX:'auto'}}>
            <table className="tbl">
              <thead>
                <tr>
                  <th>#</th>
                  <th>User</th>
                  <th>Used</th>
                  <th>Limit</th>
                  <th>Usage</th>
                </tr>
              </thead>
              <tbody>
                {data.users.map((u, i) => {
                  const pct = u.limit > 0 ? Math.min(100, (u.used / u.limit) * 100) : 0;
                  return (
                    <tr key={u.name}>
                      <td style={{color:'var(--muted)', fontSize:12, width:36}}>{i+1}</td>
                      <td style={{fontWeight:500}}>{u.name}</td>
                      <td style={{fontFamily:'var(--font-mono)', fontSize:12}}>{u.used.toFixed(3)} GB</td>
                      <td style={{fontFamily:'var(--font-mono)', fontSize:12, color:'var(--muted)'}}>
                        {u.limit > 0 ? `${u.limit} GB` : '∞'}
                      </td>
                      <td style={{width:120}}>
                        {u.limit > 0 ? (
                          <div>
                            <div className="meter-bar"><div className={`meter-fill${pct>=100?' full':pct>=80?' high':''}`} style={{width:`${pct}%`}}/></div>
                            <div style={{fontSize:10.5, color:'var(--muted)', fontFamily:'var(--font-mono)'}}>{Math.round(pct)}%</div>
                          </div>
                        ) : <span style={{color:'var(--muted)',fontSize:12}}>Unlimited</span>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
};


// --- Logs page (real xray logs) ---
const LogsPage = () => {
  return (
    <div className="page" data-screen-label="logs">
      <XrayLogViewer/>
    </div>
  );
};

// --- Reseller traffic history modal ---
const ResellerHistoryModal = ({ reseller, onClose }) => {
  const [history, setHistory] = React.useState([]);
  const [loading, setLoading] = React.useState(true);

  React.useEffect(() => {
    fetch(`/api/resellers/${reseller.id}/traffic-history`)
      .then(r => r.json())
      .then(d => { setHistory(d.history || []); setLoading(false); })
      .catch(() => setLoading(false));
  }, [reseller.id]);

  const fmtGb = v => (typeof v === 'number' ? v.toFixed(3) : '0.000');

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()} style={{width: 520, maxWidth:'95vw'}}>
        <div className="modal-head">
          <div className="modal-title">Traffic history — {reseller.username}</div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body" style={{padding:0}}>
          {loading && (
            <div style={{padding:40, textAlign:'center', color:'var(--muted)'}}>Loading…</div>
          )}
          {!loading && history.length === 0 && (
            <div style={{padding:40, textAlign:'center', color:'var(--muted)'}}>
              No history yet. Data is recorded daily once traffic is active.
            </div>
          )}
          {!loading && history.length > 0 && (
            <div style={{overflowX:'auto', maxHeight:420, overflowY:'auto'}}>
              <table className="tbl" style={{width:'100%'}}>
                <thead>
                  <tr>
                    <th style={{padding:'10px 16px'}}>Date</th>
                    <th style={{padding:'10px 16px', textAlign:'right'}}>Allocated to users</th>
                    <th style={{padding:'10px 16px', textAlign:'right'}}>Used by users</th>
                    <th style={{padding:'10px 16px', textAlign:'right'}}>Usage %</th>
                  </tr>
                </thead>
                <tbody>
                  {history.map(row => {
                    const pct = row.allocated_gb > 0 ? (row.used_gb / row.allocated_gb * 100) : 0;
                    const danger = pct >= 90;
                    return (
                      <tr key={row.date}>
                        <td style={{padding:'9px 16px', fontFamily:'var(--font-mono)', fontSize:12.5}}>{row.date}</td>
                        <td style={{padding:'9px 16px', textAlign:'right', fontFamily:'var(--font-mono)', fontSize:12.5}}>
                          {fmtGb(row.allocated_gb)} GB
                        </td>
                        <td style={{padding:'9px 16px', textAlign:'right', fontFamily:'var(--font-mono)', fontSize:12.5,
                          color: danger ? 'var(--danger)' : 'var(--text)'}}>
                          {fmtGb(row.used_gb)} GB
                        </td>
                        <td style={{padding:'9px 16px', textAlign:'right', fontFamily:'var(--font-mono)', fontSize:12.5,
                          color: danger ? 'var(--danger)' : pct >= 70 ? 'var(--warning, #f59e0b)' : 'var(--muted)'}}>
                          {pct.toFixed(1)}%
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Close</button>
        </div>
      </div>
    </div>
  );
};

// --- Resellers page ---
const ResellersPage = ({ pushToast, role }) => {
  const isSuperAdmin = role === 'superadmin';
  const [resellers, setResellers] = React.useState([]);
  const [loading, setLoading] = React.useState(true);
  const [showAdd, setShowAdd] = React.useState(false);
  const [editTarget, setEditTarget] = React.useState(null);
  const [historyTarget, setHistoryTarget] = React.useState(null);
  const [busy, setBusy] = React.useState({});  // id → true while async op in flight

  const load = () => {
    fetch('/api/resellers')
      .then(r => r.json())
      .then(d => { setResellers(d.resellers || []); setLoading(false); })
      .catch(() => setLoading(false));
  };
  React.useEffect(load, []);

  const setBusyId = (id, v) => setBusy(b => ({...b, [id]: v}));

  const deleteReseller = (id, name) => {
    if (!confirm(`Delete reseller "${name}"?`)) return;
    fetch(`/api/resellers/${id}`, { method: 'DELETE' })
      .then(() => { load(); pushToast(`Reseller "${name}" deleted`); });
  };

  const toggleReseller = (r) => {
    setBusyId(r.id, true);
    fetch(`/api/resellers/${r.id}/toggle`, { method: 'POST' })
      .then(res => res.json())
      .then(d => {
        setBusyId(r.id, false);
        load();
        pushToast(`Reseller "${r.username}" ${d.active ? 'activated' : 'suspended'}`);
      })
      .catch(() => setBusyId(r.id, false));
  };

  const lockReseller = (r) => {
    setBusyId(r.id, true);
    fetch(`/api/resellers/${r.id}/lock`, { method: 'POST' })
      .then(res => res.json())
      .then(d => {
        setBusyId(r.id, false);
        load();
        pushToast(`Reseller "${r.username}" ${d.locked ? 'locked (cannot create/edit users)' : 'unlocked'}`);
      })
      .catch(() => setBusyId(r.id, false));
  };

  const lockAllResellers = (lock) => {
    if (!confirm(lock ? 'Lock ALL resellers? They will not be able to create or edit users.' : 'Unlock ALL resellers?')) return;
    fetch('/api/resellers/lock-all', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ locked: lock }),
    }).then(() => { load(); pushToast(lock ? 'All resellers locked' : 'All resellers unlocked'); });
  };

  const resetTraffic = (r) => {
    if (!confirm(`Reset ALL traffic counters for reseller "${r.username}"?\nThis will zero out used traffic for all their users and clear the deleted-user history.`)) return;
    setBusyId(r.id, true);
    fetch(`/api/resellers/${r.id}/reset-traffic`, { method: 'POST' })
      .then(res => res.json())
      .then(d => {
        setBusyId(r.id, false);
        load();
        pushToast(`Traffic reset for "${r.username}" (${d.users_reset} users)`);
      })
      .catch(() => setBusyId(r.id, false));
  };

  const usedPct  = r => (r.used_limit_gb  || 0) > 0 ? (r.data_used_gb      / r.used_limit_gb  * 100) : 0;
  const allocPct = r => (r.data_limit_gb  || 0) > 0 ? ((r.data_allocated_gb || 0) / r.data_limit_gb * 100) : 0;

  return (
    <div className="page" data-screen-label="resellers">
      <div className="card">
        <div className="toolbar">
          <div style={{flex:1, fontFamily:'var(--font-display)', fontWeight:600, fontSize:15}}>Resellers</div>
          <button className="btn btn-ghost" style={{fontSize:12}} onClick={() => lockAllResellers(false)}>
            <Icons.Unlock size={13}/> Unlock all
          </button>
          <button className="btn btn-ghost" style={{fontSize:12, color:'var(--danger)'}} onClick={() => lockAllResellers(true)}>
            <Icons.Lock size={13}/> Lock all
          </button>
          <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
            <Icons.Plus size={14}/> Add reseller
          </button>
        </div>
        <div style={{overflowX:'auto'}}>
          <table className="tbl tbl-responsive">
            <thead>
              <tr>
                <th>Username</th>
                {isSuperAdmin && <th className="col-mobile-hide">Owner</th>}
                <th>Users</th>
                <th className="col-mobile-hide">Traffic Usage</th>
                <th className="col-mobile-hide">Defaults</th>
                <th className="col-mobile-hide">Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr><td colSpan={isSuperAdmin ? 7 : 6} style={{padding:40, textAlign:'center', color:'var(--muted)'}}>Loading…</td></tr>
              )}
              {!loading && resellers.length === 0 && (
                <tr><td colSpan={isSuperAdmin ? 7 : 6} style={{padding:40, textAlign:'center', color:'var(--muted)'}}>No resellers yet.</td></tr>
              )}
              {resellers.map(r => {
                const uPct = usedPct(r);
                const aPct = allocPct(r);
                const overUsed  = r.data_used_gb >= r.used_limit_gb;
                const overAlloc = (r.data_allocated_gb || 0) >= r.data_limit_gb;
                const overLimit = overUsed || overAlloc;
                const nearUsed  = !overUsed  && uPct >= 80;
                const nearAlloc = !overAlloc && aPct >= 80;
                const isBusy = !!busy[r.id];
                const usersOverTotal  = r.users_total  >= r.user_count;
                const usersOverActive = r.users_active >= r.active_user_count;
                return (
                  <tr key={r.id} style={{opacity: r.active ? 1 : 0.55}}>
                    <td className="td-main" style={{fontWeight:600}}>
                      {r.username}
                      {!r.active && (
                        <span style={{
                          marginLeft:7, fontSize:10.5, fontWeight:600, letterSpacing:'0.04em',
                          padding:'2px 6px', borderRadius:4,
                          background:'var(--danger-tint)', color:'var(--danger)',
                        }}>SUSPENDED</span>
                      )}
                      {r.locked && (
                        <span style={{
                          marginLeft:7, fontSize:10.5, fontWeight:600, letterSpacing:'0.04em',
                          padding:'2px 6px', borderRadius:4,
                          background:'oklch(65% 0.15 50/0.15)', color:'oklch(65% 0.15 50)',
                        }}>LOCKED</span>
                      )}
                    </td>
                    {isSuperAdmin && (
                      <td className="col-mobile-hide" style={{fontSize:12}}>
                        {r.admin_username
                          ? <span style={{
                              padding:'2px 7px', borderRadius:5, fontSize:11.5, fontWeight:600,
                              background:'oklch(72% 0.14 240/0.12)', color:'oklch(72% 0.14 240)',
                            }}>{r.admin_username}</span>
                          : <span style={{color:'var(--muted)'}}>—</span>
                        }
                      </td>
                    )}
                    <td style={{fontFamily:'var(--font-mono)', fontSize:12}}>
                      <span style={{color: usersOverActive ? 'var(--danger)' : 'var(--text)'}}>{r.users_active}</span>
                      <span style={{color:'var(--muted)'}}>/{r.users_total}</span>
                      <span style={{color: usersOverTotal ? 'var(--danger)' : 'var(--muted)', marginLeft:4}}>of {r.user_count}</span>
                    </td>
                    <td className="col-mobile-hide" style={{fontFamily:'var(--font-mono)', fontSize:12, minWidth:160}}>
                      {/* Used row */}
                      <div style={{display:'flex', justifyContent:'space-between', fontSize:11, marginBottom:1}}>
                        <span style={{color:'var(--muted)'}}>Used</span>
                        <span style={{color: overUsed ? 'var(--danger)' : nearUsed ? 'var(--warning,#f59e0b)' : 'var(--text)'}}>
                          {r.data_used_gb.toFixed(2)} / {r.used_limit_gb} GB
                        </span>
                      </div>
                      <div style={{height:3, borderRadius:2, background:'var(--border)', overflow:'hidden', width:'100%', marginBottom:5}}>
                        <div style={{height:'100%', borderRadius:2, width:`${Math.min(100,uPct)}%`,
                          background: overUsed ? 'var(--danger)' : nearUsed ? 'var(--warning,#f59e0b)' : 'var(--accent)', transition:'width 0.3s'}}/>
                      </div>
                      {/* Allocated row */}
                      <div style={{display:'flex', justifyContent:'space-between', fontSize:11, marginBottom:1}}>
                        <span style={{color:'var(--muted)'}}>Allocated</span>
                        <span style={{color: overAlloc ? 'var(--danger)' : nearAlloc ? 'var(--warning,#f59e0b)' : 'var(--text)'}}>
                          {(r.data_allocated_gb || 0).toFixed(2)} / {r.data_limit_gb} GB
                        </span>
                      </div>
                      <div style={{height:3, borderRadius:2, background:'var(--border)', overflow:'hidden', width:'100%'}}>
                        <div style={{height:'100%', borderRadius:2, width:`${Math.min(100,aPct)}%`,
                          background: overAlloc ? 'var(--danger)' : nearAlloc ? 'var(--warning,#f59e0b)' : 'oklch(72% 0.14 240)', transition:'width 0.3s'}}/>
                      </div>
                    </td>
                    <td className="col-mobile-hide" style={{fontSize:12, color:'var(--muted)'}}>
                      {r.default_traffic_gb} GB / {r.default_days}d
                    </td>
                    <td className="col-mobile-hide" style={{fontSize:12, color:'var(--muted)', fontFamily:'var(--font-mono)'}}>
                      {r.created_at ? r.created_at.slice(0,10) : '—'}
                    </td>
                    <td className="td-actions">
                      <div className="row-actions" style={{opacity:1}}>
                        {isSuperAdmin && (
                          <button className="icon-btn-sm" title="View this reseller's panel"
                            onClick={() => {
                              fetch(`/api/impersonate/reseller/${r.id}`, { method: 'POST' })
                                .then(res => res.json())
                                .then(d => { if (d.ok) window.location.reload(); else alert(d.error); });
                            }}>
                            <Icons.Eye size={14}/>
                          </button>
                        )}
                        <button className="icon-btn-sm" title="Traffic history"
                          onClick={() => setHistoryTarget(r)}>
                          <Icons.BarChart size={14}/>
                        </button>
                        <button className="icon-btn-sm" title="Reset used traffic"
                          disabled={isBusy} onClick={() => resetTraffic(r)}>
                          <Icons.Refresh size={14}/>
                        </button>
                        <button
                          className={`icon-btn-sm${r.active ? ' danger' : ''}`}
                          title={r.active ? 'Suspend reseller' : 'Activate reseller'}
                          disabled={isBusy} onClick={() => toggleReseller(r)}>
                          {r.active ? <Icons.Lock size={14}/> : <Icons.Power size={14}/>}
                        </button>
                        <button
                          className={`icon-btn-sm${r.locked ? ' active' : ''}`}
                          title={r.locked ? 'Unlock: allow creating/editing users' : 'Lock: prevent creating/editing users'}
                          disabled={isBusy} onClick={() => lockReseller(r)}
                          style={r.locked ? {color:'oklch(65% 0.15 50)', borderColor:'oklch(65% 0.15 50/0.4)'} : {}}>
                          {r.locked ? <Icons.Unlock size={14}/> : <Icons.Lock size={14}/>}
                        </button>
                        <button className="icon-btn-sm" title="Edit" onClick={() => setEditTarget(r)}>
                          <Icons.Edit size={14}/>
                        </button>
                        <button className="icon-btn-sm danger" title="Delete"
                          onClick={() => deleteReseller(r.id, r.username)}>
                          <Icons.Trash size={14}/>
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {showAdd && (
        <ResellerModal
          onClose={() => setShowAdd(false)}
          onSave={() => { load(); setShowAdd(false); pushToast('Reseller created'); }}
        />
      )}
      {editTarget && (
        <ResellerModal
          reseller={editTarget}
          onClose={() => setEditTarget(null)}
          onSave={() => { load(); setEditTarget(null); pushToast('Reseller updated'); }}
        />
      )}
      {historyTarget && (
        <ResellerHistoryModal
          reseller={historyTarget}
          onClose={() => setHistoryTarget(null)}
        />
      )}
    </div>
  );
};

const ResellerModal = ({ reseller, onClose, onSave }) => {
  const isEdit = !!reseller;
  const [form, setForm] = React.useState({
    username:            reseller?.username            || '',
    password:            '',
    user_count:          reseller?.user_count          ?? 10,
    active_user_count:   reseller?.active_user_count   ?? 10,
    data_limit_gb:       reseller?.data_limit_gb       ?? 100,
    used_limit_gb:       reseller?.used_limit_gb       ?? 100,
    default_traffic_gb:  reseller?.default_traffic_gb  ?? 10,
    default_days:        reseller?.default_days        ?? 30,
    allowed_inbound_ids: reseller?.allowed_inbound_ids ?? [],
  });
  const [inbounds, setInbounds] = React.useState([]);
  const [saving, setSaving] = React.useState(false);
  const [err, setErr] = React.useState('');

  React.useEffect(() => {
    fetch('/api/inbounds').then(r => r.json()).then(d => setInbounds(d.inbounds || [])).catch(() => {});
  }, []);

  const set = (k, v) => setForm(f => ({...f, [k]: v}));

  const save = () => {
    if (!form.username.trim()) { setErr('Username is required'); return; }
    if (!isEdit && !form.password.trim()) { setErr('Password is required'); return; }
    setSaving(true);
    setErr('');
    const url  = isEdit ? `/api/resellers/${reseller.id}` : '/api/resellers';
    const body = { ...form };
    if (isEdit && !body.password) delete body.password;
    fetch(url, { method: isEdit ? 'PUT' : 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) })
      .then(r => r.json())
      .then(d => {
        setSaving(false);
        if (d.error) { setErr(d.error); return; }
        onSave();
      })
      .catch(() => { setSaving(false); setErr('Request failed'); });
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()} style={{width:440}}>
        <div className="modal-head">
          <div className="modal-title">{isEdit ? 'Edit reseller' : 'Add reseller'}</div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          {err && <div style={{background:'var(--danger-tint)', color:'var(--danger)', borderRadius:'var(--r-md)', padding:'8px 12px', fontSize:12.5}}>{err}</div>}
          <div className="field">
            <label className="field-label">Username</label>
            <input className="input" value={form.username} onChange={e => set('username', e.target.value)} disabled={isEdit} placeholder="reseller1"/>
          </div>
          <div className="field">
            <label className="field-label">{isEdit ? 'New password (leave blank to keep)' : 'Password'}</label>
            <input className="input" type="password" value={form.password} onChange={e => set('password', e.target.value)} placeholder={isEdit ? '(unchanged)' : 'Password'}/>
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Max users (total)</label>
              <input className="input" type="number" min={1} value={form.user_count} onChange={e => set('user_count', +e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">Max active users</label>
              <input className="input" type="number" min={1} value={form.active_user_count} onChange={e => set('active_user_count', +e.target.value)}/>
            </div>
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Allocated traffic limit (GB)</label>
              <input className="input" type="number" min={1} value={form.data_limit_gb} onChange={e => set('data_limit_gb', +e.target.value)}/>
              <div className="field-hint">Max total GB that can be assigned to users</div>
            </div>
            <div className="field">
              <label className="field-label">Used traffic limit (GB)</label>
              <input className="input" type="number" min={1} value={form.used_limit_gb} onChange={e => set('used_limit_gb', +e.target.value)}/>
              <div className="field-hint">Max total GB users can actually consume</div>
            </div>
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Default traffic / user (GB)</label>
              <input className="input" type="number" min={1} value={form.default_traffic_gb} onChange={e => set('default_traffic_gb', +e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">Default expiry (days)</label>
              <input className="input" type="number" min={1} value={form.default_days} onChange={e => set('default_days', +e.target.value)}/>
            </div>
          </div>
          <div className="field">
            <label className="field-label">Allowed inbounds</label>
            {inbounds.length === 0
              ? <div style={{fontSize:12.5,color:'var(--muted)',padding:'8px 0'}}>No inbounds configured yet.</div>
              : <InboundPicker inboundList={inbounds} selectedIds={form.allowed_inbound_ids} onChange={ids => set('allowed_inbound_ids', ids)}/>
            }
            <div className="field-hint">Leave all unselected to allow every inbound. Selected = restricted to those only.</div>
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            <Icons.Check size={14}/> {saving ? 'Saving…' : isEdit ? 'Save changes' : 'Create reseller'}
          </button>
        </div>
      </div>
    </div>
  );
};

// ── VPS Console section ───────────────────────────────────────────────────────
const ConsoleSection = ({ pushToast }) => {
  const [cmd,     setCmd]     = React.useState('');
  const [history, setHistory] = React.useState([]);
  const [running, setRunning] = React.useState(false);
  const [histIdx, setHistIdx] = React.useState(-1);
  const outputRef = React.useRef(null);
  const inputRef  = React.useRef(null);

  const cmdHistory = history.map(e => e.cmd);

  const run = () => {
    const c = cmd.trim();
    if (!c || running) return;
    setRunning(true);
    setHistIdx(-1);
    fetch('/api/console', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ command: c }),
    })
      .then(r => r.json())
      .then(d => {
        setRunning(false);
        setHistory(prev => [...prev, {
          cmd: c,
          stdout:     d.stdout     || '',
          stderr:     d.stderr     || '',
          returncode: d.returncode,
          ok:         d.ok,
          error:      d.error      || null,
          ts:         new Date().toLocaleTimeString(),
        }]);
        setCmd('');
      })
      .catch(() => { setRunning(false); pushToast('Console request failed'); });
  };

  const onKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); run(); return; }
    if (e.key === 'ArrowUp') {
      e.preventDefault();
      const next = Math.min(histIdx + 1, cmdHistory.length - 1);
      setHistIdx(next);
      if (next >= 0) setCmd(cmdHistory[cmdHistory.length - 1 - next] || '');
    }
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      const next = Math.max(histIdx - 1, -1);
      setHistIdx(next);
      setCmd(next === -1 ? '' : cmdHistory[cmdHistory.length - 1 - next] || '');
    }
  };

  React.useEffect(() => {
    if (outputRef.current) outputRef.current.scrollTop = outputRef.current.scrollHeight;
  }, [history]);

  return (
    <div className="card">
      <div className="section-head">
        <div>
          <div className="section-title">VPS Console</div>
          <div className="section-sub">Run shell commands on the VPS · admin only · ↑↓ history</div>
        </div>
        {history.length > 0 && (
          <button className="btn btn-ghost" style={{fontSize:11.5, padding:'4px 10px'}}
            onClick={() => { setHistory([]); }}>
            <Icons.Trash size={12}/> Clear
          </button>
        )}
      </div>

      {/* Output */}
      <div ref={outputRef} style={{
        fontFamily:'var(--font-mono)', fontSize:12, lineHeight:1.65,
        background:'var(--bg)', borderTop:'1px solid var(--border-soft)',
        minHeight:200, maxHeight:460, overflowY:'auto', padding:'10px 18px',
      }}>
        {history.length === 0 && (
          <div style={{color:'var(--muted)', padding:'24px 0', textAlign:'center', fontSize:12.5}}>
            Type a command below and press <kbd style={{fontFamily:'var(--font-mono)', fontSize:11, padding:'1px 5px', borderRadius:4, border:'1px solid var(--border)'}}>Enter</kbd>
          </div>
        )}
        {history.map((entry, i) => (
          <div key={i} style={{marginBottom:10}}>
            <div style={{color:'var(--accent)', marginBottom:2}}>
              <span style={{color:'var(--muted)', userSelect:'none'}}>$ </span>
              <span style={{userSelect:'all'}}>{entry.cmd}</span>
              <span style={{color:'var(--muted)', fontSize:10, marginLeft:10}}>{entry.ts}</span>
            </div>
            {entry.stdout && (
              <pre style={{margin:0, color:'var(--text)', whiteSpace:'pre-wrap', wordBreak:'break-all'}}>{entry.stdout}</pre>
            )}
            {entry.stderr && (
              <pre style={{margin:0, color:'var(--danger)', whiteSpace:'pre-wrap', wordBreak:'break-all'}}>{entry.stderr}</pre>
            )}
            {entry.error && (
              <div style={{color:'var(--danger)'}}>{entry.error}</div>
            )}
            {!entry.ok && entry.returncode !== undefined && entry.returncode !== 0 && (
              <div style={{color:'var(--warn)', fontSize:10.5, marginTop:2}}>exit {entry.returncode}</div>
            )}
          </div>
        ))}
      </div>

      {/* Input bar */}
      <div style={{display:'flex', gap:0, borderTop:'1px solid var(--border)', background:'var(--surface-2)'}}>
        <span style={{
          padding:'10px 12px', fontFamily:'var(--font-mono)', fontSize:13,
          color:'var(--accent)', userSelect:'none', flexShrink:0, alignSelf:'center',
        }}>$</span>
        <input
          ref={inputRef}
          className="input"
          style={{
            flex:1, border:'none', borderRadius:0, background:'transparent',
            fontFamily:'var(--font-mono)', fontSize:12.5, outline:'none', boxShadow:'none',
          }}
          value={cmd}
          onChange={e => setCmd(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder="command…"
          disabled={running}
        />
        <button
          className="btn btn-primary"
          style={{borderRadius:0, padding:'0 18px', flexShrink:0, minHeight:40}}
          onClick={run}
          disabled={running || !cmd.trim()}
        >
          {running ? '⏳' : 'Run'}
        </button>
      </div>
    </div>
  );
};


// --- Admins page (superadmin only) ---
const AdminsPage = ({ pushToast }) => {
  const [admins, setAdmins] = React.useState([]);
  const [loading, setLoading] = React.useState(true);
  const [showAdd, setShowAdd] = React.useState(false);
  const [editTarget, setEditTarget] = React.useState(null);

  const load = () => {
    fetch('/api/admins')
      .then(r => r.json())
      .then(d => { setAdmins(d.admins || []); setLoading(false); })
      .catch(() => setLoading(false));
  };
  React.useEffect(load, []);

  const [busyAdmin, setBusyAdmin] = React.useState({});

  const deleteAdmin = (id, name) => {
    if (!confirm(`Delete admin "${name}"? Their resellers will become unassigned.`)) return;
    fetch(`/api/admins/${id}`, { method: 'DELETE' })
      .then(() => { load(); pushToast(`Admin ${name} deleted`); });
  };

  const lockAdmin = (a) => {
    setBusyAdmin(b => ({...b, [a.id]: true}));
    fetch(`/api/admins/${a.id}/lock`, { method: 'POST' })
      .then(res => res.json())
      .then(d => {
        setBusyAdmin(b => ({...b, [a.id]: false}));
        load();
        pushToast(`Admin "${a.username}" ${d.locked ? 'locked (cannot create/edit users)' : 'unlocked'}`);
      })
      .catch(() => setBusyAdmin(b => ({...b, [a.id]: false})));
  };

  const lockAllAdmins = (lock) => {
    if (!confirm(lock ? 'Lock ALL admins? They will not be able to create or edit users.' : 'Unlock ALL admins?')) return;
    fetch('/api/admins/lock-all', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ locked: lock }),
    }).then(() => { load(); pushToast(lock ? 'All admins locked' : 'All admins unlocked'); });
  };

  return (
    <div className="page" data-screen-label="admins">
      <div className="card">
        <div className="toolbar">
          <div style={{flex:1, fontFamily:'var(--font-display)', fontWeight:600, fontSize:15}}>Admins</div>
          <button className="btn btn-ghost" style={{fontSize:12}} onClick={() => lockAllAdmins(false)}>
            <Icons.Unlock size={13}/> Unlock all
          </button>
          <button className="btn btn-ghost" style={{fontSize:12, color:'var(--danger)'}} onClick={() => lockAllAdmins(true)}>
            <Icons.Lock size={13}/> Lock all
          </button>
          <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
            <Icons.Plus size={14}/> Add admin
          </button>
        </div>
        <div style={{overflowX:'auto'}}>
          <table className="tbl tbl-responsive">
            <thead>
              <tr>
                <th>Username</th>
                <th>Resellers</th>
                <th className="col-mobile-hide">Reseller quota</th>
                <th className="col-mobile-hide">Data limit</th>
                <th className="col-mobile-hide">Data used</th>
                <th className="col-mobile-hide">User quota</th>
                <th className="col-mobile-hide">Users</th>
                <th className="col-mobile-hide">Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr><td colSpan={9} style={{padding:40, textAlign:'center', color:'var(--muted)'}}>Loading…</td></tr>
              )}
              {!loading && admins.length === 0 && (
                <tr><td colSpan={9} style={{padding:40, textAlign:'center', color:'var(--muted)'}}>No admins yet.</td></tr>
              )}
              {admins.map(a => (
                <tr key={a.id}>
                  <td className="td-main" style={{fontWeight:600}}>
                    {a.username}
                    {a.locked && (
                      <span style={{
                        marginLeft:7, fontSize:10.5, fontWeight:600, letterSpacing:'0.04em',
                        padding:'2px 6px', borderRadius:4,
                        background:'oklch(65% 0.15 50/0.15)', color:'oklch(65% 0.15 50)',
                      }}>LOCKED</span>
                    )}
                  </td>
                  <td style={{fontFamily:'var(--font-mono)', fontSize:12}}>
                    {a.resellers_total}
                    <span style={{color:'var(--muted)', marginLeft:4}}>of {a.reseller_count}</span>
                  </td>
                  <td className="col-mobile-hide" style={{fontFamily:'var(--font-mono)', fontSize:12}}>{a.reseller_count}</td>
                  <td className="col-mobile-hide" style={{fontFamily:'var(--font-mono)', fontSize:12}}>{a.data_limit_gb} GB</td>
                  <td className="col-mobile-hide" style={{fontFamily:'var(--font-mono)', fontSize:12}}>
                    <span style={{color: a.data_used_gb >= a.data_limit_gb * 0.9 ? 'var(--danger)' : 'var(--text)'}}>
                      {(a.data_used_gb||0).toFixed(3)} GB
                    </span>
                  </td>
                  <td className="col-mobile-hide" style={{fontFamily:'var(--font-mono)', fontSize:12}}>{a.user_count}</td>
                  <td className="col-mobile-hide" style={{fontFamily:'var(--font-mono)', fontSize:12}}>{a.users_total}</td>
                  <td className="col-mobile-hide" style={{fontSize:12, color:'var(--muted)', fontFamily:'var(--font-mono)'}}>
                    {a.created_at ? a.created_at.slice(0,10) : '—'}
                  </td>
                  <td className="td-actions">
                    <div className="row-actions" style={{opacity:1}}>
                      <button className="icon-btn-sm" title="View this admin's panel"
                        onClick={() => {
                          fetch(`/api/impersonate/admin/${a.id}`, { method: 'POST' })
                            .then(res => res.json())
                            .then(d => { if (d.ok) window.location.reload(); else alert(d.error); });
                        }}>
                        <Icons.Eye size={14}/>
                      </button>
                      <button
                        className="icon-btn-sm"
                        title={a.locked ? 'Unlock: allow creating/editing users' : 'Lock: prevent creating/editing users'}
                        disabled={!!busyAdmin[a.id]} onClick={() => lockAdmin(a)}
                        style={a.locked ? {color:'oklch(65% 0.15 50)', borderColor:'oklch(65% 0.15 50/0.4)'} : {}}>
                        {a.locked ? <Icons.Unlock size={14}/> : <Icons.Lock size={14}/>}
                      </button>
                      <button className="icon-btn-sm" title="Edit" onClick={() => setEditTarget(a)}><Icons.Edit size={14}/></button>
                      <button className="icon-btn-sm danger" title="Delete" onClick={() => deleteAdmin(a.id, a.username)}><Icons.Trash size={14}/></button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {showAdd && (
        <AdminModal
          onClose={() => setShowAdd(false)}
          onSave={() => { load(); setShowAdd(false); pushToast('Admin created'); }}
        />
      )}
      {editTarget && (
        <AdminModal
          admin={editTarget}
          onClose={() => setEditTarget(null)}
          onSave={() => { load(); setEditTarget(null); pushToast('Admin updated'); }}
        />
      )}
    </div>
  );
};

const AdminModal = ({ admin, onClose, onSave }) => {
  const isEdit = !!admin;
  const [form, setForm] = React.useState({
    username:       admin?.username       || '',
    password:       '',
    reseller_count: admin?.reseller_count ?? 10,
    data_limit_gb:  admin?.data_limit_gb  ?? 1000,
    user_count:     admin?.user_count     ?? 1000,
  });
  const [saving, setSaving] = React.useState(false);
  const [err, setErr] = React.useState('');

  const set = (k, v) => setForm(f => ({...f, [k]: v}));

  const save = () => {
    if (!form.username.trim()) { setErr('Username is required'); return; }
    if (!isEdit && !form.password.trim()) { setErr('Password is required'); return; }
    setSaving(true); setErr('');
    const url  = isEdit ? `/api/admins/${admin.id}` : '/api/admins';
    const body = { ...form };
    if (isEdit && !body.password) delete body.password;
    fetch(url, { method: isEdit ? 'PUT' : 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) })
      .then(r => r.json())
      .then(d => {
        setSaving(false);
        if (d.error) { setErr(d.error); return; }
        onSave();
      })
      .catch(() => { setSaving(false); setErr('Request failed'); });
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()} style={{width:420}}>
        <div className="modal-head">
          <div className="modal-title">{isEdit ? 'Edit admin' : 'Add admin'}</div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          {err && <div style={{background:'var(--danger-tint)', color:'var(--danger)', borderRadius:'var(--r-md)', padding:'8px 12px', fontSize:12.5}}>{err}</div>}
          <div className="field">
            <label className="field-label">Username</label>
            <input className="input" value={form.username} onChange={e => set('username', e.target.value)} disabled={isEdit} placeholder="admin1"/>
          </div>
          <div className="field">
            <label className="field-label">{isEdit ? 'New password (leave blank to keep)' : 'Password'}</label>
            <input className="input" type="password" value={form.password} onChange={e => set('password', e.target.value)} placeholder={isEdit ? '(unchanged)' : 'Password'}/>
          </div>
          <div className="field-row">
            <div className="field">
              <label className="field-label">Max resellers</label>
              <input className="input" type="number" min={1} value={form.reseller_count} onChange={e => set('reseller_count', +e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">Max users (total)</label>
              <input className="input" type="number" min={1} value={form.user_count} onChange={e => set('user_count', +e.target.value)}/>
            </div>
          </div>
          <div className="field">
            <label className="field-label">Data pool limit (GB)</label>
            <input className="input" type="number" min={1} value={form.data_limit_gb} onChange={e => set('data_limit_gb', +e.target.value)}/>
            <div className="field-hint">Total data budget across all this admin's resellers</div>
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            <Icons.Check size={14}/> {saving ? 'Saving…' : isEdit ? 'Save changes' : 'Create admin'}
          </button>
        </div>
      </div>
    </div>
  );
};

// ── Speed Limiter (tc) section ────────────────────────────────────────────────
const SpeedLimiterSection = ({ settings, setSettings, saveSettings, saving, pushToast }) => {
  const [tcStatus,   setTcStatus]   = React.useState(null);
  const [applying,   setApplying]   = React.useState(false);

  const loadTcStatus = () => {
    fetch('/api/tc/status')
      .then(r => r.json())
      .then(d => setTcStatus(d))
      .catch(() => {});
  };

  React.useEffect(() => { loadTcStatus(); }, []);

  const forceApply = () => {
    setApplying(true);
    fetch('/api/tc/apply', { method: 'POST' })
      .then(r => r.json())
      .then(d => {
        setApplying(false);
        loadTcStatus();
        pushToast(d.ok ? `tc rules applied (${d.rules} active)` : `tc error: ${d.error}`);
      })
      .catch(() => setApplying(false));
  };

  const available = tcStatus?.available;

  return (
    <div className="card">
      <div className="section-head">
        <div>
          <div className="section-title"><Icons.Zap size={14} style={{marginRight:6, verticalAlign:'middle'}}/>Speed limiting</div>
          <div className="section-sub">Per-user bandwidth caps enforced via Linux tc/HTB on the server's network interface</div>
        </div>
        {tcStatus === null
          ? <span className="badge" style={{color:'var(--muted)'}}>Checking…</span>
          : available
            ? <span className="badge ok"><span className="dot"/>tc active</span>
            : <span className="badge danger"><span className="dot"/>tc unavailable</span>}
      </div>
      <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:12}}>
        {tcStatus && !available && (
          <div style={{
            padding:'8px 12px', borderRadius:'var(--r-md)', fontSize:12.5,
            background:'var(--danger-tint)', color:'var(--danger)',
          }}>
            Speed limits are stored but not enforced — <strong>tc</strong> requires the panel to run as <strong>root</strong> on Linux.
            Speed limit fields in users are still saved and will take effect if you re-run as root.
          </div>
        )}

        <div className="field">
          <label className="field-label">Network interface (blank = auto-detect)</label>
          <input className="input mono"
            value={settings.tc_iface || ''}
            onChange={e => setSettings({...settings, tc_iface: e.target.value})}
            placeholder={tcStatus?.iface || 'auto-detect (e.g. eth0, ens3)'}/>
          <span className="field-hint">
            Run <code style={{fontFamily:'var(--font-mono)'}}>ip route get 1.1.1.1</code> on the server to see the interface.
            Current: <strong>{tcStatus?.iface || '—'}</strong>
          </span>
        </div>

        {tcStatus && available && (
          <div style={{
            padding:'10px 14px', borderRadius:'var(--r-md)',
            background:'var(--surface-2)', border:'1px solid var(--border)',
            fontSize:12.5,
          }}>
            <div style={{fontWeight:600, marginBottom:6, display:'flex', alignItems:'center', gap:12, flexWrap:'wrap'}}>
              <span>Active rules: <span style={{color:'var(--accent)'}}>{tcStatus.rule_count}</span></span>
              <span style={{color:'var(--muted)', fontWeight:400, fontSize:11.5}}>
                updates every 30 s · daily wipe at 23:59
              </span>
              {tcStatus.last_reset_date && (
                <span style={{color:'var(--muted)', fontWeight:400, fontSize:11.5}}>
                  · last reset: <span style={{fontFamily:'var(--font-mono)'}}>{tcStatus.last_reset_date}</span>
                </span>
              )}
            </div>
            {tcStatus.rules.length > 0 ? (
              <div style={{display:'flex', flexWrap:'wrap', gap:6}}>
                {tcStatus.rules.map(r => (
                  <span key={r.ip} style={{
                    fontFamily:'var(--font-mono)', fontSize:11,
                    padding:'2px 8px', borderRadius:4,
                    background:'oklch(72% 0.17 270/0.13)', color:'oklch(62% 0.2 270)',
                  }}>
                    <Icons.Zap size={9} style={{marginRight:3, verticalAlign:'middle'}}/>
                    {r.ip} → {r.speed_kbps >= 1000 ? `${(r.speed_kbps/1000).toFixed(r.speed_kbps%1000===0?0:1)} Mbps` : `${r.speed_kbps} kbps`}
                  </span>
                ))}
              </div>
            ) : (
              <span style={{color:'var(--muted)'}}>No users with active speed limits online right now.</span>
            )}
          </div>
        )}

        <div style={{display:'flex', gap:8, flexWrap:'wrap'}}>
          <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
            <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save interface'}
          </button>
          {available && (
            <button className="btn btn-ghost" onClick={forceApply} disabled={applying}>
              <Icons.Refresh size={13}/> {applying ? 'Applying…' : 'Force apply now'}
            </button>
          )}
          <button className="btn btn-ghost" onClick={loadTcStatus}>
            <Icons.Refresh size={13}/> Refresh status
          </button>
        </div>
      </div>
    </div>
  );
};


Object.assign(window, { SettingsPage, XrayLogViewer, TrafficPage, LogsPage, SubscriptionSection, BinaryCacheManager, OutProxyStatus, TelegramBackupSection, SystemServiceSection, XrayCoreSection, ResellersPage, ResellerModal, ResellerHistoryModal, AdminsPage, AdminModal, ConsoleSection, SpeedLimiterSection });


// ── Client Apps: releases the Sentinelle apps check for, plus config health ───
const CLIENT_PLATFORMS = [
  { key: 'android', label: 'Android',  hint: 'app-arm64-v8a-release.apk' },
  { key: 'windows', label: 'Windows',  hint: 'SentinelleSetup-1.0.0.exe' },
  { key: 'linux',   label: 'Linux',    hint: 'sentinelle-linux.tar.gz' },
  { key: 'macos',   label: 'macOS',    hint: 'Sentinelle.dmg' },
];

const ClientAppsSection = ({ settings, setSettings, saveSettings, saving, pushToast }) => {
  const [realityCheck, setRealityCheck] = React.useState(null);
  const [checking, setChecking]         = React.useState(false);

  const set = (k, v) => setSettings({ ...settings, [k]: v });

  const runRealityCheck = () => {
    setChecking(true);
    fetch('/api/inbounds/reality-check')
      .then(r => r.json())
      .then(d => { setRealityCheck(d); setChecking(false); })
      .catch(() => { setChecking(false); pushToast('Check failed'); });
  };

  React.useEffect(() => { runRealityCheck(); }, []);

  const mandatory = String(settings.client_update_mandatory || 'false') === 'true';
  // Defaults on: a device limit that only applies to sign-ins is not a limit,
  // because a client that already holds a config never asks the panel again.
  const enforceIpLimit = String(settings.ip_limit_enforce ?? 'true') !== 'false';

  return (
    <>
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Client app releases</div>
            <div className="section-sub">
              What the Sentinelle apps see when they check for updates
            </div>
          </div>
        </div>

        <div style={{padding:'0 18px 18px', display:'flex', flexDirection:'column', gap:14}}>
          <div style={{
            background:'var(--surface-2)', border:'1px solid var(--border)',
            borderRadius:'var(--r-md)', padding:'10px 12px',
            fontSize:12, color:'var(--muted)', lineHeight:1.6,
          }}>
            Apps check on sign-in and from <b>Settings → Updates</b>. Leave a version
            blank to tell that platform there is nothing to update to. Versions compare
            numerically, so <code>1.10.0</code> is newer than <code>1.9.0</code>.
          </div>

          {CLIENT_PLATFORMS.map(p => (
            <div className="field-row" key={p.key}>
              <div className="field" style={{maxWidth:170}}>
                <label className="field-label">{p.label} version</label>
                <input className="input mono" placeholder="1.0.0"
                  value={settings[`client_${p.key}_version`] || ''}
                  onChange={e => set(`client_${p.key}_version`, e.target.value.trim())}/>
              </div>
              <div className="field">
                <label className="field-label">{p.label} download URL</label>
                <input className="input mono" placeholder={`https://example.com/${p.hint}`}
                  value={settings[`client_${p.key}_url`] || ''}
                  onChange={e => set(`client_${p.key}_url`, e.target.value.trim())}/>
              </div>
            </div>
          ))}

          <div className="field">
            <label className="field-label">Release notes</label>
            <textarea className="input" rows={3} style={{resize:'vertical'}}
              placeholder="What changed in this version — shown inside the app"
              value={settings.client_release_notes || ''}
              onChange={e => set('client_release_notes', e.target.value)}/>
          </div>

          <div style={{
            display:'flex', alignItems:'center', justifyContent:'space-between',
            padding:'10px 12px', background:'var(--surface-2)',
            border:'1px solid var(--border)', borderRadius:'var(--r-md)',
          }}>
            <div>
              <div style={{fontSize:13, fontWeight:500}}>Mark as required update</div>
              <div style={{fontSize:11.5, color:'var(--muted)', marginTop:2}}>
                The app tells users they should update before continuing
              </div>
            </div>
            <div className={`switch ${mandatory ? 'on' : ''}`}
              onClick={() => set('client_update_mandatory', mandatory ? 'false' : 'true')}/>
          </div>

          <div style={{
            display:'flex', alignItems:'center', justifyContent:'space-between',
            padding:'10px 12px', background:'var(--surface-2)',
            border:'1px solid var(--border)', borderRadius:'var(--r-md)',
          }}>
            <div>
              <div style={{fontSize:13, fontWeight:500}}>Enforce the device limit on the tunnel</div>
              <div style={{fontSize:11.5, color:'var(--muted)', marginTop:2}}>
                Blocks traffic from any address past a user's device limit, not
                just extra sign-ins. Applying it restarts Xray, at most once
                every 90 seconds.
              </div>
            </div>
            <div className={`switch ${enforceIpLimit ? 'on' : ''}`}
              onClick={() => set('ip_limit_enforce', enforceIpLimit ? 'false' : 'true')}/>
          </div>

          <div style={{display:'flex', gap:8}}>
            <button className="btn btn-primary" onClick={saveSettings} disabled={saving}>
              <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save release info'}
            </button>
            {CLIENT_PLATFORMS.some(p => settings[`client_${p.key}_version`]) && (
              <a className="btn btn-ghost"
                 href="/api/client/update?platform=android&version=0.0.0"
                 target="_blank" rel="noreferrer">
                Preview what apps see
              </a>
            )}
          </div>
        </div>
      </div>

      {/* ── REALITY health ── */}
      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Client compatibility check</div>
            <div className="section-sub">
              REALITY inbounds whose <code>dest</code> stops clients passing traffic
            </div>
          </div>
          <button className="btn btn-ghost" onClick={runRealityCheck} disabled={checking}>
            <Icons.Refresh size={14}/> {checking ? 'Checking…' : 'Re-check'}
          </button>
        </div>

        <div style={{padding:'0 18px 18px'}}>
          {!realityCheck && (
            <div style={{fontSize:12.5, color:'var(--muted)'}}>Checking…</div>
          )}

          {realityCheck && realityCheck.ok && (
            <div style={{
              display:'flex', alignItems:'center', gap:10,
              padding:'11px 13px', borderRadius:'var(--r-md)',
              background:'var(--accent-tint)', border:'1px solid var(--accent)',
              color:'var(--accent)', fontSize:13,
            }}>
              <Icons.Check size={15}/>
              Every REALITY inbound uses a dest that works with current clients.
            </div>
          )}

          {realityCheck && !realityCheck.ok && (
            <div style={{display:'flex', flexDirection:'column', gap:10}}>
              <div style={{
                padding:'11px 13px', borderRadius:'var(--r-md)',
                background:'var(--danger-tint)', border:'1px solid var(--danger)',
                color:'var(--danger)', fontSize:12.5, lineHeight:1.6,
              }}>
                <b>{realityCheck.problems.length} inbound(s) will connect but carry no traffic.</b><br/>
                REALITY relays the client handshake to <code>dest</code> and has a fixed
                ~8&nbsp;KB budget for it. A site with a large certificate chain never
                finishes inside that budget, so the tunnel comes up and then nothing
                passes — on every client, desktop and mobile.
              </div>

              {realityCheck.problems.map(p => (
                <div key={p.id} style={{
                  display:'flex', alignItems:'center', gap:10,
                  padding:'10px 12px', background:'var(--surface-2)',
                  border:'1px solid var(--border)', borderRadius:'var(--r-md)',
                }}>
                  <Icons.Inbound size={15} style={{color:'var(--danger)'}}/>
                  <div style={{flex:1, minWidth:0}}>
                    <div style={{fontSize:13, fontWeight:500}}>
                      {p.tag} <span style={{color:'var(--muted)', fontWeight:400}}>:{p.port}</span>
                    </div>
                    <div className="mono" style={{fontSize:11.5, color:'var(--danger)', marginTop:2}}>
                      dest = {p.dest}
                    </div>
                  </div>
                </div>
              ))}

              <div style={{fontSize:12, color:'var(--muted)', lineHeight:1.6}}>
                Edit those inbounds and set <b>dest</b> and <b>SNI</b> to one of:{' '}
                {(realityCheck.suggested_dests || []).map((d, i) => (
                  <React.Fragment key={d}>
                    {i > 0 && ', '}
                    <code style={{fontSize:11}}>{d}</code>
                  </React.Fragment>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
    </>
  );
};
