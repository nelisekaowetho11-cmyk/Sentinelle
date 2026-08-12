// Sidebar nav
const Sidebar = ({ page, setPage, counts, role, panelName, open, onClose }) => {
  const isSuperAdmin = role === 'superadmin' || !role;
  const isAdminRole  = role === 'admin';
  const isReseller   = role === 'reseller';

  const SUPERADMIN_NAV = [
    { key: 'dashboard', label: 'Dashboard', icon: Icons.Dashboard },
    { key: 'users',     label: 'Users',     icon: Icons.Users,     badge: counts.users },
    { key: 'online',    label: 'Online',    icon: Icons.Dot },
    { key: 'inbounds',  label: 'Inbounds',  icon: Icons.Inbound,   badge: counts.inbounds },
    { key: 'servers',   label: 'Servers',   icon: Icons.Server,    badge: counts.servers },
    { key: 'admins',    label: 'Admins',    icon: Icons.Shield },
    { key: 'resellers', label: 'Resellers', icon: Icons.Shield },
    { key: 'traffic',   label: 'Traffic',   icon: Icons.Traffic },
    { key: 'logs',      label: 'Logs',      icon: Icons.Logs },
  ];
  const SUPERADMIN_ACCOUNT_NAV = [
    { key: 'settings',  label: 'Settings',  icon: Icons.Settings },
  ];
  const ADMIN_NAV = [
    { key: 'dashboard', label: 'Dashboard', icon: Icons.Dashboard },
    { key: 'users',     label: 'Users',     icon: Icons.Users,     badge: counts.users },
    { key: 'resellers', label: 'Resellers', icon: Icons.Shield },
  ];
  const ADMIN_ACCOUNT_NAV = [];
  const RESELLER_NAV = [
    { key: 'dashboard', label: 'Dashboard', icon: Icons.Dashboard },
    { key: 'users',     label: 'Users',     icon: Icons.Users,     badge: counts.users },
  ];

  const mainNav    = isReseller ? RESELLER_NAV : isAdminRole ? ADMIN_NAV : SUPERADMIN_NAV;
  const accountNav = isReseller ? [] : isAdminRole ? ADMIN_ACCOUNT_NAV : SUPERADMIN_ACCOUNT_NAV;
  const roleLabel  = isReseller ? 'Reseller' : isAdminRole ? 'Admin' : 'SuperAdmin';

  return (
    <aside className={`sidebar${open ? ' open' : ''}`} data-screen-label="sidebar">
      <div className="brand" style={{justifyContent:'space-between'}}>
        <div style={{display:'flex',alignItems:'center',gap:10}}>
          <div className="brand-mark">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" fill="currentColor" fillOpacity="0.15"/>
              <path d="M9 12l2 2 4-5"/>
            </svg>
          </div>
          <div>
            <div className="brand-name">{panelName || 'Bridge'}</div>
            <div className="brand-tag">{roleLabel} · v1.0</div>
          </div>
        </div>
        <button className="topbar-hamburger" onClick={onClose} aria-label="Close menu"
          style={{display:'grid', placeItems:'center', width:30, height:30}}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
            <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </button>
      </div>

      <div>
        <div className="nav-section-label">Workspace</div>
        <div className="nav">
          {mainNav.map(n => {
            const Icon = n.icon;
            const active = page === n.key;
            return (
              <div key={n.key} className={`nav-item ${active ? 'active' : ''}`} onClick={() => setPage(n.key)} data-screen-label={`nav-${n.key}`}>
                <Icon className="nav-icon"/>
                <span>{n.label}</span>
                {n.badge > 0 && <span className="nav-badge">{n.badge.toLocaleString()}</span>}
              </div>
            );
          })}
        </div>
      </div>

      {accountNav.length > 0 && (
        <div>
          <div className="nav-section-label">Account</div>
          <div className="nav">
            {accountNav.map(n => {
              const Icon = n.icon;
              const active = page === n.key;
              return (
                <div key={n.key} className={`nav-item ${active ? 'active' : ''}`} onClick={() => setPage(n.key)}>
                  <Icon className="nav-icon"/>
                  <span>{n.label}</span>
                </div>
              );
            })}
          </div>
        </div>
      )}

      <div className="sidebar-foot">
        <div className="health-card">
          {isSuperAdmin && (
            <div className="health-row">
              <span className="health-label">Xray</span>
              <Badge kind={counts.xrayRunning ? 'online' : 'down'}>{counts.xrayRunning ? 'Running' : 'Stopped'}</Badge>
            </div>
          )}
          {/* Reseller: show live quota summary in sidebar footer */}
          {isReseller && counts.resellerQuota && (() => {
            const q = counts.resellerQuota;
            const usedPct  = q.used_limit_gb  > 0 ? Math.min(100, q.data_used_gb      / q.used_limit_gb  * 100) : 0;
            const allocPct = q.data_limit_gb  > 0 ? Math.min(100, q.data_allocated_gb / q.data_limit_gb  * 100) : 0;
            const userPct  = q.user_count     > 0 ? Math.min(100, q.users_total       / q.user_count     * 100) : 0;
            const danger = (pct) => pct >= 90;
            const warn   = (pct) => pct >= 70 && pct < 90;
            const barColor = (pct) => danger(pct) ? 'var(--danger)' : warn(pct) ? 'var(--warning,#f59e0b)' : 'var(--accent)';
            return (
              <>
                <div>
                  <div className="health-row">
                    <span className="health-label">Traffic used</span>
                    <span className="health-val" style={{color: barColor(usedPct), fontSize:11}}>
                      {q.data_used_gb.toFixed(1)}/{q.used_limit_gb} GB
                    </span>
                  </div>
                  <div className="health-bar">
                    <div style={{width:`${usedPct}%`, background: barColor(usedPct)}}/>
                  </div>
                </div>
                <div>
                  <div className="health-row">
                    <span className="health-label">Allocated</span>
                    <span className="health-val" style={{color: barColor(allocPct), fontSize:11}}>
                      {q.data_allocated_gb.toFixed(1)}/{q.data_limit_gb} GB
                    </span>
                  </div>
                  <div className="health-bar">
                    <div style={{width:`${allocPct}%`, background: barColor(allocPct)}}/>
                  </div>
                </div>
                <div>
                  <div className="health-row">
                    <span className="health-label">Users</span>
                    <span className="health-val" style={{color: barColor(userPct), fontSize:11}}>
                      {q.users_total}/{q.user_count}
                    </span>
                  </div>
                  <div className="health-bar">
                    <div style={{width:`${userPct}%`, background: barColor(userPct)}}/>
                  </div>
                </div>
              </>
            );
          })()}
          {!isReseller && (
            <>
              <div>
                <div className="health-row">
                  <span className="health-label">Active users</span>
                  <span className="health-val">{counts.activeUsers}</span>
                </div>
                <div className="health-bar"><div style={{width: `${Math.min(100, (counts.activeUsers / Math.max(counts.users, 1)) * 100)}%`}}/></div>
              </div>
              <div>
                <div className="health-row">
                  <span className="health-label">Inbounds</span>
                  <span className="health-val">{counts.enabledInbounds} / {counts.inbounds} on</span>
                </div>
                <div className="health-bar"><div style={{width: `${Math.min(100, (counts.enabledInbounds / Math.max(counts.inbounds, 1)) * 100)}%`}}/></div>
              </div>
            </>
          )}
        </div>
      </div>
    </aside>
  );
};

