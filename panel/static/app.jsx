// Main app shell — theme, routing, toasts

const App = () => {
  const saved = localStorage.getItem('bridge-theme') || 'dark';
  const [theme, setTheme] = React.useState(saved);
  const [page, setPage] = React.useState('dashboard');
  const [addOpen, setAddOpen] = React.useState(false);
  const [toasts, setToasts] = React.useState([]);
  const [counts, setCounts] = React.useState({ users:0, inbounds:0, servers:0, activeUsers:0, enabledInbounds:0, onlineServers:0, xrayRunning:false, resellerQuota:null });
  const [inboundList, setInboundList] = React.useState([]);
  const [sidebarOpen, setSidebarOpen] = React.useState(false);

  const username     = window.__BRIDGE__?.username || 'admin';
  const role         = window.__BRIDGE__?.role || 'superadmin';
  const isReseller   = role === 'reseller';
  const isAdminRole  = role === 'admin';
  const isSuperAdmin = role === 'superadmin';
  const [panelName, setPanelName] = React.useState(window.__BRIDGE__?.panel_name || 'Bridge');

  const loadPanelName = () => {
    if (!isSuperAdmin) return;
    fetch('/api/settings').then(r => r.json()).then(d => {
      const name = (d.settings || {}).panel_name;
      if (name) { setPanelName(name); document.title = `${name} — VPN Management`; }
    }).catch(() => {});
  };

  React.useEffect(() => { loadPanelName(); }, []);

  // Resellers land on dashboard
  // (dashboard page shows their quota panel)

  // Settings fetch only works for superadmin; admin/reseller skip it silently
  // (panel name is already in __BRIDGE__)


  // Apply theme to root
  React.useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('bridge-theme', theme);
  }, [theme]);

  // Load summary counts for sidebar badges
  const loadCounts = () => {
    fetch('/api/dashboard')
      .then(r => r.json())
      .then(d => {
        setCounts({
          users:           d.total_users    || 0,
          inbounds:        d.inbounds       || 0,
          servers:         d.servers        || 0,
          activeUsers:     d.active_users   || 0,
          enabledInbounds: d.enabled_inbounds || 0,
          onlineServers:   d.online_servers || 0,
          xrayRunning:     d.xray_running   || false,
          resellerQuota:   d.reseller_quota || null,
        });
      })
      .catch(() => {});
    fetch('/api/inbounds')
      .then(r => r.json())
      .then(d => setInboundList(d.inbounds || []))
      .catch(() => {});
  };

  React.useEffect(() => {
    loadCounts();
    const interval = setInterval(loadCounts, 15000);
    return () => clearInterval(interval);
  }, []);

  const pushToast = (msg) => {
    const id = Math.random().toString(36).slice(2);
    setToasts(t => [...t, { id, msg }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), 2800);
  };

  const toggleTheme = () => setTheme(t => t === 'dark' ? 'light' : 'dark');

  // Refresh counts when navigating away from pages that mutate data
  const navigate = (p) => {
    if (page === 'settings' && isSuperAdmin) loadPanelName();
    setPage(p);
    setSidebarOpen(false);
    if (['users','inbounds','servers','resellers','admins'].includes(p)) loadCounts();
  };

  let content;
  switch (page) {
    case 'users':
      content = <UsersPage addOpen={addOpen} setAddOpen={setAddOpen} pushToast={pushToast} inboundList={inboundList} role={role}/>;
      break;
    case 'inbounds':
      content = <InboundsPage pushToast={pushToast} onInboundsChange={list => setInboundList(list)}/>;
      break;
    case 'servers':
      content = <ServersPage pushToast={pushToast}/>;
      break;
    case 'traffic':
      content = <TrafficPage/>;
      break;
    case 'logs':
      content = <LogsPage/>;
      break;
    case 'settings':
      content = <SettingsPage pushToast={pushToast}/>;
      break;
    case 'admins':
      content = <AdminsPage pushToast={pushToast}/>;
      break;
    case 'resellers':
      content = <ResellersPage pushToast={pushToast} role={role}/>;
      break;
    case 'online':
      content = <OnlineUsersPage pushToast={pushToast} role={role}/>;
      break;
    default:
      content = <Dashboard onAddUser={() => { navigate('users'); setAddOpen(true); }} pushToast={pushToast}/>;
  }

  const impersonating = window.__BRIDGE__?.impersonating || false;
  const goBackToSuperadmin = () => {
    fetch('/api/impersonate/back', { method: 'POST' })
      .then(() => { window.location.reload(); });
  };

  return (
    <div className="app">
      <div className={`sidebar-backdrop${sidebarOpen ? ' open' : ''}`} onClick={() => setSidebarOpen(false)}/>
      <Sidebar page={page} setPage={navigate} counts={counts} role={role} panelName={panelName} open={sidebarOpen} onClose={() => setSidebarOpen(false)}/>
      <main>
        {impersonating && (
          <div style={{
            background: 'oklch(72% 0.16 55/0.15)',
            borderBottom: '1px solid oklch(72% 0.16 55/0.4)',
            padding: '8px 24px',
            display: 'flex', alignItems: 'center', gap: 12,
            fontSize: 13, color: 'var(--text)',
          }}>
            <span style={{
              background: 'oklch(72% 0.16 55/0.25)', color: 'oklch(82% 0.16 55)',
              padding: '2px 8px', borderRadius: 5, fontWeight: 700, fontSize: 11,
              letterSpacing: '0.05em',
            }}>VIEWING AS</span>
            <span>You are viewing <strong>{username}</strong>'s panel ({role})</span>
            <button
              onClick={goBackToSuperadmin}
              style={{
                marginLeft: 'auto', padding: '5px 14px', borderRadius: 7,
                background: 'oklch(72% 0.16 55/0.2)', border: '1px solid oklch(72% 0.16 55/0.5)',
                color: 'oklch(88% 0.14 55)', cursor: 'pointer', fontSize: 12.5, fontWeight: 600,
              }}>
              ← Back to Superadmin
            </button>
          </div>
        )}
        <TopBar page={page} theme={theme} toggleTheme={toggleTheme} onAddUser={() => setAddOpen(true)} username={username} onMenuToggle={() => setSidebarOpen(o => !o)}/>
        <div key={page}>
          {content}
        </div>
      </main>

      <div className="toast-host">
        {toasts.map(t => (
          <div key={t.id} className="toast">
            <Icons.Check size={14} style={{color:'var(--accent)'}}/> {t.msg}
          </div>
        ))}
      </div>
    </div>
  );
};

ReactDOM.createRoot(document.getElementById('root')).render(<App/>);
