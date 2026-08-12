// Inbounds page — full CRUD via /api/inbounds

const NETWORK_OPTIONS = [
  { value: 'tcp',         label: 'TCP',          desc: 'Raw / HTTP header' },
  { value: 'xhttp',       label: 'XHTTP',        desc: 'H2/H3 recommended' },
  { value: 'ws',          label: 'WebSocket',    desc: 'Legacy — use XHTTP' },
  { value: 'grpc',        label: 'gRPC',         desc: 'HTTP/2 multi-stream' },
  { value: 'mkcp',        label: 'mKCP',         desc: 'UDP-based KCP' },
  { value: 'httpupgrade', label: 'HTTP Upgrade', desc: 'HTTP → tunnel' },
];

const SS_METHODS = [
  '2022-blake3-aes-256-gcm',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-chacha20-poly1305',
  'chacha20-ietf-poly1305',
  'aes-256-gcm',
  'aes-128-gcm',
];

const TLS_FINGERPRINTS = ['chrome','firefox','safari','ios','android','edge','qq','random','randomized'];

const PROTO_DISPLAY = {
  vless:'VLESS', vmess:'VMess', trojan:'Trojan',
  shadowsocks:'Shadowsocks', socks:'SOCKS', http:'HTTP'
};

// ── InboundsPage ──────────────────────────────────────────────────────────────
const InboundsPage = ({ pushToast, onInboundsChange }) => {
  const [inbounds, setInbounds] = React.useState([]);
  const [loading, setLoading] = React.useState(true);
  const [showAdd, setShowAdd] = React.useState(false);
  const [editTarget, setEditTarget] = React.useState(null);

  const load = () => {
    fetch('/api/inbounds')
      .then(r => r.json())
      .then(d => {
        setInbounds(d.inbounds || []);
        setLoading(false);
        if (onInboundsChange) onInboundsChange(d.inbounds || []);
      })
      .catch(() => setLoading(false));
  };

  React.useEffect(() => { load(); }, []);

  const toggle = (id, enabled) => {
    fetch(`/api/inbounds/${id}`, {
      method: 'PUT', headers: {'Content-Type':'application/json'},
      body: JSON.stringify({enabled: !enabled})
    })
      .then(r => r.json())
      .then(() => { load(); pushToast('Inbound updated'); })
      .catch(() => pushToast('Update failed'));
  };

  const deleteInbound = (id) => {
    if (!confirm('Delete this inbound?')) return;
    fetch(`/api/inbounds/${id}`, {method:'DELETE'})
      .then(() => { load(); pushToast('Inbound deleted'); })
      .catch(() => pushToast('Delete failed'));
  };

  const secBadge = (ib) => {
    if (ib.tls === 'reality') return <span className="badge info"><Icons.Shield size={10}/> Reality</span>;
    if (ib.tls === 'tls')     return <span className="badge"><span className="dot"/>TLS</span>;
    return null;
  };

  const netLabel = (ib) => {
    const t = ib.transport || ib.network || 'tcp';
    if (t === 'reality') return 'TCP';
    if (t === 'mkcp') return 'KCP';
    if (t === 'httpupgrade') return 'H-UP';
    return t.toUpperCase();
  };

  return (
    <div className="page" data-screen-label="inbounds">
      {/* KPI strip */}
      <div className="inb-kpi-strip">
        {[
          { label:'Total inbounds',   value: inbounds.length,                              sub:`${inbounds.filter(i=>i.enabled).length} enabled`,     icon:'Inbound',  tone:'accent' },
          { label:'Reality-secured',  value: inbounds.filter(i=>i.tls==='reality').length, sub:'VLESS · Reality',                                      icon:'Shield',   tone:'info'   },
          { label:'Active protocols', value: new Set(inbounds.filter(i=>i.enabled).map(i=>i.proto)).size, sub:'across enabled inbounds',               icon:'Activity', tone:'warn'   },
        ].map((s, i) => {
          const Icon = Icons[s.icon];
          return (
            <div key={i} className="card kpi hover">
              <div className="kpi-head">
                <div className={`kpi-icon ${s.tone}`}><Icon size={14}/></div>
                <span>{s.label}</span>
              </div>
              <div className="kpi-value"><Ticker value={s.value}/></div>
              <div style={{fontSize:12, color:'var(--muted)'}}>{s.sub}</div>
            </div>
          );
        })}
      </div>

      <div className="card">
        <div className="section-head">
          <div>
            <div className="section-title">Inbound configurations</div>
            <div className="section-sub">Routing rules for incoming traffic</div>
          </div>
          <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
            <Icons.Plus size={14}/> New inbound
          </button>
        </div>

        {loading && <div style={{padding:40, textAlign:'center', color:'var(--muted)'}}>Loading…</div>}
        {!loading && inbounds.length === 0 && (
          <div style={{padding:40, textAlign:'center', color:'var(--muted)'}}>No inbounds yet.</div>
        )}
        {!loading && inbounds.length > 0 && (
          <div className="inb-card-grid">
            {inbounds.map(ib => (
              <div key={ib.id} style={{
                border:'1px solid var(--border)', borderRadius:'var(--r-lg)',
                background:'var(--surface-2)', padding:14,
                opacity: ib.enabled ? 1 : 0.55,
                transition:'all var(--motion-fast)'
              }}>
                <div style={{display:'flex', alignItems:'flex-start', justifyContent:'space-between', marginBottom:10}}>
                  <div>
                    <div style={{display:'flex', alignItems:'center', gap:6, marginBottom:4, flexWrap:'wrap'}}>
                      <span className={`proto-chip ${(ib.proto||'').toLowerCase()}`}>{ib.proto}</span>
                      {secBadge(ib)}
                    </div>
                    <div style={{fontFamily:'var(--font-mono)', fontWeight:500, fontSize:13.5}}>{ib.tag}</div>
                    {ib.server_addr && (
                      <div style={{fontSize:11, color:'var(--accent)', fontFamily:'var(--font-mono)', marginTop:2}}>
                        {ib.server_addr}{ib.server_port && ib.server_port !== ib.port ? `:${ib.server_port}` : ''}
                      </div>
                    )}
                    {ib.out_server_id && (
                      <div style={{
                        display:'inline-flex', alignItems:'center', gap:4, marginTop:3,
                        fontSize:10.5, padding:'1px 7px', borderRadius:'var(--r-sm)',
                        background:'oklch(72% 0.18 140 / 0.12)',
                        color:'oklch(60% 0.18 140)', fontWeight:600,
                      }}>
                        <span style={{width:5,height:5,borderRadius:'50%',background:'oklch(72% 0.18 140)',display:'inline-block'}}/>
                        Exit via server #{ib.out_server_id}
                      </div>
                    )}
                  </div>
                  <div className={`switch ${ib.enabled ? 'on' : ''}`} onClick={() => toggle(ib.id, ib.enabled)}/>
                </div>
                <div className="inb-stats-row">
                  {[
                    {label:'Port',  value: ib.server_port && ib.server_port !== ib.port ? `${ib.server_port}→${ib.port}` : ib.port},
                    {label:'Net',   value: netLabel(ib)},
                    {label:'Sec',   value: ib.tls || 'none'},
                    {label:'Users', value: ib.user_count || 0},
                  ].map(c => (
                    <div key={c.label}>
                      <div style={{fontSize:10, color:'var(--muted)', textTransform:'uppercase', letterSpacing:'0.08em'}}>{c.label}</div>
                      <div className="num" style={{fontSize:14, marginTop:2}}>{c.value}</div>
                    </div>
                  ))}
                </div>
                <div style={{display:'flex', gap:6, marginTop:14}}>
                  <button className="btn btn-ghost" style={{padding:'5px 10px', fontSize:12}} onClick={() => setEditTarget(ib)}>
                    <Icons.Edit size={12}/> Edit
                  </button>
                  {ib.out_server_id && (
                    <RoutingCheckBtn inboundId={ib.id}/>
                  )}
                  <button className="btn btn-ghost" style={{padding:'5px 10px', fontSize:12, marginLeft:'auto', color:'var(--danger)'}} onClick={() => deleteInbound(ib.id)}>
                    <Icons.Trash size={12}/>
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {showAdd   && <InboundModal onClose={() => setShowAdd(false)}   onSave={() => { load(); setShowAdd(false);   pushToast('Inbound created'); }} pushToast={pushToast}/>}
      {editTarget && <InboundModal inbound={editTarget} onClose={() => setEditTarget(null)} onSave={() => { load(); setEditTarget(null); pushToast('Inbound updated'); }} pushToast={pushToast}/>}
    </div>
  );
};


// ── Routing check button ─────────────────────────────────────────────────────
const RoutingCheckBtn = ({ inboundId }) => {
  const [result,   setResult]   = React.useState(null);
  const [checking, setChecking] = React.useState(false);

  const check = (e) => {
    e.stopPropagation();
    setChecking(true);
    fetch(`/api/inbounds/${inboundId}/routing-check`)
      .then(r => r.json())
      .then(d => { setResult(d); setChecking(false); })
      .catch(() => setChecking(false));
  };

  return (
    <div style={{ position: 'relative', display: 'inline-block' }}>
      <button className="btn btn-ghost" style={{ padding: '5px 10px', fontSize: 12 }} onClick={check} disabled={checking}>
        {checking ? '⏳' : '🔍'} {checking ? 'Checking…' : 'Check route'}
      </button>
      {result && (
        <div style={{
          position: 'absolute', bottom: '110%', left: 0, zIndex: 100,
          background: 'var(--surface)', border: '1px solid var(--border)',
          borderRadius: 'var(--r-md)', padding: '10px 12px', minWidth: 280,
          fontSize: 12, lineHeight: 1.6, boxShadow: '0 4px 16px rgba(0,0,0,0.3)',
        }}>
          <div style={{
            fontWeight: 600, marginBottom: 4,
            color: result.ok ? 'oklch(60% 0.18 140)' : 'var(--danger)',
          }}>{result.message}</div>
          {result.server && (
            <div style={{ color: 'var(--muted)', fontSize: 11.5 }}>
              Server: {result.server.name} ({result.server.ip}:{result.port})<br/>
              Reachable: {result.reachable ? '✅' : '❌'} ·
              Outbound: {result.has_outbound ? '✅' : '❌'} ·
              Rule: {result.has_rule ? '✅' : '❌'}
            </div>
          )}
          <button style={{
            marginTop: 6, fontSize: 10.5, color: 'var(--muted)',
            background: 'none', border: 'none', cursor: 'pointer', padding: 0,
          }} onClick={e => { e.stopPropagation(); setResult(null); }}>✕ close</button>
        </div>
      )}
    </div>
  );
};


// ── InboundModal ──────────────────────────────────────────────────────────────
const InboundModal = ({ inbound, onClose, onSave, pushToast }) => {
  const editing = !!inbound;
  const s0      = inbound?.settings || {};
  const [tab, setTab] = React.useState('Protocol');

  // ── Protocol ──────────────────────────────────────────────────────────────
  const [proto,      setProto]      = React.useState(inbound?.proto      || 'VLESS');
  const [tag,        setTag]        = React.useState(inbound?.tag        || '');
  const [port,       setPort]       = React.useState(inbound?.port       || 443);
  const [listen,     setListen]     = React.useState(s0.listen           || '0.0.0.0');
  const [serverAddr,  setServerAddr]  = React.useState(s0.server_addr  || inbound?.server_addr  || '');
  const [serverPort,  setServerPort]  = React.useState(s0.server_port  || inbound?.server_port  || '');
  const [configName,  setConfigName]  = React.useState(s0.config_name  || inbound?.config_name  || '');
  const [country,     setCountry]     = React.useState((s0.country || inbound?.country || '').toUpperCase());

  // Shadowsocks
  const [ssMethod,   setSsMethod]   = React.useState(inbound?.ss_method   || '2022-blake3-aes-256-gcm');
  const [ssPassword, setSsPassword] = React.useState(inbound?.ss_password || '');

  // SOCKS
  const [socksAuth,     setSocksAuth]     = React.useState(s0.auth || 'noauth');
  const [socksUdp,      setSocksUdp]      = React.useState(s0.udp  || false);
  const [socksIp,       setSocksIp]       = React.useState(s0.ip   || '');
  const [socksAccounts, setSocksAccounts] = React.useState((s0.accounts||[]).length ? s0.accounts : [{user:'',pass:''}]);

  // HTTP
  const [httpAccounts,        setHttpAccounts]        = React.useState((s0.http_accounts||[]).length ? s0.http_accounts : [{user:'',pass:''}]);
  const [httpAllowTransparent,setHttpAllowTransparent]= React.useState(s0.allow_transparent || false);

  // ── Transport ─────────────────────────────────────────────────────────────
  // resolve stored transport back to a network value
  const rawNet = (inbound?.transport === 'reality' ? 'tcp' : (inbound?.transport || inbound?.network || 'tcp'));
  const [network, setNetwork] = React.useState(rawNet);

  // TCP
  const [tcpAcceptProxy, setTcpAcceptProxy] = React.useState(s0.accept_proxy_protocol || false);
  const [tcpHeaderType,  setTcpHeaderType]  = React.useState(s0.tcp_header_type || 'none');
  const [tcpHeaderPath,  setTcpHeaderPath]  = React.useState(s0.tcp_header_path || '/');
  const [tcpHeaderHost,  setTcpHeaderHost]  = React.useState(s0.tcp_header_host || '');

  // WS
  const [wsPath,        setWsPath]        = React.useState(s0.ws_path || inbound?.ws_path || '/');
  const [wsHost,        setWsHost]        = React.useState(s0.ws_host || '');
  const [wsHeartbeat,   setWsHeartbeat]   = React.useState(s0.ws_heartbeat || 0);
  const [wsAcceptProxy, setWsAcceptProxy] = React.useState(s0.accept_proxy_protocol || false);

  // gRPC
  const [grpcService,   setGrpcService]   = React.useState(s0.grpc_service   || 'xray');
  const [grpcAuthority, setGrpcAuthority] = React.useState(s0.grpc_authority || '');
  const [grpcMultiMode, setGrpcMultiMode] = React.useState(s0.grpc_multi_mode || false);

  // mKCP
  const [kcpMtu,       setKcpMtu]       = React.useState(s0.kcp_mtu       || 1350);
  const [kcpTti,       setKcpTti]       = React.useState(s0.kcp_tti       || 50);
  const [kcpUplink,    setKcpUplink]    = React.useState(s0.kcp_uplink    || 5);
  const [kcpDownlink,  setKcpDownlink]  = React.useState(s0.kcp_downlink  || 20);
  const [kcpCongestion,setKcpCongestion]= React.useState(s0.kcp_congestion || false);
  const [kcpReadBuf,   setKcpReadBuf]   = React.useState(s0.kcp_read_buf  || 2);
  const [kcpWriteBuf,  setKcpWriteBuf]  = React.useState(s0.kcp_write_buf || 2);

  // HTTPUpgrade
  const [huPath,        setHuPath]        = React.useState(s0.hu_path         || '/');
  const [huHost,        setHuHost]        = React.useState(s0.hu_host         || '');
  const [huAcceptProxy, setHuAcceptProxy] = React.useState(s0.hu_accept_proxy || false);

  // XHTTP (H2/H3 — recommended replacement for WebSocket)
  const [xhttpPath,  setXhttpPath]  = React.useState(s0.xhttp_path  || inbound?.xhttp_path  || '/');
  const [xhttpHost,  setXhttpHost]  = React.useState(s0.xhttp_host  || inbound?.xhttp_host  || '');
  const [xhttpMode,  setXhttpMode]  = React.useState(s0.xhttp_mode  || inbound?.xhttp_mode  || 'auto');
  const [xhttpExtra, setXhttpExtra] = React.useState(s0.xhttp_extra || inbound?.xhttp_extra || '');

  // ── Security ──────────────────────────────────────────────────────────────
  const [security, setSecurity] = React.useState(inbound?.tls || 'none');

  // TLS
  const [certFile,         setCertFile]         = React.useState(s0.cert_file        || '');
  const [keyFile,          setKeyFile]          = React.useState(s0.key_file         || '');
  const [tlsServerName,    setTlsServerName]    = React.useState(s0.tls_server_name  || '');
  const [tlsAlpn,          setTlsAlpn]          = React.useState(s0.alpn             || 'h2,http/1.1');
  const [tlsFingerprint,   setTlsFingerprint]   = React.useState(s0.fingerprint      || '');
  const [tlsRejectUnknown, setTlsRejectUnknown] = React.useState(s0.reject_unknown_sni || false);

  // Reality
  const [realitySni,  setRealitySni]  = React.useState(inbound?.sni || s0.sni || 'www.cloudflare.com');
  const [realityDest, setRealityDest] = React.useState(s0.dest || 'www.cloudflare.com:443');
  const [privateKey,  setPrivateKey]  = React.useState(inbound?.private_key || s0.private_key || '');
  const [publicKey,   setPublicKey]   = React.useState(inbound?.public_key  || s0.public_key  || '');
  const [shortId,     setShortId]     = React.useState(inbound?.short_id    || s0.short_id    || '');
  const [realityFp,   setRealityFp]   = React.useState(s0.fingerprint || 'chrome');

  // ── Sniffing ──────────────────────────────────────────────────────────────
  const [sniffEnabled,   setSniffEnabled]   = React.useState(s0.sniffing_enabled || false);
  const [sniffHttp,      setSniffHttp]      = React.useState(s0.sniff_http !== false);
  const [sniffTls,       setSniffTls]       = React.useState(s0.sniff_tls  !== false);
  const [sniffQuic,      setSniffQuic]      = React.useState(s0.sniff_quic    || false);
  const [sniffFakedns,   setSniffFakedns]   = React.useState(s0.sniff_fakedns  || false);
  const [sniffRouteOnly, setSniffRouteOnly] = React.useState(s0.sniff_route_only || false);

  const [outServerId,     setOutServerId]     = React.useState(String(s0.out_server_id || inbound?.out_server_id || ''));
  const [outServers,      setOutServers]      = React.useState([]);
  const [outServerStatus, setOutServerStatus] = React.useState(null); // null | {ok, uuid, port, message}
  const [checkingOut,     setCheckingOut]     = React.useState(false);
  const [saving, setSaving] = React.useState(false);

  // ── Access control ────────────────────────────────────────────────────────
  const [accessMode,      setAccessMode]    = React.useState(inbound?.access_mode    || 'none');
  const [accessDomains,   setAccessDomains] = React.useState((inbound?.access_domains || []).join('\n'));
  const [accessIps,       setAccessIps]     = React.useState((inbound?.access_ips     || []).join('\n'));

  // Load OUT servers for the exit-IP picker
  React.useEffect(() => {
    fetch('/api/servers')
      .then(r => r.json())
      .then(d => setOutServers((d.servers || []).filter(s => ['out','both'].includes(s.server_type || 'out'))))
      .catch(() => {});
  }, []);

  // Check out server readiness whenever selection changes
  React.useEffect(() => {
    if (!outServerId) { setOutServerStatus(null); return; }
    setCheckingOut(true);
    fetch(`/api/servers/${outServerId}/out-proxy`)
      .then(r => r.json())
      .then(d => {
        setOutServerStatus({
          ready:    !!d.out_proxy_uuid,
          uuid:     d.out_proxy_uuid || '',
          port:     d.out_proxy_port || 10001,
          protocol: d.out_proxy_protocol || 'vless',
          script_url: d.script_url || '',
        });
        setCheckingOut(false);
      })
      .catch(() => { setCheckingOut(false); });
  }, [outServerId]);

  // Reality requires TCP
  React.useEffect(() => { if (security === 'reality' && network !== 'tcp') setNetwork('tcp'); }, [security]);
  React.useEffect(() => { if (network !== 'tcp' && security === 'reality') setSecurity('none'); }, [network]);

  // ── Helpers ───────────────────────────────────────────────────────────────
  const genKeys = () => {
    fetch('/api/generate-keys').then(r => r.json()).then(d => {
      if (d.error) { pushToast('Key gen failed: ' + d.error); return; }
      setPrivateKey(d.private_key); setPublicKey(d.public_key);
      pushToast('Keys generated');
    }).catch(() => pushToast('Key generation failed'));
  };

  const genUUID = () => fetch('/api/uuid').then(r=>r.json()).then(d => setSsPassword(d.uuid));

  const genShortId = () => {
    const h = '0123456789abcdef';
    setShortId(Array.from({length:8}, ()=>h[Math.floor(Math.random()*16)]).join(''));
  };

  const addAccount   = (set) => set(p => [...p, {user:'',pass:''}]);
  const removeAccount= (set, i) => set(p => p.filter((_,j) => j!==i));
  const updateAccount= (set, i, f, v) => set(p => p.map((a,j) => j===i ? {...a,[f]:v} : a));

  const save = () => {
    if (!tag || !port) return;
    setSaving(true);
    const body = {
      proto, tag, port: Number(port), listen, server_addr: serverAddr,
      server_port: serverPort ? Number(serverPort) : 0,
      config_name: configName,
      country: (country || '').trim().toUpperCase().slice(0, 2),
      out_server_id: outServerId || null,
      network, tls: security,
      // TCP
      accept_proxy_protocol: tcpAcceptProxy || wsAcceptProxy,
      tcp_header_type: tcpHeaderType, tcp_header_path: tcpHeaderPath, tcp_header_host: tcpHeaderHost,
      // WS
      ws_path: wsPath, ws_host: wsHost, ws_heartbeat: Number(wsHeartbeat),
      // gRPC
      grpc_service: grpcService, grpc_authority: grpcAuthority, grpc_multi_mode: grpcMultiMode,
      // mKCP
      kcp_mtu: Number(kcpMtu), kcp_tti: Number(kcpTti),
      kcp_uplink: Number(kcpUplink), kcp_downlink: Number(kcpDownlink),
      kcp_congestion: kcpCongestion, kcp_read_buf: Number(kcpReadBuf), kcp_write_buf: Number(kcpWriteBuf),
      // HTTPUpgrade
      hu_path: huPath, hu_host: huHost, hu_accept_proxy: huAcceptProxy,
      // XHTTP
      xhttp_path: xhttpPath, xhttp_host: xhttpHost, xhttp_mode: xhttpMode, xhttp_extra: xhttpExtra,
      // TLS
      cert_file: certFile, key_file: keyFile,
      tls_server_name: tlsServerName, alpn: tlsAlpn,
      fingerprint: security === 'reality' ? realityFp : tlsFingerprint,
      reject_unknown_sni: tlsRejectUnknown,
      // Reality
      sni: realitySni, dest: realityDest,
      private_key: privateKey, public_key: publicKey, short_id: shortId,
      // Sniffing
      sniffing_enabled: sniffEnabled,
      sniff_http: sniffHttp, sniff_tls: sniffTls,
      sniff_quic: sniffQuic, sniff_fakedns: sniffFakedns,
      sniff_route_only: sniffRouteOnly,
      // Shadowsocks
      ss_method: ssMethod, ss_password: ssPassword,
      // SOCKS
      auth: socksAuth, udp: socksUdp, ip: socksIp,
      accounts: socksAuth === 'password' ? socksAccounts : [],
      // HTTP
      http_accounts: httpAccounts,
      allow_transparent: httpAllowTransparent,
      // Access control
      access_mode:    accessMode,
      access_domains: accessDomains.split('\n').map(s=>s.trim()).filter(Boolean),
      access_ips:     accessIps.split('\n').map(s=>s.trim()).filter(Boolean),
    };
    const url = editing ? `/api/inbounds/${inbound.id}` : '/api/inbounds';
    fetch(url, { method: editing ? 'PUT' : 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) })
      .then(r => r.json())
      .then(d => { setSaving(false); if (d.error) pushToast(d.error); else onSave(); })
      .catch(() => setSaving(false));
  };

  const TABS = ['Protocol', 'Transport', 'Security', 'Sniffing', 'Access'];
  const tabDot = (t) => {
    if (t === 'Protocol' && !tag) return true;
    if (t === 'Security' && security === 'tls' && !certFile && !keyFile) return true;
    if (t === 'Security' && security === 'reality' && (!privateKey || !publicKey)) return true;
    return false;
  };

  // ── Section box helper ────────────────────────────────────────────────────
  const Section = ({children, style}) => (
    <div style={{
      background:'var(--surface-2)', border:'1px solid var(--border)',
      borderRadius:'var(--r-lg)', padding:'12px 14px',
      display:'flex', flexDirection:'column', gap:10, ...style
    }}>{children}</div>
  );

  const ToggleRow = ({label, desc, value, onChange}) => (
    <div style={{display:'flex', alignItems:'center', justifyContent:'space-between',
      padding:'8px 10px', background:'var(--bg)', borderRadius:'var(--r-md)', border:'1px solid var(--border-soft)'}}>
      <div>
        <div style={{fontSize:12.5, fontWeight:500}}>{label}</div>
        {desc && <div style={{fontSize:11.5, color:'var(--muted)', marginTop:1}}>{desc}</div>}
      </div>
      <div className={`switch ${value ? 'on' : ''}`} onClick={onChange}/>
    </div>
  );

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{maxWidth:560}} onClick={e => e.stopPropagation()}>

        {/* Head */}
        <div className="modal-head">
          <div>
            <div className="modal-title">{editing ? 'Edit inbound' : 'New inbound'}</div>
            <div style={{fontSize:12, color:'var(--muted)', marginTop:2}}>
              {editing
                ? <span className="mono" style={{fontSize:11}}>{inbound.tag}</span>
                : 'Protocol · Transport · Security · Sniffing'}
            </div>
          </div>
          <button className="icon-btn-sm" onClick={onClose}><Icons.X size={15}/></button>
        </div>

        {/* Tab bar */}
        <div style={{display:'flex', borderBottom:'1px solid var(--border)', padding:'0 18px', background:'var(--surface)'}}>
          {TABS.map(t => (
            <button key={t} onClick={() => setTab(t)} style={{
              padding:'9px 14px', fontSize:12.5, fontWeight: tab===t ? 600 : 400,
              color: tab===t ? 'var(--accent)' : 'var(--text-2)',
              background:'none', border:'none', cursor:'pointer',
              borderBottom: tab===t ? '2px solid var(--accent)' : '2px solid transparent',
              marginBottom:-1, position:'relative', whiteSpace:'nowrap'
            }}>
              {t}
              {tabDot(t) && <span style={{
                position:'absolute', top:7, right:4, width:5, height:5,
                borderRadius:'50%', background:'var(--warn)'
              }}/>}
            </button>
          ))}
        </div>

        {/* Body */}
        <div className="modal-body" style={{maxHeight:'58vh', overflowY:'auto'}}>

          {/* ════════════════════════════════ PROTOCOL tab ══════════════════ */}
          {tab === 'Protocol' && (<>

            <div className="field">
              <label className="field-label">Protocol</label>
              <div className="proto-pick">
                {INBOUND_PROTOCOLS.map(p => (
                  <button key={p} className={proto===p?'active':''} onClick={() => setProto(p)}>{p}</button>
                ))}
              </div>
            </div>

            <div className="field-row">
              <div className="field">
                <label className="field-label">Tag / name</label>
                <input className="input mono" placeholder="vless-reality-443" value={tag} onChange={e=>setTag(e.target.value)} autoFocus/>
              </div>
              <div className="field">
                <label className="field-label">Port</label>
                <input className="input mono" type="number" min={1} max={65535} value={port} onChange={e=>setPort(e.target.value)}/>
              </div>
            </div>

            <div className="field-row">
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">Listen address</label>
                <input className="input mono" placeholder="0.0.0.0" value={listen} onChange={e=>setListen(e.target.value)}/>
                <span className="field-hint">0.0.0.0 = all interfaces</span>
              </div>
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">Server address (for links)</label>
                <input className="input mono" placeholder="e.g. cdn.example.com" value={serverAddr} onChange={e=>setServerAddr(e.target.value)}/>
                <span className="field-hint">Domain or IP used in client links · overrides global server IP</span>
              </div>
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">Link port override</label>
                <input className="input mono" type="number" placeholder={`${port} (same as listen port)`} value={serverPort} onChange={e=>setServerPort(e.target.value)}/>
                <span className="field-hint">Port shown in user configs — use the IN server's listen port when behind a tunnel</span>
              </div>
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">Server location (country code)</label>
                <input className="input mono" maxLength={2} placeholder="DE"
                  style={{textTransform:'uppercase'}}
                  value={country}
                  onChange={e=>setCountry(e.target.value.toUpperCase().replace(/[^A-Z]/g,'').slice(0,2))}/>
                <span className="field-hint">
                  Two-letter ISO code (DE, NL, US, TR…). The client apps use it for the
                  flag and to place this server on the world map. Leave blank to let the
                  panel guess from the IP.
                </span>
              </div>
              <div className="field" style={{marginBottom:0}}>
                <label className="field-label">Config name in subscription</label>
                <input className="input" placeholder="{username} | {remain_data} left" value={configName} onChange={e=>setConfigName(e.target.value)}/>
                <span className="field-hint">
                  Leave blank to use the username.&nbsp;
                  Variables: <code style={{fontSize:10.5}}>{'{username}'}</code>&nbsp;
                  <code style={{fontSize:10.5}}>{'{remain_data}'}</code>&nbsp;
                  <code style={{fontSize:10.5}}>{'{remain_days}'}</code>&nbsp;
                  <code style={{fontSize:10.5}}>{'{traffic_limit}'}</code>
                </span>
              </div>
            </div>

            {/* Out server (exit IP) picker */}
            <div className="field" style={{marginBottom:0}}>
              <label className="field-label">Exit IP / Out server</label>
              <select className="select" value={outServerId} onChange={e => setOutServerId(e.target.value)}>
                <option value="">— Default (panel's own IP) —</option>
                {outServers.map(s => (
                  <option key={s.id} value={String(s.id)}>
                    {s.name} ({s.ip})
                  </option>
                ))}
              </select>
              <span className="field-hint">
                Traffic from this inbound exits via the selected server's IP. Leave blank to use the panel's own IP.
              </span>

              {/* Out server status indicator */}
              {outServerId && (
                <div style={{ marginTop: 6 }}>
                  {checkingOut ? (
                    <div style={{ fontSize: 12, color: 'var(--muted)' }}>Checking server…</div>
                  ) : outServerStatus?.ready ? (
                    <div style={{
                      fontSize: 11.5, padding: '8px 12px', borderRadius: 'var(--r-md)',
                      background: 'oklch(72% 0.18 140 / 0.07)',
                      border: '1px solid oklch(72% 0.18 140 / 0.3)',
                      color: 'oklch(55% 0.18 140)', lineHeight: 1.6,
                    }}>
                      ✅ Bridge configured —&nbsp;
                      <span style={{ fontFamily: 'var(--font-mono)' }}>
                        {outServerStatus.protocol?.toUpperCase()} :{outServerStatus.port}
                      </span>
                      &nbsp;· UUID: <span style={{ fontFamily: 'var(--font-mono)' }}>
                        {outServerStatus.uuid?.slice(0, 8)}…
                      </span>
                    </div>
                  ) : (
                    <div style={{
                      fontSize: 11.5, padding: '8px 12px', borderRadius: 'var(--r-md)',
                      background: 'oklch(68% 0.20 25 / 0.08)',
                      border: '1px solid oklch(68% 0.20 25 / 0.3)',
                      color: 'var(--danger)', lineHeight: 1.7,
                    }}>
                      ⚠️ Xray bridge not yet configured on this server.<br/>
                      <span style={{ color: 'var(--text-2)' }}>
                        Go to <strong>Servers</strong> → find this server → expand <strong>Xray bridge</strong>
                        → copy the install command, run it on the server, then click <strong>Activate</strong>.
                      </span>
                    </div>
                  )}
                </div>
              )}
            </div>

            {/* Shadowsocks */}
            {proto === 'Shadowsocks' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>Shadowsocks</div>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label">Cipher method</label>
                  <select className="select" value={ssMethod} onChange={e=>setSsMethod(e.target.value)}>
                    {SS_METHODS.map(m=><option key={m} value={m}>{m}</option>)}
                  </select>
                </div>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label" style={{display:'flex',alignItems:'center',justifyContent:'space-between'}}>
                    <span>Password / PSK</span>
                    <button className="btn btn-ghost" style={{padding:'2px 8px',fontSize:11}} onClick={genUUID}>
                      <Icons.Refresh size={11}/> Generate
                    </button>
                  </label>
                  <input className="input mono" placeholder="pre-shared key" value={ssPassword} onChange={e=>setSsPassword(e.target.value)}/>
                </div>
              </Section>
            )}

            {/* SOCKS */}
            {proto === 'SOCKS' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>SOCKS proxy</div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Authentication</label>
                    <select className="select" value={socksAuth} onChange={e=>setSocksAuth(e.target.value)}>
                      <option value="noauth">No auth (open)</option>
                      <option value="password">Username / password</option>
                    </select>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">UDP relay</label>
                    <div style={{display:'flex',alignItems:'center',gap:8,paddingTop:6}}>
                      <div className={`switch ${socksUdp?'on':''}`} onClick={()=>setSocksUdp(v=>!v)}/>
                      <span style={{fontSize:12,color:'var(--muted)'}}>Enable UDP</span>
                    </div>
                  </div>
                </div>
                {socksUdp && (
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Local UDP IP (for NAT)</label>
                    <input className="input mono" placeholder="127.0.0.1" value={socksIp} onChange={e=>setSocksIp(e.target.value)}/>
                  </div>
                )}
                {socksAuth === 'password' && (
                  <div>
                    <label className="field-label" style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:6}}>
                      <span>Accounts</span>
                      <button className="btn btn-ghost" style={{padding:'2px 8px',fontSize:11}} onClick={()=>addAccount(setSocksAccounts)}>
                        <Icons.Plus size={11}/> Add
                      </button>
                    </label>
                    {socksAccounts.map((a,i)=>(
                      <div key={i} style={{display:'flex',gap:6,marginBottom:6,alignItems:'center'}}>
                        <input className="input mono" style={{flex:1}} placeholder="username" value={a.user} onChange={e=>updateAccount(setSocksAccounts,i,'user',e.target.value)}/>
                        <input className="input mono" style={{flex:1}} placeholder="password" type="password" value={a.pass} onChange={e=>updateAccount(setSocksAccounts,i,'pass',e.target.value)}/>
                        {socksAccounts.length > 1 && <button className="icon-btn-sm danger" onClick={()=>removeAccount(setSocksAccounts,i)}><Icons.Trash size={12}/></button>}
                      </div>
                    ))}
                  </div>
                )}
              </Section>
            )}

            {/* HTTP */}
            {proto === 'HTTP' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>HTTP proxy</div>
                <ToggleRow
                  label="Transparent mode"
                  desc="Forward all HTTP requests, not just CONNECT proxy requests"
                  value={httpAllowTransparent}
                  onChange={()=>setHttpAllowTransparent(v=>!v)}
                />
                <div>
                  <label className="field-label" style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginBottom:6}}>
                    <span>Basic auth accounts <span style={{color:'var(--muted)',fontWeight:400}}>(optional — leave empty for open proxy)</span></span>
                    <button className="btn btn-ghost" style={{padding:'2px 8px',fontSize:11}} onClick={()=>addAccount(setHttpAccounts)}>
                      <Icons.Plus size={11}/> Add
                    </button>
                  </label>
                  {httpAccounts.map((a,i)=>(
                    <div key={i} style={{display:'flex',gap:6,marginBottom:6,alignItems:'center'}}>
                      <input className="input mono" style={{flex:1}} placeholder="username" value={a.user} onChange={e=>updateAccount(setHttpAccounts,i,'user',e.target.value)}/>
                      <input className="input mono" style={{flex:1}} placeholder="password" type="password" value={a.pass} onChange={e=>updateAccount(setHttpAccounts,i,'pass',e.target.value)}/>
                      {httpAccounts.length > 1 && <button className="icon-btn-sm danger" onClick={()=>removeAccount(setHttpAccounts,i)}><Icons.Trash size={12}/></button>}
                    </div>
                  ))}
                </div>
              </Section>
            )}

          </>)}

          {/* ════════════════════════════════ TRANSPORT tab ═════════════════ */}
          {tab === 'Transport' && (<>

            <div className="field">
              <label className="field-label">Network transport</label>
              <div style={{display:'grid',gridTemplateColumns:'repeat(3,1fr)',gap:8}}>
                {NETWORK_OPTIONS.map(n=>(
                  <button key={n.value} onClick={()=>setNetwork(n.value)} style={{
                    padding:'9px 6px', borderRadius:'var(--r-md)', fontSize:12,
                    fontWeight: network===n.value ? 600 : 400,
                    border: network===n.value ? '1.5px solid var(--accent)' : '1px solid var(--border)',
                    background: network===n.value ? 'var(--accent-tint)' : 'var(--surface-2)',
                    color: network===n.value ? 'var(--accent)' : 'var(--text)',
                    cursor:'pointer', textAlign:'center', transition:'all var(--motion-fast)'
                  }}>
                    <div style={{fontWeight:600}}>{n.label}</div>
                    <div style={{fontSize:10, color:'var(--muted)', marginTop:2}}>{n.desc}</div>
                  </button>
                ))}
              </div>
            </div>

            {/* TCP */}
            {network === 'tcp' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>TCP / RAW settings</div>
                <ToggleRow label="Accept PROXY protocol" desc="Read real client IP from upstream load balancer" value={tcpAcceptProxy} onChange={()=>setTcpAcceptProxy(v=>!v)}/>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label">Header obfuscation</label>
                  <select className="select" value={tcpHeaderType} onChange={e=>setTcpHeaderType(e.target.value)}>
                    <option value="none">None (plain TCP)</option>
                    <option value="http">HTTP (mimic HTTP traffic)</option>
                  </select>
                </div>
                {tcpHeaderType === 'http' && (
                  <div className="field-row" style={{marginBottom:0}}>
                    <div className="field" style={{marginBottom:0}}>
                      <label className="field-label">Fake path</label>
                      <input className="input mono" placeholder="/api" value={tcpHeaderPath} onChange={e=>setTcpHeaderPath(e.target.value)}/>
                    </div>
                    <div className="field" style={{marginBottom:0}}>
                      <label className="field-label">Fake host</label>
                      <input className="input mono" placeholder="example.com" value={tcpHeaderHost} onChange={e=>setTcpHeaderHost(e.target.value)}/>
                    </div>
                  </div>
                )}
              </Section>
            )}

            {/* XHTTP */}
            {network === 'xhttp' && (
              <Section>
                <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:2}}>
                  <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>XHTTP settings</div>
                  <span style={{fontSize:11, background:'oklch(72% 0.14 175 / 0.15)', color:'oklch(72% 0.14 175)', borderRadius:4, padding:'1px 6px'}}>Recommended — replaces WebSocket</span>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Path</label>
                    <input className="input mono" placeholder="/" value={xhttpPath} onChange={e=>setXhttpPath(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Host</label>
                    <input className="input mono" placeholder="cdn.example.com" value={xhttpHost} onChange={e=>setXhttpHost(e.target.value)}/>
                  </div>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Mode</label>
                    <select className="input" value={xhttpMode} onChange={e=>setXhttpMode(e.target.value)}>
                      {['auto','stream-up','stream-one','packet-up'].map(m => <option key={m} value={m}>{m}</option>)}
                    </select>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Extra JSON (optional)</label>
                    <input className="input mono" placeholder='{"noGRPCHeader":false}' value={xhttpExtra} onChange={e=>setXhttpExtra(e.target.value)}/>
                  </div>
                </div>
              </Section>
            )}

            {/* WebSocket */}
            {network === 'ws' && (
              <Section>
                <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:2}}>
                  <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>WebSocket settings</div>
                  <span style={{fontSize:11, background:'oklch(70% 0.18 30 / 0.12)', color:'oklch(65% 0.18 30)', borderRadius:4, padding:'1px 6px'}}>Deprecated — migrate to XHTTP</span>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Path</label>
                    <input className="input mono" placeholder="/ws" value={wsPath} onChange={e=>setWsPath(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Host header</label>
                    <input className="input mono" placeholder="cdn.example.com" value={wsHost} onChange={e=>setWsHost(e.target.value)}/>
                  </div>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Heartbeat (s, 0=off)</label>
                    <input className="input mono" type="number" min={0} value={wsHeartbeat} onChange={e=>setWsHeartbeat(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">PROXY protocol</label>
                    <div style={{display:'flex',alignItems:'center',gap:8,paddingTop:6}}>
                      <div className={`switch ${wsAcceptProxy?'on':''}`} onClick={()=>setWsAcceptProxy(v=>!v)}/>
                      <span style={{fontSize:12,color:'var(--muted)'}}>Accept upstream</span>
                    </div>
                  </div>
                </div>
              </Section>
            )}

            {/* gRPC */}
            {network === 'grpc' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>gRPC settings</div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Service name</label>
                    <input className="input mono" placeholder="xray" value={grpcService} onChange={e=>setGrpcService(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Authority (Host)</label>
                    <input className="input mono" placeholder="cdn.example.com" value={grpcAuthority} onChange={e=>setGrpcAuthority(e.target.value)}/>
                  </div>
                </div>
                <ToggleRow label="Multi-mode (experimental)" desc="~20% throughput gain via multiplexed streams" value={grpcMultiMode} onChange={()=>setGrpcMultiMode(v=>!v)}/>
              </Section>
            )}

            {/* mKCP */}
            {network === 'mkcp' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>mKCP settings</div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">MTU (576–1460)</label>
                    <input className="input mono" type="number" min={576} max={1460} value={kcpMtu} onChange={e=>setKcpMtu(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">TTI ms (10–100)</label>
                    <input className="input mono" type="number" min={10} max={100} value={kcpTti} onChange={e=>setKcpTti(e.target.value)}/>
                  </div>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Uplink cap MB/s</label>
                    <input className="input mono" type="number" min={1} value={kcpUplink} onChange={e=>setKcpUplink(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Downlink cap MB/s</label>
                    <input className="input mono" type="number" min={1} value={kcpDownlink} onChange={e=>setKcpDownlink(e.target.value)}/>
                  </div>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Read buffer MB</label>
                    <input className="input mono" type="number" min={1} value={kcpReadBuf} onChange={e=>setKcpReadBuf(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Write buffer MB</label>
                    <input className="input mono" type="number" min={1} value={kcpWriteBuf} onChange={e=>setKcpWriteBuf(e.target.value)}/>
                  </div>
                </div>
                <ToggleRow label="Congestion control" desc="Auto-adjust throughput based on network quality" value={kcpCongestion} onChange={()=>setKcpCongestion(v=>!v)}/>
              </Section>
            )}

            {/* HTTPUpgrade */}
            {network === 'httpupgrade' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>HTTP Upgrade settings</div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Path</label>
                    <input className="input mono" placeholder="/" value={huPath} onChange={e=>setHuPath(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Host header</label>
                    <input className="input mono" placeholder="cdn.example.com" value={huHost} onChange={e=>setHuHost(e.target.value)}/>
                  </div>
                </div>
                <ToggleRow label="Accept PROXY protocol" desc="Read real client IP from upstream proxy" value={huAcceptProxy} onChange={()=>setHuAcceptProxy(v=>!v)}/>
                <div style={{fontSize:11.5, color:'var(--muted)', padding:'5px 8px', background:'var(--bg)', borderRadius:'var(--r-sm)', border:'1px solid var(--border-soft)'}}>
                  💡 Works well behind nginx/Cloudflare. Add TLS in the Security tab.
                </div>
              </Section>
            )}

          </>)}

          {/* ════════════════════════════════ SECURITY tab ══════════════════ */}
          {tab === 'Security' && (<>

            <div className="field">
              <label className="field-label">Security type</label>
              <div className="proto-pick">
                {['none','tls','reality'].map(s => (
                  <button key={s}
                    className={security===s?'active':''}
                    disabled={s==='reality' && network!=='tcp'}
                    onClick={()=>setSecurity(s)}
                    style={s==='reality' && network!=='tcp' ? {opacity:0.4, cursor:'not-allowed'} : {}}
                  >
                    {s==='none'?'None':s==='tls'?'TLS':'Reality'}
                  </button>
                ))}
              </div>
              {security === 'reality' && network !== 'tcp' && (
                <span className="field-hint" style={{color:'var(--warn)'}}>⚠ Reality only works with TCP transport</span>
              )}
            </div>

            {/* None */}
            {security === 'none' && (
              <div style={{padding:'20px', textAlign:'center', color:'var(--muted)', fontSize:12.5,
                background:'var(--surface-2)', borderRadius:'var(--r-lg)', border:'1px solid var(--border)'}}>
                No transport encryption. Use for local proxies or when TLS is terminated upstream by nginx / CDN.
              </div>
            )}

            {/* TLS */}
            {security === 'tls' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>TLS certificate</div>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label">Certificate file (.crt / .pem)</label>
                  <input className="input mono" placeholder="/etc/letsencrypt/live/domain/fullchain.pem" value={certFile} onChange={e=>setCertFile(e.target.value)}/>
                </div>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label">Private key file (.key / .pem)</label>
                  <input className="input mono" placeholder="/etc/letsencrypt/live/domain/privkey.pem" value={keyFile} onChange={e=>setKeyFile(e.target.value)}/>
                </div>
                <span className="field-hint">Leave blank to use the global cert in <b>Settings → TLS / Certs</b></span>
                <div style={{borderTop:'1px dashed var(--border)', paddingTop:10, display:'flex', flexDirection:'column', gap:10}}>
                  <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>TLS options</div>
                  <div className="field-row" style={{marginBottom:0}}>
                    <div className="field" style={{marginBottom:0}}>
                      <label className="field-label">SNI override (serverName)</label>
                      <input className="input mono" placeholder="example.com" value={tlsServerName} onChange={e=>setTlsServerName(e.target.value)}/>
                    </div>
                    <div className="field" style={{marginBottom:0}}>
                      <label className="field-label">ALPN (comma-sep)</label>
                      <input className="input mono" placeholder="h2,http/1.1" value={tlsAlpn} onChange={e=>setTlsAlpn(e.target.value)}/>
                    </div>
                  </div>
                  <div className="field-row" style={{marginBottom:0}}>
                    <div className="field" style={{marginBottom:0}}>
                      <label className="field-label">Browser fingerprint</label>
                      <select className="select" value={tlsFingerprint} onChange={e=>setTlsFingerprint(e.target.value)}>
                        <option value="">None</option>
                        {TLS_FINGERPRINTS.map(f=><option key={f} value={f}>{f}</option>)}
                      </select>
                    </div>
                    <div className="field" style={{marginBottom:0}}>
                      <label className="field-label">Reject unknown SNI</label>
                      <div style={{display:'flex',alignItems:'center',gap:8,paddingTop:6}}>
                        <div className={`switch ${tlsRejectUnknown?'on':''}`} onClick={()=>setTlsRejectUnknown(v=>!v)}/>
                        <span style={{fontSize:12,color:'var(--muted)'}}>Drop mismatched</span>
                      </div>
                    </div>
                  </div>
                </div>
              </Section>
            )}

            {/* Reality */}
            {security === 'reality' && (
              <Section>
                <div style={{fontSize:12, fontWeight:700, color:'var(--text-2)', textTransform:'uppercase', letterSpacing:'0.07em'}}>Reality settings</div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Destination (dest)</label>
                    <input className="input mono" placeholder="www.cloudflare.com:443" value={realityDest} onChange={e=>setRealityDest(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Server name (SNI)</label>
                    <input className="input mono" placeholder="www.cloudflare.com" value={realitySni} onChange={e=>setRealitySni(e.target.value)}/>
                  </div>
                </div>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label" style={{display:'flex',alignItems:'center',justifyContent:'space-between'}}>
                    <span>Private key (x25519)</span>
                    <button className="btn btn-ghost" style={{padding:'2px 8px',fontSize:11}} onClick={genKeys}>
                      <Icons.Key size={11}/> Generate pair
                    </button>
                  </label>
                  <input className="input mono" placeholder="x25519 private key" value={privateKey} onChange={e=>setPrivateKey(e.target.value)}/>
                </div>
                <div className="field" style={{marginBottom:0}}>
                  <label className="field-label">Public key (x25519)</label>
                  <input className="input mono" placeholder="auto-filled by Generate pair" value={publicKey} onChange={e=>setPublicKey(e.target.value)}/>
                </div>
                <div className="field-row" style={{marginBottom:0}}>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label" style={{display:'flex',alignItems:'center',justifyContent:'space-between'}}>
                      <span>Short ID</span>
                      <button className="btn btn-ghost" style={{padding:'2px 6px',fontSize:10}} onClick={genShortId}>
                        <Icons.Refresh size={10}/> Random
                      </button>
                    </label>
                    <input className="input mono" placeholder="e.g. e648da1f" value={shortId} onChange={e=>setShortId(e.target.value)}/>
                  </div>
                  <div className="field" style={{marginBottom:0}}>
                    <label className="field-label">Browser fingerprint</label>
                    <select className="select" value={realityFp} onChange={e=>setRealityFp(e.target.value)}>
                      {TLS_FINGERPRINTS.map(f=><option key={f} value={f}>{f}</option>)}
                    </select>
                  </div>
                </div>
              </Section>
            )}

          </>)}

          {/* ════════════════════════════════ SNIFFING tab ══════════════════ */}
          {tab === 'Sniffing' && (<>

            <ToggleRow
              label="Enable traffic sniffing"
              desc="Extract destination domain from TLS SNI / HTTP Host for smart routing"
              value={sniffEnabled}
              onChange={()=>setSniffEnabled(v=>!v)}
            />

            {sniffEnabled ? (<>
              <div className="field">
                <label className="field-label">Sniff protocols</label>
                <div style={{display:'grid',gridTemplateColumns:'1fr 1fr',gap:8}}>
                  {[
                    {state:sniffHttp,   set:setSniffHttp,   label:'HTTP',   desc:'Extract Host header'},
                    {state:sniffTls,    set:setSniffTls,    label:'TLS',    desc:'Extract SNI from ClientHello'},
                    {state:sniffQuic,   set:setSniffQuic,   label:'QUIC',   desc:'Extract SNI from QUIC'},
                    {state:sniffFakedns,set:setSniffFakedns,label:'FakeDNS',desc:'Use FakeDNS IP mapping'},
                  ].map(item=>(
                    <div key={item.label} onClick={()=>item.set(v=>!v)} style={{
                      display:'flex', alignItems:'center', gap:10, padding:'10px 12px',
                      background: item.state ? 'var(--accent-tint)' : 'var(--surface-2)',
                      border: item.state ? '1.5px solid var(--accent)' : '1px solid var(--border)',
                      borderRadius:'var(--r-md)', cursor:'pointer', transition:'all var(--motion-fast)'
                    }}>
                      <div style={{
                        width:16, height:16, borderRadius:4, flexShrink:0,
                        background: item.state ? 'var(--accent)' : 'transparent',
                        border: item.state ? '1.5px solid var(--accent)' : '1.5px solid var(--border)',
                        display:'flex', alignItems:'center', justifyContent:'center'
                      }}>
                        {item.state && <Icons.Check size={9} style={{color:'white'}}/>}
                      </div>
                      <div>
                        <div style={{fontSize:12.5, fontWeight:600}}>{item.label}</div>
                        <div style={{fontSize:11, color:'var(--muted)'}}>{item.desc}</div>
                      </div>
                    </div>
                  ))}
                </div>
              </div>

              <ToggleRow
                label="Route only (don't override destination)"
                desc="Use sniffed domain for routing only; proxy still connects to the original IP"
                value={sniffRouteOnly}
                onChange={()=>setSniffRouteOnly(v=>!v)}
              />
            </>) : (
              <div style={{padding:'20px', textAlign:'center', color:'var(--muted)', fontSize:12.5,
                background:'var(--surface-2)', borderRadius:'var(--r-lg)', border:'1px solid var(--border)'}}>
                Sniffing is off. Enable it to extract domains from traffic for advanced routing rules.
              </div>
            )}

          </>)}

          {/* ═══════════════════════════════════ ACCESS tab ══════════════════ */}
          {tab === 'Access' && (<>

            {/* Mode selector */}
            <div className="field">
              <label className="field-label">Filter mode</label>
              <div className="proto-pick">
                {[['none','Disabled'],['blacklist','Blacklist'],['whitelist','Whitelist']].map(([v,l]) => (
                  <button key={v} className={accessMode===v?'active':''} onClick={() => setAccessMode(v)}>{l}</button>
                ))}
              </div>
              {accessMode === 'none' && (
                <span className="field-hint">No filtering — all destinations are reachable from this inbound.</span>
              )}
              {accessMode === 'blacklist' && (
                <span className="field-hint">Block the listed domains / IPs. Everything else is allowed.</span>
              )}
              {accessMode === 'whitelist' && (
                <span className="field-hint">Only the listed domains / IPs are reachable. Everything else is blocked. Server IP and public DNS (8.8.8.8, 1.1.1.1) are automatically allowed.</span>
              )}
            </div>

            {accessMode !== 'none' && (<>

              <div className="field">
                <label className="field-label">
                  Domains
                  <span style={{marginLeft:6,fontWeight:400,color:'var(--muted)'}}>one per line</span>
                </label>
                <textarea
                  className="input"
                  rows={5}
                  style={{fontFamily:'var(--font-mono)',fontSize:12,resize:'vertical'}}
                  placeholder={'example.com\ngoogleapis.com\ngeosite:category-ads-all'}
                  value={accessDomains}
                  onChange={e => setAccessDomains(e.target.value)}
                />
                <span className="field-hint">Plain domain, suffix match (domain:), regex (regexp:), or geosite: keywords.</span>
              </div>

              <div className="field">
                <label className="field-label">
                  IPs / CIDRs
                  <span style={{marginLeft:6,fontWeight:400,color:'var(--muted)'}}>one per line</span>
                </label>
                <textarea
                  className="input"
                  rows={4}
                  style={{fontFamily:'var(--font-mono)',fontSize:12,resize:'vertical'}}
                  placeholder={'192.168.1.0/24\n10.0.0.0/8\ngeoip:ir'}
                  value={accessIps}
                  onChange={e => setAccessIps(e.target.value)}
                />
                <span className="field-hint">IPv4/IPv6, CIDR ranges, or geoip: keywords (geoip:ir, geoip:cn, etc.).</span>
              </div>

              <div style={{
                display:'flex', alignItems:'flex-start', gap:8, padding:'10px 12px',
                background:'var(--surface-2)', borderRadius:'var(--r-md)',
                border:'1px solid var(--border)', fontSize:12, color:'var(--muted)',
              }}>
                <Icons.Shield size={13} style={{marginTop:1, flexShrink:0}}/>
                <span>
                  {accessMode === 'whitelist'
                    ? 'Server IP, 127.0.0.1, and public DNS servers (8.8.8.8, 1.1.1.1) are always allowed automatically. Domain rules require sniffing to be enabled.'
                    : 'Sniffing must be enabled on this inbound for domain-based rules to work.'}
                </span>
              </div>

            </>)}

          </>)}

        </div>{/* /modal-body */}

        {/* Footer */}
        <div className="modal-foot">
          <div style={{display:'flex', alignItems:'center', gap:6, fontSize:12}}>
            <span className={`proto-chip ${proto.toLowerCase()}`}>{proto}</span>
            <span style={{color:'var(--muted)'}}>{network.toUpperCase()}</span>
            {security !== 'none' && <span className="badge info">{security.toUpperCase()}</span>}
            {sniffEnabled && <span className="badge" style={{fontSize:10}}>sniff</span>}
            {accessMode !== 'none' && (
              <span className="badge" style={{
                fontSize:10,
                background: accessMode==='whitelist' ? 'var(--accent-tint)' : 'var(--danger-tint,rgba(255,80,80,0.12))',
                color: accessMode==='whitelist' ? 'var(--accent)' : 'var(--danger)',
                border: `1px solid ${accessMode==='whitelist' ? 'var(--accent)' : 'var(--danger)'}`,
              }}>{accessMode}</span>
            )}
          </div>
          <div style={{display:'flex', gap:8}}>
            <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
            <button className="btn btn-primary" onClick={save} disabled={saving || !tag}>
              <Icons.Check size={14}/> {saving ? 'Saving…' : (editing ? 'Update' : 'Create')}
            </button>
          </div>
        </div>

      </div>
    </div>
  );
};

Object.assign(window, { InboundsPage, InboundModal });
