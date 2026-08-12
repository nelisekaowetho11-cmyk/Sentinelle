// Shared components: charts, badges, useful primitives

// ------- Number ticker (counts up to value) -------
const Ticker = ({ value, decimals = 0, suffix = '', duration = 900 }) => {
  const [v, setV] = React.useState(0);
  React.useEffect(() => {
    let raf, start;
    const from = 0;
    const to = value;
    const step = (t) => {
      if (!start) start = t;
      const k = Math.min(1, (t - start) / duration);
      const eased = 1 - Math.pow(1 - k, 3);
      setV(from + (to - from) * eased);
      if (k < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [value, duration]);
  const display = decimals > 0 ? v.toFixed(decimals) : Math.round(v).toLocaleString();
  return <span>{display}{suffix}</span>;
};

// ------- Sparkline (animated draw-in) -------
const Sparkline = ({ data, stroke = 'var(--accent)', fill = true, w = 220, h = 50 }) => {
  const min = Math.min(...data);
  const max = Math.max(...data);
  const range = (max - min) || 1;
  const stepX = w / (data.length - 1);
  const pts = data.map((v, i) => [i * stepX, h - ((v - min) / range) * (h - 6) - 3]);
  const d = pts.map((p, i) => (i === 0 ? `M${p[0]},${p[1]}` : `L${p[0]},${p[1]}`)).join(' ');
  const area = `${d} L ${w},${h} L 0,${h} Z`;
  const id = React.useMemo(() => `g${Math.random().toString(36).slice(2,8)}`, []);
  return (
    <svg viewBox={`0 0 ${w} ${h}`} width="100%" height={h} preserveAspectRatio="none">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={stroke} stopOpacity="0.25"/>
          <stop offset="100%" stopColor={stroke} stopOpacity="0"/>
        </linearGradient>
      </defs>
      {fill && <path d={area} fill={`url(#${id})`} />}
      <path className="spark-path" d={d} fill="none" stroke={stroke} strokeWidth="1.6" strokeLinecap="round"/>
    </svg>
  );
};

// ------- Area chart with grid + 2 series + hover crosshair -------
const AreaChart = ({ down, up, h = 240 }) => {
  const w = 720;
  const padL = 40, padR = 12, padT = 16, padB = 22;
  const W = w - padL - padR;
  const H = h - padT - padB;
  const max = Math.max(...down, ...up) * 1.15;
  const min = 0;
  const stepX = W / (down.length - 1);
  const ptsFor = (arr) => arr.map((v, i) => [padL + i * stepX, padT + H - ((v - min) / (max - min)) * H]);
  const lineD = (arr) => ptsFor(arr).map((p, i) => (i === 0 ? `M${p[0]},${p[1]}` : `L${p[0]},${p[1]}`)).join(' ');
  const areaD = (arr) => `${lineD(arr)} L ${padL + W},${padT + H} L ${padL},${padT + H} Z`;
  const gridY = 4;
  const gridLines = Array.from({length: gridY + 1}, (_, i) => padT + (H * i) / gridY);
  const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  const [hover, setHover] = React.useState(null);

  const onMove = (e) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * w;
    const idx = Math.round((x - padL) / stepX);
    if (idx >= 0 && idx < down.length) setHover(idx);
  };

  return (
    <div style={{position:'relative', overflow:'hidden'}}>
      <svg viewBox={`0 0 ${w} ${h}`} width="100%" height={h} preserveAspectRatio="none" onMouseMove={onMove} onMouseLeave={() => setHover(null)} style={{display:'block'}}>
        <defs>
          <linearGradient id="g-down" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.32"/>
            <stop offset="100%" stopColor="var(--accent)" stopOpacity="0"/>
          </linearGradient>
          <linearGradient id="g-up" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="oklch(72% 0.14 240)" stopOpacity="0.20"/>
            <stop offset="100%" stopColor="oklch(72% 0.14 240)" stopOpacity="0"/>
          </linearGradient>
        </defs>
        {gridLines.map((y, i) => (
          <line key={i} x1={padL} y1={y} x2={padL+W} y2={y} stroke="var(--border-soft)" strokeDasharray="3 4"/>
        ))}
        {gridLines.map((y, i) => (
          <text key={i} x={padL - 8} y={y + 3} fontFamily="JetBrains Mono" fontSize="9.5" fill="var(--muted)" textAnchor="end">
            {Math.round((max - (max - min) * i / gridY))}<tspan dx="2" fill="var(--muted)">GB</tspan>
          </text>
        ))}
        {days.map((d, i) => {
          const x = padL + (W * (i / 6));
          return <text key={d} x={x} y={h - 6} fontFamily="DM Sans" fontSize="10" fill="var(--muted)" textAnchor="middle">{d}</text>;
        })}
        <path d={areaD(down)} fill="url(#g-down)" />
        <path d={areaD(up)}   fill="url(#g-up)"   />
        <path className="spark-path" d={lineD(up)}   fill="none" stroke="oklch(72% 0.14 240)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
        <path className="spark-path" d={lineD(down)} fill="none" stroke="var(--accent)" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/>

        {hover !== null && (() => {
          const [hx, hy] = ptsFor(down)[hover];
          const [, uy] = ptsFor(up)[hover];
          return (
            <g>
              <line x1={hx} y1={padT} x2={hx} y2={padT+H} stroke="var(--muted)" strokeDasharray="3 3" strokeWidth="1"/>
              <circle cx={hx} cy={hy} r="4.5" fill="var(--accent)" stroke="var(--surface)" strokeWidth="2"/>
              <circle cx={hx} cy={uy} r="3.5" fill="oklch(72% 0.14 240)" stroke="var(--surface)" strokeWidth="2"/>
            </g>
          );
        })()}
      </svg>
      {hover !== null && (
        <div style={{
          position:'absolute',
          left:`calc(${((padL + hover * stepX) / w) * 100}% + 8px)`,
          top: 12,
          background:'var(--surface)', border:'1px solid var(--border)', borderRadius:8,
          padding:'7px 10px', fontSize:11, boxShadow:'0 8px 24px rgba(0,0,0,0.2)',
          fontFamily:'var(--font-mono)', pointerEvents:'none', minWidth: 120
        }}>
          <div style={{color:'var(--muted)', fontSize:10, marginBottom:4}}>Slot {hover+1}</div>
          <div style={{display:'flex', alignItems:'center', gap:6}}>
            <span style={{width:6, height:6, borderRadius:'50%', background:'var(--accent)'}} /> Down <b style={{marginLeft:'auto'}}>{down[hover].toFixed(1)} GB</b>
          </div>
          <div style={{display:'flex', alignItems:'center', gap:6, marginTop:2}}>
            <span style={{width:6, height:6, borderRadius:'50%', background:'oklch(72% 0.14 240)'}} /> Up <b style={{marginLeft:'auto'}}>{up[hover].toFixed(1)} GB</b>
          </div>
        </div>
      )}
    </div>
  );
};

// ------- Donut chart -------
const Donut = ({ data, size = 180, thickness = 18 }) => {
  const r = (size - thickness) / 2;
  const c = 2 * Math.PI * r;
  const total = data.reduce((s, d) => s + d.value, 0);
  let offset = 0;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <g transform={`translate(${size/2}, ${size/2}) rotate(-90)`}>
        <circle r={r} fill="none" stroke="var(--border-soft)" strokeWidth={thickness}/>
        {data.map((d, i) => {
          const frac = d.value / total;
          const dash = c * frac;
          const gap = c - dash;
          const seg = (
            <circle
              key={d.name}
              r={r} fill="none"
              stroke={d.color}
              strokeWidth={thickness}
              strokeDasharray={`${dash} ${gap}`}
              strokeDashoffset={-offset}
              strokeLinecap="butt"
              className="donut-seg"
              style={{animationDelay: `${i * 80}ms`}}
            />
          );
          offset += dash;
          return seg;
        })}
      </g>
      <text x="50%" y="48%" textAnchor="middle" dominantBaseline="middle" fontFamily="Space Grotesk" fontWeight="600" fontSize="22" fill="var(--text)">
        <Ticker value={total} />
      </text>
      <text x="50%" y="62%" textAnchor="middle" fontFamily="DM Sans" fontSize="10.5" fill="var(--muted)" letterSpacing="0.08em">TOTAL %</text>
    </svg>
  );
};

// ------- Status badge -------
const Badge = ({ kind = 'default', children }) => {
  const cls = ({ active:'ok', online:'ok', paused:'warn', degraded:'warn', limit:'warn', expired:'danger', down:'danger' })[kind] || '';
  return <span className={`badge ${cls}`}><span className="dot"/>{children || kind}</span>;
};

// ------- Avatar -------
const Avatar = ({ name, i = 0, size = 30 }) => {
  const initials = name.split(' ').slice(0,2).map(s => s[0]).join('').toUpperCase();
  const [c1, c2] = gradFor(i);
  return (
    <div className="user-avatar" style={{ background: `linear-gradient(135deg, ${c1}, ${c2})`, width: size, height: size, fontSize: size * 0.4 }}>
      {initials}
    </div>
  );
};

// ------- Real QR code (uses qrcode-generator loaded from /static/qrcode.js) -------
const FakeQR = ({ seed = '', size = 220 }) => {
  const [src, setSrc] = React.useState('');

  React.useEffect(() => {
    if (!seed) return;
    if (typeof qrcode === 'undefined') return;
    const levels = ['L', 'M', 'Q', 'H'];
    for (let i = 0; i < levels.length; i++) {
      try {
        const qr = qrcode(0, levels[i]);
        qr.addData(seed);
        qr.make();
        setSrc(qr.createDataURL(4, 0));
        return;
      } catch (e) { /* try next error-correction level */ }
    }
  }, [seed]);

  if (!src) return (
    <div style={{
      width: size, height: size, background: '#fff', borderRadius: 4,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontSize: 11, color: '#aaa',
    }}>…</div>
  );

  return (
    <img src={src} width={size} height={size}
      style={{display:'block', imageRendering:'pixelated', borderRadius: 4}}
      alt="QR code"
    />
  );
};

// ------- Live ring (CPU-style ring around a number) -------
const Ring = ({ value, max = 100, size = 56, label }) => {
  const r = (size - 6) / 2;
  const c = 2 * Math.PI * r;
  const dash = c * (value / max);
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <g transform={`translate(${size/2}, ${size/2}) rotate(-90)`}>
        <circle r={r} fill="none" stroke="var(--border-soft)" strokeWidth="3"/>
        <circle r={r} fill="none" stroke="var(--accent)" strokeWidth="3" strokeLinecap="round"
                strokeDasharray={`${dash} ${c}`}
                style={{transition: 'stroke-dasharray 800ms cubic-bezier(.16,.84,.4,1)'}}/>
      </g>
      <text x="50%" y={label ? '46%' : '54%'} textAnchor="middle" dominantBaseline="middle"
            fontFamily="JetBrains Mono" fontSize={size*0.26} fontWeight="600" fill="var(--text)">
        {value}<tspan fontSize={size*0.18} fill="var(--muted)">%</tspan>
      </text>
      {label && <text x="50%" y="66%" textAnchor="middle" fontSize={size*0.13} fill="var(--muted)" fontFamily="DM Sans" letterSpacing="0.08em">{label}</text>}
    </svg>
  );
};

Object.assign(window, { Ticker, Sparkline, AreaChart, Donut, Badge, Avatar, FakeQR, Ring });
