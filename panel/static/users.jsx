// Users page — full CRUD via /api/users

// Clipboard helper that works on HTTP too
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text);
  }
  const el = document.createElement('textarea');
  el.value = text;
  el.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
  document.body.appendChild(el);
  el.focus(); el.select();
  try { document.execCommand('copy'); } catch(e) {}
  document.body.removeChild(el);
  return Promise.resolve();
}

// ── App login credentials (Veil client apps) ─────────────────────────────────

// Inline username + masked password, with reveal / copy. Used in the table.
const AppLoginCell = ({ user, pushToast, compact }) => {
  const [shown, setShown] = React.useState(false);
  const uname = user.vpn_username || '';
  const pw    = user.vpn_password || '';
  if (!uname) return <span style={{color:'var(--muted)', fontSize:12}}>—</span>;
  const stop = (e) => e.stopPropagation();
  return (
    <div onClick={stop} style={{display:'flex', flexDirection:'column', gap:3, minWidth:0}}>
      <div style={{display:'flex', alignItems:'center', gap:5}}>
        <span className="mono" style={{fontSize:12, color:'var(--text-2)'}}>{uname}</span>
        <button className="icon-btn-sm" title="Copy app username"
          onClick={() => copyText(uname).then(() => pushToast('App username copied'))}>
          <Icons.Copy size={11}/>
        </button>
      </div>
      <div style={{display:'flex', alignItems:'center', gap:5}}>
        <span className="mono" style={{fontSize:12, color: shown ? 'var(--accent)' : 'var(--muted)',
                                       letterSpacing: shown ? 0 : 1.5}}>
          {shown ? pw : '••••••••'}
        </span>
        <button className="icon-btn-sm" title={shown ? 'Hide password' : 'Reveal password'}
          onClick={() => setShown(v => !v)}>
          {shown ? <Icons.EyeOff size={11}/> : <Icons.Eye size={11}/>}
        </button>
        <button className="icon-btn-sm" title="Copy app password"
          onClick={() => copyText(pw).then(() => pushToast('App password copied'))}>
          <Icons.Copy size={11}/>
        </button>
        {!compact && (
          <button className="icon-btn-sm" title="Copy username + password"
            onClick={() => copyText(`${uname} / ${pw}`).then(() => pushToast('App login copied'))}>
            <Icons.Key size={11}/>
          </button>
        )}
      </div>
    </div>
  );
};

// Shown right after provisioning so the operator can hand the login over.
const NewUserCredentialsModal = ({ user, onClose, pushToast }) => {
  const uname = user.vpn_username || '';
  const pw    = user.vpn_password || '';
  const both  = `Username: ${uname}\nPassword: ${pw}`;
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{maxWidth:460}} onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">App login created</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>
              Give these to {user.name} — they sign into the Veil app with them.
            </div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          {[['Username', uname], ['Password', pw]].map(([label, val]) => (
            <div className="field" key={label}>
              <label className="field-label">{label}</label>
              <div style={{
                display:'flex', alignItems:'center', gap:8,
                background:'var(--surface-2)', border:'1px solid var(--border)',
                borderRadius:'var(--r-md)', padding:'10px 12px',
              }}>
                <span className="mono" style={{flex:1, fontSize:15, letterSpacing:0.5, color:'var(--text)'}}>{val}</span>
                <button className="icon-btn-sm" title={`Copy ${label.toLowerCase()}`}
                  onClick={() => copyText(val).then(() => pushToast(`${label} copied`))}>
                  <Icons.Copy size={13}/>
                </button>
              </div>
            </div>
          ))}
          <div style={{
            background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:'var(--r-md)',
            padding:'9px 11px', fontSize:11.5, color:'var(--muted)',
            display:'flex', alignItems:'center', gap:8,
          }}>
            <Icons.Key size={13}/> The password is stored in the panel — you can view or change it any time from Edit user.
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={() => copyText(both).then(() => pushToast('Login copied'))}>
            <Icons.Copy size={14}/> Copy both
          </button>
          <button className="btn btn-primary" onClick={onClose}><Icons.Check size={14}/> Done</button>
        </div>
      </div>
    </div>
  );
};

// Full editor used inside EditUserModal.
const AppLoginEditor = ({ user, pushToast }) => {
  const [uname,   setUname]   = React.useState(user.vpn_username || '');
  const [pw,      setPw]      = React.useState(user.vpn_password || '');
  const [shown,   setShown]   = React.useState(false);
  const [editing, setEditing] = React.useState(false);
  const [draftU,  setDraftU]  = React.useState(user.vpn_username || '');
  const [draftP,  setDraftP]  = React.useState(user.vpn_password || '');
  const [busy,    setBusy]    = React.useState(false);
  const [err,     setErr]     = React.useState('');

  const send = (body, okMsg) => {
    setBusy(true); setErr('');
    return fetch(`/api/users/${user.id}/credentials`, {
      method: 'PUT', headers: {'Content-Type':'application/json'},
      body: JSON.stringify(body),
    })
      .then(r => r.json())
      .then(d => {
        setBusy(false);
        if (d.error) { setErr(d.error); return false; }
        setUname(d.vpn_username); setPw(d.vpn_password);
        setDraftU(d.vpn_username); setDraftP(d.vpn_password);
        user.vpn_username = d.vpn_username;      // reflect locally
        user.vpn_password = d.vpn_password;
        pushToast(okMsg);
        return true;
      })
      .catch(() => { setBusy(false); setErr('Request failed'); return false; });
  };

  const apply = () => {
    const body = {};
    if (draftU && draftU !== uname) body.username = draftU;
    if (draftP && draftP !== pw)    body.password = draftP;
    if (!Object.keys(body).length) { setEditing(false); return; }
    send(body, 'App login updated').then(ok => { if (ok) setEditing(false); });
  };

  return (
    <div style={{
      background:'var(--surface-2)', border:'1px solid var(--border)',
      borderRadius:'var(--r-lg)', padding:'12px 14px',
      display:'flex', flexDirection:'column', gap:10, marginTop:2,
    }}>
      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between'}}>
        <div style={{fontSize:12.5, fontWeight:600, color:'var(--text)'}}>
          App login <span style={{fontWeight:400, color:'var(--muted)'}}>— Veil client sign-in</span>
        </div>
        <button onClick={() => { setEditing(v => !v); setDraftU(uname); setDraftP(pw); setErr(''); }}
          style={{fontSize:11, color:'var(--accent)', background:'none', border:'none', cursor:'pointer', padding:0}}>
          {editing ? 'Cancel' : '✏ Change'}
        </button>
      </div>

      {err && (
        <div style={{background:'var(--danger-tint)', color:'var(--danger)', borderRadius:'var(--r-md)',
                     padding:'6px 10px', fontSize:12}}>{err}</div>
      )}

      {!editing ? (
        <div className="field-row" style={{marginBottom:0}}>
          <div className="field" style={{marginBottom:0}}>
            <label className="field-label">Username</label>
            <div style={{display:'flex', alignItems:'center', gap:6,
                         background:'var(--surface)', border:'1px solid var(--border)',
                         borderRadius:'var(--r-md)', padding:'7px 10px'}}>
              <span className="mono" style={{flex:1, fontSize:12.5}}>{uname || '—'}</span>
              <button className="icon-btn-sm" title="Copy username"
                onClick={() => copyText(uname).then(() => pushToast('Username copied'))}>
                <Icons.Copy size={12}/>
              </button>
            </div>
          </div>
          <div className="field" style={{marginBottom:0}}>
            <label className="field-label">Password</label>
            <div style={{display:'flex', alignItems:'center', gap:6,
                         background:'var(--surface)', border:'1px solid var(--border)',
                         borderRadius:'var(--r-md)', padding:'7px 10px'}}>
              <span className="mono" style={{flex:1, fontSize:12.5,
                     letterSpacing: shown ? 0 : 2, color: shown ? 'var(--text)' : 'var(--muted)'}}>
                {shown ? (pw || '—') : '••••••••'}
              </span>
              <button className="icon-btn-sm" title={shown ? 'Hide' : 'Reveal'} onClick={() => setShown(v => !v)}>
                {shown ? <Icons.EyeOff size={12}/> : <Icons.Eye size={12}/>}
              </button>
              <button className="icon-btn-sm" title="Copy password"
                onClick={() => copyText(pw).then(() => pushToast('Password copied'))}>
                <Icons.Copy size={12}/>
              </button>
            </div>
          </div>
        </div>
      ) : (
        <>
          <div className="field-row" style={{marginBottom:0}}>
            <div className="field" style={{marginBottom:0}}>
              <label className="field-label">Username</label>
              <input className="input mono" style={{fontSize:12.5}} value={draftU}
                onChange={e => setDraftU(e.target.value.trim())} placeholder="pvb10001"/>
            </div>
            <div className="field" style={{marginBottom:0}}>
              <label className="field-label">Password</label>
              <input className="input mono" style={{fontSize:12.5}} value={draftP}
                onChange={e => setDraftP(e.target.value.trim())} placeholder="min. 6 characters"/>
            </div>
          </div>
          <div style={{display:'flex', gap:6, justifyContent:'flex-end'}}>
            <button className="btn btn-ghost" style={{fontSize:11.5, padding:'5px 10px'}}
              disabled={busy} onClick={() => send({regenerate: true}, 'New password generated')}>
              ↻ Random password
            </button>
            <button className="btn btn-primary" style={{fontSize:11.5, padding:'5px 12px'}}
              disabled={busy || (!draftU && !draftP)} onClick={apply}>
              {busy ? '…' : 'Apply'}
            </button>
          </div>
        </>
      )}

      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', gap:8}}>
        <span style={{fontSize:11, color:'var(--muted)'}}>
          Changing the password signs the user out of every device.
        </span>
        <button
          onClick={() => copyText(`Username: ${uname}\nPassword: ${pw}`).then(() => pushToast('App login copied'))}
          style={{fontSize:11, color:'var(--accent)', background:'none', border:'none', cursor:'pointer', padding:0, whiteSpace:'nowrap'}}>
          Copy both
        </button>
      </div>
    </div>
  );
};