// Top bar
const TopBar = ({ page, theme, toggleTheme, onAddUser, username, onMenuToggle }) => {
  const PAGES = {
    dashboard: { title: 'Dashboard',   sub: 'Your quota and traffic overview'      },
    users:     { title: 'Users',       sub: 'Manage clients across all protocols'  },
    inbounds:  { title: 'Inbounds',    sub: 'Protocol configurations and routing'  },
    servers:   { title: 'Servers',     sub: 'Node health and capacity'             },
    admins:    { title: 'Admins',       sub: 'Manage admin accounts and quotas'    },
    resellers: { title: 'Resellers',   sub: 'Manage reseller accounts and limits'  },
    traffic:   { title: 'Traffic',     sub: 'Bandwidth usage by source'            },
    logs:      { title: 'Logs',        sub: 'Audit trail and connection events'    },
    settings:  { title: 'Settings',    sub: 'Workspace, security and notifications'},
  };
  const p = PAGES[page] || PAGES.dashboard;
  const initials = (username || 'AD').slice(0, 2).toUpperCase();

  return (
    <header className="topbar">
      <button className="topbar-hamburger" onClick={onMenuToggle} aria-label="Toggle menu">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
          <line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/>
        </svg>
      </button>
      <div className="crumbs">
        <span className="crumb-title">{p.title}</span>
        <span className="crumb-sub">· {p.sub}</span>
      </div>
      <div className="topbar-spacer"/>

      <div className="search">
        <Icons.Search size={15}/>
        <input placeholder="Search users, inbounds, servers…" readOnly/>
        <kbd>⌘K</kbd>
      </div>

      <div className="theme-toggle" onClick={toggleTheme} title={theme === 'dark' ? 'Switch to light' : 'Switch to dark'}>
        <div className="knob">
          {theme === 'dark' ? <Icons.Moon size={12}/> : <Icons.Sun size={12}/>}
        </div>
      </div>

      {page === 'users' && (
        <button className="btn btn-primary" onClick={onAddUser}>
          <Icons.Plus size={14}/> New user
        </button>
      )}

      <a href="/logout" className="icon-btn" title="Sign out" style={{textDecoration:'none'}}>
        <Icons.LogOut size={15}/>
      </a>

      <div className="avatar" title={username}>{initials}</div>
    </header>
  );
};

Object.assign(window, { Sidebar, TopBar });