// ── Reusable multi-select inbound picker (tile grid) ─────────────────────────
const InboundPicker = ({ inboundList, selectedIds, onChange }) => {
  const toggle = (id) => {
    const next = selectedIds.includes(id)
      ? selectedIds.filter(x => x !== id)
      : [...selectedIds, id];
    onChange(next);
  };

  if (!inboundList || inboundList.length === 0) {
    return (
      <div style={{
        padding: '12px 14px', color: 'var(--muted)', fontSize: 12.5,
        border: '1px solid var(--border)', borderRadius: 'var(--r-md)',
        background: 'var(--surface-2)',
      }}>
        No inbounds configured yet — create one in the Inbounds tab first.
      </div>
    );
  }

  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fill, minmax(130px, 1fr))',
      gap: 8,
    }}>
      {inboundList.map(ib => {
        const checked = selectedIds.includes(ib.id);
        return (
          <div
            key={ib.id}
            onClick={() => toggle(ib.id)}
            style={{
              display: 'flex', flexDirection: 'column', gap: 6,
              padding: '10px 12px', cursor: 'pointer',
              borderRadius: 'var(--r-md)', userSelect: 'none',
              border: `1.5px solid ${checked ? 'var(--accent)' : 'var(--border)'}`,
              background: checked ? 'var(--accent-tint)' : 'var(--surface-2)',
              transition: 'all 0.12s',
              position: 'relative',
            }}
          >
            {/* Check indicator */}
            {checked && (
              <div style={{
                position: 'absolute', top: 6, right: 6,
                width: 14, height: 14, borderRadius: '50%',
                background: 'var(--accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <svg width="8" height="6" viewBox="0 0 9 7" fill="none">
                  <path d="M1 3.5L3.5 6L8 1" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
            )}
            <span style={{fontSize: 13, fontWeight: 600, color: checked ? 'var(--text)' : 'var(--text)', lineHeight: 1.2, paddingRight: checked ? 16 : 0}}>
              {ib.tag}
            </span>
            <div style={{display: 'flex', alignItems: 'center', gap: 5, flexWrap: 'wrap'}}>
              <span className={`proto-chip ${(ib.proto||'').toLowerCase()}`} style={{fontSize: 10}}>{ib.proto}</span>
              <span style={{color: 'var(--muted)', fontSize: 10.5, fontFamily: 'var(--font-mono)'}}>:{ib.port}</span>
            </div>
            {!ib.enabled && (
              <span style={{fontSize: 10, color: 'var(--warn)', background: 'var(--warn-tint)',
                borderRadius: 4, padding: '1px 5px', alignSelf: 'flex-start'}}>off</span>
            )}
          </div>
        );
      })}
    </div>
  );
};

// ── UsersPage ─────────────────────────────────────────────────────────────────
// ── Sortable column header ────────────────────────────────────────────────────
const SortTh = ({ col, label, sort, dir, onSort, className, style }) => {
  const active = sort === col;
  return (
    <th className={className} style={{cursor:'pointer', userSelect:'none', whiteSpace:'nowrap', ...style}}
      onClick={() => onSort(col)}>
      {label}
      <span style={{marginLeft:4, opacity: active ? 1 : 0.25, fontSize:10}}>
        {active ? (dir === 'asc' ? '▲' : '▼') : '⇅'}
      </span>
    </th>
  );
};

// ── Filter select ─────────────────────────────────────────────────────────────
const FilterSelect = ({ value, onChange, options, style }) => (
  <select
    value={value} onChange={e => onChange(e.target.value)}
    style={{
      height:34, padding:'0 10px 0 8px', border:'1px solid var(--border)',
      borderRadius:'var(--r-md)', background:'var(--surface-2)',
      color: value ? 'var(--text)' : 'var(--muted)',
      fontSize:12.5, cursor:'pointer', outline:'none', minWidth:0, ...style,
    }}>
    {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
  </select>
);

const UsersPage = ({ addOpen, setAddOpen, pushToast, inboundList, role }) => {
  const isAdmin    = role !== 'reseller';
  const isSuperAdmin = role === 'superadmin';
  const isAdminRole  = role === 'admin';

  // ── data state ──────────────────────────────────────────────────────────────
  const [users,    setUsers]    = React.useState([]);
  const [total,    setTotal]    = React.useState(0);
  const [page,     setPage]     = React.useState(1);
  const [pages,    setPages]    = React.useState(1);
  const [perPage,  setPerPage]  = React.useState(20);

  // ── bulk selection ───────────────────────────────────────────────────────────
  const [selected,     setSelected]     = React.useState(new Set());
  const [bulkModal,    setBulkModal]    = React.useState(null); // null | 'extend'|'set_expiry'|'set_traffic'
  const [bulkBusy,     setBulkBusy]     = React.useState(false);
  const [renewModal,   setRenewModal]   = React.useState(null); // user obj | null

  const toggleSelect = (id) => setSelected(prev => {
    const next = new Set(prev);
    next.has(id) ? next.delete(id) : next.add(id);
    return next;
  });
  const selectAll = () => {
    if (selected.size === users.length) setSelected(new Set());
    else setSelected(new Set(users.map(u => u.id)));
  };
  const clearSelection = () => setSelected(new Set());

  const runBulk = (action, value) => {
    setBulkBusy(true);
    fetch('/api/users/bulk', {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ ids: [...selected], action, value }),
    })
      .then(r => r.json())
      .then(d => {
        setBulkBusy(false); setBulkModal(null); clearSelection();
        load();
        pushToast(d.error ? d.error : `${d.changed} users updated`);
      })
      .catch(() => { setBulkBusy(false); pushToast('Bulk action failed'); });
  };

  const renewUser = (u, days) => {
    fetch(`/api/users/${u.id}/renew`, {
      method: 'POST', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ days }),
    })
      .then(r => r.json())
      .then(d => {
        load();
        setRenewModal(null);
        pushToast(d.error ? d.error : `${u.name} renewed +${days} days`);
      });
  };

  // ── filter / sort state ─────────────────────────────────────────────────────
  const [search,        setSearch]        = React.useState('');
  const [searchInput,   setSearchInput]   = React.useState('');   // raw input, debounced → search
  const [statusFilter,  setStatusFilter]  = React.useState('');
  const [ownerFilter,   setOwnerFilter]   = React.useState('');
  const [expireFilter,  setExpireFilter]  = React.useState('');
  const [trafficFilter, setTrafficFilter] = React.useState('');
  const [sortCol,       setSortCol]       = React.useState('created');
  const [sortDir,       setSortDir]       = React.useState('desc');

  // ── helpers ──────────────────────────────────────────────────────────────────
  const [adminResellers, setAdminResellers] = React.useState([]);
  const [loading,        setLoading]        = React.useState(true);
  const [qrUser,         setQrUser]         = React.useState(null);
  const [editUser,       setEditUser]       = React.useState(null);
  const [newCreds,       setNewCreds]       = React.useState(null); // just-created user
  const [defaultQuota,   setDefaultQuota]   = React.useState(100);
  const [defaultExpiry,  setDefaultExpiry]  = React.useState(30);
  const [expandedId,     setExpandedId]     = React.useState(null);
  const toggleExpand = (id) => setExpandedId(prev => prev === id ? null : id);

  // fetch resellers for owner filter (admin/superadmin only)
  React.useEffect(() => {
    if (!isAdmin) return;
    fetch('/api/resellers').then(r => r.json()).then(d => setAdminResellers(d.resellers || [])).catch(() => {});
  }, [role]);

  // fetch default settings
  React.useEffect(() => {
    if (role === 'reseller' || role === 'admin') return;
    fetch('/api/settings').then(r => r.json()).then(d => {
      const s = d.settings || {};
      if (s.default_quota)  setDefaultQuota(Number(s.default_quota));
      if (s.default_expiry) setDefaultExpiry(Number(s.default_expiry));
    }).catch(() => {});
  }, []);

  // debounce search input → search param
  React.useEffect(() => {
    const t = setTimeout(() => setSearch(searchInput), 350);
    return () => clearTimeout(t);
  }, [searchInput]);

  // ── load (called whenever any filter/sort/page changes) ──────────────────────
  const load = (pg, pp) => {
    setLoading(true);
    const p = pg ?? page;
    const params = new URLSearchParams({page: p, per_page: pp !== undefined ? pp : perPage, sort: sortCol, dir: sortDir});
    if (search)        params.set('search',  search);
    if (statusFilter)  params.set('status',  statusFilter);
    if (ownerFilter)   params.set('owner',   ownerFilter);
    if (expireFilter)  params.set('expire',  expireFilter);
    if (trafficFilter) params.set('traffic', trafficFilter);
    fetch(`/api/users?${params}`)
      .then(r => r.json())
      .then(d => {
        setUsers(d.users   || []);
        setTotal(d.total   ?? 0);
        setPage(d.page     ?? 1);
        setPages(d.pages   ?? 1);
        setLoading(false);
      })
      .catch(() => setLoading(false));
  };

  // reset to page 1 and reload when any filter/sort changes
  React.useEffect(() => { setPage(1); load(1); },
    [search, statusFilter, ownerFilter, expireFilter, trafficFilter, sortCol, sortDir]);

  const goToPage = (pg) => {
    const clamped = Math.max(1, Math.min(pages, pg));
    setPage(clamped);
    load(clamped);
  };

  const handleSort = (col) => {
    if (col === sortCol) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortCol(col); setSortDir('asc'); }
  };

  // ── actions ──────────────────────────────────────────────────────────────────
  const toggleStatus = (id, currentStatus) => {
    const newStatus = currentStatus === 'active' ? 'paused' : 'active';
    fetch(`/api/users/${id}`, {
      method: 'PUT', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({status: newStatus})
    })
      .then(r => r.json())
      .then(d => {
        load();
        pushToast(d.xray === 'restarted' ? 'Status updated — Xray restarted' : 'Status updated');
      })
      .catch(() => pushToast('Update failed'));
  };

  const removeUser = (id) => {
    if (!confirm('Delete this user?')) return;
    fetch(`/api/users/${id}`, { method: 'DELETE' })
      .then(r => r.json())
      .then(() => { load(); pushToast('User deleted'); })
      .catch(() => pushToast('Delete failed'));
  };

  const copySub = (u) => {
    const url = u.sub_url || `${window.location.origin}/sub/${u.sub_token}`;
    copyText(url).then(() => pushToast('Subscription URL copied'));
  };

  const copyAllLinks = (u) => {
    const all = (u.links || []).map(l => l.link).join('\n');
    if (!all) return pushToast('No links to copy');
    copyText(all).then(() => pushToast(`${u.links.length} link(s) copied`));
  };

  const hasFilters = search || statusFilter || ownerFilter || expireFilter || trafficFilter;
  const clearFilters = () => {
    setSearchInput(''); setSearch('');
    setStatusFilter(''); setOwnerFilter('');
    setExpireFilter(''); setTrafficFilter('');
  };

  const colSpan = isAdmin ? 9 : 8;

  return (
    <div className="page" data-screen-label="users">
      <div className="card" style={{overflow:'hidden'}}>

        {/* ── Bulk action bar ── */}
        {selected.size > 0 && (
          <div style={{
            display:'flex', alignItems:'center', gap:8, padding:'10px 14px',
            background:'var(--accent-tint)', borderBottom:'1px solid var(--accent)',
            flexWrap:'wrap',
          }}>
            <span style={{fontSize:13, fontWeight:600, color:'var(--accent)', marginRight:4}}>
              {selected.size} selected
            </span>
            <button className="btn btn-sm btn-secondary" onClick={() => runBulk('activate')} disabled={bulkBusy}>
              <Icons.Power size={13}/> Activate
            </button>
            <button className="btn btn-sm btn-secondary" onClick={() => runBulk('suspend')} disabled={bulkBusy}>
              <Icons.Lock size={13}/> Suspend
            </button>
            <button className="btn btn-sm btn-secondary" onClick={() => runBulk('reset_traffic')} disabled={bulkBusy}>
              <Icons.Refresh size={13}/> Reset traffic
            </button>
            <button className="btn btn-sm btn-secondary" onClick={() => setBulkModal('extend')} disabled={bulkBusy}>
              <Icons.Calendar size={13}/> Extend expiry
            </button>
            <button className="btn btn-sm btn-secondary" onClick={() => setBulkModal('set_expiry')} disabled={bulkBusy}>
              <Icons.Calendar size={13}/> Set expiry date
            </button>
            <button className="btn btn-sm btn-secondary" onClick={() => setBulkModal('set_traffic')} disabled={bulkBusy}>
              <Icons.Traffic size={13}/> Set traffic
            </button>
            <button className="btn btn-sm btn-ghost" style={{marginLeft:'auto'}} onClick={clearSelection}>
              <Icons.X size={12}/> Clear
            </button>
          </div>
        )}

        {/* ── Toolbar: search + status pills ── */}
        <div style={{display:'flex', alignItems:'center', gap:8, flexWrap:'wrap', padding:'12px 14px 10px'}}>
          <div className="toolbar-search" style={{flex:'1 1 200px', minWidth:0}}>
            <Icons.Search size={14}/>
            <input value={searchInput} onChange={e => setSearchInput(e.target.value)} placeholder="Search name, email or app login…"/>
          </div>
          <div className="tab-pill" style={{flexShrink:0}}>
            {[{v:'',l:'All'},{v:'active',l:'Active'},{v:'paused',l:'Paused'},{v:'limit',l:'Limit'},{v:'expired',l:'Expired'}].map(s => (
              <button key={s.v} className={statusFilter === s.v ? 'active' : ''}
                onClick={() => setStatusFilter(s.v === statusFilter ? '' : s.v)}>
                {s.l}
              </button>
            ))}
          </div>
        </div>

        {/* ── Filter row ── */}
        <div style={{display:'flex', alignItems:'center', gap:8, flexWrap:'wrap', padding:'0 14px 12px', borderBottom:'1px solid var(--border)'}}>
          {/* Selects grow to fill width equally; on mobile they wrap 2-per-row */}
          {isAdmin && (
            <FilterSelect style={{flex:'1 1 130px'}} value={ownerFilter} onChange={setOwnerFilter} options={[
              {value:'',     label:'All owners'},
              {value:'none', label:'No owner (admin)'},
              ...adminResellers.map(r => ({value: String(r.id), label: r.username})),
            ]}/>
          )}
          <FilterSelect style={{flex:'1 1 130px'}} value={expireFilter} onChange={setExpireFilter} options={[
            {value:'',         label:'Any expiry'},
            {value:'soon',     label:'Expiring ≤ 7 days'},
            {value:'month',    label:'Expiring ≤ 30 days'},
            {value:'expired',  label:'Already expired'},
            {value:'no_expiry',label:'No expiry set'},
          ]}/>
          <FilterSelect style={{flex:'1 1 130px'}} value={trafficFilter} onChange={setTrafficFilter} options={[
            {value:'',         label:'Any traffic'},
            {value:'over90',   label:'Usage > 90 %'},
            {value:'over75',   label:'Usage > 75 %'},
            {value:'over50',   label:'Usage > 50 %'},
            {value:'unlimited',label:'Unlimited'},
            {value:'unused',   label:'No usage'},
          ]}/>
          {hasFilters && (
            <button onClick={clearFilters} style={{
              display:'flex', alignItems:'center', gap:5, flexShrink:0,
              padding:'0 10px', height:34, border:'1px solid var(--border)',
              borderRadius:'var(--r-md)', background:'transparent',
              color:'var(--muted)', fontSize:12, cursor:'pointer', whiteSpace:'nowrap',
            }}>
              <Icons.X size={11}/> Clear
            </button>
          )}
          <span style={{marginLeft:'auto', fontSize:12, color:'var(--muted)', whiteSpace:'nowrap', flexShrink:0}}>
            <b style={{color:'var(--text)'}}>{total}</b> user{total !== 1 ? 's' : ''}{hasFilters ? ' matched' : ''}
          </span>
        </div>

        {/* ── Table ── */}
        <div style={{overflowX:'auto'}}>
          <table className="tbl tbl-responsive">
            <thead>
              <tr>
                <th style={{width:36, paddingRight:0}}>
                  <input type="checkbox"
                    checked={users.length > 0 && selected.size === users.length}
                    ref={el => { if (el) el.indeterminate = selected.size > 0 && selected.size < users.length; }}
                    onChange={selectAll}
                    style={{cursor:'pointer', accentColor:'var(--accent)'}}/>
                </th>
                <SortTh col="name"    label="User"    sort={sortCol} dir={sortDir} onSort={handleSort} style={{width:'20%'}}/>
                <th className="col-mobile-hide">App login</th>
                <th className="col-mobile-hide">Inbounds</th>
                <SortTh col="traffic" label="Traffic" sort={sortCol} dir={sortDir} onSort={handleSort} className="col-mobile-hide"/>
                <SortTh col="expires" label="Expires" sort={sortCol} dir={sortDir} onSort={handleSort} className="col-mobile-hide"/>
                <SortTh col="status"  label="Status"  sort={sortCol} dir={sortDir} onSort={handleSort}/>
                {isAdmin && <th className="col-mobile-hide">Owner</th>}
                <th style={{textAlign:'right'}}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {loading && (
                <tr><td colSpan={colSpan} style={{padding:40, textAlign:'center', color:'var(--muted)'}}>Loading…</td></tr>
              )}
              {!loading && users.map((u, i) => {
                const pct = u.traffic_limit > 0 ? (u.traffic_used / u.traffic_limit) * 100 : 0;
                const fillClass = pct > 90 ? 'full' : pct > 75 ? 'high' : '';
                const isExpanded = expandedId === u.id;
                const isSelected = selected.has(u.id);
                const isExpiredStatus = u.status === 'expired' || (u.expires && new Date(u.expires) < new Date());
                return (
                  <React.Fragment key={u.id}>
                    <tr style={{cursor:'pointer', background: isSelected ? 'var(--accent-tint)' : undefined}}
                      onClick={() => toggleExpand(u.id)}>
                      <td style={{paddingRight:0}} onClick={e => e.stopPropagation()}>
                        <input type="checkbox" checked={isSelected}
                          onChange={() => toggleSelect(u.id)}
                          style={{cursor:'pointer', accentColor:'var(--accent)'}}/>
                      </td>
                      <td className="td-main">
                        <div className="user-cell">
                          <Avatar name={u.name} i={i}/>
                          <div style={{minWidth:0}}>
                            <div style={{fontWeight:500,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{u.name}</div>
                            <div style={{display:'flex',alignItems:'center',gap:4,flexWrap:'wrap'}}>
                              <div className="user-email">{u.email || '—'}</div>
                              {u.speed_limit_kbps > 0 && (
                                <span title={`Speed limit: ${(u.speed_limit_kbps/1000).toFixed(u.speed_limit_kbps%1000===0?0:1)} Mbps`} style={{
                                  display:'inline-flex', alignItems:'center', gap:2,
                                  fontSize:10, fontWeight:600, padding:'1px 5px', borderRadius:3,
                                  background:'oklch(72% 0.17 270/0.13)', color:'oklch(62% 0.2 270)',
                                  fontFamily:'var(--font-mono)',
                                }}>
                                  <Icons.Zap size={9}/>
                                  {u.speed_limit_kbps >= 1000
                                    ? `${(u.speed_limit_kbps/1000).toFixed(u.speed_limit_kbps%1000===0?0:1)}M`
                                    : `${u.speed_limit_kbps}k`}
                                </span>
                              )}
                              {u.access_type && u.access_type !== 'both' && (
                                <span title={u.access_type === 'sub'
                                  ? 'Subscription link only — app sign-in is refused'
                                  : 'App only — the subscription URL returns 403'} style={{
                                  display:'inline-flex', alignItems:'center',
                                  fontSize:10, fontWeight:600, padding:'1px 5px', borderRadius:3,
                                  background:'var(--warn-tint, oklch(75% 0.15 75/0.13))',
                                  color:'var(--warn)', fontFamily:'var(--font-mono)',
                                }}>
                                  {u.access_type === 'sub' ? 'SUB ONLY' : 'APP ONLY'}
                                </span>
                              )}
                            </div>
                          </div>
                        </div>
                      </td>
                      <td className="col-mobile-hide">
                        <AppLoginCell user={u} pushToast={pushToast}/>
                      </td>
                      <td className="col-mobile-hide">
                        <div style={{display:'flex', flexWrap:'wrap', gap:4}}>
                          {(u.inbounds||[]).length === 0 && <span style={{color:'var(--muted)', fontSize:12}}>—</span>}
                          {(u.inbounds||[]).map(ib => (
                            <span key={ib.id} title={`${ib.proto} :${ib.port}`}
                              className={`proto-chip ${(ib.proto||'').toLowerCase()}`}
                              style={{fontSize:10.5, opacity: ib.enabled ? 1 : 0.45}}>
                              {ib.tag}
                            </span>
                          ))}
                        </div>
                      </td>
                      <td className="col-mobile-hide">
                        {u.traffic_limit > 0 ? (
                          <div className="meter">
                            <div className="meter-bar">
                              <div className={`meter-fill ${fillClass}`} style={{width:`${Math.min(100, pct)}%`}}/>
                            </div>
                            <div className="meter-meta">
                              <span>{u.traffic_used} / {u.traffic_limit} GB</span>
                              <span>{Math.round(pct)}%</span>
                            </div>
                          </div>
                        ) : <span style={{color:'var(--muted)', fontSize:12}}>Unlimited</span>}
                      </td>
                      <td className="col-mobile-hide">
                        {u.expires ? (() => {
                          const diff = Math.ceil((new Date(u.expires) - Date.now()) / 86400000);
                          const overdue = diff < 0;
                          const soon    = !overdue && diff <= 7;
                          const color   = overdue ? 'var(--danger)' : soon ? 'var(--warning,#f59e0b)' : 'var(--muted)';
                          return (
                            <div style={{lineHeight:1.35}}>
                              <span className="mono" style={{fontSize:12, color:'var(--text-2)'}}>{u.expires}</span>
                              <div style={{fontSize:11, color, fontWeight:600, marginTop:2}}>
                                {overdue ? `${Math.abs(diff)}d overdue` : diff === 0 ? 'Today' : `${diff}d left`}
                              </div>
                            </div>
                          );
                        })() : <span style={{color:'var(--muted)', fontSize:12}}>—</span>}
                      </td>
                      <td><Badge kind={u.status}>{u.status ? u.status[0].toUpperCase()+u.status.slice(1) : '—'}</Badge></td>
                      {isAdmin && (
                        <td className="col-mobile-hide">
                          {u.owner
                            ? <span style={{display:'inline-flex',alignItems:'center',gap:4,fontSize:11.5,padding:'2px 8px',borderRadius:999,background:'var(--info-tint)',color:'var(--info)',fontWeight:500}}>{u.owner}</span>
                            : <span style={{fontSize:11.5,color:'var(--muted)'}}>Admin</span>}
                        </td>
                      )}
                      <td className="td-actions">
                        <div className="row-actions">
                          {/* Expand chevron — mobile only */}
                          <button className="icon-btn-sm expand-chevron" title="Expand" onClick={e => { e.stopPropagation(); toggleExpand(u.id); }}>
                            {isExpanded
                              ? <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><path d="M6 15l6-6 6 6" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                              : <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                            }
                          </button>
                          {/* Desktop action buttons */}
                          <button className="icon-btn-sm mobile-hide-action" title="Show QR / configs" onClick={e => { e.stopPropagation(); setQrUser(u); }}><Icons.QR size={14}/></button>
                          <button className="icon-btn-sm mobile-hide-action" title="Copy all links" onClick={e => { e.stopPropagation(); copyAllLinks(u); }}><Icons.Copy size={14}/></button>
                          <button className="icon-btn-sm mobile-hide-action" title="Copy subscription URL" onClick={e => { e.stopPropagation(); copySub(u); }}><Icons.Link size={14}/></button>
                          <button className="icon-btn-sm mobile-hide-action" title="Edit user" onClick={e => { e.stopPropagation(); setEditUser(u); }}><Icons.Edit size={14}/></button>
                          {isExpiredStatus && (
                            <button className="icon-btn-sm mobile-hide-action" title="Renew (+30 days)" style={{color:'var(--accent)'}}
                              onClick={e => { e.stopPropagation(); setRenewModal(u); }}>
                              <Icons.Calendar size={14}/>
                            </button>
                          )}
                          <button className="icon-btn-sm mobile-hide-action" title={u.status === 'active' ? 'Pause' : 'Activate'} onClick={e => { e.stopPropagation(); toggleStatus(u.id, u.status); }}><Icons.Power size={14}/></button>
                          <button className="icon-btn-sm danger mobile-hide-action" title="Delete" onClick={e => { e.stopPropagation(); removeUser(u.id); }}><Icons.Trash size={14}/></button>
                        </div>
                      </td>
                    </tr>

                    {/* ── Mobile expand panel ── */}
                    {isExpanded && (
                      <tr className="mobile-expand-row">
                        <td colSpan={colSpan} className="mobile-expand-td">
                          <div className="mobile-expand-panel">

                            {/* User data */}
                            <div className="mobile-expand-data">
                              <div className="mobile-expand-item">
                                <span className="mobile-expand-label">Traffic</span>
                                {u.traffic_limit > 0 ? (
                                  <div className="meter" style={{flex:1}}>
                                    <div className="meter-bar">
                                      <div className={`meter-fill ${fillClass}`} style={{width:`${Math.min(100,pct)}%`}}/>
                                    </div>
                                    <div className="meter-meta">
                                      <span>{u.traffic_used} / {u.traffic_limit} GB</span>
                                      <span>{Math.round(pct)}%</span>
                                    </div>
                                  </div>
                                ) : <span style={{color:'var(--muted)',fontSize:12}}>Unlimited</span>}
                              </div>
                              <div className="mobile-expand-item">
                                <span className="mobile-expand-label">Expires</span>
                                {u.expires ? (() => {
                                  const diff = Math.ceil((new Date(u.expires) - Date.now()) / 86400000);
                                  const overdue = diff < 0;
                                  const soon = !overdue && diff <= 7;
                                  const color = overdue ? 'var(--danger)' : soon ? 'var(--warning,#f59e0b)' : 'var(--muted)';
                                  return (
                                    <div style={{lineHeight:1.4}}>
                                      <span className="mono" style={{fontSize:12,color:'var(--text-2)'}}>{u.expires}</span>
                                      <div style={{fontSize:11,color,fontWeight:600,marginTop:1}}>
                                        {overdue ? `${Math.abs(diff)}d overdue` : diff === 0 ? 'Today' : `${diff}d left`}
                                      </div>
                                    </div>
                                  );
                                })() : <span style={{color:'var(--muted)',fontSize:12}}>—</span>}
                              </div>
                              <div className="mobile-expand-item">
                                <span className="mobile-expand-label">App login</span>
                                <AppLoginCell user={u} pushToast={pushToast} compact/>
                              </div>
                              <div className="mobile-expand-item">
                                <span className="mobile-expand-label">Inbounds</span>
                                <div style={{display:'flex',flexWrap:'wrap',gap:4,flex:1}}>
                                  {(u.inbounds||[]).length === 0
                                    ? <span style={{color:'var(--muted)',fontSize:12}}>—</span>
                                    : (u.inbounds||[]).map(ib => (
                                        <span key={ib.id} className={`proto-chip ${(ib.proto||'').toLowerCase()}`}
                                          style={{fontSize:10.5,opacity:ib.enabled?1:0.45}}>
                                          {ib.tag}
                                        </span>
                                      ))
                                  }
                                </div>
                              </div>
                              {isAdmin && (
                                <div className="mobile-expand-item">
                                  <span className="mobile-expand-label">Owner</span>
                                  {u.owner
                                    ? <span style={{display:'inline-flex',alignItems:'center',gap:4,fontSize:11.5,padding:'2px 8px',borderRadius:999,background:'var(--info-tint)',color:'var(--info)',fontWeight:500}}>{u.owner}</span>
                                    : <span style={{fontSize:11.5,color:'var(--muted)'}}>Admin</span>}
                                </div>
                              )}
                            </div>

                            {/* All action buttons */}
                            <div className="mobile-expand-actions">
                              <button onClick={e => { e.stopPropagation(); setQrUser(u); }}>
                                <Icons.QR size={15}/><span>QR</span>
                              </button>
                              <button onClick={e => { e.stopPropagation(); copyAllLinks(u); }}>
                                <Icons.Copy size={15}/><span>Copy Links</span>
                              </button>
                              <button onClick={e => { e.stopPropagation(); copySub(u); }}>
                                <Icons.Link size={15}/><span>Sub URL</span>
                              </button>
                              <button onClick={e => { e.stopPropagation(); setEditUser(u); }}>
                                <Icons.Edit size={15}/><span>Edit</span>
                              </button>
                              {isExpiredStatus && (
                                <button onClick={e => { e.stopPropagation(); setRenewModal(u); }}>
                                  <Icons.Calendar size={15}/><span>Renew</span>
                                </button>
                              )}
                              <button onClick={e => { e.stopPropagation(); toggleStatus(u.id, u.status); }}>
                                <Icons.Power size={15}/><span>{u.status === 'active' ? 'Pause' : 'Activate'}</span>
                              </button>
                              <button className="danger" onClick={e => { e.stopPropagation(); removeUser(u.id); }}>
                                <Icons.Trash size={15}/><span>Delete</span>
                              </button>
                            </div>

                          </div>
                        </td>
                      </tr>
                    )}
                  </React.Fragment>
                );
              })}
              {!loading && users.length === 0 && (
                <tr><td colSpan={colSpan} style={{padding:40, textAlign:'center', color:'var(--muted)'}}>
                  {hasFilters ? 'No users match the current filters.' : 'No users yet.'}
                </td></tr>
              )}
            </tbody>
          </table>
        </div>

        {/* ── Pagination footer ── */}
        <div style={{
          padding:'10px 16px', borderTop:'1px solid var(--border-soft)',
          display:'flex', alignItems:'center', justifyContent:'space-between',
          flexWrap:'wrap', gap:8, fontSize:12.5, color:'var(--muted)',
        }}>
          <div style={{display:'flex', alignItems:'center', gap:10, flexWrap:'wrap'}}>
            <span>
              Page <b style={{color:'var(--text)'}}>{page}</b> of <b style={{color:'var(--text)'}}>{pages}</b>
              {' '}·{' '}
              <b style={{color:'var(--text)'}}>{total}</b> user{total !== 1 ? 's' : ''}
              {hasFilters ? ' matched' : ''}
            </span>
            <label style={{display:'flex', alignItems:'center', gap:5, fontSize:12, color:'var(--muted)'}}>
              Per page:
              <select value={perPage} onChange={e => { const n=Number(e.target.value); setPerPage(n); setPage(1); load(1, n); }}
                style={{
                  height:28, padding:'0 8px', border:'1px solid var(--border)',
                  borderRadius:'var(--r-md)', background:'var(--surface-2)',
                  color:'var(--text)', fontSize:12, cursor:'pointer', outline:'none',
                  colorScheme:'dark',
                }}>
                {[10,20,30,40,50].map(n => <option key={n} value={n}>{n}</option>)}
              </select>
            </label>
          </div>
          <div style={{display:'flex', alignItems:'center', gap:4}}>
            <button onClick={() => goToPage(1)} disabled={page <= 1}
              style={{padding:'3px 8px', borderRadius:'var(--r-md)', border:'1px solid var(--border)',
                background:'var(--surface-2)', color:'var(--text)', cursor: page<=1 ? 'default':'pointer',
                opacity: page<=1 ? 0.4 : 1, fontSize:12}}>«</button>
            <button onClick={() => goToPage(page - 1)} disabled={page <= 1}
              style={{padding:'3px 8px', borderRadius:'var(--r-md)', border:'1px solid var(--border)',
                background:'var(--surface-2)', color:'var(--text)', cursor: page<=1 ? 'default':'pointer',
                opacity: page<=1 ? 0.4 : 1, fontSize:12}}>‹ Prev</button>

            {/* page number buttons — show up to 5 around current page */}
            {Array.from({length: pages}, (_,i) => i+1)
              .filter(p => p === 1 || p === pages || Math.abs(p - page) <= 2)
              .reduce((acc, p, idx, arr) => {
                if (idx > 0 && p - arr[idx-1] > 1) acc.push('…');
                acc.push(p);
                return acc;
              }, [])
              .map((p, idx) => p === '…'
                ? <span key={`e${idx}`} style={{padding:'0 4px', fontSize:12, color:'var(--muted)'}}>…</span>
                : <button key={p} onClick={() => goToPage(p)}
                    style={{
                      padding:'3px 8px', borderRadius:'var(--r-md)', fontSize:12,
                      border: p === page ? '1px solid var(--accent)' : '1px solid var(--border)',
                      background: p === page ? 'var(--accent-tint)' : 'var(--surface-2)',
                      color: p === page ? 'var(--accent)' : 'inherit',
                      fontWeight: p === page ? 600 : 400, cursor:'pointer',
                    }}>{p}</button>
              )
            }

            <button onClick={() => goToPage(page + 1)} disabled={page >= pages}
              style={{padding:'3px 8px', borderRadius:'var(--r-md)', border:'1px solid var(--border)',
                background:'var(--surface-2)', color:'var(--text)', cursor: page>=pages ? 'default':'pointer',
                opacity: page>=pages ? 0.4 : 1, fontSize:12}}>Next ›</button>
            <button onClick={() => goToPage(pages)} disabled={page >= pages}
              style={{padding:'3px 8px', borderRadius:'var(--r-md)', border:'1px solid var(--border)',
                background:'var(--surface-2)', color:'var(--text)', cursor: page>=pages ? 'default':'pointer',
                opacity: page>=pages ? 0.4 : 1, fontSize:12}}>»</button>
          </div>
        </div>
      </div>

      {addOpen && (
        <AddUserModal
          inboundList={inboundList}
          defaultQuota={defaultQuota}
          defaultExpiry={defaultExpiry}
          role={role}
          adminResellers={adminResellers}
          onClose={() => setAddOpen(false)}
          onCreate={(u, xrayMsg) => {
            load();
            setAddOpen(false);
            setNewCreds(u);
            pushToast(xrayMsg === 'restarted'
              ? `User ${u.name} created — Xray restarted`
              : `User ${u.name} created`);
          }}
        />
      )}

      {newCreds && (
        <NewUserCredentialsModal user={newCreds} pushToast={pushToast}
          onClose={() => setNewCreds(null)}/>
      )}

      {editUser && (
        <EditUserModal
          user={editUser}
          inboundList={inboundList}
          onClose={() => setEditUser(null)}
          onSave={(xrayMsg) => {
            load();
            setEditUser(null);
            pushToast(xrayMsg === 'restarted' ? 'User updated — Xray restarted' : 'User updated');
          }}
          pushToast={pushToast}
        />
      )}

      {qrUser && <QRModal user={qrUser} onClose={() => setQrUser(null)} pushToast={pushToast}/>}

      {bulkModal && (
        <BulkActionModal
          action={bulkModal}
          count={selected.size}
          busy={bulkBusy}
          onConfirm={(value) => runBulk(
            bulkModal === 'extend'     ? 'extend_expiry'  :
            bulkModal === 'set_expiry' ? 'set_expiry'     :
            'set_traffic',
            value
          )}
          onClose={() => setBulkModal(null)}
        />
      )}

      {renewModal && (
        <RenewModal
          user={renewModal}
          onConfirm={(days) => renewUser(renewModal, days)}
          onClose={() => setRenewModal(null)}
        />
      )}
    </div>
  );
};

// ── Access type picker ────────────────────────────────────────────────────────
// Which of the two delivery routes an account may use. Kept as one component so
// the add and edit modals cannot drift apart on the wording — the labels are
// the only explanation the operator gets of what the restriction actually does.
const ACCESS_TYPE_OPTIONS = [
  { val: 'both', label: 'Both',         hint: 'Subscription link and the app' },
  { val: 'sub',  label: 'Subscription', hint: 'Link only — app sign-in refused' },
  { val: 'app',  label: 'App',          hint: 'App only — link returns 403' },
];

const AccessTypePicker = ({ value, onChange }) => (
  <div className="field">
    <label className="field-label">Allowed access</label>
    <div style={{display:'flex', gap:8}}>
      {ACCESS_TYPE_OPTIONS.map(opt => (
        <label key={opt.val} style={{
          display:'flex', flexDirection:'column', gap:2, cursor:'pointer', flex:1,
          padding:'8px 11px', borderRadius:'var(--r-md)',
          border:`1.5px solid ${value === opt.val ? 'var(--accent)' : 'var(--border)'}`,
          background: value === opt.val ? 'var(--accent-tint)' : 'var(--surface-2)',
          transition:'all 0.12s',
        }}>
          <span style={{display:'flex', alignItems:'center', gap:7, fontSize:13}}>
            <input type="radio" name={`accessType-${opt.val}-${value}`} value={opt.val}
              checked={value === opt.val}
              onChange={() => onChange(opt.val)}
              style={{accentColor:'var(--accent)'}}/>
            {opt.label}
          </span>
          <span style={{fontSize:10.5, color:'var(--muted)', paddingLeft:22}}>{opt.hint}</span>
        </label>
      ))}
    </div>
  </div>
);

// ── Add user modal ────────────────────────────────────────────────────────────
const AddUserModal = ({ onClose, onCreate, inboundList, defaultQuota = 100, defaultExpiry = 30, role, adminResellers = [] }) => {
  const isAdminRole = role === 'admin';
  const toExpiryDate = (days) => {
    const d = new Date(); d.setDate(d.getDate() + (days || 30));
    return d.toISOString().split('T')[0];
  };
  const [name,          setName]          = React.useState('');
  const [email,         setEmail]         = React.useState('');
  const [limit,         setLimit]         = React.useState(defaultQuota);
  const [expires,       setExpires]       = React.useState(toExpiryDate(defaultExpiry));
  const [ipLimit,       setIpLimit]       = React.useState(0);
  const [speedLimit,    setSpeedLimit]    = React.useState(0);
  const [selectedIds,   setSelectedIds]   = React.useState([]);
  const [resellerId,    setResellerId]    = React.useState(adminResellers[0]?.id || null);
  const [dateStartMode, setDateStartMode] = React.useState('on_create');
  const [connectDays,   setConnectDays]   = React.useState(defaultExpiry || 30);
  const [accessType,    setAccessType]    = React.useState('both');
  const [saving,        setSaving]        = React.useState(false);
  const [err,           setErr]           = React.useState('');

  React.useEffect(() => {
    if (adminResellers.length > 0 && !resellerId) setResellerId(adminResellers[0].id);
  }, [adminResellers]);

  // Pre-select all enabled inbounds by default
  React.useEffect(() => {
    if (inboundList && inboundList.length > 0 && selectedIds.length === 0) {
      setSelectedIds(inboundList.filter(i => i.enabled !== false).map(i => i.id));
    }
  }, [inboundList]);

  const create = () => {
    if (!name) return;
    if (isAdminRole && !resellerId) { setErr('Select a reseller'); return; }
    setSaving(true); setErr('');
    const body = {
      name, email,
      inbound_ids: selectedIds,
      traffic_limit: Number(limit),
      ip_limit: Number(ipLimit),
      speed_limit_kbps: Math.round(Number(speedLimit) * 1000),
      date_start_mode: dateStartMode,
      access_type: accessType,
    };
    if (dateStartMode === 'on_first_connect') {
      body.connect_days = Number(connectDays) || 30;
    } else {
      body.expires = expires || null;
    }
    if (isAdminRole && resellerId) body.reseller_id = resellerId;
    fetch('/api/users', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify(body),
    })
      .then(r => r.json())
      .then(d => {
        setSaving(false);
        if (d.error) { setErr(d.error); return; }
        if (d.user) onCreate(d.user, d.xray);
      })
      .catch(() => setSaving(false));
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">Provision new user</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>Assign to one or more inbounds</div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          {err && <div style={{background:'var(--danger-tint)', color:'var(--danger)', borderRadius:'var(--r-md)', padding:'8px 12px', fontSize:12.5, marginBottom:4}}>{err}</div>}
          {isAdminRole && (
            <div className="field">
              <label className="field-label">Reseller</label>
              <select className="input" value={resellerId || ''} onChange={e => setResellerId(+e.target.value)}>
                {adminResellers.length === 0
                  ? <option value="">No resellers — create one first</option>
                  : adminResellers.map(r => <option key={r.id} value={r.id}>{r.username}</option>)
                }
              </select>
            </div>
          )}
          <div className="field-row">
            <div className="field">
              <label className="field-label">Display name</label>
              <input className="input" placeholder="e.g. Alex Kim" value={name} onChange={e => setName(e.target.value)} autoFocus/>
            </div>
            <div className="field">
              <label className="field-label">Email (optional)</label>
              <input className="input" placeholder="alex@example.com" value={email} onChange={e => setEmail(e.target.value)}/>
            </div>
          </div>

          <div className="field">
            <label className="field-label">
              Inbounds
              <span style={{marginLeft:6, fontWeight:400, color:'var(--muted)'}}>
                ({selectedIds.length} selected)
              </span>
            </label>
            <InboundPicker
              inboundList={inboundList}
              selectedIds={selectedIds}
              onChange={setSelectedIds}
            />
          </div>

          <div className="field-row">
            <div className="field">
              <label className="field-label">Traffic limit (GB, 0=∞)</label>
              <input className="input mono" type="number" min={0} value={limit} onChange={e => setLimit(e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">IP / device limit (0=∞)</label>
              <input className="input mono" type="number" min={0} value={ipLimit} onChange={e => setIpLimit(e.target.value)}/>
            </div>
          </div>

          <div className="field">
            <label className="field-label">
              <Icons.Zap size={12} style={{marginRight:4, verticalAlign:'middle'}}/>
              Speed limit (Mbps, 0=∞)
            </label>
            <input className="input mono" type="number" min={0} step={0.1} value={speedLimit}
              onChange={e => setSpeedLimit(e.target.value)}
              placeholder="0 = unlimited"/>
          </div>

          <AccessTypePicker value={accessType} onChange={setAccessType}/>

          <div className="field">
            <label className="field-label">Expiry start</label>
            <div style={{display:'flex', gap:10, marginBottom:10}}>
              {[
                { val: 'on_create',        label: 'From creation date' },
                { val: 'on_first_connect', label: 'From first connection' },
              ].map(opt => (
                <label key={opt.val} style={{
                  display:'flex', alignItems:'center', gap:8, cursor:'pointer',
                  padding:'8px 14px', borderRadius:'var(--r-md)',
                  border:`1.5px solid ${dateStartMode === opt.val ? 'var(--accent)' : 'var(--border)'}`,
                  background: dateStartMode === opt.val ? 'var(--accent-tint)' : 'var(--surface-2)',
                  flex:1, fontSize:13, transition:'all 0.12s',
                }}>
                  <input type="radio" name="dateStartMode" value={opt.val}
                    checked={dateStartMode === opt.val}
                    onChange={() => setDateStartMode(opt.val)}
                    style={{accentColor:'var(--accent)'}}/>
                  {opt.label}
                </label>
              ))}
            </div>
            {dateStartMode === 'on_create'
              ? <input className="input mono" type="date" value={expires} onChange={e => setExpires(e.target.value)}/>
              : (
                <div style={{display:'flex', alignItems:'center', gap:10}}>
                  <input className="input mono" type="number" min={1} value={connectDays}
                    onChange={e => setConnectDays(e.target.value)}
                    style={{width:100}}/>
                  <span style={{fontSize:13, color:'var(--muted)'}}>days from first VPN connection</span>
                </div>
              )
            }
          </div>

          <div style={{
            background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:'var(--r-md)',
            padding:'9px 11px', fontSize:11.5, color:'var(--muted)', fontFamily:'var(--font-mono)',
            display:'flex', alignItems:'center', gap:8, marginTop:2,
          }}>
            <Icons.Key size={13}/> UUID · subscription URL · app login (pvb…) all generated automatically
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={create} disabled={!name || saving}>
            <Icons.Check size={14}/> {saving ? 'Creating…' : 'Create user'}
          </button>
        </div>
      </div>
    </div>
  );
};

// ── Edit user modal ───────────────────────────────────────────────────────────
const EditUserModal = ({ user, onClose, onSave, inboundList, pushToast }) => {
  const [name,        setName]        = React.useState(user.name || '');
  const [email,       setEmail]       = React.useState(user.email || '');
  const [status,      setStatus]      = React.useState(user.status || 'active');
  const [limit,       setLimit]       = React.useState(user.traffic_limit || 100);
  const [ipLimit,     setIpLimit]     = React.useState(user.ip_limit || 0);
  const [speedLimit,  setSpeedLimit]  = React.useState(((user.speed_limit_kbps || 0) / 1000) || 0);
  const [expires,     setExpires]     = React.useState(user.expires || '');
  const [subNote,     setSubNote]     = React.useState(user.sub_note || '');
  const [accessType,  setAccessType]  = React.useState(user.access_type || 'both');
  const [usedReset,   setUsedReset]   = React.useState(false);
  const [selectedIds, setSelectedIds] = React.useState(user.inbound_ids || []);
  const [saving,      setSaving]      = React.useState(false);

  // Access control
  const [accessMode,    setAccessMode]    = React.useState(user.access_mode    || 'none');
  const [accessDomains, setAccessDomains] = React.useState((user.access_domains || []).join('\n'));
  const [accessIps,     setAccessIps]     = React.useState((user.access_ips     || []).join('\n'));

  // UUID change
  const [editingUuid, setEditingUuid] = React.useState(false);
  const [newUuid,     setNewUuid]     = React.useState(user.uuid || '');
  const [uuidSaving,  setUuidSaving]  = React.useState(false);

  const changeUuid = () => {
    if (!newUuid || newUuid === user.uuid) return;
    setUuidSaving(true);
    fetch(`/api/users/${user.id}/uuid`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ uuid: newUuid }),
    })
      .then(r => r.json())
      .then(d => {
        setUuidSaving(false);
        if (d.error) { pushToast('UUID error: ' + d.error); return; }
        pushToast('UUID updated — Xray restarted');
        setEditingUuid(false);
        user.uuid = d.uuid; // reflect locally
      })
      .catch(() => { setUuidSaving(false); pushToast('UUID change failed'); });
  };

  const genNewUuid = () => {
    fetch('/api/uuid').then(r => r.json()).then(d => setNewUuid(d.uuid));
  };

  const [subToken, setSubToken] = React.useState(user.sub_token || '');
  const [subUrl, setSubUrl] = React.useState(user.sub_url || '');
  const [subUrls, setSubUrls] = React.useState(user.sub_urls || []);

  const resetSubToken = () => {
    fetch(`/api/users/${user.id}/reset-sub`, { method: 'POST' })
      .then(r => r.json())
      .then(d => {
        if (d.sub_token) {
          setSubToken(d.sub_token);
          if (d.sub_url) setSubUrl(d.sub_url);
          if (d.sub_urls) setSubUrls(d.sub_urls);
          pushToast('Subscription token regenerated');
        }
      })
      .catch(() => pushToast('Reset failed'));
  };

  const save = () => {
    setSaving(true);
    const body = {
      name, email, status,
      traffic_limit: Number(limit),
      ip_limit: Number(ipLimit),
      speed_limit_kbps: Math.round(Number(speedLimit) * 1000),
      inbound_ids: selectedIds,
      expires: expires || null,
      sub_note: subNote || null,
      access_type:    accessType,
      access_mode:    accessMode,
      access_domains: accessDomains.split('\n').map(s=>s.trim()).filter(Boolean),
      access_ips:     accessIps.split('\n').map(s=>s.trim()).filter(Boolean),
    };
    if (usedReset) body.traffic_used = 0;
    fetch(`/api/users/${user.id}`, {
      method: 'PUT',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify(body)
    })
      .then(r => r.json())
      .then(d => { setSaving(false); onSave(d.xray); })
      .catch(() => setSaving(false));
  };

  const STATUSES = ['active','paused','limit','expired'];

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">Edit user</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>
              <span className="mono" style={{fontSize:11}}>{user.uuid}</span>
            </div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          <div className="field-row">
            <div className="field">
              <label className="field-label">Display name</label>
              <input className="input" value={name} onChange={e => setName(e.target.value)} autoFocus/>
            </div>
            <div className="field">
              <label className="field-label">Email</label>
              <input className="input" value={email} onChange={e => setEmail(e.target.value)} placeholder="optional"/>
            </div>
          </div>

          {/* UUID field */}
          <div className="field">
            <label className="field-label" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <span>Xray UUID</span>
              <button onClick={() => { setEditingUuid(v => !v); setNewUuid(user.uuid); }}
                style={{ fontSize: 11, color: 'var(--accent)', background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}>
                {editingUuid ? 'Cancel' : '✏ Change'}
              </button>
            </label>
            {!editingUuid ? (
              <div style={{
                fontFamily: 'var(--font-mono)', fontSize: 11.5, padding: '7px 10px',
                background: 'var(--surface-2)', border: '1px solid var(--border)',
                borderRadius: 'var(--r-md)', color: 'var(--muted)',
              }}>{user.uuid}</div>
            ) : (
              <div style={{ display: 'flex', gap: 6 }}>
                <input className="input mono" style={{ flex: 1, fontSize: 12 }}
                  value={newUuid} onChange={e => setNewUuid(e.target.value)}
                  placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"/>
                <button className="btn btn-ghost" style={{ fontSize: 11, padding: '5px 8px' }}
                  onClick={genNewUuid} title="Generate new UUID">↻</button>
                <button className="btn btn-primary" style={{ fontSize: 11, padding: '5px 10px' }}
                  onClick={changeUuid} disabled={uuidSaving || !newUuid || newUuid === user.uuid}>
                  {uuidSaving ? '…' : 'Apply'}
                </button>
              </div>
            )}
            {editingUuid && (
              <div style={{ fontSize: 11, color: 'var(--warn)', marginTop: 3 }}>
                Changing UUID will invalidate the user's existing client configs — they must reimport.
              </div>
            )}
          </div>

          {/* App login credentials */}
          <AppLoginEditor user={user} pushToast={pushToast}/>
          {accessType === 'sub' && (
            <div style={{fontSize:11, color:'var(--warn)', marginTop:-6, marginBottom:10}}>
              Disabled — this account is set to Subscription only, so the app refuses these credentials.
            </div>
          )}

          <div className="field">
            <label className="field-label">Status</label>
            <div className="proto-pick">
              {STATUSES.map(s => (
                <button key={s} className={status === s ? 'active' : ''} onClick={() => setStatus(s)}>
                  {s[0].toUpperCase()+s.slice(1)}
                </button>
              ))}
            </div>
          </div>

          <div className="field">
            <label className="field-label">
              Inbounds
              <span style={{marginLeft:6, fontWeight:400, color:'var(--muted)'}}>
                ({selectedIds.length} selected)
              </span>
            </label>
            <InboundPicker
              inboundList={inboundList}
              selectedIds={selectedIds}
              onChange={setSelectedIds}
            />
          </div>

          <div className="field-row">
            <div className="field">
              <label className="field-label">Traffic limit (GB, 0=∞)</label>
              <input className="input mono" type="number" min={0} value={limit} onChange={e => setLimit(e.target.value)}/>
            </div>
            <div className="field">
              <label className="field-label">IP / device limit (0=∞)</label>
              <input className="input mono" type="number" min={0} value={ipLimit} onChange={e => setIpLimit(e.target.value)}/>
            </div>
          </div>

          <div className="field">
            <label className="field-label">
              <Icons.Zap size={12} style={{marginRight:4, verticalAlign:'middle'}}/>
              Speed limit (Mbps, 0=∞)
            </label>
            <input className="input mono" type="number" min={0} step={0.1} value={speedLimit}
              onChange={e => setSpeedLimit(e.target.value)}
              placeholder="0 = unlimited"/>
          </div>

          <AccessTypePicker value={accessType} onChange={setAccessType}/>

          <div className="field">
            <label className="field-label">Expiry date</label>
            <input className="input mono" type="date" value={expires} onChange={e => setExpires(e.target.value)}/>
          </div>

          {/* Subscription URL */}
          {subUrl && (
            <div className="field">
              <label className="field-label">Subscription URL</label>
              <div style={{
                display:'flex', alignItems:'center', gap:6,
                background:'var(--surface-2)', border:'1px solid var(--border)',
                borderRadius:'var(--r-md)', padding:'7px 10px',
              }}>
                <span style={{
                  flex:1, fontSize:11.5, fontFamily:'var(--font-mono)',
                  color:'var(--text-2)', overflow:'hidden', textOverflow:'ellipsis',
                  whiteSpace:'nowrap',
                }}>{subUrl}</span>
                <button className="icon-btn-sm" title="Copy subscription URL" onClick={() => {
                  copyText(subUrl).then(() => pushToast('Subscription URL copied'));
                }}><Icons.Copy size={12}/></button>
                <a href={subUrl} target="_blank" rel="noreferrer" className="icon-btn-sm" title="Open in new tab"
                   style={{display:'flex', alignItems:'center', justifyContent:'center'}}>
                  <Icons.Up size={12} style={{transform:'rotate(45deg)'}}/>
                </a>
              </div>
              <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginTop:4}}>
                <span style={{fontSize:11, color: accessType === 'app' ? 'var(--warn)' : 'var(--muted)'}}>
                  {accessType === 'app'
                    ? 'Disabled — this account is set to App only, so this URL returns 403'
                    : 'Import into your client app for automatic config updates'}
                </span>
                <button
                  onClick={resetSubToken}
                  style={{fontSize:11, color:'var(--warn)', background:'none', border:'none', cursor:'pointer', padding:0}}
                  title="Regenerate token — invalidates the current URL"
                >↻ Regenerate</button>
              </div>
            </div>
          )}

          {/* Sub info note */}
          <div className="field">
            <label className="field-label">
              Subscription info note
              <span style={{marginLeft:6, fontWeight:400, color:'var(--muted)'}}>shown in client app</span>
            </label>
            <input
              className="input"
              placeholder="e.g. Contact @admin · expires soon"
              value={subNote}
              onChange={e => setSubNote(e.target.value)}
            />
            <div style={{fontSize:11, color:'var(--muted)', marginTop:3}}>
              Appears as an extra entry in the subscription list alongside remaining data &amp; days.
            </div>
          </div>

          {/* Reset traffic */}
          <div style={{
            display:'flex', alignItems:'center', justifyContent:'space-between',
            padding:'10px 12px', background:'var(--surface-2)', border:'1px solid var(--border)',
            borderRadius:'var(--r-md)', marginTop:2
          }}>
            <div>
              <div style={{fontSize:13, fontWeight:500}}>Reset traffic counter</div>
              <div style={{fontSize:11.5, color:'var(--muted)', marginTop:2}}>
                Currently {user.traffic_used} GB used
              </div>
            </div>
            <div className={`switch ${usedReset ? 'on' : ''}`} onClick={() => setUsedReset(r => !r)}/>
          </div>

          {/* Access control */}
          <div style={{
            background:'var(--surface-2)', border:'1px solid var(--border)',
            borderRadius:'var(--r-lg)', padding:'12px 14px',
            display:'flex', flexDirection:'column', gap:10, marginTop:2,
          }}>
            <div style={{fontSize:12.5, fontWeight:600, color:'var(--text)'}}>Access Control</div>

            <div className="field" style={{marginBottom:0}}>
              <label className="field-label">Filter mode</label>
              <div className="proto-pick">
                {[['none','Disabled'],['blacklist','Blacklist'],['whitelist','Whitelist']].map(([v,l]) => (
                  <button key={v} className={accessMode===v?'active':''} onClick={() => setAccessMode(v)}>{l}</button>
                ))}
              </div>
              {accessMode === 'none' && (
                <span className="field-hint">No filtering — user can reach all destinations.</span>
              )}
              {accessMode === 'blacklist' && (
                <span className="field-hint">Block listed domains / IPs. Everything else is allowed.</span>
              )}
              {accessMode === 'whitelist' && (
                <span className="field-hint">Only listed domains / IPs are reachable. Everything else is blocked. Server IP and public DNS (8.8.8.8, 1.1.1.1) are auto-allowed.</span>
              )}
            </div>

            {accessMode !== 'none' && (<>
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">Domains <span style={{fontWeight:400,color:'var(--muted)'}}>one per line</span></label>
                <textarea
                  className="input"
                  rows={4}
                  style={{fontFamily:'var(--font-mono)',fontSize:12,resize:'vertical'}}
                  placeholder={'example.com\ngeosite:category-ads-all'}
                  value={accessDomains}
                  onChange={e => setAccessDomains(e.target.value)}
                />
              </div>
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">IPs / CIDRs <span style={{fontWeight:400,color:'var(--muted)'}}>one per line</span></label>
                <textarea
                  className="input"
                  rows={3}
                  style={{fontFamily:'var(--font-mono)',fontSize:12,resize:'vertical'}}
                  placeholder={'192.168.1.0/24\ngeoip:ir'}
                  value={accessIps}
                  onChange={e => setAccessIps(e.target.value)}
                />
              </div>
            </>)}
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={!name || saving}>
            <Icons.Check size={14}/> {saving ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
};

// ── QR / config modal ─────────────────────────────────────────────────────────
const QRModal = ({ user, onClose, pushToast }) => {
  const [activeLink, setActiveLink] = React.useState(
    (user.links && user.links.length > 0) ? user.links[0].link : (user.link || '')
  );
  const [activeTag, setActiveTag] = React.useState(
    (user.links && user.links.length > 0) ? user.links[0].tag : ''
  );

  // Use server-provided sub_urls (includes all relays); fall back gracefully
  const subUrls = user.sub_urls && user.sub_urls.length > 0
    ? user.sub_urls
    : (user.sub_url ? [{ name: 'Primary', url: user.sub_url }] : []);
  const [activeSubUrl, setActiveSubUrl] = React.useState(
    subUrls.length > 0 ? subUrls[0].url : ''
  );

  const allLinks = user.links && user.links.length > 0
    ? user.links
    : (user.link ? [{ tag: user.proto || 'link', link: user.link }] : []);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={e => e.stopPropagation()} style={{width:440}}>
        <div className="modal-head">
          <div>
            <div className="modal-title">Client configs</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>{user.name}</div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body" style={{alignItems:'center', gap:14}}>

          {/* Inbound selector tabs (if multiple) */}
          {allLinks.length > 1 && (
            <div style={{display:'flex', gap:6, flexWrap:'wrap', width:'100%'}}>
              {allLinks.map(l => (
                <button
                  key={l.tag}
                  onClick={() => { setActiveLink(l.link); setActiveTag(l.tag); }}
                  style={{
                    padding:'4px 10px', borderRadius:'var(--r-sm)', fontSize:12, fontWeight:500,
                    cursor:'pointer', border:'1px solid var(--border)',
                    background: activeTag === l.tag ? 'var(--accent)' : 'var(--surface-2)',
                    color: activeTag === l.tag ? '#fff' : 'var(--text-2)',
                    transition:'all 0.12s',
                  }}
                >
                  {l.tag}
                </button>
              ))}
            </div>
          )}

          {/* QR code */}
          {activeLink ? (
            <>
              <div className="qr-box">
                <FakeQR seed={activeLink || user.uuid || String(user.id)} size={220}/>
              </div>
              <div style={{
                width:'100%',
                background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:'var(--r-md)',
                padding:'10px 12px', fontFamily:'var(--font-mono)', fontSize:11,
                color:'var(--text-2)', wordBreak:'break-all', display:'flex', alignItems:'flex-start', gap:8
              }}>
                <span style={{flex:1}}>{activeLink}</span>
                <button className="icon-btn-sm" onClick={() => {
                  copyText(activeLink).then(() => pushToast('Config copied'));
                }} title="Copy"><Icons.Copy size={13}/></button>
              </div>
            </>
          ) : (
            <div style={{padding:32, textAlign:'center', color:'var(--muted)', fontSize:13}}>
              No configs — assign this user to an inbound first
            </div>
          )}

          {/* Subscription URLs + QR */}
          {subUrls.length > 0 && (
            <div style={{
              width:'100%', borderTop:'1px solid var(--border-soft)', paddingTop:14,
              display:'flex', flexDirection:'column', gap:10,
            }}>
              <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', flexWrap:'wrap', gap:6}}>
                <div style={{fontSize:11.5, fontWeight:600, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.06em'}}>
                  Subscription
                </div>
                {/* Relay selector tabs */}
                {subUrls.length > 1 && (
                  <div style={{display:'flex', gap:4}}>
                    {subUrls.map((s, i) => (
                      <button key={i} onClick={() => setActiveSubUrl(s.url)} style={{
                        padding:'2px 8px', borderRadius:'var(--r-sm)', fontSize:11, fontWeight:500, cursor:'pointer',
                        border:'1px solid var(--border)',
                        background: activeSubUrl === s.url ? 'var(--accent)' : 'var(--surface-2)',
                        color: activeSubUrl === s.url ? '#fff' : 'var(--text-2)',
                      }}>{s.name}</button>
                    ))}
                  </div>
                )}
              </div>
              <div style={{display:'flex', gap:14, alignItems:'flex-start'}}>
                {/* Sub QR */}
                <div style={{
                  background:'#fff', borderRadius:'var(--r-md)', padding:8,
                  flexShrink:0, border:'1px solid var(--border)',
                }}>
                  <FakeQR seed={activeSubUrl} size={90}/>
                </div>
                {/* Sub URL + info */}
                <div style={{flex:1, minWidth:0, display:'flex', flexDirection:'column', gap:6}}>
                  <div style={{
                    display:'flex', alignItems:'center', gap:6,
                    background:'var(--surface-2)', border:'1px solid var(--border)',
                    borderRadius:'var(--r-md)', padding:'7px 10px', minWidth:0,
                  }}>
                    <span style={{
                      flex:1, minWidth:0, fontSize:10.5, fontFamily:'var(--font-mono)',
                      color:'var(--accent)', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap',
                    }}>{activeSubUrl}</span>
                    <button className="icon-btn-sm" title="Copy" onClick={() => {
                      copyText(activeSubUrl).then(() => pushToast('Subscription URL copied'));
                    }}><Icons.Copy size={12}/></button>
                  </div>
                  <div style={{fontSize:11, color:'var(--muted)'}}>
                    Paste into your client for automatic updates · updates every 12 h
                    {subUrls.length > 1 && <span style={{marginLeft:6, color:'var(--accent)'}}>· {subUrls.length} URLs available</span>}
                  </div>
                  {/* Copy all URLs */}
                  {subUrls.length > 1 && (
                    <button className="btn btn-ghost" style={{fontSize:11, padding:'3px 8px', alignSelf:'flex-start'}}
                      onClick={() => copyText(subUrls.map(s => s.url).join('\n')).then(() => pushToast('All sub URLs copied'))}>
                      <Icons.Copy size={11}/> Copy all
                    </button>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose}>Close</button>
          {allLinks.length > 1 && (
            <button className="btn btn-ghost" onClick={() => {
              const all = allLinks.map(l => l.link).join('\n');
              copyText(all).then(() => pushToast(`${allLinks.length} links copied`));
            }}><Icons.Copy size={14}/> Copy all</button>
          )}
          {activeLink && (
            <button className="btn btn-primary" onClick={() => {
              copyText(activeLink).then(() => pushToast('Config copied to clipboard'));
            }}><Icons.Copy size={14}/> Copy config</button>
          )}
        </div>
      </div>
    </div>
  );
};

// ── Bulk action modal ─────────────────────────────────────────────────────────
const BulkActionModal = ({ action, count, busy, onConfirm, onClose }) => {
  const isExtend    = action === 'extend';
  const isSetExpiry = action === 'set_expiry';
  const isSetTraffic = action === 'set_traffic';

  const [days,    setDays]    = React.useState(30);
  const [date,    setDate]    = React.useState(() => {
    const d = new Date(); d.setMonth(d.getMonth() + 1);
    return d.toISOString().split('T')[0];
  });
  const [gb, setGb] = React.useState(100);

  const title = isExtend ? 'Extend expiry' : isSetExpiry ? 'Set expiry date' : 'Set traffic limit';

  const handleConfirm = () => {
    if (isExtend)     onConfirm(Number(days));
    if (isSetExpiry)  onConfirm(date);
    if (isSetTraffic) onConfirm(Number(gb));
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{maxWidth:380}} onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">{title}</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>Applies to {count} selected user{count !== 1 ? 's' : ''}</div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          {isExtend && (
            <div className="field">
              <label className="field-label">Days to add</label>
              <input className="input" type="number" min={1} value={days}
                onChange={e => setDays(e.target.value)} autoFocus/>
              <span style={{fontSize:11.5, color:'var(--muted)', marginTop:4}}>
                Adds days to current expiry (or from today if already expired)
              </span>
            </div>
          )}
          {isSetExpiry && (
            <div className="field">
              <label className="field-label">New expiry date</label>
              <input className="input" type="date" value={date}
                onChange={e => setDate(e.target.value)} autoFocus/>
            </div>
          )}
          {isSetTraffic && (
            <div className="field">
              <label className="field-label">Traffic limit (GB)</label>
              <input className="input" type="number" min={1} value={gb}
                onChange={e => setGb(e.target.value)} autoFocus/>
              <span style={{fontSize:11.5, color:'var(--muted)', marginTop:4}}>
                Sets a new limit and resets used traffic to 0
              </span>
            </div>
          )}
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose} disabled={busy}>Cancel</button>
          <button className="btn btn-primary" onClick={handleConfirm} disabled={busy}>
            {busy ? 'Applying…' : `Apply to ${count} user${count !== 1 ? 's' : ''}`}
          </button>
        </div>
      </div>
    </div>
  );
};

// ── Renew modal ───────────────────────────────────────────────────────────────
const RenewModal = ({ user, onConfirm, onClose }) => {
  const [days, setDays] = React.useState(30);
  const [busy, setBusy] = React.useState(false);

  const handle = () => {
    setBusy(true);
    Promise.resolve(onConfirm(Number(days))).finally(() => setBusy(false));
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{maxWidth:360}} onClick={e => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">Renew user</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>{user.name}</div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>
        <div className="modal-body">
          <div className="field">
            <label className="field-label">Days to add</label>
            <div style={{display:'flex', gap:6, flexWrap:'wrap', marginBottom:8}}>
              {[7, 14, 30, 60, 90].map(d => (
                <button key={d} onClick={() => setDays(d)}
                  className={days === d ? 'btn btn-primary btn-sm' : 'btn btn-secondary btn-sm'}
                  style={{minWidth:44}}>
                  {d}d
                </button>
              ))}
            </div>
            <input className="input" type="number" min={1} value={days}
              onChange={e => setDays(Number(e.target.value))}/>
            <span style={{fontSize:11.5, color:'var(--muted)', marginTop:4}}>
              Added from today if expired, or appended to current expiry
            </span>
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn btn-ghost" onClick={onClose} disabled={busy}>Cancel</button>
          <button className="btn btn-primary" onClick={handle} disabled={busy}>
            {busy ? 'Renewing…' : `Renew +${days} days`}
          </button>
        </div>
      </div>
    </div>
  );
};

Object.assign(window, { UsersPage, AddUserModal, EditUserModal, QRModal, copyText, InboundPicker });
