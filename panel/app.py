import os, io, json, uuid, re, subprocess, threading, time, functools, ipaddress
from collections import deque, Counter
from datetime import datetime, date, timedelta, timezone

def _utcnow():
    """Naive UTC datetime — compatible with SQLite's timezone-unaware columns."""
    return datetime.now(timezone.utc).replace(tzinfo=None)

from flask import (Flask, render_template, request, redirect,
                   url_for, flash, jsonify, send_file, session)
from flask_sqlalchemy import SQLAlchemy
from flask_login import (LoginManager, UserMixin, login_user,
                         login_required, logout_user, current_user)
from werkzeug.security import generate_password_hash, check_password_hash

def _load_secret_key():
    """Return a stable SECRET_KEY — reads from .secret_key file, creates it if missing.
    Using a persistent key means remember-me cookies survive server restarts.
    """
    _dir = os.path.dirname(os.path.abspath(__file__))
    key_file = os.path.join(_dir, '.secret_key')
    env_key  = os.environ.get('SECRET_KEY', '')
    if env_key:
        return env_key
    if os.path.isfile(key_file):
        key = open(key_file).read().strip()
        if key:
            return key
    key = os.urandom(32).hex()
    try:
        with open(key_file, 'w') as f:
            f.write(key)
    except OSError:
        pass
    return key


app = Flask(__name__)
app.config['SECRET_KEY']                  = _load_secret_key()
app.config['SQLALCHEMY_DATABASE_URI']     = 'sqlite:///panel.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['REMEMBER_COOKIE_DURATION']    = timedelta(days=30)
app.config['REMEMBER_COOKIE_HTTPONLY']    = True
app.config['PERMANENT_SESSION_LIFETIME']  = timedelta(days=30)

db            = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'

# ── Models ────────────────────────────────────────────────────────────────────

class Admin(UserMixin, db.Model):
    id             = db.Column(db.Integer, primary_key=True)
    username       = db.Column(db.String(80), unique=True, nullable=False)
    password_hash  = db.Column(db.String(256), nullable=False)
    role           = db.Column(db.String(20), nullable=False, default='superadmin')
    reseller_count = db.Column(db.Integer, default=10)
    data_limit_gb  = db.Column(db.Float, default=1000.0)
    user_count     = db.Column(db.Integer, default=1000)
    locked         = db.Column(db.Boolean, default=False)
    created_at     = db.Column(db.DateTime, default=_utcnow)

    def set_password(self, pw):   self.password_hash = generate_password_hash(pw)
    def check_password(self, pw): return check_password_hash(self.password_hash, pw)
    def to_dict(self):
        resellers = Reseller.query.filter_by(admin_id=self.id).all()
        used = db.session.query(db.func.sum(User.traffic_used)).filter(
            User.reseller_id.in_([r.id for r in resellers])).scalar() or 0 if resellers else 0
        total_users = sum(User.query.filter_by(reseller_id=r.id).count() for r in resellers)
        return {
            'id': self.id, 'username': self.username, 'role': self.role,
            'reseller_count': self.reseller_count, 'data_limit_gb': self.data_limit_gb,
            'user_count': self.user_count,
            'resellers_total': len(resellers),
            'users_total': total_users,
            'data_used_gb': round(float(used), 3),
            'locked': bool(self.locked),
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }


class Reseller(db.Model):
    id                  = db.Column(db.Integer, primary_key=True)
    username            = db.Column(db.String(80), unique=True, nullable=False)
    password_hash       = db.Column(db.String(256), nullable=False)
    user_count          = db.Column(db.Integer, default=10)
    active_user_count   = db.Column(db.Integer, default=10)
    data_limit_gb       = db.Column(db.Float, default=100.0)   # allocated traffic limit
    used_limit_gb       = db.Column(db.Float, default=100.0)   # used traffic limit
    default_traffic_gb  = db.Column(db.Float, default=10.0)
    default_days        = db.Column(db.Integer, default=30)
    allowed_inbound_ids            = db.Column(db.Text, nullable=False, default='[]')
    deleted_users_allocated_gb     = db.Column(db.Float, default=0.0)
    deleted_users_used_gb          = db.Column(db.Float, default=0.0)
    active              = db.Column(db.Boolean, default=True)
    locked              = db.Column(db.Boolean, default=False)
    created_at          = db.Column(db.DateTime, default=datetime.utcnow)
    admin_id            = db.Column(db.Integer, db.ForeignKey('admin.id', ondelete='SET NULL'), nullable=True)
    def set_password(self, pw): self.password_hash = generate_password_hash(pw)
    def check_password(self, pw): return check_password_hash(self.password_hash, pw)
    def total_used_gb(self):
        """Total traffic used by ALL users ever (including deleted)."""
        live = db.session.query(db.func.sum(User.traffic_used)).filter(User.reseller_id == self.id).scalar() or 0
        return float(live) + (self.deleted_users_used_gb or 0)

    def total_allocated_gb(self):
        """Total traffic currently allocated across all active users of this reseller."""
        live = db.session.query(db.func.sum(User.traffic_limit)).filter(User.reseller_id == self.id).scalar() or 0
        return float(live)

    def to_dict(self):
        owner_username = None
        if self.admin_id:
            adm = db.session.get(Admin, self.admin_id)
            owner_username = adm.username if adm else None
        return {
            'id': self.id, 'username': self.username,
            'user_count': self.user_count, 'active_user_count': self.active_user_count,
            'data_limit_gb': self.data_limit_gb, 'used_limit_gb': self.used_limit_gb,
            'default_traffic_gb': self.default_traffic_gb,
            'default_days': self.default_days,
            'allowed_inbound_ids': json.loads(self.allowed_inbound_ids or '[]'),
            'users_total': User.query.filter_by(reseller_id=self.id).count(),
            'users_active': User.query.filter_by(reseller_id=self.id, status='active').count(),
            'data_used_gb': round(self.total_used_gb(), 3),
            'data_allocated_gb': round(self.total_allocated_gb(), 3),
            'active': bool(self.active),
            'locked': bool(self.locked),
            'created_at': self.created_at.isoformat(),
            'admin_id': self.admin_id,
            'admin_username': owner_username,
        }


class AppSetting(db.Model):
    id    = db.Column(db.Integer, primary_key=True)
    key   = db.Column(db.String(80), unique=True, nullable=False)
    value = db.Column(db.String(1000), nullable=False, default='')


# Many-to-many: one user can belong to multiple inbounds
user_inbound_assoc = db.Table(
    'user_inbound_assoc',
    db.Column('user_id',    db.Integer, db.ForeignKey('user.id',    ondelete='CASCADE'), primary_key=True),
    db.Column('inbound_id', db.Integer, db.ForeignKey('inbound.id', ondelete='CASCADE'), primary_key=True)
)


class Inbound(db.Model):
    id         = db.Column(db.Integer, primary_key=True)
    tag        = db.Column(db.String(100), nullable=False)
    protocol   = db.Column(db.String(20), nullable=False)
    transport  = db.Column(db.String(20), nullable=False)
    port       = db.Column(db.Integer, nullable=False, unique=True)
    settings   = db.Column(db.Text, nullable=False, default='{}')
    enabled        = db.Column(db.Boolean, default=True)
    access_mode    = db.Column(db.String(16), nullable=False, default='none')   # 'none'|'whitelist'|'blacklist'
    access_domains = db.Column(db.Text, nullable=False, default='[]')
    access_ips     = db.Column(db.Text, nullable=False, default='[]')
    created_at     = db.Column(db.DateTime, default=datetime.utcnow)
    # .users populated via backref on User.inbounds

    def get_settings(self): return json.loads(self.settings or '{}')
    def set_settings(self, d): self.settings = json.dumps(d)

    def to_dict(self):
        s = self.get_settings()
        # reality is stored as transport='reality' but actual network is tcp
        net = 'tcp' if self.transport == 'reality' else self.transport
        return {
            'id': self.id,
            'tag': self.tag,
            'proto': self.protocol.upper(),
            'protocol': self.protocol,
            'network': net,
            'transport': self.transport,
            'port': self.port,
            'listen':      s.get('listen', '0.0.0.0'),
            'server_addr': s.get('server_addr', ''),
            'server_port': s.get('server_port', 0) or 0,
            'config_name': s.get('config_name', ''),
            'country':     s.get('country', ''),
            'settings': s,
            'tls': s.get('tls_type', 'none'),
            'security': s.get('tls_type', 'none'),
            'net': net,
            'user_count': len(self.users),
            'users': len(self.users),
            'traffic': f"{round(sum(u.traffic_used for u in self.users), 1)} GB",
            'enabled': self.enabled,
            # Reality
            'private_key':  s.get('private_key', ''),
            'public_key':   s.get('public_key', ''),
            'short_id':     s.get('short_id', ''),
            'sni':          s.get('sni', ''),
            'dest':         s.get('dest', ''),
            # WS
            'ws_path':      s.get('ws_path', '/ws'),
            'ws_host':      s.get('ws_host', ''),
            'ws_heartbeat': s.get('ws_heartbeat', 0),
            # gRPC
            'grpc_service':    s.get('grpc_service', 'xray'),
            'grpc_authority':  s.get('grpc_authority', ''),
            'grpc_multi_mode': s.get('grpc_multi_mode', False),
            # mKCP
            'kcp_mtu':       s.get('kcp_mtu', 1350),
            'kcp_tti':       s.get('kcp_tti', 50),
            'kcp_uplink':    s.get('kcp_uplink', 5),
            'kcp_downlink':  s.get('kcp_downlink', 20),
            'kcp_congestion':s.get('kcp_congestion', False),
            'kcp_read_buf':  s.get('kcp_read_buf', 2),
            'kcp_write_buf': s.get('kcp_write_buf', 2),
            # HTTPUpgrade
            'hu_path':         s.get('hu_path', '/'),
            'hu_host':         s.get('hu_host', ''),
            'hu_accept_proxy': s.get('hu_accept_proxy', False),
            # XHTTP
            'xhttp_path':  s.get('xhttp_path', '/'),
            'xhttp_host':  s.get('xhttp_host', ''),
            'xhttp_mode':  s.get('xhttp_mode', 'auto'),
            'xhttp_extra': s.get('xhttp_extra', ''),
            # TLS
            'cert_file':          s.get('cert_file', ''),
            'key_file':           s.get('key_file', ''),
            'tls_server_name':    s.get('tls_server_name', ''),
            'alpn':               s.get('alpn', []),
            'fingerprint':        s.get('fingerprint', ''),
            'reject_unknown_sni': s.get('reject_unknown_sni', False),
            # TCP
            'accept_proxy_protocol': s.get('accept_proxy_protocol', False),
            'tcp_header_type':       s.get('tcp_header_type', 'none'),
            'tcp_header_path':       s.get('tcp_header_path', '/'),
            'tcp_header_host':       s.get('tcp_header_host', ''),
            # Sniffing
            'sniffing_enabled': s.get('sniffing_enabled', False),
            'sniff_http':       s.get('sniff_http', True),
            'sniff_tls':        s.get('sniff_tls', True),
            'sniff_quic':       s.get('sniff_quic', False),
            'sniff_fakedns':    s.get('sniff_fakedns', False),
            'sniff_route_only': s.get('sniff_route_only', False),
            # Shadowsocks
            'ss_method':   s.get('method', ''),
            'ss_password': s.get('password', ''),
            # SOCKS
            'auth':     s.get('auth', 'noauth'),
            'udp':      s.get('udp', True),
            'ip':       s.get('ip', ''),
            'accounts': s.get('accounts', []),
            # HTTP
            'http_accounts':     s.get('http_accounts', []),
            'allow_transparent': s.get('allow_transparent', False),
            'out_server_id': s.get('out_server_id', '') or '',
            'access_mode':    self.access_mode or 'none',
            'access_domains': json.loads(self.access_domains or '[]'),
            'access_ips':     json.loads(self.access_ips or '[]'),
            'created_at': self.created_at.isoformat(),
        }


# ── App login credentials (pvb##### / 8-char password) ────────────────────────

VPN_USERNAME_PREFIX = 'pvb'
VPN_USERNAME_START  = 10001
VPN_PASSWORD_LEN    = 8
_vpn_cred_lock      = threading.Lock()

# Ambiguous glyphs (0/O, 1/l/I) are excluded — these passwords get read out loud
# and typed by hand on phones.
_VPN_PW_ALPHABET = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'


def _gen_vpn_password(n=VPN_PASSWORD_LEN):
    import secrets
    return ''.join(secrets.choice(_VPN_PW_ALPHABET) for _ in range(n))


def _next_vpn_username():
    """Return the next free 'pvb<number>' username."""
    rows = db.session.query(User.vpn_username).filter(
        User.vpn_username.like(f'{VPN_USERNAME_PREFIX}%')).all()
    highest = VPN_USERNAME_START - 1
    plen = len(VPN_USERNAME_PREFIX)
    for (val,) in rows:
        tail = str(val or '')[plen:]
        if tail.isdigit():
            highest = max(highest, int(tail))
    n = highest + 1
    # Defensive: skip any number already taken (e.g. a manually set username)
    while User.query.filter_by(vpn_username=f'{VPN_USERNAME_PREFIX}{n}').first():
        n += 1
    return f'{VPN_USERNAME_PREFIX}{n}'


def _ensure_vpn_credentials(u, force_password=False):
    """Assign app username/password to a user if missing. Returns (username, password)."""
    with _vpn_cred_lock:
        if not u.vpn_username:
            u.vpn_username = _next_vpn_username()
        if force_password or not u.vpn_password:
            u.vpn_password = _gen_vpn_password()
    return u.vpn_username, u.vpn_password


def _safe_reseller_username(reseller_id):
    """Return reseller username for a given ID, or None if not found / column missing."""
    if not reseller_id:
        return None
    try:
        r = Reseller.query.filter_by(id=reseller_id).first()
        return r.username if r else None
    except Exception:
        return None


class User(db.Model):
    id            = db.Column(db.Integer, primary_key=True)
    name          = db.Column(db.String(100), nullable=False)
    email         = db.Column(db.String(200), nullable=True)
    uuid          = db.Column(db.String(36), nullable=False,
                               default=lambda: str(uuid.uuid4()))
    inbound_id    = db.Column(db.Integer, nullable=True)   # legacy column (kept for migration)
    status        = db.Column(db.String(20), nullable=False, default='active')
    traffic_limit = db.Column(db.Float, default=100.0)
    traffic_used  = db.Column(db.Float, default=0.0)
    ip_limit          = db.Column(db.Integer, default=0)   # 0 = unlimited
    speed_limit_kbps  = db.Column(db.Integer, default=0)   # 0 = unlimited (kilobits/s)
    expires           = db.Column(db.DateTime, nullable=True)
    sub_token     = db.Column(db.String(36), unique=True,
                               default=lambda: str(uuid.uuid4()))
    # ── App login credentials (used by the Veil client apps) ──────────────────
    # vpn_username: 'pvb' + incrementing number, unique across the panel.
    # vpn_password: 8 random chars, stored in clear so the owning admin/reseller
    #               can read it back and hand it to the customer.
    vpn_username   = db.Column(db.String(64), unique=True, nullable=True)
    vpn_password   = db.Column(db.String(64), nullable=True)
    sub_note       = db.Column(db.Text,     nullable=True)   # shown as info entry in subscription
    # How this account is allowed to reach its configs:
    #   'both' — subscription URL *and* the Sentinelle apps (default)
    #   'sub'  — subscription URL only; the apps refuse to sign in
    #   'app'  — apps only; the subscription URL answers 403
    # A customer who is meant to use the branded app should not be able to lift
    # the raw links out of the subscription and hand them round, and a plain
    # subscription customer has no business holding an app session either.
    access_type    = db.Column(db.String(8), nullable=False, default='both')
    access_mode    = db.Column(db.String(16), nullable=False, default='none')   # 'none'|'whitelist'|'blacklist'
    access_domains = db.Column(db.Text, nullable=False, default='[]')
    access_ips     = db.Column(db.Text, nullable=False, default='[]')
    created_at     = db.Column(db.DateTime, default=datetime.utcnow)
    reseller_id    = db.Column(db.Integer, db.ForeignKey('reseller.id', ondelete='SET NULL'), nullable=True)
    date_start_mode = db.Column(db.String(20), nullable=False, default='on_create')  # 'on_create'|'on_first_connect'
    expires_days    = db.Column(db.Integer, default=0)  # used when date_start_mode='on_first_connect'

    # Many-to-many: user can be on multiple inbounds
    inbounds = db.relationship(
        'Inbound', secondary=user_inbound_assoc,
        backref=db.backref('users', lazy=True),
        lazy=True
    )

    def is_expired(self):
        return bool(self.expires and self.expires < _utcnow())

    def is_over_limit(self):
        return bool(self.traffic_limit > 0 and self.traffic_used >= self.traffic_limit)

    def to_dict(self):
        server_ip = get_setting('server_ip', '0.0.0.0')
        ibs = self.inbounds   # list of Inbound objects

        computed_status = self.status
        if computed_status == 'active' and self.is_expired():
            computed_status = 'expired'
        elif computed_status == 'active' and self.is_over_limit():
            computed_status = 'limit'

        # Build links for every inbound this user belongs to
        all_links = []
        for ib in ibs:
            lnk = _build_link(self, ib, ib.get_settings(), server_ip)
            if lnk:
                all_links.append({'tag': ib.tag, 'proto': ib.protocol.upper(), 'link': lnk})

        ib0 = ibs[0] if ibs else None
        return {
            'id': self.id,
            'name': self.name,
            'email': self.email or f"{self.name.lower().replace(' ','.')}@bridge.mireda.app",
            'uuid': self.uuid,
            'vpn_username': self.vpn_username or '',
            'vpn_password': self.vpn_password or '',
            'proto': ib0.protocol.upper() if ib0 else '—',
            'inbound_id': ib0.id if ib0 else None,        # legacy compat
            'inbound_ids': [ib.id for ib in ibs],
            'inbounds': [{'id': ib.id, 'tag': ib.tag, 'proto': ib.protocol.upper(),
                          'port': ib.port, 'enabled': ib.enabled} for ib in ibs],
            'status': computed_status,
            'traffic_limit': self.traffic_limit,
            'traffic_used': round(self.traffic_used, 3),
            'used': round(self.traffic_used, 3),
            'limit': self.traffic_limit,
            'ip_limit': self.ip_limit or 0,
            'speed_limit_kbps': self.speed_limit_kbps or 0,
            'expires': self.expires.strftime('%Y-%m-%d') if self.expires else '',
            'sub_token': self.sub_token or '',
            'sub_note':  self.sub_note  or '',
            'access_type': self.access_type or 'both',
            'sub_url':   _build_sub_url(self),
            'sub_urls':  _build_sub_urls(self),
            'link': all_links[0]['link'] if all_links else '',   # primary link (compat)
            'links': all_links,
            'last': 'recently',
            'country': '?',
            'access_mode':    self.access_mode or 'none',
            'access_domains': json.loads(self.access_domains or '[]'),
            'access_ips':     json.loads(self.access_ips or '[]'),
            'created_at': self.created_at.isoformat(),
            'reseller_id': self.reseller_id,
            'owner': _safe_reseller_username(self.reseller_id),
            'date_start_mode': self.date_start_mode or 'on_create',
            'expires_days': self.expires_days or 0,
        }


class Server(db.Model):
    id          = db.Column(db.Integer, primary_key=True)
    name        = db.Column(db.String(100), nullable=False)
    region      = db.Column(db.String(100), nullable=False)
    code        = db.Column(db.String(5),   nullable=False)
    ip          = db.Column(db.String(100), nullable=False)
    server_type = db.Column(db.String(10),  nullable=False, default='out')  # 'in', 'out', 'both'
    status      = db.Column(db.String(20),  nullable=False, default='online')
    users       = db.Column(db.Integer,     default=0)
    load        = db.Column(db.Integer,     default=0)
    ping        = db.Column(db.Integer,     default=0)
    notes       = db.Column(db.Text,        nullable=True)
    settings    = db.Column(db.Text,        nullable=True, default='{}')
    created_at  = db.Column(db.DateTime,    default=datetime.utcnow)

    def get_settings(self): return json.loads(self.settings or '{}')
    def set_settings(self, d): self.settings = json.dumps(d)

    def to_dict(self):
        s = self.get_settings()
        active_ids = []
        try:
            from flask import has_app_context
            if has_app_context():
                raw = get_setting('active_outbound_server_ids', '[]')
                try:
                    active_ids = json.loads(raw)
                except Exception:
                    single = get_setting('active_outbound_server_id', '')
                    if single:
                        active_ids = [single]
        except Exception:
            pass
        return {
            'id': self.id, 'name': self.name, 'region': self.region,
            'code': self.code, 'ip': self.ip,
            'server_type': self.server_type or 'out',
            'status': self.status,
            'users': self.users, 'load': self.load, 'ping': self.ping,
            'notes': self.notes or '',
            'out_proxy_port':     s.get('out_proxy_port',  10001),
            'out_proxy_uuid':     s.get('out_proxy_uuid',  ''),
            'out_proxy_protocol': s.get('out_proxy_protocol', 'vless'),
            'out_proxy_token':    s.get('out_proxy_token', ''),
            'is_active_outbound': str(self.id) in [str(x) for x in active_ids],
        }


class Tunnel(db.Model):
    id            = db.Column(db.Integer, primary_key=True)
    name          = db.Column(db.String(100), nullable=False)
    in_server_id  = db.Column(db.Integer, db.ForeignKey('server.id', ondelete='SET NULL'), nullable=True)
    out_server_id = db.Column(db.Integer, db.ForeignKey('server.id', ondelete='SET NULL'), nullable=True)
    method        = db.Column(db.String(20), nullable=False, default='haproxy')
    in_port       = db.Column(db.Integer, nullable=False)
    out_port      = db.Column(db.Integer, nullable=False)
    secret        = db.Column(db.String(100), nullable=True)
    enabled       = db.Column(db.Boolean, default=True)
    notes         = db.Column(db.Text,    nullable=True)
    settings      = db.Column(db.Text,    nullable=True, default='{}')
    created_at    = db.Column(db.DateTime, default=datetime.utcnow)

    in_server  = db.relationship('Server', foreign_keys=[in_server_id],
                                  backref=db.backref('tunnels_in',  lazy='dynamic'))
    out_server = db.relationship('Server', foreign_keys=[out_server_id],
                                  backref=db.backref('tunnels_out', lazy='dynamic'))

    def get_settings(self): return json.loads(self.settings or '{}')
    def set_settings(self, d): self.settings = json.dumps(d)

    def to_dict(self):
        ts = self.get_settings()
        return {
            'id':            self.id,
            'name':          self.name,
            'in_server_id':  self.in_server_id,
            'out_server_id': self.out_server_id,
            'in_server':     self.in_server.to_dict()  if self.in_server  else None,
            'out_server':    self.out_server.to_dict() if self.out_server else None,
            'method':        self.method,
            'in_port':       self.in_port,
            'out_port':      self.out_port,
            'secret':        self.secret or '',
            'enabled':       self.enabled,
            'notes':         self.notes or '',
            'tunnel_settings':       ts,
            'backhaul_transport':    ts.get('backhaul_transport', 'tcp'),
            'backhaul_nodelay':      ts.get('backhaul_nodelay', True),
            'backhaul_keepalive':    ts.get('backhaul_keepalive', 75),
            'backhaul_mux_con':      ts.get('backhaul_mux_con', 8),
            'backhaul_chan_size':     ts.get('backhaul_chan_size', 2048),
            'frp_protocol':          ts.get('frp_protocol', 'tcp'),
            'rathole_transport':     ts.get('rathole_transport', 'tcp'),
            'created_at':    self.created_at.isoformat(),
        }


class TrafficRecord(db.Model):
    id      = db.Column(db.Integer, primary_key=True)
    ts      = db.Column(db.DateTime, nullable=False, index=True)
    down_gb = db.Column(db.Float, default=0.0)
    up_gb   = db.Column(db.Float, default=0.0)


class ResellerTrafficLog(db.Model):
    """Daily snapshot of a reseller's total allocated and used traffic.
    Deleted users' traffic is preserved via the reseller's accumulator columns."""
    __tablename__ = 'reseller_traffic_log'
    id           = db.Column(db.Integer, primary_key=True)
    reseller_id  = db.Column(db.Integer, db.ForeignKey('reseller.id', ondelete='CASCADE'), nullable=False, index=True)
    date         = db.Column(db.Date, nullable=False, index=True)
    allocated_gb = db.Column(db.Float, default=0.0)  # sum of all users' traffic_limit
    used_gb      = db.Column(db.Float, default=0.0)  # sum of all users' traffic_used
    __table_args__ = (db.UniqueConstraint('reseller_id', 'date', name='uq_reseller_date'),)


class ActivityLog(db.Model):
    """Audit trail — every significant action by any admin or reseller."""
    __tablename__ = 'activity_log'
    id         = db.Column(db.Integer, primary_key=True)
    ts         = db.Column(db.DateTime, nullable=False, default=_utcnow, index=True)
    actor      = db.Column(db.String(80),  nullable=False)   # username
    actor_role = db.Column(db.String(20),  nullable=False)   # superadmin / admin / reseller
    action     = db.Column(db.String(50),  nullable=False)   # create_user, delete_reseller, …
    target     = db.Column(db.String(200), nullable=True)    # name of affected entity
    detail     = db.Column(db.String(500), nullable=True)    # extra context


@login_manager.user_loader
def load_user(uid): return db.session.get(Admin, int(uid))

def get_setting(key, default=''):
    s = AppSetting.query.filter_by(key=key).first()
    return s.value if s else default

def set_setting(key, value):
    s = AppSetting.query.filter_by(key=key).first()
    if s:   s.value = str(value)
    else:   db.session.add(AppSetting(key=key, value=str(value)))
    db.session.commit()

# ── Binary cache ──────────────────────────────────────────────────────────────
# (BINARIES_DIR is set after _PANEL_DIR is defined below)

# Maps tool name → (arch_label, github_fetch_logic)
# arch_label: 'amd64' or 'arm64'
_TOOL_FETCH = {
    # use_assets=True  → look at GitHub release asset list to find the right filename
    # url              → direct pattern (used as fallback when use_assets is False or API fails)
    'rathole':  {
        # Repo moved: rapiz1/rathole → rathole-org/rathole
        # x86_64 release uses -gnu (no musl build!), aarch64 uses -musl
        'amd64': {
            'use_assets': True,
            'asset_keywords': ['x86_64', 'linux', 'gnu'],
            'type': 'zip', 'bin': 'rathole', 'fallback': 'v0.5.0',
            'fallback_urls': [
                'https://github.com/rathole-org/rathole/releases/download/{ver}/rathole-x86_64-unknown-linux-gnu.zip',
                'https://github.com/rapiz1/rathole/releases/download/{ver}/rathole-x86_64-unknown-linux-gnu.zip',
            ],
        },
        'arm64': {
            'use_assets': True,
            'asset_keywords': ['aarch64', 'linux'],
            'type': 'zip', 'bin': 'rathole', 'fallback': 'v0.5.0',
            'fallback_urls': [
                'https://github.com/rathole-org/rathole/releases/download/{ver}/rathole-aarch64-unknown-linux-musl.zip',
                'https://github.com/rapiz1/rathole/releases/download/{ver}/rathole-aarch64-unknown-linux-musl.zip',
            ],
        },
        'api': 'https://api.github.com/repos/rathole-org/rathole/releases/latest',
    },
    'backhaul': {
        'amd64': {'url': 'https://github.com/Musixal/Backhaul/releases/download/{ver}/backhaul_linux_amd64.tar.gz',  'type': 'tar', 'bin': 'backhaul', 'fallback': 'v0.9.1'},
        'arm64': {'url': 'https://github.com/Musixal/Backhaul/releases/download/{ver}/backhaul_linux_arm64.tar.gz',  'type': 'tar', 'bin': 'backhaul', 'fallback': 'v0.9.1'},
        'api': 'https://api.github.com/repos/Musixal/Backhaul/releases/latest',
    },
    'gost':     {
        'amd64': {'url': 'https://github.com/go-gost/gost/releases/download/{ver}/gost_{ver_no_v}_linux_amd64.tar.gz', 'type': 'tar', 'bin': 'gost', 'fallback': 'v3.0.0-rc.4'},
        'arm64': {'url': 'https://github.com/go-gost/gost/releases/download/{ver}/gost_{ver_no_v}_linux_arm64.tar.gz', 'type': 'tar', 'bin': 'gost', 'fallback': 'v3.0.0-rc.4'},
        'api': 'https://api.github.com/repos/go-gost/gost/releases/latest',
    },
    'frp':      {
        'amd64': {'url': 'https://github.com/fatedier/frp/releases/download/{ver}/frp_{ver_no_v}_linux_amd64.tar.gz', 'type': 'tar_frp', 'fallback': 'v0.61.1'},
        'arm64': {'url': 'https://github.com/fatedier/frp/releases/download/{ver}/frp_{ver_no_v}_linux_arm64.tar.gz', 'type': 'tar_frp', 'fallback': 'v0.61.1'},
        'api': 'https://api.github.com/repos/fatedier/frp/releases/latest',
    },
    'chisel':   {
        'amd64': {'url': 'https://github.com/jpillora/chisel/releases/download/{ver}/chisel_{ver_no_v}_linux_amd64.gz', 'type': 'gz', 'bin': 'chisel', 'fallback': 'v1.9.1'},
        'arm64': {'url': 'https://github.com/jpillora/chisel/releases/download/{ver}/chisel_{ver_no_v}_linux_arm64.gz', 'type': 'gz', 'bin': 'chisel', 'fallback': 'v1.9.1'},
        'api': 'https://api.github.com/repos/jpillora/chisel/releases/latest',
    },
}


def _list_binaries():
    """Return list of cached binary info dicts."""
    result = []
    try:
        for fname in sorted(os.listdir(BINARIES_DIR)):
            fpath = os.path.join(BINARIES_DIR, fname)
            if os.path.isfile(fpath):
                stat = os.stat(fpath)
                result.append({
                    'name': fname,
                    'size': stat.st_size,
                    'size_kb': round(stat.st_size / 1024, 1),
                    'modified': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M'),
                })
    except Exception:
        pass
    return result


def _curl_download(url, dest, timeout=120):
    """Download url → dest using curl (follows redirects, retries).
    Falls back to urllib if curl is not installed.
    Returns (ok, stderr_or_error).
    """
    import shutil as _sh
    if _sh.which('curl'):
        result = subprocess.run(
            ['curl', '-fsSL', '--retry', '3', '--retry-delay', '2',
             '--connect-timeout', '15', '-o', dest, url],
            timeout=timeout, capture_output=True
        )
        return result.returncode == 0, result.stderr.decode(errors='replace').strip()
    # urllib fallback
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            import shutil
            with open(dest, 'wb') as f:
                shutil.copyfileobj(r, f)
        return True, ''
    except Exception as e:
        return False, str(e)


def _gh_release_info(api_url, fallback_ver):
    """Fetch GitHub latest release JSON. Returns (tag, assets_list)."""
    import urllib.request
    try:
        req = urllib.request.Request(api_url,
              headers={'User-Agent': 'bridge-panel/1.0',
                       'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
        ver    = data.get('tag_name', '') or fallback_ver
        assets = data.get('assets', [])
        return ver, assets
    except Exception:
        return fallback_ver, []


def _fetch_binary_to_cache(tool, arch):
    """Download a tool binary from GitHub and save it to BINARIES_DIR.
    Returns (ok, message, saved_names[]).
    """
    import tarfile, zipfile, gzip as _gzip, shutil, tempfile
    info = _TOOL_FETCH.get(tool, {}).get(arch)
    if not info:
        return False, f'Unknown tool/arch: {tool}/{arch}', []

    api_url  = _TOOL_FETCH[tool].get('api', '')
    ver, assets = _gh_release_info(api_url, info['fallback']) if api_url else (info['fallback'], [])
    ver_no_v = ver.lstrip('v')

    # ── Resolve download URL ──────────────────────────────────────────────────
    url = None

    # 1) Asset-based discovery (when filenames aren't predictable, e.g. rathole)
    if info.get('use_assets') and assets:
        keywords = [kw.lower() for kw in info.get('asset_keywords', [])]
        for asset in assets:
            name = asset.get('name', '').lower()
            if all(kw in name for kw in keywords):
                url = asset.get('browser_download_url')
                break

    # 2) Direct URL pattern
    if not url and info.get('url'):
        url = info['url'].format(ver=ver, ver_no_v=ver_no_v)

    # 3) Fallback URL list (try each until one works)
    fallback_urls = info.get('fallback_urls', [])
    urls_to_try   = [url] if url else []
    urls_to_try  += [u.format(ver=ver, ver_no_v=ver_no_v) for u in fallback_urls]
    urls_to_try   = [u for u in urls_to_try if u]  # remove None/empty

    if not urls_to_try:
        return False, f'No download URL could be resolved for {tool}/{arch}', []

    saved = []
    with tempfile.TemporaryDirectory() as tmpdir:
        archive = os.path.join(tmpdir, 'dl_file')

        # Try each URL until one succeeds
        last_err = ''
        dl_url   = ''
        for candidate in urls_to_try:
            ok, err = _curl_download(candidate, archive)
            if ok and os.path.isfile(archive) and os.path.getsize(archive) > 1024:
                dl_url = candidate
                break
            last_err = f'{candidate}: {err}'
            # Remove partial file before next attempt
            try: os.remove(archive)
            except OSError: pass
        else:
            return False, f'All URLs failed. Last error: {last_err}', []

        url = dl_url  # for error messages below

        btype = info['type']
        try:
            if btype == 'zip':
                with zipfile.ZipFile(archive) as zf:
                    members = zf.namelist()
                    # Look for exact binary name OR any executable at root
                    target = next(
                        (m for m in members
                         if os.path.basename(m) == info['bin'] and not m.endswith('/')),
                        None
                    )
                    if not target:
                        return False, (f"'{info['bin']}' not found in zip. "
                                       f"Contents: {members[:10]}"), []
                    dest = os.path.join(BINARIES_DIR, f"{tool}-{arch}")
                    with zf.open(target) as src, open(dest, 'wb') as dst:
                        shutil.copyfileobj(src, dst)
                    os.chmod(dest, 0o755)
                    saved.append(f"{tool}-{arch}")

            elif btype == 'tar':
                with tarfile.open(archive) as tf:
                    target = next(
                        (m for m in tf.getmembers()
                         if os.path.basename(m.name) == info['bin'] and m.isfile()),
                        None
                    )
                    if not target:
                        return False, f"'{info['bin']}' not found in tar", []
                    dest = os.path.join(BINARIES_DIR, f"{tool}-{arch}")
                    with tf.extractfile(target) as src, open(dest, 'wb') as dst:
                        shutil.copyfileobj(src, dst)
                    os.chmod(dest, 0o755)
                    saved.append(f"{tool}-{arch}")

            elif btype == 'tar_frp':
                with tarfile.open(archive) as tf:
                    for member in tf.getmembers():
                        bname = os.path.basename(member.name)
                        if bname in ('frps', 'frpc') and member.isfile():
                            dest = os.path.join(BINARIES_DIR, f"{bname}-{arch}")
                            with tf.extractfile(member) as src, open(dest, 'wb') as dst:
                                shutil.copyfileobj(src, dst)
                            os.chmod(dest, 0o755)
                            saved.append(f"{bname}-{arch}")

            elif btype == 'gz':
                dest = os.path.join(BINARIES_DIR, f"{tool}-{arch}")
                with _gzip.open(archive) as src, open(dest, 'wb') as dst:
                    shutil.copyfileobj(src, dst)
                os.chmod(dest, 0o755)
                saved.append(f"{tool}-{arch}")

        except Exception as e:
            return False, f'Extraction error: {e} (url={url})', []

    if not saved:
        return False, f'No binaries extracted from archive (url={url})', []
    return True, f'Saved: {", ".join(saved)} (ver={ver})', saved


# ── Xray ──────────────────────────────────────────────────────────────────────

xray_process  = None
xray_log_buf  = deque(maxlen=500)
_PANEL_DIR    = os.path.dirname(os.path.abspath(__file__))
_PARENT_DIR   = os.path.dirname(_PANEL_DIR)
_XRAY_API_PORT = 10085

import platform as _platform
if _platform.system() == 'Windows':
    DEFAULT_BIN = os.environ.get('XRAY_BINARY',
                    next((os.path.join(_PARENT_DIR, n)
                          for n in ('xray.exe', 'xray-windows-amd64.exe')
                          if os.path.isfile(os.path.join(_PARENT_DIR, n))), 'xray.exe'))
else:
    DEFAULT_BIN = os.environ.get('XRAY_BINARY',
                    next((os.path.join(_PARENT_DIR, n)
                          for n in ('xray', 'xray-linux-amd64', 'xray-linux-arm64')
                          if os.path.isfile(os.path.join(_PARENT_DIR, n))),
                         './xray-linux-amd64'))

CONFIG_FILE       = os.path.join(_PANEL_DIR, 'generated-config.json')
BINARIES_DIR      = os.path.join(_PANEL_DIR, 'binaries')
BACKHAUL_P_DIR    = os.path.join(os.path.dirname(_PANEL_DIR), 'backhaul_p')
os.makedirs(BINARIES_DIR, exist_ok=True)

# ── Stats tracking ────────────────────────────────────────────────────────────

_stats_snapshot      = {}           # {uuid: {uplink: bytes, downlink: bytes}}
_bw_history          = deque(maxlen=120)  # {ts, down_gb, up_gb} every 30s
_stats_thread_started = False
_user_last_seen      = {}           # {uuid: {'ts': datetime, 'ip': str}}

# Live per-session tracking (feeds the Online users page)
ONLINE_WINDOW_MIN    = 5            # a user drops off the list after this many idle minutes
_SPARK_POINTS        = 18           # throughput samples kept per user
_user_session_start  = {}           # {uuid: datetime}  — start of the current session
_user_rate_hist      = {}           # {uuid: deque[float]} — Mbps samples, one per stats poll
_stats_last_ts       = None         # timestamp of the previous successful stats poll

# Patterns for Xray access log lines
_ACCESS_IP_RE   = re.compile(r'(?:from\s+)?(\d{1,3}(?:\.\d{1,3}){3}):\d+')
_ACCESS_UUID_RE = re.compile(r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')

# ── Device limit, enforced at the tunnel ──────────────────────────────────────
#  ip_limit was only ever advisory: the client API refuses a sign-in past the
#  limit, but an app that already holds a config never asks again, and anything
#  using the subscription link never asks at all. Xray's `limitIp` client field
#  does not help either — it is a 3x-ui extension that the core silently
#  ignores. So the limit has to be applied where the traffic actually is.
#
#  The access log names both the user (their uuid is the email) and the address
#  the connection came from, which is enough to see how many places an account
#  is in use from. Everything past the limit gets a source-matched block rule in
#  the generated config.
IP_LIMIT_WINDOW_MIN  = 5    # an address stops holding a slot after this silence
IP_LIMIT_REAPPLY_SEC = 90   # never restart Xray more often than this

_user_active_ips  = {}      # {uuid: {ip: {'first': dt, 'last': dt}}}
_ip_blocklist     = {}      # {uuid: set(ip)} — what the live config blocks
_ip_block_last_at = None


def _touch_user_ip(uid, ip):
    """Record that this user is carrying traffic from [ip] right now."""
    if not ip:
        return
    seen = _user_active_ips.setdefault(uid, {})
    rec  = seen.get(ip)
    now  = _utcnow()
    if rec is None:
        seen[ip] = {'first': now, 'last': now}
    else:
        rec['last'] = now


def _active_user_ips(uid):
    """[(ip, rec)] seen inside the window, longest-established first.

    Sorted on first sight rather than last: the addresses that got there first
    are the ones that keep the slots, so a shared account settles on whoever is
    already connected instead of flapping between devices.
    """
    cutoff = _utcnow() - timedelta(minutes=IP_LIMIT_WINDOW_MIN)
    seen   = _user_active_ips.get(uid, {})
    for ip in [k for k, v in seen.items() if v['last'] < cutoff]:
        seen.pop(ip, None)
    return sorted(seen.items(), key=lambda kv: kv[1]['first'])


def _ip_limit_enforced():
    return get_setting('ip_limit_enforce', 'true').strip().lower() in ('1', 'true', 'yes')


def _recompute_ip_blocks():
    """{uuid: {ip}} for every address currently over its account's limit."""
    wanted = {}
    for u in User.query.filter(User.ip_limit > 0).all():
        limit = u.ip_limit or 0
        # Belt and braces against the query above ever changing: an uncapped
        # account reaching this loop would have every one of its addresses
        # blocked, which is the worst possible way to get this wrong.
        if limit <= 0:
            continue
        active = _active_user_ips(u.uuid)
        if len(active) <= limit:
            continue
        wanted[u.uuid] = {ip for ip, _ in active[limit:]}
    return wanted


def _enforce_ip_limits():
    """Push the block list into Xray, but only when it actually changed.

    Applying a config restarts the core and drops everybody, so this is
    deliberately lazy: no change means no restart, and even a real change waits
    out IP_LIMIT_REAPPLY_SEC so a device retrying in a loop cannot turn into a
    restart loop.
    """
    global _ip_blocklist, _ip_block_last_at
    with app.app_context():
        wanted = _recompute_ip_blocks() if _ip_limit_enforced() else {}
        if wanted == _ip_blocklist:
            return
        now = _utcnow()
        if (_ip_block_last_at is not None
                and (now - _ip_block_last_at).total_seconds() < IP_LIMIT_REAPPLY_SEC):
            return
        _ip_blocklist     = wanted
        _ip_block_last_at = now
        try:
            apply_config()
        except Exception:
            pass


def _touch_user_seen(uid, ip=None):
    """Record activity for a user UUID.

    Keeps `_user_last_seen` fresh and opens a new session whenever the user has
    been idle for longer than the online window (i.e. they dropped off the list
    and came back). `ip` of None keeps whatever IP we already had.
    """
    now  = datetime.now(timezone.utc).replace(tzinfo=None)
    prev = _user_last_seen.get(uid)
    if prev is None or (now - prev['ts']).total_seconds() > ONLINE_WINDOW_MIN * 60:
        _user_session_start[uid] = now
        _user_rate_hist.pop(uid, None)
    _user_last_seen[uid] = {
        'ts': now,
        'ip': ip if ip else (prev or {}).get('ip', '?'),
    }


def _record_user_rate(uid, bytes_delta, elapsed_s):
    """Append one throughput sample (Mbps) to the user's rolling history."""
    if elapsed_s <= 0:
        return
    hist = _user_rate_hist.get(uid)
    if hist is None:
        hist = deque(maxlen=_SPARK_POINTS)
        _user_rate_hist[uid] = hist
    hist.append(round((bytes_delta * 8) / elapsed_s / 1_000_000, 3))


# ── IP → country ──────────────────────────────────────────────────────────────
# Uses a local MaxMind database when one is available; never calls out to the
# network. Returns None when the country genuinely cannot be determined, so the
# UI can hide the badge instead of showing a made-up value.

GEOIP_DB_CANDIDATES = [
    os.path.join(_PANEL_DIR, 'GeoLite2-Country.mmdb'),
    '/usr/share/GeoIP/GeoLite2-Country.mmdb',
    '/var/lib/GeoIP/GeoLite2-Country.mmdb',
]
_geoip_reader  = None
_geoip_checked = False
_geoip_cache   = {}


def _geoip_get_reader():
    global _geoip_reader, _geoip_checked
    if _geoip_checked:
        return _geoip_reader
    _geoip_checked = True
    try:
        import geoip2.database  # optional dependency
    except Exception:
        return None
    for path in [get_setting('geoip_db', '')] + GEOIP_DB_CANDIDATES:
        if path and os.path.isfile(path):
            try:
                _geoip_reader = geoip2.database.Reader(path)
                break
            except Exception:
                continue
    return _geoip_reader


def _ip_country(ip):
    """Two-letter country code for an IP, 'LAN' for private ranges, None if unknown."""
    if not ip or ip == '?':
        return None
    if ip in _geoip_cache:
        return _geoip_cache[ip]
    code = None
    try:
        addr = ipaddress.ip_address(ip)
        if addr.is_private or addr.is_loopback or addr.is_link_local:
            code = 'LAN'
        else:
            reader = _geoip_get_reader()
            if reader is not None:
                code = reader.country(ip).country.iso_code or None
    except Exception:
        code = None
    _geoip_cache[ip] = code
    return code


def _query_xray_stats(binary):
    """Run 'xray api statsquery', return:
      {'users': {email: {uplink, downlink}},
       'inbounds': {tag: {uplink, downlink}}}
    or None on error. Must be called with a resolved binary path (no DB access).
    """
    if not os.path.isfile(binary):
        xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'),
                             'line': f'[stats] binary not found: {binary}'})
        return None
    try:
        result = subprocess.run(
            [binary, 'api', 'statsquery',
             f'--server=127.0.0.1:{_XRAY_API_PORT}', '--pattern', ''],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            err = (result.stderr or result.stdout or '').strip()[:200]
            xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'),
                                 'line': f'[stats] statsquery rc={result.returncode}: {err}'})
            return None
        raw = (result.stdout or '').strip()
        if not raw:
            return {'users': {}, 'inbounds': {}}
        data = json.loads(raw)
        users    = {}
        inbounds = {}
        for stat in data.get('stat', []):
            name  = stat.get('name', '')
            value = int(stat.get('value', 0) or 0)
            parts = name.split('>>>')
            # format: KIND>>>ID>>>traffic>>>uplink|downlink
            if len(parts) != 4 or parts[2] != 'traffic':
                continue
            kind, tag, _, direction = parts
            if direction not in ('uplink', 'downlink'):
                continue
            if kind == 'user':
                if tag not in users:
                    users[tag] = {'uplink': 0, 'downlink': 0}
                users[tag][direction] = value
            elif kind == 'inbound' and tag != 'api':
                if tag not in inbounds:
                    inbounds[tag] = {'uplink': 0, 'downlink': 0}
                inbounds[tag][direction] = value
        return {'users': users, 'inbounds': inbounds}
    except Exception as e:
        xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'),
                             'line': f'[stats] query exception: {e}'})
        return None


def _log_activity(action, target='', detail=''):
    """Append one ActivityLog row.  Does NOT commit — caller must commit."""
    rid = _get_reseller_id() if not current_user.is_authenticated else None
    if rid is not None:
        r = db.session.get(Reseller, rid)
        actor = r.username if r else 'reseller'
        role  = 'reseller'
    elif current_user.is_authenticated:
        actor = current_user.username
        role  = getattr(current_user, 'role', 'superadmin')
    else:
        actor, role = 'system', 'system'
    db.session.add(ActivityLog(
        actor=actor, actor_role=role,
        action=action, target=str(target or ''), detail=str(detail or ''),
    ))
    # Keep only the 500 most recent rows (lazy cleanup — runs on write)
    try:
        oldest_ids = db.session.query(ActivityLog.id).order_by(ActivityLog.ts.desc()).offset(500).all()
        if oldest_ids:
            ActivityLog.query.filter(ActivityLog.id.in_([r[0] for r in oldest_ids])).delete(synchronize_session=False)
    except Exception:
        pass


def _upsert_reseller_snapshots(today=None):
    """Upsert one ResellerTrafficLog row per reseller for *today*.
    Includes traffic from deleted users so data is never lost.
    Safe to call many times per day — uses INSERT-or-UPDATE logic.
    """
    if today is None:
        today = _utcnow().date()
    for reseller in Reseller.query.all():
        cur_allocated = reseller.total_allocated_gb()
        cur_used      = reseller.total_used_gb()
        existing = ResellerTrafficLog.query.filter_by(reseller_id=reseller.id, date=today).first()
        if existing:
            existing.allocated_gb = round(cur_allocated, 3)
            existing.used_gb      = round(cur_used, 3)
        else:
            db.session.add(ResellerTrafficLog(
                reseller_id  = reseller.id,
                date         = today,
                allocated_gb = round(cur_allocated, 3),
                used_gb      = round(cur_used, 3),
            ))
    db.session.commit()


def _update_stats():
    """Poll Xray stats, update per-user traffic in DB, record bandwidth history.
    - Inbound-level totals → bandwidth chart (always available once traffic flows)
    - User-level stats     → per-user accounting (available after first connection)
    Must run inside an app context (reads settings + writes DB).
    """
    global _stats_snapshot, _stats_last_ts

    with app.app_context():
        binary = get_setting('xray_binary', DEFAULT_BIN)
        result = _query_xray_stats(binary)
        if result is None:
            return

        user_stats    = result['users']     # {uuid: {uplink, downlink}}
        inbound_stats = result['inbounds']  # {tag:  {uplink, downlink}}

        # Seconds since the previous successful poll — used for throughput.
        poll_ts   = datetime.now(timezone.utc).replace(tzinfo=None)
        elapsed_s = (poll_ts - _stats_last_ts).total_seconds() if _stats_last_ts else 0

        # ── Per-user traffic delta ──────────────────────────────────────────
        prev_users   = _stats_snapshot.get('__users__', {})
        # First poll after a restart has no baseline: the "delta" is really the
        # lifetime counter, so it must not mark long-gone users as online.
        is_baseline  = '__users__' not in _stats_snapshot
        newly_limited = []   # users that crossed the limit this poll
        for email, vals in user_stats.items():
            prev       = prev_users.get(email, {'uplink': 0, 'downlink': 0})
            delta_up   = max(0, vals['uplink']   - prev.get('uplink',   0))
            delta_down = max(0, vals['downlink'] - prev.get('downlink', 0))
            # Throughput sample for anyone currently on the online list — a zero
            # sample is meaningful (it's what makes an idling session flatline).
            if email in _user_last_seen:
                _record_user_rate(email, delta_up + delta_down, elapsed_s)
            if delta_up + delta_down > 0:
                u = User.query.filter_by(uuid=email).first()
                if u:
                    u.traffic_used = round(
                        (u.traffic_used or 0) + (delta_up + delta_down) / 1_073_741_824, 6)
                    if u.status == 'active' and u.is_over_limit():
                        u.status = 'limit'
                        newly_limited.append(u.name)
                    # Update last-seen from stats (IP comes from log parser if available)
                    if not is_baseline:
                        _touch_user_seen(email)
                        if email not in _user_rate_hist:
                            _record_user_rate(email, delta_up + delta_down, elapsed_s)
        _stats_last_ts = poll_ts
        db.session.commit()

        # Push config to Xray immediately so over-limit users are kicked out.
        # Only fires when at least one user just crossed the threshold this poll.
        if newly_limited:
            try:
                apply_config()
            except Exception:
                pass

        # ── Bandwidth history from inbound totals ───────────────────────────
        # Inbound stats always reflect total traffic through the system,
        # even when individual user attribution hasn't fired yet.
        prev_inbounds = _stats_snapshot.get('__inbounds__', {})
        interval_up = interval_down = 0
        for tag, vals in inbound_stats.items():
            prev          = prev_inbounds.get(tag, {'uplink': 0, 'downlink': 0})
            interval_up   += max(0, vals['uplink']   - prev.get('uplink',   0))
            interval_down += max(0, vals['downlink'] - prev.get('downlink', 0))

        # Update snapshot
        _stats_snapshot = {
            '__users__':    user_stats,
            '__inbounds__': inbound_stats,
        }

        now_ts = _utcnow()
        _bw_history.append({
            'ts':      now_ts.strftime('%H:%M'),
            'down_gb': round(interval_down / 1_073_741_824, 6),
            'up_gb':   round(interval_up   / 1_073_741_824, 6),
        })
        # Persist to TrafficRecord for long-term traffic history
        db.session.add(TrafficRecord(
            ts=now_ts,
            down_gb=round(interval_down / 1_073_741_824, 6),
            up_gb=round(interval_up / 1_073_741_824, 6),
        ))
        # Keep only last 30 days
        cutoff = now_ts - timedelta(days=30)
        TrafficRecord.query.filter(TrafficRecord.ts < cutoff).delete()
        db.session.commit()

        # ── Reseller traffic snapshot (upsert every poll so history stays live) ──
        _upsert_reseller_snapshots(now_ts.date())


# ── tc / HTB speed-limit enforcer ────────────────────────────────────────────

_tc_current         = {}    # ip → speed_kbps currently applied
_tc_iface_cache     = None
_tc_available       = None  # None = unchecked, True/False
_tc_last_reset_date = None  # date of last daily wipe


def _tc_check_available():
    global _tc_available
    if _tc_available is not None:
        return _tc_available
    try:
        r  = subprocess.run(['tc', '-V'], capture_output=True, timeout=3)
        r2 = subprocess.run(['id', '-u'], capture_output=True, text=True, timeout=3)
        _tc_available = (r.returncode == 0 and r2.stdout.strip() == '0')
    except Exception:
        _tc_available = False
    if not _tc_available:
        app.logger.warning('[tc] tc not available or not root — speed limiting disabled')
    return _tc_available


def _tc_detect_iface():
    global _tc_iface_cache
    manual = get_setting('tc_iface', '')
    if manual:
        _tc_iface_cache = manual
        return manual
    if _tc_iface_cache:
        return _tc_iface_cache
    try:
        out = subprocess.check_output(
            ['ip', 'route', 'get', '1.1.1.1'], text=True, timeout=5
        )
        toks = out.split()
        if 'dev' in toks:
            _tc_iface_cache = toks[toks.index('dev') + 1]
            return _tc_iface_cache
    except Exception:
        pass
    _tc_iface_cache = 'eth0'
    return _tc_iface_cache


def _tc_run(*args):
    return subprocess.run(['tc'] + list(args), capture_output=True)


def _tc_rebuild(iface, desired):
    """Tear down and rebuild all HTB rules for `desired` = {ip: kbps}."""
    # Remove existing root qdisc (ignoring error if none)
    _tc_run('qdisc', 'del', 'dev', iface, 'root')
    # New root HTB; class 1:999 is the unlimited default
    _tc_run('qdisc', 'add', 'dev', iface, 'root', 'handle', '1:', 'htb', 'default', '999')
    _tc_run('class', 'add', 'dev', iface,
            'parent', '1:', 'classid', '1:999', 'htb', 'rate', '10000mbit', 'burst', '1m')

    speed_to_minor = {}
    next_minor = 1
    for ip, kbps in desired.items():
        if kbps not in speed_to_minor:
            minor = next_minor
            next_minor += 1
            if minor >= 999:
                break
            speed_to_minor[kbps] = minor
            _tc_run('class', 'add', 'dev', iface,
                    'parent', '1:', 'classid', f'1:{minor}',
                    'htb', 'rate', f'{kbps}kbit', 'burst', '64k')
        minor = speed_to_minor[kbps]
        # Limit egress (download) to user's IP
        _tc_run('filter', 'add', 'dev', iface, 'parent', '1:',
                'protocol', 'ip', 'prio', '1', 'u32',
                'match', 'ip', 'dst', f'{ip}/32',
                'flowid', f'1:{minor}')


def _apply_speed_limits():
    """Enforce speed_limit_kbps via tc HTB. Called from the stats loop."""
    global _tc_current
    if not _tc_check_available():
        return

    with app.app_context():
        now    = datetime.now(timezone.utc).replace(tzinfo=None)
        cutoff = now - timedelta(minutes=5)

        desired = {}
        for u in User.query.filter(
            User.speed_limit_kbps > 0,
            User.status == 'active',
        ).all():
            info = _user_last_seen.get(u.uuid)
            if not info or info['ts'] < cutoff:
                continue
            ip = info.get('ip', '')
            if not ip or ip == '?':
                continue
            # Strictest limit wins when multiple users share an IP
            desired[ip] = min(desired.get(ip, u.speed_limit_kbps), u.speed_limit_kbps)

        if desired == _tc_current:
            return

        iface = _tc_detect_iface()
        try:
            _tc_rebuild(iface, desired)
            _tc_current = desired.copy()
        except Exception as e:
            app.logger.error(f'[tc] rebuild failed: {e}')


def _tc_cleanup():
    """Remove all tc rules — called when Xray stops."""
    global _tc_current
    if not _tc_available or not _tc_current:
        return
    try:
        iface = _tc_detect_iface()
        _tc_run('qdisc', 'del', 'dev', iface, 'root')
    except Exception:
        pass
    _tc_current = {}


def _tc_daily_reset():
    """Wipe all IP-based tc rules at 23:59 so stale IP→user mappings don't linger.
    Active limited users get their rules re-applied on the next stats cycle when
    Xray logs their new connection IP."""
    global _tc_current, _tc_last_reset_date
    if not _tc_check_available():
        return
    today = datetime.now().date()
    if _tc_last_reset_date == today:
        return   # already reset today
    try:
        iface = _tc_detect_iface()
        _tc_run('qdisc', 'del', 'dev', iface, 'root')
        _tc_current = {}
        _tc_last_reset_date = today
        app.logger.info('[tc] 23:59 daily reset — all IP speed rules cleared')
    except Exception as e:
        app.logger.error(f'[tc] daily reset failed: {e}')


def _expire_users():
    """Set status='expired' for any active user whose expiry time has passed,
    then kick them out of Xray immediately (same approach as traffic-limit kick)."""
    with app.app_context():
        now = _utcnow()
        newly_expired = User.query.filter(
            User.status == 'active',
            User.expires != None,
            User.expires < now,
        ).all()
        if not newly_expired:
            return
        for u in newly_expired:
            u.status = 'expired'
        db.session.commit()
        try:
            apply_config()
        except Exception:
            pass


def _stats_loop():
    while True:
        time.sleep(30)
        try:
            _update_stats()
        except Exception:
            pass
        try:
            _expire_users()
        except Exception:
            pass
        try:
            _apply_speed_limits()
        except Exception:
            pass
        try:
            _enforce_ip_limits()
        except Exception:
            pass
        try:
            now = datetime.now()
            if now.hour == 23 and now.minute == 59:
                _tc_daily_reset()
        except Exception:
            pass


def _start_stats_thread():
    global _stats_thread_started
    if not _stats_thread_started:
        _stats_thread_started = True
        threading.Thread(target=_stats_loop, daemon=True).start()


# ── Config builder helpers ────────────────────────────────────────────────────

def _build_tls_settings(s, cert, key):
    """Build a tlsSettings dict. Returns None if cert/key are empty."""
    if not cert or not key:
        return None
    tls = {"certificates": [{"certificateFile": cert, "keyFile": key}]}
    if s.get("tls_server_name"):
        tls["serverName"] = s["tls_server_name"]
    alpn = s.get("alpn", [])
    if isinstance(alpn, list) and alpn:
        tls["alpn"] = alpn
    elif isinstance(alpn, str) and alpn:
        tls["alpn"] = [a.strip() for a in alpn.split(',') if a.strip()]
    if s.get("fingerprint"):
        tls["fingerprint"] = s["fingerprint"]
    if s.get("reject_unknown_sni"):
        tls["rejectUnknownSni"] = True
    return tls


def _build_sniffing(s):
    """Build a sniffing block from settings, or return None if disabled."""
    if not s.get("sniffing_enabled"):
        return None
    dest = []
    if s.get("sniff_http",  True):    dest.append("http")
    if s.get("sniff_tls",   True):    dest.append("tls")
    if s.get("sniff_quic",  False):   dest.append("quic")
    if s.get("sniff_fakedns", False): dest.append("fakedns")
    sniff = {"enabled": True, "destOverride": dest or ["http", "tls"]}
    if s.get("sniff_route_only"):
        sniff["routeOnly"] = True
    return sniff


# ── Config builder ────────────────────────────────────────────────────────────

def build_config():
    config = {
        "log": {"loglevel": "warning", "access": ""},  # access="" → stdout for online-user tracking
        "stats": {},
        "api": {
            "tag": "api",
            "services": ["StatsService"]
        },
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True}
        },
        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": _XRAY_API_PORT,
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
                "tag": "api"
            }
        ],
        "outbounds": [
            {"protocol": "freedom",   "settings": {}, "tag": "direct"},
            {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
        ],
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
            ]
        }
    }

    # ── Per-inbound OUT proxy: build one outbound entry per unique out server ──
    # Each inbound that has out_server_id set gets its own routing rule pointing
    # to that server's Xray bridge.  Inbounds without out_server_id use direct.
    _built_out_tags = {}   # server_id (str) → outbound tag

    def _ensure_out_proxy(srv_id_str):
        """Return the outbound tag for srv_id, building it into config if needed."""
        if srv_id_str in _built_out_tags:
            return _built_out_tags[srv_id_str]
        try:
            out_srv = db.session.get(Server, int(srv_id_str))
            if not out_srv:
                return None
            s_out   = out_srv.get_settings()
            o_port  = int(s_out.get('out_proxy_port', 10001))
            o_uuid  = s_out.get('out_proxy_uuid', '')
            o_proto = s_out.get('out_proxy_protocol', 'vless')
            if not o_uuid:
                return None
            tag = f"out-proxy-{srv_id_str}"
            if o_proto == 'vmess':
                outb = {
                    "tag": tag, "protocol": "vmess",
                    "settings": {"vnext": [{
                        "address": out_srv.ip, "port": o_port,
                        "users": [{"id": o_uuid, "alterId": 0, "level": 0}]
                    }]},
                    "streamSettings": {"network": "tcp"}
                }
            else:
                outb = {
                    "tag": tag, "protocol": "vless",
                    "settings": {"vnext": [{
                        "address": out_srv.ip, "port": o_port,
                        "users": [{"id": o_uuid, "encryption": "none", "level": 0}]
                    }]},
                    "streamSettings": {"network": "tcp"}
                }
            config["outbounds"].append(outb)
            _built_out_tags[srv_id_str] = tag
            return tag
        except Exception:
            return None

    # ── Device limit ──────────────────────────────────────────────────────────
    # Addresses past the account's ip_limit, worked out from the access log by
    # _enforce_ip_limits(). First in the list on purpose: Xray takes the first
    # matching rule, so this has to beat any per-user or per-inbound rule that
    # would otherwise send the same traffic to `direct`.
    for _limited_uuid, _limited_ips in sorted(_ip_blocklist.items()):
        if _limited_ips:
            config["routing"]["rules"].append({
                "type": "field", "user": [_limited_uuid],
                "source": sorted(_limited_ips), "outboundTag": "blocked"
            })

    # ── Access control: server IP is always implicitly allowed in whitelists ──
    _server_ip = get_setting('server_ip', '0.0.0.0')

    # ── User-level access rules (processed first — most specific, highest priority) ──
    # Rules use user email (= uuid) so they apply regardless of which inbound is used.
    _enabled_inbounds = Inbound.query.filter_by(enabled=True).all()
    _seen_user_ids = set()
    for _ib in _enabled_inbounds:
        for _u in _ib.users:
            if _u.id in _seen_user_ids:
                continue
            _seen_user_ids.add(_u.id)
            if _u.status != 'active' or _u.is_expired() or _u.is_over_limit():
                continue
            _u_mode = (_u.access_mode or 'none').strip()
            if _u_mode == 'none':
                continue
            _u_domains = json.loads(_u.access_domains or '[]')
            _u_ips     = json.loads(_u.access_ips     or '[]')

            if _u_mode == 'blacklist':
                if _u_domains:
                    config["routing"]["rules"].append({
                        "type": "field", "user": [_u.uuid],
                        "domain": _u_domains, "outboundTag": "blocked"
                    })
                if _u_ips:
                    config["routing"]["rules"].append({
                        "type": "field", "user": [_u.uuid],
                        "ip": _u_ips, "outboundTag": "blocked"
                    })

            elif _u_mode == 'whitelist':
                # Auto-include server IP, loopback, and public DNS so apps can resolve hostnames
                _effective_ips = list({_server_ip, "127.0.0.1", "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1"} | set(_u_ips))
                if _u_domains:
                    config["routing"]["rules"].append({
                        "type": "field", "user": [_u.uuid],
                        "domain": _u_domains, "outboundTag": "direct"
                    })
                config["routing"]["rules"].append({
                    "type": "field", "user": [_u.uuid],
                    "ip": _effective_ips, "outboundTag": "direct"
                })
                # Block everything else for this user
                config["routing"]["rules"].append({
                    "type": "field", "user": [_u.uuid], "outboundTag": "blocked"
                })

    for ib in _enabled_inbounds:
        s      = ib.get_settings()
        proto  = ib.protocol.lower()
        listen = s.get("listen", "0.0.0.0")

        # ── Build clients list (UUID-based protocols) ──
        clients = []
        for u in ib.users:
            if u.status != 'active' or u.is_expired() or u.is_over_limit():
                continue
            if proto == 'vless':
                entry = {"id": u.uuid, "email": u.uuid, "level": 0}
                if ib.transport == 'reality':
                    entry["flow"] = "xtls-rprx-vision"
                if u.ip_limit and u.ip_limit > 0:
                    entry["limitIp"] = u.ip_limit
                clients.append(entry)
            elif proto == 'vmess':
                entry = {"id": u.uuid, "email": u.uuid, "alterId": 0, "level": 0}
                if u.ip_limit and u.ip_limit > 0:
                    entry["limitIp"] = u.ip_limit
                clients.append(entry)
            elif proto == 'trojan':
                entry = {"password": u.uuid, "email": u.uuid, "level": 0}
                if u.ip_limit and u.ip_limit > 0:
                    entry["limitIp"] = u.ip_limit
                clients.append(entry)

        # ── Build protocol-level inbound object ──
        if proto == 'vless':
            inb = {"listen": listen, "port": ib.port, "protocol": "vless", "tag": ib.tag,
                   "settings": {"clients": clients, "decryption": "none"}}
        elif proto == 'vmess':
            inb = {"listen": listen, "port": ib.port, "protocol": "vmess", "tag": ib.tag,
                   "settings": {"clients": clients}}
        elif proto == 'trojan':
            inb = {"listen": listen, "port": ib.port, "protocol": "trojan", "tag": ib.tag,
                   "settings": {"clients": clients}}
        elif proto == 'shadowsocks':
            inb = {"listen": listen, "port": ib.port, "protocol": "shadowsocks", "tag": ib.tag,
                   "settings": {"method":   s.get("method", "chacha20-ietf-poly1305"),
                                 "password": s.get("password", ""),
                                 "network":  "tcp,udp"}}
        elif proto == 'socks':
            socks_cfg = {"udp": s.get("udp", True)}
            if s.get("ip"):
                socks_cfg["ip"] = s["ip"]
            if s.get("auth") == "password":
                socks_cfg["auth"]     = "password"
                socks_cfg["accounts"] = s.get("accounts", [])
            else:
                socks_cfg["auth"] = "noauth"
            inb = {"listen": listen, "port": ib.port, "protocol": "socks", "tag": ib.tag,
                   "settings": socks_cfg}
        elif proto == 'http':
            http_cfg = {}
            if s.get("allow_transparent"):
                http_cfg["allowTransparent"] = True
            if s.get("http_accounts"):
                http_cfg["accounts"] = s["http_accounts"]
            inb = {"listen": listen, "port": ib.port, "protocol": "http", "tag": ib.tag,
                   "settings": http_cfg}
        else:
            continue   # unknown protocol — skip

        # ── Build stream settings ──
        # Cert hierarchy: per-inbound cert → global setting
        cert = s.get("cert_file") or get_setting("tls_cert_file", "")
        key  = s.get("key_file")  or get_setting("tls_key_file", "")
        tls_type = s.get("tls_type", "none")

        # reality is stored as transport='reality' but stream network is tcp
        net    = 'tcp' if ib.transport == 'reality' else ib.transport
        stream = {"network": net}

        if ib.transport == 'tcp':
            if tls_type == "tls":
                tls_cfg = _build_tls_settings(s, cert, key)
                if tls_cfg:
                    stream["security"]    = "tls"
                    stream["tlsSettings"] = tls_cfg
                else:
                    stream["security"] = "none"
            else:
                stream["security"] = "none"
            # TCP header obfuscation (rawSettings)
            header_type = s.get("tcp_header_type", "none")
            tcp_s = {}
            if s.get("accept_proxy_protocol"):
                tcp_s["acceptProxyProtocol"] = True
            if header_type and header_type != "none":
                hdr = {"type": header_type}
                if header_type == "http":
                    hdr["request"] = {
                        "version": "1.1",
                        "method": "GET",
                        "path": [s.get("tcp_header_path", "/")],
                        "headers": {
                            "Host": [s.get("tcp_header_host", "")],
                            "User-Agent": ["Mozilla/5.0"],
                            "Accept-Encoding": ["gzip, deflate"],
                            "Connection": ["keep-alive"],
                            "Pragma": "no-cache"
                        }
                    }
                    hdr["response"] = {
                        "version": "1.1", "status": "200", "reason": "OK",
                        "headers": {
                            "Content-Type": ["application/octet-stream"],
                            "Transfer-Encoding": ["chunked"],
                            "Connection": ["keep-alive"],
                            "Pragma": "no-cache"
                        }
                    }
                tcp_s["header"] = hdr
            if tcp_s:
                stream["tcpSettings"] = tcp_s

        elif ib.transport == 'ws':
            tls_cfg = _build_tls_settings(s, cert, key) if tls_type == "tls" else None
            stream["security"] = "tls" if tls_cfg else "none"
            ws = {"path": s.get("ws_path", "/ws")}
            # Use top-level "host" (headers.Host is deprecated since Xray-core v25+)
            if s.get("ws_host"):
                ws["host"] = s["ws_host"]
            if s.get("ws_heartbeat"):
                ws["heartbeatPeriod"] = int(s["ws_heartbeat"])
            if s.get("accept_proxy_protocol"):
                ws["acceptProxyProtocol"] = True
            stream["wsSettings"] = ws
            if tls_cfg:
                stream["tlsSettings"] = tls_cfg

        elif ib.transport == 'xhttp':
            tls_cfg = _build_tls_settings(s, cert, key) if tls_type == "tls" else None
            stream["security"] = "tls" if tls_cfg else "none"
            xhttp = {"path": s.get("xhttp_path", "/"), "mode": s.get("xhttp_mode", "auto")}
            if s.get("ws_host") or s.get("xhttp_host"):
                xhttp["host"] = s.get("xhttp_host") or s.get("ws_host", "")
            if s.get("xhttp_extra"):
                try: xhttp["extra"] = json.loads(s["xhttp_extra"])
                except Exception: pass
            stream["xhttpSettings"] = xhttp
            if tls_cfg:
                stream["tlsSettings"] = tls_cfg

        elif ib.transport == 'grpc':
            tls_cfg = _build_tls_settings(s, cert, key) if tls_type == "tls" else None
            stream["security"] = "tls" if tls_cfg else "none"
            grpc = {"serviceName": s.get("grpc_service", "xray")}
            if s.get("grpc_authority"):
                grpc["authority"] = s["grpc_authority"]
            if s.get("grpc_multi_mode"):
                grpc["multiMode"] = True
            stream["grpcSettings"] = grpc
            if tls_cfg:
                stream["tlsSettings"] = tls_cfg

        elif ib.transport == 'mkcp':
            stream["network"]  = "kcp"
            stream["security"] = "none"
            kcp = {}
            if s.get("kcp_mtu"):          kcp["mtu"]               = int(s["kcp_mtu"])
            if s.get("kcp_tti"):          kcp["tti"]               = int(s["kcp_tti"])
            if s.get("kcp_uplink"):       kcp["uplinkCapacity"]    = int(s["kcp_uplink"])
            if s.get("kcp_downlink"):     kcp["downlinkCapacity"]  = int(s["kcp_downlink"])
            if s.get("kcp_congestion"):   kcp["congestion"]        = True
            if s.get("kcp_read_buf"):     kcp["readBufferSize"]    = int(s["kcp_read_buf"])
            if s.get("kcp_write_buf"):    kcp["writeBufferSize"]   = int(s["kcp_write_buf"])
            if kcp:
                stream["kcpSettings"] = kcp

        elif ib.transport == 'httpupgrade':
            tls_cfg = _build_tls_settings(s, cert, key) if tls_type == "tls" else None
            stream["security"] = "tls" if tls_cfg else "none"
            hu = {"path": s.get("hu_path", "/")}
            if s.get("hu_host"):
                hu["host"] = s["hu_host"]
            if s.get("hu_accept_proxy"):
                hu["acceptProxyProtocol"] = True
            stream["httpupgradeSettings"] = hu
            if tls_cfg:
                stream["tlsSettings"] = tls_cfg

        elif ib.transport == 'reality':
            stream["security"] = "reality"
            short_id = s.get("short_id", "")
            reality  = {
                "show":        False,
                "dest":        s.get("dest", "www.cloudflare.com:443"),
                "xver":        0,
                "serverNames": [s.get("sni", "www.cloudflare.com")],
                "privateKey":  s.get("private_key", ""),
                "shortIds":    [short_id] if short_id else [""]
            }
            if s.get("fingerprint"):
                reality["fingerprint"] = s["fingerprint"]
            stream["realitySettings"] = reality

        inb["streamSettings"] = stream

        # ── Sniffing ──
        sniff = _build_sniffing(s)
        if sniff:
            inb["sniffing"] = sniff

        config["inbounds"].append(inb)

        # ── Inbound-level access control rules ──
        _ib_mode = (ib.access_mode or 'none').strip()
        if _ib_mode != 'none':
            _ib_domains = json.loads(ib.access_domains or '[]')
            _ib_ips     = json.loads(ib.access_ips     or '[]')

            if _ib_mode == 'blacklist':
                if _ib_domains:
                    config["routing"]["rules"].append({
                        "type": "field", "inboundTag": [ib.tag],
                        "domain": _ib_domains, "outboundTag": "blocked"
                    })
                if _ib_ips:
                    config["routing"]["rules"].append({
                        "type": "field", "inboundTag": [ib.tag],
                        "ip": _ib_ips, "outboundTag": "blocked"
                    })

            elif _ib_mode == 'whitelist':
                # Auto-include server IP, loopback, and public DNS so apps can resolve hostnames
                _effective_ips = list({_server_ip, "127.0.0.1", "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1"} | set(_ib_ips))
                if _ib_domains:
                    config["routing"]["rules"].append({
                        "type": "field", "inboundTag": [ib.tag],
                        "domain": _ib_domains, "outboundTag": "direct"
                    })
                config["routing"]["rules"].append({
                    "type": "field", "inboundTag": [ib.tag],
                    "ip": _effective_ips, "outboundTag": "direct"
                })
                # Block all remaining traffic from this inbound
                config["routing"]["rules"].append({
                    "type": "field", "inboundTag": [ib.tag], "outboundTag": "blocked"
                })

        # ── Per-inbound out-proxy routing rule ──
        out_srv_id = str(s.get('out_server_id', '') or '').strip()
        if out_srv_id:
            out_tag = _ensure_out_proxy(out_srv_id)
            if out_tag:
                config["routing"]["rules"].append({
                    "type": "field",
                    "inboundTag": [ib.tag],
                    "outboundTag": out_tag
                })

    # Private IP rule goes LAST so per-inbound out-proxy rules take priority.
    # Xray evaluates rules in order — first match wins.
    config["routing"]["rules"].append(
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
    )

    return config


def _log_reader(proc):
    try:
        for line in proc.stdout:
            ts = datetime.now(timezone.utc).strftime('%H:%M:%S')
            xray_log_buf.append({'ts': ts, 'line': line.rstrip()})
            # Parse access log for client IP + user UUID
            if 'accepted' in line:
                ip_m   = _ACCESS_IP_RE.search(line)
                uuid_m = _ACCESS_UUID_RE.search(line)
                if uuid_m:
                    _touch_user_seen(uuid_m.group(1), ip_m.group(1) if ip_m else None)
                    if ip_m:
                        _touch_user_ip(uuid_m.group(1), ip_m.group(1))
    except Exception:
        pass


def xray_start():
    global xray_process, _stats_snapshot
    if xray_process and xray_process.poll() is None:
        return False, "Already running"
    binary = get_setting('xray_binary', DEFAULT_BIN)
    if not os.path.isfile(binary):
        return False, f"Binary not found: {binary!r} — set the correct path in Settings → Xray Control"
    cfg = build_config()
    with open(CONFIG_FILE, 'w') as f:
        json.dump(cfg, f, indent=2)
    try:
        xray_process = subprocess.Popen(
            [binary, 'run', '-c', CONFIG_FILE],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1
        )
        _stats_snapshot = {}  # reset stats counters on each start
        threading.Thread(target=_log_reader, args=(xray_process,), daemon=True).start()
        xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'),
                              'line': f'[panel] xray started — PID {xray_process.pid}'})
        return True, f"Started (PID {xray_process.pid})"
    except Exception as e:
        xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'),
                              'line': f'[panel] start error: {e}'})
        return False, str(e)


def xray_stop():
    global xray_process
    if xray_process and xray_process.poll() is None:
        xray_process.terminate()
        try: xray_process.wait(timeout=5)
        except: xray_process.kill()
        xray_process = None
        xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'), 'line': '[panel] xray stopped'})
        _tc_cleanup()
        return True, "Stopped"
    return False, "Not running"


USERS_FILE = os.path.join(_PANEL_DIR, 'generated-users.json')


def write_users_file():
    """Write a human-readable users.json alongside the Xray config."""
    try:
        server_ip  = get_setting('server_ip', '0.0.0.0')
        data = {'generated': datetime.now(timezone.utc).isoformat(), 'users': []}
        for u in User.query.order_by(User.created_at).all():
            links = []
            for ib in u.inbounds:
                if ib.enabled:
                    lnk = _build_link(u, ib, ib.get_settings(), server_ip)
                    if lnk:
                        links.append({'tag': ib.tag, 'proto': ib.protocol.upper(), 'link': lnk})
            sub_url = _build_sub_url(u)
            data['users'].append({
                'name':              u.name,
                'uuid':              u.uuid,
                'status':            u.status,
                'inbounds':          [ib.tag for ib in u.inbounds],
                'links':             links,
                'sub_url':           sub_url,
                'traffic_used_gb':   round(u.traffic_used, 3),
                'traffic_limit_gb':  u.traffic_limit,
                'expires':           u.expires.strftime('%Y-%m-%d') if u.expires else None,
            })
        with open(USERS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def apply_config():
    cfg = build_config()
    with open(CONFIG_FILE, 'w') as f:
        json.dump(cfg, f, indent=2)
    write_users_file()
    status, _ = xray_status()
    if status == 'running':
        xray_stop()
        ok, msg = xray_start()
        return ok, 'restarted' if ok else msg
    return True, 'config_updated'


def xray_status():
    if xray_process and xray_process.poll() is None:
        return "running", xray_process.pid
    return "stopped", None


def _format_config_name(template, user):
    """Substitute {username}, {remain_data}, {remain_days}, {traffic_limit} in a name template."""
    if not template:
        return user.name

    def _fmt_gb(v):
        v = max(0.0, float(v or 0))
        return f'{round(v, 1):g}GB'

    remain_gb = max(0.0, (user.traffic_limit or 0) - (user.traffic_used or 0))

    if user.expires:
        delta_days = max(0, (user.expires - _utcnow()).days)
        remain_days = str(delta_days)
    else:
        remain_days = '∞'   # ∞

    result = template
    result = result.replace('{username}',      user.name)
    result = result.replace('{remain_data}',   _fmt_gb(remain_gb))
    result = result.replace('{remain_days}',   remain_days)
    result = result.replace('{traffic_limit}', _fmt_gb(user.traffic_limit or 0))
    return result


def _build_link(user, ib, s, server_ip):
    from urllib.parse import quote as _quote
    if not ib: return ''
    # Per-inbound server address takes priority over global server IP
    addr  = s.get('server_addr', '').strip() or server_ip
    # server_port overrides the actual Xray listen port in generated links (e.g. tunnel IN port)
    port  = int(s.get('server_port') or 0) or ib.port
    proto = ib.protocol.lower()
    tls   = s.get('tls_type', 'none')  # 'none' | 'tls' | 'reality'

    link_name = _format_config_name(s.get('config_name', ''), user)

    if proto == 'vless':
        t      = 'tcp' if ib.transport == 'reality' else ib.transport
        params = f"encryption=none&type={t}"
        if ib.transport == 'reality':
            fp  = s.get('fingerprint', 'chrome') or 'chrome'
            params += (f"&security=reality&flow=xtls-rprx-vision"
                       f"&sni={s.get('sni','')}&fp={fp}"
                       f"&pbk={s.get('public_key','')}&sid={s.get('short_id','')}")
        elif t == 'ws':
            params += f"&path={s.get('ws_path','/')}"
            if s.get('ws_host'): params += f"&host={s.get('ws_host','')}"
            if tls == 'tls': params += "&security=tls"
        elif t == 'xhttp':
            params += f"&path={s.get('xhttp_path','/')}"
            if s.get('xhttp_host'): params += f"&host={s.get('xhttp_host','')}"
            if tls == 'tls': params += "&security=tls"
        elif t == 'grpc':
            params += f"&serviceName={s.get('grpc_service','xray')}"
            if tls == 'tls': params += "&security=tls"
        elif t == 'tcp' and tls == 'tls':
            params += "&security=tls"
        if s.get('tls_server_name') and tls == 'tls':
            params += f"&sni={s['tls_server_name']}"
        return f"vless://{user.uuid}@{addr}:{port}?{params}#{_quote(link_name)}"

    elif proto == 'vmess':
        import base64 as _b64
        net = 'tcp' if ib.transport == 'reality' else ib.transport
        cfg = {
            "v": "2", "ps": link_name,
            "add": addr, "port": str(port),
            "id": user.uuid, "aid": "0",
            "net": net, "type": "none",
            "host": s.get('ws_host', '') or s.get('xhttp_host', ''),
            "path": s.get('ws_path', '/') or s.get('xhttp_path', '/'),
            "tls": "tls" if tls == "tls" else "",
            "sni": s.get('tls_server_name', ''),
        }
        return "vmess://" + _b64.urlsafe_b64encode(json.dumps(cfg).encode()).decode()

    elif proto == 'trojan':
        params = ""
        if tls == 'tls':
            sni = s.get('tls_server_name', '') or addr
            params = f"?security=tls&sni={sni}"
        return f"trojan://{user.uuid}@{addr}:{port}{params}#{_quote(link_name)}"

    elif proto == 'shadowsocks':
        import base64 as _b64
        method = s.get('method', 'chacha20-ietf-poly1305')
        pwd    = s.get('password', '')
        cred   = _b64.urlsafe_b64encode(f"{method}:{pwd}".encode()).decode().rstrip('=')
        return f"ss://{cred}@{addr}:{port}#{_quote(link_name)}"

    return ''


# ── Auth routes ───────────────────────────────────────────────────────────────

@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('index'))
    if session.get('_reseller_role') == 'reseller' and session.get('_reseller_id'):
        return redirect(url_for('index'))
    if request.method == 'POST':
        a = Admin.query.filter_by(username=request.form.get('username', '').strip()).first()
        if a and a.check_password(request.form.get('password', '')):
            login_user(a, remember=True)
            return redirect(url_for('index'))
        # Try reseller login
        r = Reseller.query.filter_by(username=request.form.get('username', '').strip()).first()
        if r and r.check_password(request.form.get('password', '')):
            if not r.active:
                flash('Account suspended', 'error')
            else:
                session['_reseller_role'] = 'reseller'
                session['_reseller_id'] = r.id
                session.permanent = True
                return redirect(url_for('index'))
        flash('Invalid credentials', 'error')
    return render_template('login.html')


@app.route('/logout')
def logout():
    if current_user.is_authenticated:
        logout_user()
    session.pop('_reseller_role', None)
    session.pop('_reseller_id', None)
    session.pop('_view_as', None)
    session.pop('_view_as_id', None)
    return redirect(url_for('login'))


@app.route('/api/impersonate/admin/<int:aid>', methods=['POST'])
def impersonate_admin(aid):
    if not (current_user.is_authenticated and getattr(current_user, 'role', None) == 'superadmin' and not session.get('_view_as')):
        return jsonify({'error': 'Superadmin access required'}), 403
    target = db.session.get(Admin, aid)
    if not target or target.role != 'admin':
        return jsonify({'error': 'Admin not found'}), 404
    session['_view_as'] = 'admin'
    session['_view_as_id'] = aid
    return jsonify({'ok': True})


@app.route('/api/impersonate/reseller/<int:rid>', methods=['POST'])
def impersonate_reseller(rid):
    if not (current_user.is_authenticated and getattr(current_user, 'role', None) == 'superadmin' and not session.get('_view_as')):
        return jsonify({'error': 'Superadmin access required'}), 403
    target = db.session.get(Reseller, rid)
    if not target:
        return jsonify({'error': 'Reseller not found'}), 404
    session['_view_as'] = 'reseller'
    session['_view_as_id'] = rid
    return jsonify({'ok': True})


@app.route('/api/impersonate/back', methods=['POST'])
def impersonate_back():
    session.pop('_view_as', None)
    session.pop('_view_as_id', None)
    return jsonify({'ok': True})


def _static_version():
    """Return the newest mtime across all JSX/CSS static files — used as cache-buster."""
    static_dir = os.path.join(_PANEL_DIR, 'static')
    try:
        mtimes = [
            os.path.getmtime(os.path.join(static_dir, f))
            for f in os.listdir(static_dir)
            if f.endswith(('.jsx', '.js', '.css'))
        ]
        return str(int(max(mtimes))) if mtimes else '1'
    except Exception:
        return '1'


@app.route('/')
def index():
    v = _static_version()
    if current_user.is_authenticated:
        panel_name = get_setting('workspace_name', 'Bridge')
        view_as    = session.get('_view_as')
        view_as_id = session.get('_view_as_id')
        if view_as == 'admin' and view_as_id:
            target = db.session.get(Admin, view_as_id)
            if target:
                return render_template('app.html', username=target.username, role='admin',
                                       reseller_id=0, v=v, panel_name=panel_name, impersonating=True)
        elif view_as == 'reseller' and view_as_id:
            target = db.session.get(Reseller, view_as_id)
            if target:
                return render_template('app.html', username=target.username, role='reseller',
                                       reseller_id=view_as_id, v=v, panel_name=panel_name, impersonating=True)
        role = getattr(current_user, 'role', 'superadmin')
        return render_template('app.html', username=current_user.username, role=role,
                               reseller_id=0, v=v, panel_name=panel_name, impersonating=False)
    if session.get('_reseller_role') == 'reseller':
        rid = session.get('_reseller_id', 0)
        r = db.session.get(Reseller, rid)
        if r:
            panel_name = get_setting('workspace_name', 'Bridge')
            return render_template('app.html', username=r.username, role='reseller',
                                   reseller_id=rid, v=v, panel_name=panel_name, impersonating=False)
        session.pop('_reseller_role', None)
        session.pop('_reseller_id', None)
    return redirect(url_for('login'))


# ── Reseller helpers ──────────────────────────────────────────────────────────

def _get_reseller_id():
    # Superadmin impersonating a reseller
    if (current_user.is_authenticated
            and getattr(current_user, 'role', None) == 'superadmin'
            and session.get('_view_as') == 'reseller'):
        return session.get('_view_as_id')
    if session.get('_reseller_role') == 'reseller':
        return session.get('_reseller_id')
    return None


def _is_superadmin():
    if session.get('_view_as'):  # impersonating someone — act as non-super
        return False
    return current_user.is_authenticated and getattr(current_user, 'role', 'superadmin') == 'superadmin'


def _get_admin_id():
    """Return admin ID if logged in as 'admin' role (not superadmin), else None."""
    # Superadmin impersonating an admin
    if (current_user.is_authenticated
            and getattr(current_user, 'role', None) == 'superadmin'
            and session.get('_view_as') == 'admin'):
        return session.get('_view_as_id')
    if current_user.is_authenticated and getattr(current_user, 'role', 'superadmin') == 'admin':
        return current_user.id
    return None


def superadmin_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if _is_superadmin():
            return f(*args, **kwargs)
        if not current_user.is_authenticated and not session.get('_reseller_role'):
            return redirect(url_for('login'))
        return jsonify({'error': 'Superadmin access required'}), 403
    return decorated


def reseller_or_admin_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        if current_user.is_authenticated:
            return f(*args, **kwargs)
        if session.get('_reseller_role') == 'reseller' and session.get('_reseller_id'):
            r = db.session.get(Reseller, session['_reseller_id'])
            if r and not r.active:
                session.pop('_reseller_role', None)
                session.pop('_reseller_id', None)
                return jsonify({'error': 'Account suspended'}), 403
            return f(*args, **kwargs)
        return jsonify({'error': 'Authentication required'}), 401
    return decorated


def _check_user_ownership(user):
    """Return 403 if a reseller or scoped admin tries to access a user they don't own."""
    rid = _get_reseller_id()
    if rid is not None and user.reseller_id != rid:
        return jsonify({'error': 'Access denied'}), 403
    aid = _get_admin_id()
    if aid is not None:
        if user.reseller_id is None:
            return jsonify({'error': 'Access denied'}), 403
        r = db.session.get(Reseller, user.reseller_id)
        if not r or r.admin_id != aid:
            return jsonify({'error': 'Access denied'}), 403
    return None


@app.before_request
def _enforce_superadmin_routes():
    """Block 'admin' role from system-level endpoints (superadmin only)."""
    if not current_user.is_authenticated:
        return
    if getattr(current_user, 'role', 'superadmin') != 'admin':
        return
    path, method = request.path, request.method
    if path == '/api/inbounds' and method == 'GET':
        return
    _SUPERADMIN_PREFIXES = (
        '/api/inbounds', '/api/servers', '/api/tunnels', '/api/binaries',
        '/api/xray/', '/api/config/', '/api/backup/', '/api/console',
        '/api/sub-server-script', '/api/systemd-service', '/api/traffic',
        '/api/admins',
    )
    for prefix in _SUPERADMIN_PREFIXES:
        if path.startswith(prefix):
            return jsonify({'error': 'Superadmin access required'}), 403
    if path.startswith('/api/settings') and path != '/api/settings/password':
        return jsonify({'error': 'Superadmin access required'}), 403


# ── API — Dashboard ───────────────────────────────────────────────────────────

@app.route('/api/dashboard')
@reseller_or_admin_required
def api_dashboard():
    rid = _get_reseller_id()
    aid = _get_admin_id()

    if aid is not None:
        # ── Admin-scoped dashboard ─────────────────────────────────────────────
        my_resellers   = Reseller.query.filter_by(admin_id=aid).all()
        my_r_ids       = [r.id for r in my_resellers]
        if my_r_ids:
            user_q       = User.query.filter(User.reseller_id.in_(my_r_ids))
            total_traffic = db.session.query(db.func.sum(User.traffic_used)).filter(
                User.reseller_id.in_(my_r_ids)).scalar() or 0
        else:
            user_q       = User.query.filter(User.id == -1)
            total_traffic = 0
        total_users    = user_q.count()
        active_users   = user_q.filter_by(status='active').count()
        admin          = db.session.get(Admin, aid)
        bw = list(_bw_history)
        # Activity scoped to this admin's resellers
        r_names = {r.username for r in my_resellers}
        r_names.add(admin.username if admin else '')
        recent_a = ActivityLog.query.filter(
            ActivityLog.actor.in_(r_names)
        ).order_by(ActivityLog.ts.desc()).limit(50).all()
        activity = [{
            'actor': a.actor, 'actor_role': a.actor_role,
            'action': a.action, 'target': a.target,
            'detail': a.detail, 'time': a.ts.strftime('%Y-%m-%d %H:%M'),
        } for a in recent_a]
        return jsonify({
            'total_users':      total_users,
            'active_users':     active_users,
            'inbounds':         0, 'enabled_inbounds': 0,
            'servers':          0, 'online_servers':   0,
            'traffic_gb':       round(float(total_traffic), 2),
            'xray_running':     False, 'xray_status': 'unknown', 'xray_pid': None,
            'proto_share':      [],
            'server_list':      [],
            'bw_history':       {'down': [p['down_gb'] for p in bw], 'up': [p['up_gb'] for p in bw], 'ts': [p['ts'] for p in bw]},
            'activity':         activity,
            'admin_list':       [],
            'reseller_list':    [r.to_dict() for r in my_resellers],
            'admin_quota': {
                'reseller_count':  admin.reseller_count  if admin else 0,
                'data_limit_gb':   admin.data_limit_gb   if admin else 0,
                'user_count':      admin.user_count       if admin else 0,
                'resellers_total': len(my_resellers),
                'users_total':     total_users,
                'users_active':    active_users,
                'data_used_gb':    round(float(total_traffic), 3),
            },
        })

    if rid is not None:
        # ── Reseller-scoped dashboard ──────────────────────────────────────────
        user_q       = User.query.filter_by(reseller_id=rid)
        total_users  = user_q.count()
        active_users = user_q.filter_by(status='active').count()
        total_traffic = db.session.query(db.func.sum(User.traffic_used)).filter(
            User.reseller_id == rid).scalar() or 0
        proto_counts = Counter(
            ib.protocol.upper()
            for u in user_q.all()
            for ib in u.inbounds
        )
        total_pc    = sum(proto_counts.values()) or 1
        proto_share = [{'name': k, 'value': round(v / total_pc * 100)} for k, v in proto_counts.most_common()]
        bw = list(_bw_history)
        reseller    = db.session.get(Reseller, rid)
        return jsonify({
            'total_users':      total_users,
            'active_users':     active_users,
            'inbounds':         0,
            'enabled_inbounds': 0,
            'servers':          0,
            'online_servers':   0,
            'traffic_gb':       round(float(total_traffic), 2),
            'xray_running':     False,
            'xray_status':      'unknown',
            'xray_pid':         None,
            'proto_share':      proto_share,
            'server_list':      [],
            'bw_history':       {'down': [p['down_gb'] for p in bw], 'up': [p['up_gb'] for p in bw], 'ts': [p['ts'] for p in bw]},
            'activity':         [],
            'reseller_quota':   {
                'user_count':        reseller.user_count if reseller else 0,
                'active_user_count': reseller.active_user_count if reseller else 0,
                'data_limit_gb':     reseller.data_limit_gb if reseller else 0,
                'used_limit_gb':     reseller.used_limit_gb if reseller else 0,
                'data_used_gb':      round(reseller.total_used_gb(), 3) if reseller else 0,
                'data_allocated_gb': round(reseller.total_allocated_gb(), 3) if reseller else 0,
                'users_total':       total_users,
                'users_active':      active_users,
            },
        })

    # ── Admin dashboard ────────────────────────────────────────────────────────
    status, pid    = xray_status()
    total_users    = User.query.count()
    active_users   = User.query.filter_by(status='active').count()
    total_ib       = Inbound.query.count()
    enabled_ib     = Inbound.query.filter_by(enabled=True).count()
    total_servers  = Server.query.count()
    online_servers = Server.query.filter_by(status='online').count()
    total_traffic  = db.session.query(db.func.sum(User.traffic_used)).scalar() or 0

    bw = list(_bw_history)
    bw_history = {
        'down': [p['down_gb'] for p in bw],
        'up':   [p['up_gb']   for p in bw],
        'ts':   [p['ts']      for p in bw],
    }

    # ── Admin overview list ────────────────────────────────────────────────────
    admin_objs = Admin.query.filter_by(role='admin').order_by(Admin.created_at.desc()).all()
    admin_list = []
    for a in admin_objs:
        r_ids = [r.id for r in Reseller.query.filter_by(admin_id=a.id).all()]
        used  = db.session.query(db.func.sum(User.traffic_used)).filter(
            User.reseller_id.in_(r_ids)).scalar() or 0 if r_ids else 0
        alloc = db.session.query(db.func.sum(User.traffic_limit)).filter(
            User.reseller_id.in_(r_ids)).scalar() or 0 if r_ids else 0
        admin_list.append({
            'id': a.id, 'username': a.username,
            'resellers_count': len(r_ids), 'resellers_max': a.reseller_count,
            'users_total': User.query.filter(User.reseller_id.in_(r_ids)).count() if r_ids else 0,
            'users_max': a.user_count,
            'data_used_gb': round(float(used), 2),
            'data_allocated_gb': round(float(alloc), 2),
            'data_limit_gb': a.data_limit_gb,
            'created_at': a.created_at.isoformat() if a.created_at else None,
        })

    # ── Reseller overview list ─────────────────────────────────────────────────
    reseller_list = [r.to_dict() for r in
                     Reseller.query.order_by(Reseller.created_at.desc()).limit(20).all()]

    # ── Recent activity ────────────────────────────────────────────────────────
    recent = ActivityLog.query.order_by(ActivityLog.ts.desc()).limit(50).all()
    activity = [{
        'actor':      a.actor,
        'actor_role': a.actor_role,
        'action':     a.action,
        'target':     a.target,
        'detail':     a.detail,
        'time':       a.ts.strftime('%Y-%m-%d %H:%M'),
    } for a in recent]

    return jsonify({
        'total_users':      total_users,
        'active_users':     active_users,
        'inbounds':         total_ib,
        'enabled_inbounds': enabled_ib,
        'servers':          total_servers,
        'online_servers':   online_servers,
        'traffic_gb':       round(total_traffic, 2),
        'xray_running':     status == 'running',
        'xray_status':      status,
        'xray_pid':         pid,
        'proto_share':      [],
        'server_list':      [],
        'bw_history':       bw_history,
        'activity':         activity,
        'admin_list':       admin_list,
        'reseller_list':    reseller_list,
    })


# ── API — Users ───────────────────────────────────────────────────────────────

@app.route('/api/users', methods=['GET'])
@reseller_or_admin_required
def api_users():
    rid = _get_reseller_id()
    aid = _get_admin_id()
    q = User.query
    if rid is not None:
        q = q.filter_by(reseller_id=rid)
    elif aid is not None:
        my_r_ids = [r.id for r in Reseller.query.filter_by(admin_id=aid).all()]
        q = q.filter(User.reseller_id.in_(my_r_ids)) if my_r_ids else q.filter(User.id == -1)

    # ── Filters ──────────────────────────────────────────────────────────────
    status_f = request.args.get('status', '').strip()
    if status_f and status_f != 'all':
        q = q.filter(User.status == status_f)

    # Owner filter (only meaningful for superadmin/admin views)
    owner_f = request.args.get('owner', '').strip()
    if owner_f and rid is None:
        if owner_f == 'none':
            q = q.filter(User.reseller_id.is_(None))
        else:
            try:
                q = q.filter(User.reseller_id == int(owner_f))
            except ValueError:
                pass

    # Text search (name, email, uuid, sub_token)
    search_f = request.args.get('search', '').strip()
    if search_f:
        like = f'%{search_f}%'
        q = q.filter(db.or_(
            User.name.ilike(like),
            User.email.ilike(like),
            User.uuid.ilike(like),
            User.sub_token.ilike(like),
            User.vpn_username.ilike(like),
        ))

    # Expire filter
    expire_f = request.args.get('expire', '').strip()
    now = datetime.utcnow()
    if expire_f == 'soon':
        q = q.filter(User.expires.isnot(None), User.expires > now,
                     User.expires <= now + timedelta(days=7))
    elif expire_f == 'month':
        q = q.filter(User.expires.isnot(None), User.expires > now,
                     User.expires <= now + timedelta(days=30))
    elif expire_f == 'expired':
        q = q.filter(User.expires.isnot(None), User.expires <= now)
    elif expire_f == 'no_expiry':
        q = q.filter(User.expires.is_(None))

    # Traffic filter
    traffic_f = request.args.get('traffic', '').strip()
    if traffic_f == 'over90':
        q = q.filter(User.traffic_limit > 0,
                     User.traffic_used >= User.traffic_limit * 0.9)
    elif traffic_f == 'over75':
        q = q.filter(User.traffic_limit > 0,
                     User.traffic_used >= User.traffic_limit * 0.75)
    elif traffic_f == 'over50':
        q = q.filter(User.traffic_limit > 0,
                     User.traffic_used >= User.traffic_limit * 0.5)
    elif traffic_f == 'unlimited':
        q = q.filter(User.traffic_limit <= 0)
    elif traffic_f == 'unused':
        q = q.filter(User.traffic_used <= 0)

    # ── Sort ─────────────────────────────────────────────────────────────────
    sort_by  = request.args.get('sort', 'created')
    sort_dir = request.args.get('dir',  'desc')
    _sort_cols = {
        'name':    User.name,
        'traffic': User.traffic_used,
        'expires': User.expires,
        'status':  User.status,
        'created': User.created_at,
    }
    col = _sort_cols.get(sort_by, User.created_at)
    q = q.order_by(col.asc() if sort_dir == 'asc' else col.desc())

    # ── Pagination ────────────────────────────────────────────────────────────
    try:
        page     = max(1, int(request.args.get('page', 1)))
        per_page = min(200, max(1, int(request.args.get('per_page', 50))))
    except (ValueError, TypeError):
        page, per_page = 1, 50

    try:
        total    = q.count()
        pages    = max(1, (total + per_page - 1) // per_page)
        page     = min(page, pages)
        users_q  = q.offset((page - 1) * per_page).limit(per_page).all()
        return jsonify({
            'users':    [u.to_dict() for u in users_q],
            'total':    total,
            'page':     page,
            'per_page': per_page,
            'pages':    pages,
        })
    except Exception as e:
        app.logger.error(f'api_users error: {e}')
        return jsonify({'error': str(e), 'users': [], 'total': 0, 'page': 1, 'pages': 1}), 500


@app.route('/api/users', methods=['POST'])
@reseller_or_admin_required
def api_create_user():
    d    = request.json or {}
    name = d.get('name', '').strip()
    if not name:
        return jsonify({'error': 'Name is required'}), 400
    rid = _get_reseller_id()
    aid = _get_admin_id()
    if aid is not None:
        req_rid = d.get('reseller_id')
        if not req_rid:
            return jsonify({'error': 'Select a reseller to assign this user to'}), 400
        r_check = db.session.get(Reseller, int(req_rid))
        if not r_check or r_check.admin_id != aid:
            return jsonify({'error': 'Invalid reseller'}), 400
        rid = int(req_rid)
    # ── Check account creation lock ─────────────────────────────────────────
    if rid is not None:
        _r_lock = db.session.get(Reseller, rid)
        if _r_lock and _r_lock.locked:
            return jsonify({'error': 'Account creation is locked for this reseller.'}), 403
    if aid is not None:
        _a_lock = db.session.get(Admin, aid)
        if _a_lock and _a_lock.locked:
            return jsonify({'error': 'Account creation is locked for this admin.'}), 403
    # ── Enforce reseller quotas ──────────────────────────────────────────────
    if rid is not None:
        reseller = db.session.get(Reseller, rid)
        if reseller:
            total_users  = User.query.filter_by(reseller_id=rid).count()
            active_users = User.query.filter_by(reseller_id=rid, status='active').count()
            new_traffic  = float(d.get('traffic_limit', reseller.default_traffic_gb or 100))
            if total_users >= reseller.user_count:
                return jsonify({'error': f'User limit reached ({reseller.user_count} max total users)'}), 400
            if active_users >= reseller.active_user_count:
                return jsonify({'error': f'Active user limit reached ({reseller.active_user_count} max active users)'}), 400
            if new_traffic <= 0:
                return jsonify({'error': 'Cannot assign unlimited traffic to a user — reseller has a data limit. Please set a specific traffic value.'}), 400
            if reseller.total_allocated_gb() + new_traffic > reseller.data_limit_gb:
                remaining = max(0.0, reseller.data_limit_gb - reseller.total_allocated_gb())
                return jsonify({'error': f'Allocated traffic limit reached — only {remaining:.2f} GB remaining of {reseller.data_limit_gb} GB'}), 400
            if reseller.total_used_gb() >= reseller.used_limit_gb:
                return jsonify({'error': f'Used traffic limit reached — {reseller.total_used_gb():.2f} GB consumed of {reseller.used_limit_gb} GB'}), 400
    # ── Enforce admin-level user_count across all resellers under the admin ───
    if aid is not None:
        admin = db.session.get(Admin, aid)
        if admin:
            admin_reseller_ids = [r.id for r in Reseller.query.filter_by(admin_id=aid).all()]
            if admin_reseller_ids:
                total_under_admin = User.query.filter(User.reseller_id.in_(admin_reseller_ids)).count()
                if total_under_admin >= admin.user_count:
                    return jsonify({'error': f'Admin user limit reached ({admin.user_count} max total users across all resellers)'}), 400
    date_start_mode = d.get('date_start_mode', 'on_create')
    if date_start_mode == 'on_first_connect':
        connect_days = int(d.get('connect_days', 30) or 30)
        expires = None
    else:
        date_start_mode = 'on_create'
        connect_days    = 0
        expires         = _parse_expires(d)
    u = User(
        name=name,
        email=d.get('email', '') or None,
        traffic_limit=float(d.get('traffic_limit', 100)),
        ip_limit=int(d.get('ip_limit', 0)),
        speed_limit_kbps=int(d.get('speed_limit_kbps', 0)),
        expires=expires,
        status='active',
        reseller_id=rid,
        date_start_mode=date_start_mode,
        expires_days=connect_days,
        access_type=(d.get('access_type') or 'both')
                    if (d.get('access_type') or 'both') in ACCESS_TYPES else 'both',
    )
    # App login credentials — auto-assigned unless explicitly supplied
    _ensure_vpn_credentials(u)
    want_user = (d.get('vpn_username') or '').strip()
    want_pass = (d.get('vpn_password') or '').strip()
    if want_user:
        ok, err = _validate_vpn_username(want_user, exclude_id=None)
        if not ok:
            return jsonify({'error': err}), 400
        u.vpn_username = want_user
    if want_pass:
        ok, err = _validate_vpn_password(want_pass)
        if not ok:
            return jsonify({'error': err}), 400
        u.vpn_password = want_pass

    db.session.add(u)
    db.session.flush()   # get u.id before commit

    # Assign inbounds (multi) — accept inbound_ids list or legacy inbound_id
    iid_list = _parse_inbound_ids(d)
    if iid_list and rid is not None:
        reseller = db.session.get(Reseller, rid)
        if reseller:
            allowed = json.loads(reseller.allowed_inbound_ids or '[]')
            if allowed:
                iid_list = [i for i in iid_list if i in allowed]
    if iid_list:
        u.inbounds = Inbound.query.filter(Inbound.id.in_(iid_list)).all()

    _log_activity('create_user', u.name, f'traffic={u.traffic_limit} GB')
    db.session.commit()
    _, apply_msg = apply_config()
    return jsonify({'user': u.to_dict(), 'xray': apply_msg}), 201


@app.route('/api/users/<int:uid>', methods=['PUT'])
@reseller_or_admin_required
def api_update_user(uid):
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    d = request.json or {}
    # ── Check edit lock ──────────────────────────────────────────────────────
    _acting_rid = _get_reseller_id()
    _acting_aid = _get_admin_id()
    if _acting_rid is not None:
        _rl = db.session.get(Reseller, _acting_rid)
        if _rl and _rl.locked:
            return jsonify({'error': 'Editing users is locked for this reseller.'}), 403
    if _acting_aid is not None:
        _al = db.session.get(Admin, _acting_aid)
        if _al and _al.locked:
            return jsonify({'error': 'Editing users is locked for this admin.'}), 403
    if 'name'          in d: u.name          = d['name']
    if 'email'         in d: u.email         = d['email'] or None
    if 'status'        in d: u.status        = d['status']
    if 'traffic_limit' in d:
        new_limit = float(d['traffic_limit'])
        if u.reseller_id is not None:
            reseller = db.session.get(Reseller, u.reseller_id)
            if reseller and reseller.data_limit_gb > 0:
                if new_limit <= 0:
                    return jsonify({'error': 'Cannot assign unlimited traffic to a user — reseller has a data limit. Please set a specific traffic value.'}), 400
                # Only check capacity when the allocation is being increased
                if new_limit > (u.traffic_limit or 0):
                    extra = new_limit - (u.traffic_limit or 0)
                    if reseller.total_allocated_gb() + extra > reseller.data_limit_gb:
                        remaining = max(0.0, reseller.data_limit_gb - reseller.total_allocated_gb())
                        return jsonify({'error': f'Allocated traffic limit reached — only {remaining:.2f} GB remaining of {reseller.data_limit_gb} GB'}), 400
                    if reseller.total_used_gb() >= reseller.used_limit_gb:
                        return jsonify({'error': f'Used traffic limit reached — {reseller.total_used_gb():.2f} GB consumed of {reseller.used_limit_gb} GB'}), 400
        u.traffic_limit = new_limit
    if 'traffic_used' in d:
        # Resellers cannot reset user traffic when their used limit is reached
        if _get_reseller_id() is not None and u.reseller_id is not None:
            reseller = db.session.get(Reseller, u.reseller_id)
            if reseller and reseller.total_used_gb() >= reseller.used_limit_gb:
                return jsonify({'error': f'Used traffic limit reached — cannot reset user traffic. Contact your admin to purchase more traffic.'}), 400
        u.traffic_used = float(d['traffic_used'])
    if 'ip_limit'          in d: u.ip_limit          = int(d['ip_limit'])
    if 'speed_limit_kbps'  in d: u.speed_limit_kbps  = int(d['speed_limit_kbps'])
    if 'sub_note'          in d: u.sub_note          = d['sub_note'] or None
    if 'access_type'    in d and d['access_type'] in ACCESS_TYPES:
        u.access_type = d['access_type']
    if 'access_mode'    in d: u.access_mode    = d['access_mode']
    if 'access_domains' in d: u.access_domains = json.dumps(d['access_domains'] or [])
    if 'access_ips'     in d: u.access_ips     = json.dumps(d['access_ips'] or [])
    expires = _parse_expires(d)
    if expires is not None:
        u.expires = expires
    # Update inbound assignments if provided
    if 'inbound_ids' in d or 'inbound_id' in d:
        iid_list = _parse_inbound_ids(d)
        u.inbounds = Inbound.query.filter(Inbound.id.in_(iid_list)).all() if iid_list else []
    db.session.commit()
    _, apply_msg = apply_config()
    return jsonify({'user': u.to_dict(), 'xray': apply_msg})


# ── Renew user expiry ─────────────────────────────────────────────────────────

@app.route('/api/users/<int:uid>/renew', methods=['POST'])
@reseller_or_admin_required
def api_renew_user(uid):
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    d    = request.json or {}
    days = int(d.get('days', 30))
    base = u.expires if (u.expires and u.expires > _utcnow()) else _utcnow()
    u.expires = base + timedelta(days=days)
    if u.status in ('expired', 'paused'):
        u.status = 'active'
    db.session.commit()
    _, apply_msg = apply_config()
    _log_activity('renew_user', u.name, f'+{days}d → {u.expires.strftime("%Y-%m-%d")}')
    return jsonify({'user': u.to_dict(), 'xray': apply_msg})


# ── Bulk user operations ──────────────────────────────────────────────────────

@app.route('/api/users/bulk', methods=['POST'])
@reseller_or_admin_required
def api_bulk_users():
    d      = request.json or {}
    ids    = [int(i) for i in (d.get('ids') or [])]
    action = d.get('action', '')
    value  = d.get('value')
    if not ids or not action:
        return jsonify({'error': 'ids and action required'}), 400

    users_qs = User.query.filter(User.id.in_(ids)).all()
    allowed  = [u for u in users_qs if _check_user_ownership(u) is None]
    if not allowed:
        return jsonify({'error': 'No accessible users'}), 403

    changed = 0
    for u in allowed:
        if action == 'suspend':
            u.status = 'paused'; changed += 1
        elif action == 'activate':
            u.status = 'active'; changed += 1
        elif action == 'reset_traffic':
            u.traffic_used = 0.0
            if u.status == 'limit': u.status = 'active'
            changed += 1
        elif action == 'extend_expiry':
            try:
                days = int(value or 30)
                base = u.expires if (u.expires and u.expires > _utcnow()) else _utcnow()
                u.expires = base + timedelta(days=days)
                changed += 1
            except (ValueError, TypeError):
                pass
        elif action == 'set_expiry':
            try:
                u.expires = datetime.strptime(str(value), '%Y-%m-%d')
                changed += 1
            except (ValueError, TypeError):
                pass
        elif action == 'set_traffic':
            try:
                u.traffic_limit = float(value); changed += 1
            except (ValueError, TypeError):
                pass

    db.session.commit()
    _, apply_msg = apply_config()
    _log_activity(f'bulk_{action}', f'{changed} users', str(value or ''))
    return jsonify({'changed': changed, 'xray': apply_msg})


# ── Online users ──────────────────────────────────────────────────────────────

@app.route('/api/online')
@reseller_or_admin_required
def api_online_users():
    rid = _get_reseller_id()
    aid = _get_admin_id()
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    cutoff = now - timedelta(minutes=ONLINE_WINDOW_MIN)

    # Total user pool visible to the caller — powers the "N of M connected" line.
    if rid is not None:
        total_users = User.query.filter_by(reseller_id=rid).count()
    elif aid is not None:
        my_r_ids = [r.id for r in Reseller.query.filter_by(admin_id=aid).all()]
        total_users = User.query.filter(User.reseller_id.in_(my_r_ids)).count() if my_r_ids else 0
    else:
        total_users = User.query.count()

    results = []
    for uid, info in list(_user_last_seen.items()):
        if info['ts'] < cutoff:
            continue
        u = User.query.filter_by(uuid=uid).first()
        if not u:
            continue
        # scope check
        if rid is not None and u.reseller_id != rid:
            continue
        if aid is not None:
            if u.reseller_id is None:
                continue
            r = db.session.get(Reseller, u.reseller_id)
            if not r or r.admin_id != aid:
                continue

        elapsed = int((now - info['ts']).total_seconds())
        ip      = info.get('ip', '?')

        started    = _user_session_start.get(uid, info['ts'])
        session_s  = max(0, int((now - started).total_seconds()))

        hist       = list(_user_rate_hist.get(uid, ()))
        rate_mbps  = hist[-1] if hist else 0.0

        limit_gb   = float(u.traffic_limit or 0)
        used_gb    = float(u.traffic_used  or 0)
        quota_pct  = round(min(100.0, used_gb / limit_gb * 100), 1) if limit_gb > 0 else None

        ib0        = u.inbounds[0] if u.inbounds else None

        results.append({
            'id':          u.id,
            'name':        u.name,
            'uuid':        u.uuid,
            'ip':          ip,
            'cc':          _ip_country(ip),
            'last_seen_s': elapsed,
            'session_s':   session_s,
            'rate_mbps':   rate_mbps,
            'spark':       hist,
            'proto':       (ib0.protocol.lower() if ib0 else None),
            'inbound_tag': (ib0.tag if ib0 else None),
            'traffic_used':  round(used_gb, 3),
            'traffic_limit': limit_gb,
            'quota_pct':   quota_pct,
            'status':      u.status,
            'owner':       _safe_reseller_username(u.reseller_id),
        })

    results.sort(key=lambda x: x['last_seen_s'])
    return jsonify({
        'online':       results,
        'count':        len(results),
        'total_users':  total_users,
        'window_min':   ONLINE_WINDOW_MIN,
    })


@app.route('/api/tc/status', methods=['GET'])
@login_required
def api_tc_status():
    return jsonify({
        'available':       bool(_tc_available),
        'iface':           _tc_iface_cache or get_setting('tc_iface', ''),
        'rules':           [{'ip': ip, 'speed_kbps': kbps} for ip, kbps in _tc_current.items()],
        'rule_count':      len(_tc_current),
        'last_reset_date': _tc_last_reset_date.isoformat() if _tc_last_reset_date else None,
    })


@app.route('/api/tc/apply', methods=['POST'])
@login_required
def api_tc_apply():
    """Force an immediate tc rule refresh (don't wait for the 30-s poll)."""
    try:
        _apply_speed_limits()
        return jsonify({'ok': True, 'rules': len(_tc_current)})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/users/<int:uid>/reset-sub', methods=['POST'])
@reseller_or_admin_required
def api_reset_sub_token(uid):
    """Regenerate the subscription token, invalidating any existing subscription URLs."""
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    import uuid as _uuid
    u.sub_token = str(_uuid.uuid4())
    db.session.commit()
    return jsonify({'sub_token': u.sub_token, 'sub_url': _build_sub_url(u), 'sub_urls': _build_sub_urls(u)})


@app.route('/api/users/<int:uid>/toggle', methods=['POST'])
@reseller_or_admin_required
def api_toggle_user(uid):
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    new_status = 'paused' if u.status == 'active' else 'active'
    # Enforce active_user_count when re-activating a user under a reseller
    if new_status == 'active' and u.reseller_id is not None:
        reseller = db.session.get(Reseller, u.reseller_id)
        if reseller:
            active_now = User.query.filter_by(reseller_id=u.reseller_id, status='active').count()
            if active_now >= reseller.active_user_count:
                return jsonify({'error': f'Active user limit reached ({reseller.active_user_count} max active users)'}), 400
    u.status = new_status
    _log_activity('toggle_user', u.name, f'status → {u.status}')
    db.session.commit()
    apply_config()
    return jsonify({'status': u.status})


@app.route('/api/users/<int:uid>', methods=['DELETE'])
@reseller_or_admin_required
def api_delete_user(uid):
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    uname = u.name
    if u.reseller_id:
        r = db.session.get(Reseller, u.reseller_id)
        if r:
            r.deleted_users_used_gb = (r.deleted_users_used_gb or 0) + (u.traffic_used or 0)
    _log_activity('delete_user', uname, f'used={round(u.traffic_used or 0, 2)} GB')
    db.session.delete(u)
    db.session.commit()
    # Immediately persist today's snapshot so history reflects the deletion
    try:
        _upsert_reseller_snapshots()
    except Exception:
        pass
    apply_config()
    return jsonify({'ok': True})


@app.route('/api/users/<int:uid>/link')
@reseller_or_admin_required
def api_user_link(uid):
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    server_ip = get_setting('server_ip', request.host.split(':')[0])
    links = []
    for ib in u.inbounds:
        lnk = _build_link(u, ib, ib.get_settings(), server_ip)
        if lnk:
            links.append({'tag': ib.tag, 'proto': ib.protocol.upper(), 'link': lnk})
    return jsonify({'links': links, 'link': links[0]['link'] if links else ''})


# ── App login credentials (used by the Veil client apps) ──────────────────────

_VPN_USERNAME_RE = re.compile(r'^[A-Za-z0-9_.\-]{3,64}$')


def _validate_vpn_username(name, exclude_id=None):
    if not _VPN_USERNAME_RE.match(name or ''):
        return False, 'Username must be 3–64 chars (letters, digits, . _ -)'
    q = User.query.filter(User.vpn_username == name)
    if exclude_id is not None:
        q = q.filter(User.id != exclude_id)
    if q.first():
        return False, 'That app username is already taken'
    return True, ''


def _validate_vpn_password(pw):
    if not pw or len(pw) < 6:
        return False, 'Password must be at least 6 characters'
    if len(pw) > 64:
        return False, 'Password must be 64 characters or fewer'
    if any(c.isspace() for c in pw):
        return False, 'Password cannot contain spaces'
    return True, ''


@app.route('/api/users/<int:uid>/credentials', methods=['PUT'])
@reseller_or_admin_required
def api_update_user_credentials(uid):
    """Change a user's app login username / password.

    Accepts any of:
      {"password": "..."}        set an explicit password
      {"regenerate": true}       roll a fresh random password
      {"username": "..."}        change the app username (must stay unique)
    Only the owning reseller / admin (or superadmin) may call this.
    """
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny

    # Same edit-lock rules as api_update_user
    _acting_rid = _get_reseller_id()
    _acting_aid = _get_admin_id()
    if _acting_rid is not None:
        _rl = db.session.get(Reseller, _acting_rid)
        if _rl and _rl.locked:
            return jsonify({'error': 'Editing users is locked for this reseller.'}), 403
    if _acting_aid is not None:
        _al = db.session.get(Admin, _acting_aid)
        if _al and _al.locked:
            return jsonify({'error': 'Editing users is locked for this admin.'}), 403

    d = request.json or {}
    changed = []

    if 'username' in d:
        new_name = (d.get('username') or '').strip()
        if new_name and new_name != u.vpn_username:
            ok, err = _validate_vpn_username(new_name, exclude_id=u.id)
            if not ok:
                return jsonify({'error': err}), 400
            u.vpn_username = new_name
            changed.append('username')

    if d.get('regenerate'):
        u.vpn_password = _gen_vpn_password()
        changed.append('password')
    elif 'password' in d:
        new_pw = (d.get('password') or '').strip()
        if new_pw and new_pw != u.vpn_password:
            ok, err = _validate_vpn_password(new_pw)
            if not ok:
                return jsonify({'error': err}), 400
            u.vpn_password = new_pw
            changed.append('password')

    # Backfill anything still missing (older users created before this feature)
    _ensure_vpn_credentials(u)

    db.session.commit()
    if changed:
        _log_activity('update_credentials', u.name, ', '.join(changed))
    return jsonify({
        'vpn_username': u.vpn_username,
        'vpn_password': u.vpn_password,
        'changed': changed,
    })


@app.route('/api/users/<int:uid>/uuid', methods=['PUT'])
@reseller_or_admin_required
def api_change_user_uuid(uid):
    """Change a user's xray UUID if the new value is not already taken."""
    import uuid as _uuid_mod
    u = User.query.get_or_404(uid)
    deny = _check_user_ownership(u)
    if deny: return deny
    d = request.json or {}
    new_uuid = d.get('uuid', '').strip()
    if not new_uuid:
        return jsonify({'error': 'UUID is required'}), 400
    try:
        _uuid_mod.UUID(new_uuid)
    except ValueError:
        return jsonify({'error': 'Invalid UUID format'}), 400
    existing = User.query.filter_by(uuid=new_uuid).first()
    if existing and existing.id != uid:
        return jsonify({'error': 'UUID already in use by another user'}), 409
    u.uuid = new_uuid
    db.session.commit()
    _, apply_msg = apply_config()
    return jsonify({'uuid': u.uuid, 'xray': apply_msg})


# ══════════════════════════════════════════════════════════════════════════════
#  Client API — consumed by the Veil client apps (Android / desktop)
#  Auth: POST /api/client/login with the user's vpn_username + vpn_password,
#        then send `Authorization: Bearer <token>` on every other call.
# ══════════════════════════════════════════════════════════════════════════════

CLIENT_TOKEN_SALT    = 'veil-client-auth-v1'
CLIENT_TOKEN_MAX_AGE = 60 * 60 * 24 * 30      # 30 days

# ── Device registry ───────────────────────────────────────────────────────────
#  Enforces the account's ip_limit as a *device* limit, which is what users
#  actually mean by "3 devices": counting IPs punishes anyone behind CGNAT or
#  hopping between wifi and mobile data, while an install id is stable.
#
#  Held in memory alongside _user_last_seen for the same reason: it is live
#  state, not a record. A panel restart forgets it and every device simply
#  re-registers on its next call.
CLIENT_DEVICE_WINDOW_MIN = 10   # a device stops counting after this much silence

_client_devices = {}            # {user_id: {device_id: {'ts','ip','name','platform'}}}


def _client_device_headers():
    """Device identity the app sends on every call. All optional."""
    d = request.json if request.is_json and request.method == 'POST' else None
    d = d if isinstance(d, dict) else {}
    return (
        (request.headers.get('X-Device-Id') or d.get('device_id') or '').strip()[:80],
        (request.headers.get('X-Device-Name') or d.get('device_name') or '').strip()[:60],
        (request.headers.get('X-Device-Platform') or d.get('platform') or '').strip()[:20],
    )


def _client_request_ip():
    """Caller's address, honouring the reverse proxy we generate configs for."""
    fwd = request.headers.get('X-Forwarded-For', '')
    if fwd:
        return fwd.split(',')[0].strip()
    return request.headers.get('X-Real-IP') or request.remote_addr or ''


def _client_active_devices(user_id):
    """Devices seen inside the window, oldest first. Prunes as it goes."""
    now = _utcnow()
    cutoff = now - timedelta(minutes=CLIENT_DEVICE_WINDOW_MIN)
    seen = _client_devices.get(user_id, {})
    for did in [k for k, v in seen.items() if v['ts'] < cutoff]:
        seen.pop(did, None)
    return sorted(seen.items(), key=lambda kv: kv[1]['ts'])


def _client_touch_device(user_id, device_id, name, platform):
    """Records this device as active. No-op when the app sent no id."""
    if not device_id:
        return
    seen = _client_devices.setdefault(user_id, {})
    prev = seen.get(device_id, {})
    seen[device_id] = {
        'ts':       _utcnow(),
        'ip':       _client_request_ip(),
        'name':     name or prev.get('name', ''),
        'platform': platform or prev.get('platform', ''),
    }


def _client_device_allowed(u, device_id):
    """(allowed, active_count).

    A device is allowed when the account is uncapped, when it is already one of
    the active devices, or when there is a free slot. An app that sends no id
    is never blocked — older builds must keep working.
    """
    limit = u.ip_limit or 0
    active = _client_active_devices(u.id)
    count = len(active)
    if limit <= 0 or not device_id:
        return True, count
    if any(did == device_id for did, _ in active):
        return True, count
    return count < limit, count


def _client_device_list(user_id):
    return [
        {
            'id':       did[:8],
            'name':     info.get('name', '') or 'Unknown device',
            'platform': info.get('platform', ''),
            'ip':       info.get('ip', ''),
            'last_seen': info['ts'].isoformat(),
        }
        for did, info in _client_active_devices(user_id)
    ]


def _client_serializer():
    from itsdangerous import URLSafeTimedSerializer
    return URLSafeTimedSerializer(app.config['SECRET_KEY'], salt=CLIENT_TOKEN_SALT)


def _client_pw_fingerprint(u):
    """Short digest of the current password — lets a password change kill old tokens."""
    import hashlib
    return hashlib.sha256((u.vpn_password or '').encode()).hexdigest()[:16]


def _client_issue_token(u):
    return _client_serializer().dumps({'uid': u.id, 'fp': _client_pw_fingerprint(u)})


def _client_user_from_token(token):
    """Return (user, error_message). error_message is None on success."""
    from itsdangerous import BadSignature, SignatureExpired
    try:
        data = _client_serializer().loads(token, max_age=CLIENT_TOKEN_MAX_AGE)
    except SignatureExpired:
        return None, 'Session expired — please sign in again'
    except BadSignature:
        return None, 'Invalid session'
    except Exception:
        return None, 'Invalid session'
    u = db.session.get(User, data.get('uid'))
    if not u:
        return None, 'Account no longer exists'
    if data.get('fp') != _client_pw_fingerprint(u):
        return None, 'Password changed — please sign in again'
    return u, None


def client_auth_required(f):
    @functools.wraps(f)
    def decorated(*args, **kwargs):
        from flask import g
        auth = request.headers.get('Authorization', '')
        token = auth[7:].strip() if auth.lower().startswith('bearer ') else \
                (request.args.get('token', '') or '').strip()
        if not token:
            return jsonify({'error': 'Authentication required'}), 401
        u, err = _client_user_from_token(token)
        if err:
            return jsonify({'error': err}), 401
        g.client_user = u
        return f(*args, **kwargs)
    return decorated


def _client_status(u, device_id=None):
    """Effective status as the app should show it."""
    # Checked ahead of everything else: an account the operator has restricted
    # to subscription links has nothing to say about quota or devices, and a
    # token issued before the switch must stop working here rather than at the
    # next sign-in.
    if not _app_allowed(u):
        return 'sub_only'
    if u.status != 'active':
        return u.status
    if u.is_expired():
        return 'expired'
    if u.is_over_limit():
        return 'limit'
    if device_id is not None:
        allowed, _ = _client_device_allowed(u, device_id)
        if not allowed:
            return 'devices'
    return 'active'


def _client_can_connect(u, device_id=None):
    return _client_status(u, device_id) == 'active'


def _client_profile(u, device_id=None):
    limit_gb = float(u.traffic_limit or 0)
    used_gb  = float(u.traffic_used  or 0)
    days_left = None
    if u.expires:
        days_left = max(0, (u.expires - _utcnow()).days)
    return {
        'id':              u.id,
        'name':            u.name,
        'username':        u.vpn_username or '',
        'email':           u.email or '',
        'status':          _client_status(u, device_id),
        'can_connect':     _client_can_connect(u, device_id),
        'unlimited':       limit_gb <= 0,
        'traffic_limit_gb': round(limit_gb, 3),
        'traffic_used_gb':  round(used_gb, 3),
        'traffic_left_gb':  round(max(0.0, limit_gb - used_gb), 3) if limit_gb > 0 else None,
        'traffic_pct':      round(min(100.0, used_gb / limit_gb * 100), 1) if limit_gb > 0 else 0.0,
        'expires':          u.expires.strftime('%Y-%m-%d') if u.expires else '',
        'days_left':        days_left,
        'ip_limit':         u.ip_limit or 0,
        'devices_in_use':   len(_client_active_devices(u.id)),
        'devices':          _client_device_list(u.id),
        'speed_limit_kbps': u.speed_limit_kbps or 0,
        'note':             u.sub_note or '',
        'sub_url':          _build_sub_url(u),
        'owner':            _safe_reseller_username(u.reseller_id),
        'created_at':       u.created_at.isoformat() if u.created_at else None,
    }


_client_dns_cache = {}


def _client_country_for(addr, s):
    """Best-effort 2-letter country code + human location for a server address."""
    # 1. The inbound may be pinned to a Server record, which already carries a code.
    out_id = str(s.get('out_server_id', '') or '')
    if out_id.isdigit():
        srv = db.session.get(Server, int(out_id))
        if srv:
            return (srv.code or '').upper()[:2], srv.region or srv.name
    # 2. Otherwise fall back to GeoIP on the resolved address.
    ip = addr
    if addr and not re.match(r'^[\d.]+$', addr) and ':' not in addr:
        if addr in _client_dns_cache:
            ip = _client_dns_cache[addr]
        else:
            try:
                import socket
                ip = socket.gethostbyname(addr)
            except Exception:
                ip = None
            _client_dns_cache[addr] = ip
    cc = _ip_country(ip) if ip else None
    if cc in (None, 'LAN'):
        return '', ''
    return cc, ''


def _client_outbound(user, ib, s, server_ip):
    """Build a ready-to-use Xray outbound object for this user on this inbound."""
    addr  = s.get('server_addr', '').strip() or server_ip
    port  = int(s.get('server_port') or 0) or ib.port
    proto = ib.protocol.lower()
    tls   = s.get('tls_type', 'none')
    net   = 'tcp' if ib.transport == 'reality' else ib.transport
    if net == 'mkcp':
        net = 'kcp'

    stream = {'network': net, 'security': 'none'}

    if ib.transport == 'reality':
        stream['security'] = 'reality'
        stream['realitySettings'] = {
            'serverName':  s.get('sni', '') or '',
            'fingerprint': s.get('fingerprint', 'chrome') or 'chrome',
            'publicKey':   s.get('public_key', '') or '',
            'shortId':     s.get('short_id', '') or '',
            'spiderX':     '',
        }
    elif tls == 'tls':
        sni = (s.get('tls_server_name', '') or s.get('ws_host', '')
               or s.get('xhttp_host', '') or s.get('hu_host', '') or addr)
        tls_cfg = {'serverName': sni, 'allowInsecure': False}
        if s.get('fingerprint'):
            tls_cfg['fingerprint'] = s['fingerprint']
        if s.get('alpn'):
            tls_cfg['alpn'] = s['alpn']
        stream['security']    = 'tls'
        stream['tlsSettings'] = tls_cfg

    if net == 'ws':
        ws = {'path': s.get('ws_path', '/ws') or '/'}
        if s.get('ws_host'):
            ws['host'] = s['ws_host']
        stream['wsSettings'] = ws
    elif net == 'grpc':
        grpc = {'serviceName': s.get('grpc_service', 'xray') or 'xray'}
        if s.get('grpc_authority'):
            grpc['authority'] = s['grpc_authority']
        if s.get('grpc_multi_mode'):
            grpc['multiMode'] = True
        stream['grpcSettings'] = grpc
    elif net == 'httpupgrade':
        hu = {'path': s.get('hu_path', '/') or '/'}
        if s.get('hu_host'):
            hu['host'] = s['hu_host']
        stream['httpupgradeSettings'] = hu
    elif net == 'xhttp':
        xh = {'path': s.get('xhttp_path', '/') or '/',
              'mode': s.get('xhttp_mode', 'auto') or 'auto'}
        if s.get('xhttp_host') or s.get('ws_host'):
            xh['host'] = s.get('xhttp_host') or s.get('ws_host')
        if s.get('xhttp_extra'):
            try: xh['extra'] = json.loads(s['xhttp_extra'])
            except Exception: pass
        stream['xhttpSettings'] = xh
    elif net == 'kcp':
        kcp = {}
        if s.get('kcp_mtu'):        kcp['mtu']              = int(s['kcp_mtu'])
        if s.get('kcp_tti'):        kcp['tti']              = int(s['kcp_tti'])
        if s.get('kcp_uplink'):     kcp['uplinkCapacity']   = int(s['kcp_uplink'])
        if s.get('kcp_downlink'):   kcp['downlinkCapacity'] = int(s['kcp_downlink'])
        if s.get('kcp_congestion'): kcp['congestion']       = True
        if s.get('kcp_read_buf'):   kcp['readBufferSize']   = int(s['kcp_read_buf'])
        if s.get('kcp_write_buf'):  kcp['writeBufferSize']  = int(s['kcp_write_buf'])
        if kcp:
            stream['kcpSettings'] = kcp
    elif net == 'tcp':
        header_type = s.get('tcp_header_type', 'none')
        if header_type and header_type != 'none':
            hdr = {'type': header_type}
            if header_type == 'http':
                hdr['request'] = {
                    'version': '1.1', 'method': 'GET',
                    'path': [s.get('tcp_header_path', '/')],
                    'headers': {
                        'Host': [s.get('tcp_header_host', '')],
                        'User-Agent': ['Mozilla/5.0'],
                        'Accept-Encoding': ['gzip, deflate'],
                        'Connection': ['keep-alive'],
                        'Pragma': 'no-cache',
                    },
                }
            stream['tcpSettings'] = {'header': hdr}

    if proto == 'vless':
        vuser = {'id': user.uuid, 'encryption': 'none', 'level': 0}
        if ib.transport == 'reality':
            vuser['flow'] = 'xtls-rprx-vision'
        settings = {'vnext': [{'address': addr, 'port': port, 'users': [vuser]}]}
    elif proto == 'vmess':
        settings = {'vnext': [{'address': addr, 'port': port,
                               'users': [{'id': user.uuid, 'alterId': 0,
                                          'security': 'auto', 'level': 0}]}]}
    elif proto == 'trojan':
        settings = {'servers': [{'address': addr, 'port': port,
                                 'password': user.uuid, 'level': 0}]}
    elif proto == 'shadowsocks':
        settings = {'servers': [{'address': addr, 'port': port,
                                 'method': s.get('method', 'chacha20-ietf-poly1305'),
                                 'password': s.get('password', ''),
                                 'level': 0, 'uot': False}]}
    else:
        return None, addr, port

    return {
        'tag':            'proxy',
        'protocol':       proto,
        'settings':       settings,
        'streamSettings': stream,
        'mux':            {'enabled': False, 'concurrency': -1},
    }, addr, port


ACCESS_TYPES = ('both', 'sub', 'app')


def _access_type(u):
    """Normalised access_type, tolerant of rows written before the column."""
    value = (getattr(u, 'access_type', None) or 'both').lower()
    return value if value in ACCESS_TYPES else 'both'


def _sub_allowed(u):
    """True when this account may fetch its configs over the subscription URL."""
    return _access_type(u) != 'app'


def _app_allowed(u):
    """True when this account may sign into the client apps."""
    return _access_type(u) != 'sub'


def _client_servers(u):
    """List of connectable configs for this user, newest inbound first."""
    server_ip = get_setting('server_ip', request.host.split(':')[0])
    out = []
    for ib in u.inbounds:
        if not ib.enabled:
            continue
        s = ib.get_settings()
        ob, addr, port = _client_outbound(u, ib, s, server_ip)
        if not ob:
            continue
        link = _build_link(u, ib, s, server_ip)
        cc, region = _client_country_for(addr, s)
        # An explicitly configured country always wins over GeoIP guessing.
        if s.get('country'):
            cc = s['country'].upper()[:2]
        display = _format_config_name(s.get('config_name', ''), u) if s.get('config_name') else ib.tag
        out.append({
            'id':        ib.id,
            'tag':       ib.tag,
            'name':      display or ib.tag,
            'region':    region,
            'country':   cc,
            'protocol':  ib.protocol.lower(),
            'transport': ib.transport,
            'network':   ob['streamSettings']['network'],
            'security':  ob['streamSettings'].get('security', 'none'),
            'address':   addr,
            'port':      port,
            'link':      link,
            'outbound':  ob,
        })
    return out


@app.route('/api/client/login', methods=['POST'])
def api_client_login():
    d = request.json or {}
    username = (d.get('username') or '').strip()
    password = (d.get('password') or '').strip()
    if not username or not password:
        return jsonify({'error': 'Username and password are required'}), 400

    u = User.query.filter(db.func.lower(User.vpn_username) == username.lower()).first()
    if not u or not u.vpn_password or u.vpn_password != password:
        return jsonify({'error': 'Wrong username or password'}), 401

    # Refused before a token is issued rather than by handing over an empty
    # server list: "signed in but there is nothing here" is indistinguishable
    # from a broken panel.
    if not _app_allowed(u):
        return jsonify({
            'error': 'This account is set up for subscription links only. '
                     'Use the subscription URL your provider gave you.',
            'code':  'app_not_allowed',
        }), 403

    device_id, device_name, platform = _client_device_headers()

    # Refuse the sign-in rather than hand out a token this device cannot use.
    allowed, in_use = _client_device_allowed(u, device_id)
    if not allowed:
        return jsonify({
            'error': _client_blocked_reason(u, device_id),
            'code':  'device_limit',
            'ip_limit': u.ip_limit or 0,
            'devices_in_use': in_use,
            'devices': _client_device_list(u.id),
        }), 403

    # Start the clock on 'expiry from first connection' accounts.
    if (getattr(u, 'date_start_mode', 'on_create') == 'on_first_connect'
            and u.expires is None and (u.expires_days or 0) > 0):
        u.expires = _utcnow() + timedelta(days=u.expires_days)
        db.session.commit()

    _client_touch_device(u.id, device_id, device_name, platform)

    return jsonify({
        'token':      _client_issue_token(u),
        'expires_in': CLIENT_TOKEN_MAX_AGE,
        'profile':    _client_profile(u, device_id),
        'servers':    _client_servers(u) if _client_can_connect(u, device_id) else [],
        'brand':      get_setting('workspace_name', 'Veil') or 'Veil',
        'you':        _client_origin(),
    })


def _client_origin():
    """Where this request came from, so the app can draw its own position.

    The panel already terminates the connection, so reporting it back costs
    the user no privacy — and it saves the app from asking a third-party
    geolocation service where it is.
    """
    ip = _client_request_ip()
    cc = _ip_country(ip) if ip else None
    return {'ip': ip, 'country': '' if cc in (None, 'LAN') else cc}


@app.route('/api/client/session', methods=['GET'])
@client_auth_required
def api_client_session():
    """Everything the app needs in one round-trip: profile + connectable configs."""
    from flask import g
    u = g.client_user
    device_id, device_name, platform = _client_device_headers()
    # Touch first so a returning device keeps its slot rather than being
    # treated as a newcomer against a full limit.
    allowed, _ = _client_device_allowed(u, device_id)
    if allowed:
        _client_touch_device(u.id, device_id, device_name, platform)
    can = _client_can_connect(u, device_id)
    return jsonify({
        'profile': _client_profile(u, device_id),
        'servers': _client_servers(u) if can else [],
        'brand':   get_setting('workspace_name', 'Veil') or 'Veil',
        'blocked_reason': None if can else _client_blocked_reason(u, device_id),
        'you':     _client_origin(),
    })


def _client_blocked_reason(u, device_id=None):
    st = _client_status(u, device_id)
    if st == 'devices':
        n = u.ip_limit or 0
        return (f'This account is limited to {n} device{"s" if n != 1 else ""} '
                f'at a time, and {n} are already connected. Disconnect another '
                f'device and try again.')
    return {
        'expired':  'Your subscription has expired. Contact your provider to renew.',
        'limit':    'You have used all of your data allowance.',
        'paused':   'Your account has been paused by your provider.',
        'sub_only': 'This account is set up for subscription links only. Use the '
                    'subscription URL your provider gave you.',
    }.get(st, 'Your account is not active.')


@app.route('/api/client/profile', methods=['GET'])
@client_auth_required
def api_client_profile():
    from flask import g
    device_id, _, _ = _client_device_headers()
    return jsonify({'profile': _client_profile(g.client_user, device_id)})


@app.route('/api/client/servers', methods=['GET'])
@client_auth_required
def api_client_servers():
    from flask import g
    u = g.client_user
    device_id, _, _ = _client_device_headers()
    if not _client_can_connect(u, device_id):
        return jsonify({
            'servers': [],
            'blocked_reason': _client_blocked_reason(u, device_id),
        })
    return jsonify({'servers': _client_servers(u), 'blocked_reason': None})


@app.route('/api/client/heartbeat', methods=['POST'])
@client_auth_required
def api_client_heartbeat():
    """Called while connected — returns fresh quota so the app can self-disconnect.

    Also the device registry's keep-alive: a device that stops sending
    heartbeats ages out of the limit within CLIENT_DEVICE_WINDOW_MIN, which is
    what frees the slot when someone closes the app or loses their connection.
    """
    from flask import g
    u = g.client_user
    device_id, device_name, platform = _client_device_headers()
    allowed, _ = _client_device_allowed(u, device_id)
    if allowed:
        _client_touch_device(u.id, device_id, device_name, platform)
    can = _client_can_connect(u, device_id)
    return jsonify({
        'profile':    _client_profile(u, device_id),
        'can_connect': can,
        'blocked_reason': None if can else _client_blocked_reason(u, device_id),
    })


@app.route('/api/client/logout', methods=['POST'])
@client_auth_required
def api_client_logout():
    """Releases this device's slot straight away.

    Without it a signed-out device went on holding its slot for the whole
    silence window, which is how signing out on a laptop left the phone unable
    to connect for the next ten minutes.
    """
    from flask import g
    device_id, _, _ = _client_device_headers()
    if device_id:
        _client_devices.get(g.client_user.id, {}).pop(device_id, None)
    return jsonify({'ok': True, 'devices': _client_device_list(g.client_user.id)})


@app.route('/api/client/devices', methods=['GET'])
@client_auth_required
def api_client_devices():
    from flask import g
    u = g.client_user
    return jsonify({
        'ip_limit':       u.ip_limit or 0,
        'devices_in_use': len(_client_active_devices(u.id)),
        'devices':        _client_device_list(u.id),
    })


@app.route('/api/client/devices/release', methods=['POST'])
def api_client_release_device():
    """Signs another one of the account's devices out, freeing its slot.

    The account holder is the only person who can resolve "all my slots are
    taken", and they cannot always walk over to the other device. Deliberately
    *not* behind @client_auth_required: the app that most needs this is the one
    that was just refused a token for being over the limit, so username and
    password are accepted here as well as a bearer token.

    Ids are matched on the short form the app is shown, which is all it has.
    """
    d = request.json if request.is_json else {}
    d = d if isinstance(d, dict) else {}
    want = (d.get('id') or '').strip()
    if not want:
        return jsonify({'error': 'A device id is required'}), 400

    auth  = request.headers.get('Authorization', '')
    token = auth[7:].strip() if auth.lower().startswith('bearer ') else ''
    if token:
        u, err = _client_user_from_token(token)
        if err:
            return jsonify({'error': err}), 401
    else:
        username = (d.get('username') or '').strip()
        password = (d.get('password') or '').strip()
        u = User.query.filter(
            db.func.lower(User.vpn_username) == username.lower()).first() \
            if username else None
        if not u or not u.vpn_password or u.vpn_password != password:
            return jsonify({'error': 'Wrong username or password'}), 401

    seen = _client_devices.get(u.id, {})
    gone = [did for did in list(seen) if did == want or did[:8] == want[:8]]
    for did in gone:
        seen.pop(did, None)
    if not gone:
        return jsonify({'error': 'That device is not holding a slot'}), 404
    return jsonify({'ok': True, 'devices': _client_device_list(u.id)})


@app.route('/api/client/update', methods=['GET'])
def api_client_update():
    """Latest client version + download links, driven by panel settings.

    Unauthenticated on purpose: an app that cannot sign in (because it is too
    old) still needs to be able to find its update.
    """
    platform = (request.args.get('platform', '') or '').strip().lower()
    current  = (request.args.get('version', '') or '').strip()

    def _s(key, default=''):
        return get_setting(key, default).strip()

    builds = {
        'android': {
            'version': _s('client_android_version'),
            'url':     _s('client_android_url'),
        },
        'windows': {
            'version': _s('client_windows_version'),
            'url':     _s('client_windows_url'),
        },
        'linux': {
            'version': _s('client_linux_version'),
            'url':     _s('client_linux_url'),
        },
        'macos': {
            'version': _s('client_macos_version'),
            'url':     _s('client_macos_url'),
        },
    }

    notes     = _s('client_release_notes')
    mandatory = _s('client_update_mandatory', 'false').lower() in ('1', 'true', 'yes')

    info = builds.get(platform)
    if info is None:
        return jsonify({'builds': builds, 'notes': notes, 'mandatory': mandatory})

    latest = info['version']
    return jsonify({
        'platform':      platform,
        'latest':        latest,
        # Echoed back so a client that disagrees about its own version — the
        # "already updated but still offered the update" case — can be told
        # apart from a panel that simply has a newer build published.
        'current':       current,
        'url':           info['url'],
        'notes':         notes,
        'mandatory':     mandatory,
        'update_available': bool(latest) and _version_gt(latest, current),
    })


def _version_gt(a, b):
    """True when version a is newer than b. Tolerates junk on either side."""
    def parts(v):
        out = []
        for chunk in re.split(r'[.\-+]', v or ''):
            digits = ''.join(ch for ch in chunk if ch.isdigit())
            out.append(int(digits) if digits else 0)
        return out or [0]
    pa, pb = parts(a), parts(b)
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else 0
        y = pb[i] if i < len(pb) else 0
        if x != y:
            return x > y
    return False


@app.route('/api/client/ping', methods=['GET'])
def api_client_ping():
    """Unauthenticated reachability probe — used by the app's server-URL setup screen."""
    return jsonify({
        'ok':    True,
        'panel': get_setting('workspace_name', 'Veil') or 'Veil',
        'api':   1,
    })


# ── Subscription endpoint (public — no login required) ────────────────────────

def _is_browser_request():
    """Return True if the request looks like a browser (not a VPN client fetching a sub)."""
    ua     = request.headers.get('User-Agent', '').lower()
    accept = request.headers.get('Accept', '')
    # Browsers always include 'mozilla' in UA and request text/html.
    # VPN clients (v2rayNG, Clash, sing-box, Shadowrocket, Hiddify…) use custom UAs
    # and typically accept */* or application/json, never text/html.
    return 'mozilla' in ua or 'text/html' in accept


def _subscription_page(u, sub_url):
    """Render the beautiful browser subscription page for a user."""
    server_ip = get_setting('server_ip', request.host.split(':')[0])
    brand     = get_setting('workspace_name', 'Bridge') or 'Bridge'

    # ── Compute status ───────────────────────────────────────────────────────
    if u.status != 'active':
        status = u.status
    elif u.is_expired():
        status = 'expired'
    elif u.is_over_limit():
        status = 'limit'
    else:
        status = 'active'

    # ── Traffic numbers ──────────────────────────────────────────────────────
    total_gb  = float(u.traffic_limit or 0)
    used_gb   = float(u.traffic_used  or 0)
    remain_gb = max(0.0, total_gb - used_gb)

    def _fmt(n):
        return str(int(n)) if n == int(n) else f'{n:.1f}'

    gauge_pct = round(min(100, (used_gb / total_gb) * 100)) if total_gb > 0 else 0

    # ── Days left ────────────────────────────────────────────────────────────
    if u.expires:
        days_left  = max(0, (u.expires - _utcnow()).days)
        expires_str = u.expires.strftime('%b %d, %Y')
    else:
        days_left  = None
        expires_str = None

    # ── Build server list (only for active accounts) ─────────────────────────
    servers = []
    if status == 'active':
        for ib in u.inbounds:
            if not ib.enabled:
                continue
            lnk = _build_link(u, ib, ib.get_settings(), server_ip)
            if not lnk:
                continue
            s          = ib.get_settings()
            cfg_name   = _format_config_name(s.get('config_name', ''), u)
            transport  = ib.transport.upper()
            if ib.transport == 'reality':
                proto_label = f'{ib.protocol.upper()} · Reality'
            elif ib.transport in ('ws', 'grpc', 'xhttp', 'kcp', 'quic'):
                proto_label = f'{ib.protocol.upper()} · {transport}'
            else:
                proto_label = ib.protocol.upper()
            servers.append({'name': cfg_name, 'proto': proto_label, 'uri': lnk})

    # ── Display email / dot colour ───────────────────────────────────────────
    display_email = u.email or f'{u.name.lower().replace(" ", ".")}@{brand.lower()}.app'
    dot_class = {'active': '', 'expired': 'danger', 'limit': 'warn'}.get(status, 'danger')

    _qrcode_js_path = os.path.join(_PANEL_DIR, 'static', 'qrcode.js')
    try:
        with open(_qrcode_js_path, 'r', encoding='utf-8') as _f:
            _qrcode_js = _f.read()
    except Exception:
        _qrcode_js = ''

    return render_template(
        'sub.html',
        brand         = brand,
        user_name     = u.name,
        display_email = display_email,
        dot_class     = dot_class,
        status        = status,
        total_gb      = total_gb,
        total_gb_fmt  = _fmt(total_gb),
        used_gb_fmt   = _fmt(used_gb),
        remain_gb_fmt = _fmt(remain_gb),
        gauge_pct     = gauge_pct,
        days_left     = days_left,
        expires       = expires_str,
        servers       = servers,
        sub_url       = sub_url,
        qrcode_js     = _qrcode_js,
    )


def _subscription_response(token):
    """Core subscription logic — shared by all sub URL routes.
    Returns the browser subscription page when visited from a browser,
    and the raw base64 config list when fetched by a VPN client.
    """
    import base64 as _b64
    from urllib.parse import quote as _quote
    from flask import Response
    u = User.query.filter_by(sub_token=token).first_or_404()

    # App-only accounts get nothing here — not an empty list, which every VPN
    # client renders as "the subscription is broken", but a plain refusal that
    # says where the configs actually live.
    if not _sub_allowed(u):
        message = ('This account is set up for the app only. Sign into the '
                   'Sentinelle app with the username and password your '
                   'provider gave you.')
        if _is_browser_request():
            return Response(
                f'<!doctype html><meta charset="utf-8">'
                f'<title>App only</title>'
                f'<body style="font:15px/1.6 system-ui;margin:0;display:flex;'
                f'min-height:100vh;align-items:center;justify-content:center;'
                f'background:#0d1117;color:#c9d1d9">'
                f'<p style="max-width:34rem;padding:2rem">{message}</p></body>',
                status=403, mimetype='text/html; charset=utf-8')
        return Response(message, status=403,
                        mimetype='text/plain; charset=utf-8')

    # Activate expiry timer on first connection when mode is 'on_first_connect'
    if (getattr(u, 'date_start_mode', 'on_create') == 'on_first_connect'
            and u.expires is None
            and (u.expires_days or 0) > 0):
        u.expires = _utcnow() + timedelta(days=u.expires_days)
        db.session.commit()

    # Build the canonical sub URL for this user (used by both paths)
    sub_url = _build_sub_url(u) or request.url

    # ── Browser path: render the visual subscription page ────────────────────
    if _is_browser_request():
        return _subscription_page(u, sub_url)

    # ── VPN client path: return raw base64 config list ───────────────────────
    server_ip = get_setting('server_ip', request.host.split(':')[0])
    show_info = get_setting('sub_info_entry', 'true').lower() in ('1', 'true', 'yes')

    links = []
    if u.status == 'active' and not u.is_expired() and not u.is_over_limit():
        for ib in u.inbounds:
            if not ib.enabled:
                continue
            lnk = _build_link(u, ib, ib.get_settings(), server_ip)
            if lnk:
                links.append(lnk)

    # ── Info entry (prepended) ───────────────────────────────────────────────
    # A non-connectable vless link whose name shows remaining data / days.
    # Most clients show it as a label in the config list.
    if show_info:
        info_parts = []
        # remaining traffic
        if u.traffic_limit and u.traffic_limit > 0:
            remaining_gb = max(0.0, u.traffic_limit - (u.traffic_used or 0))
            info_parts.append(f"↕ {remaining_gb:.2f} GB")
        else:
            info_parts.append("↕ ∞ GB")
        # remaining days
        if u.expires:
            remaining_days = max(0, (u.expires - _utcnow()).days)
            info_parts.append(f"⏱ {remaining_days}d")
        # custom note
        if u.sub_note and u.sub_note.strip():
            info_parts.append(u.sub_note.strip())
        # fall back to user's name always
        info_label = f"[{u.name}] " + " · ".join(info_parts)
        info_link = (
            "vless://00000000-0000-0000-0000-000000000000"
            f"@0.0.0.0:0?type=none#{_quote(info_label)}"
        )
        links.insert(0, info_link)

    content = _b64.b64encode('\n'.join(links).encode()).decode()
    return Response(
        content,
        mimetype='text/plain; charset=utf-8',
        headers={
            'Content-Disposition': f'inline; filename="sub.txt"',
            'Profile-Update-Interval': '12',
            'Subscription-Userinfo': (
                f'upload={int((u.traffic_used or 0) * 1073741824)};'
                f'download=0;'
                f'total={int((u.traffic_limit or 0) * 1073741824)};'
                + (f'expire={int(u.expires.timestamp())}' if u.expires else '')
            ),
        }
    )


@app.route('/sub/<token>')
def subscription(token):
    """Standard /sub/<token> subscription endpoint."""
    return _subscription_response(token)


@app.route('/<keyword>/<token>')
def subscription_alt(keyword, token):
    """Dynamic subscription path — matches when keyword == configured sub_path setting."""
    sub_path = get_setting('sub_path', 'sub')
    if keyword == sub_path and keyword != 'sub':
        return _subscription_response(token)
    from flask import abort
    abort(404)


def _build_sub_urls(user):
    """Return a list of {name, url} dicts: primary URL + all configured relay URLs."""
    if not user.sub_token:
        return []
    sub_domain = get_setting('sub_domain', '').strip()
    sub_path   = get_setting('sub_path', 'sub').strip() or 'sub'
    sub_scheme = get_setting('sub_scheme', 'http').strip() or 'http'
    panel_port = int(os.environ.get('PORT', 5000))
    sub_port   = get_setting('sub_port', str(panel_port)).strip()
    import re as _re
    def _host_needs_port(h, p):
        if _re.search(r'[a-zA-Z]', h):   # domain name — nginx handles the port
            return False
        return p not in ('80', '443', '')
    if sub_domain:
        primary = f"{sub_scheme}://{sub_domain}/{sub_path}/{user.sub_token}"
    else:
        host = get_setting('server_ip', '0.0.0.0')
        if _host_needs_port(host, sub_port):
            primary = f"{sub_scheme}://{host}:{sub_port}/{sub_path}/{user.sub_token}"
        else:
            primary = f"{sub_scheme}://{host}/{sub_path}/{user.sub_token}"
    result     = [{'name': 'Primary', 'url': primary}]
    try:
        for relay in json.loads(get_setting('sub_extra_urls', '[]')):
            base = relay.get('base_url', '').rstrip('/')
            if base:
                result.append({'name': relay.get('name', base), 'url': f"{base}/{sub_path}/{user.sub_token}"})
    except Exception:
        pass
    return result


def _build_sub_url(user):
    """Return the primary subscription URL (first entry from _build_sub_urls)."""
    urls = _build_sub_urls(user)
    return urls[0]['url'] if urls else ''


def _parse_expires(d):
    """Extract expires datetime from request dict. Returns None if not provided."""
    if 'expires' in d and d['expires']:
        try:
            return datetime.strptime(d['expires'], '%Y-%m-%d')
        except ValueError:
            pass
    if 'expires_days' in d and d['expires_days']:
        try:
            return _utcnow() + timedelta(days=int(d['expires_days']))
        except (ValueError, TypeError):
            pass
    return None


def _parse_inbound_ids(d):
    """Return a deduplicated list of integer inbound IDs from the request dict.
    Accepts both 'inbound_ids' (list) and legacy 'inbound_id' (single int).
    """
    ids = set()
    for x in (d.get('inbound_ids') or []):
        try: ids.add(int(x))
        except (TypeError, ValueError): pass
    if d.get('inbound_id'):
        try: ids.add(int(d['inbound_id']))
        except (TypeError, ValueError): pass
    return list(ids)


# ── API — Inbounds ────────────────────────────────────────────────────────────

@app.route('/api/inbounds', methods=['GET'])
@reseller_or_admin_required
def api_inbounds():
    inbounds = Inbound.query.order_by(Inbound.created_at.desc()).all()
    rid = _get_reseller_id()
    if rid is not None:
        reseller = db.session.get(Reseller, rid)
        if reseller:
            allowed = json.loads(reseller.allowed_inbound_ids or '[]')
            if allowed:
                inbounds = [ib for ib in inbounds if ib.id in allowed]
    return jsonify({'inbounds': [ib.to_dict() for ib in inbounds]})


def _resolve_transport(d):
    """Determine DB transport value from the request dict.
    UI sends network= (tcp/ws/grpc/mkcp/httpupgrade) and tls= (none/tls/reality).
    We store 'reality' as a special transport so the config builder knows.
    """
    network  = (d.get('network') or d.get('transport', 'tcp')).lower()
    tls_mode = (d.get('tls', 'none') or 'none').lower()
    return 'reality' if tls_mode == 'reality' else network


def _auto_init_out_server(out_server_id_str):
    """If an out server is assigned to an inbound, ensure its UUID/port are initialized.
    Returns the server settings dict, or None if server not found.
    """
    if not out_server_id_str:
        return None
    try:
        srv = db.session.get(Server, int(out_server_id_str))
        if srv:
            return _init_out_proxy_settings(srv)
    except Exception:
        pass
    return None


@app.route('/api/inbounds', methods=['POST'])
@login_required
def api_create_inbound():
    d = request.json or {}
    tag      = d.get('tag', '').strip()
    protocol = (d.get('proto') or d.get('protocol', '')).lower()
    transport = _resolve_transport(d)
    port     = d.get('port')
    if not all([tag, protocol, transport, port]):
        return jsonify({'error': 'tag, proto, network, port are required'}), 400
    if Inbound.query.filter_by(port=int(port)).first():
        return jsonify({'error': f'Port {port} already in use'}), 409
    ib = Inbound(tag=tag, protocol=protocol, transport=transport, port=int(port))
    settings = _extract_settings(d, protocol, transport)
    _auto_init_out_server(settings.get('out_server_id'))
    ib.set_settings(settings)
    ib.access_mode    = d.get('access_mode', 'none')
    ib.access_domains = json.dumps(d.get('access_domains') or [])
    ib.access_ips     = json.dumps(d.get('access_ips') or [])
    db.session.add(ib)
    db.session.commit()
    _, apply_msg = apply_config()
    resp = {'inbound': ib.to_dict(), 'xray': apply_msg}
    if ib.transport == 'reality':
        warn = _reality_dest_warning(ib.get_settings())
        if warn:
            resp['warning'] = warn
    return jsonify(resp), 201


@app.route('/api/inbounds/<int:iid>', methods=['PUT'])
@login_required
def api_update_inbound(iid):
    ib = Inbound.query.get_or_404(iid)
    d  = request.json or {}
    if set(d.keys()) == {'enabled'}:
        ib.enabled = bool(d['enabled'])
        db.session.commit()
        _, apply_msg = apply_config()
        return jsonify({**ib.to_dict(), 'xray': apply_msg})
    new_port = d.get('port', ib.port)
    if int(new_port) != ib.port and Inbound.query.filter_by(port=int(new_port)).first():
        return jsonify({'error': f'Port {new_port} already in use'}), 409
    if 'tag'     in d: ib.tag     = d['tag']
    if 'enabled' in d: ib.enabled = bool(d['enabled'])
    protocol  = (d.get('proto') or d.get('protocol', ib.protocol)).lower()
    transport = _resolve_transport(d) if ('network' in d or 'transport' in d or 'tls' in d) else ib.transport
    ib.protocol  = protocol
    ib.transport = transport
    if 'port' in d: ib.port = int(d['port'])
    settings = _extract_settings(d, ib.protocol, ib.transport)
    _auto_init_out_server(settings.get('out_server_id'))
    ib.set_settings(settings)
    if 'access_mode' in d:    ib.access_mode    = d['access_mode']
    if 'access_domains' in d: ib.access_domains = json.dumps(d['access_domains'] or [])
    if 'access_ips' in d:     ib.access_ips     = json.dumps(d['access_ips'] or [])
    db.session.commit()
    _, apply_msg = apply_config()
    return jsonify({**ib.to_dict(), 'xray': apply_msg})


# ── REALITY dest validation ───────────────────────────────────────────────────

# REALITY relays the client's TLS handshake to `dest` and has a fixed ~8 KB
# buffer for it. Sites with a large certificate chain never finish inside that
# budget, so every client connects and then silently carries nothing — the
# hardest failure in this whole stack to diagnose from the client side.
REALITY_BAD_DESTS = {
    'www.microsoft.com': "its certificate chain (~8 KB) overflows REALITY's handshake buffer",
    'microsoft.com':     "its certificate chain (~8 KB) overflows REALITY's handshake buffer",
    'www.apple.com':     'it does not present a usable TLS 1.3 handshake for REALITY',
    'www.amazon.com':    'it redirects and negotiates inconsistently',
}

REALITY_GOOD_DESTS = [
    'www.cloudflare.com:443',
    'dl.google.com:443',
    'www.speedtest.net:443',
    'www.datadoghq.com:443',
]


def _reality_dest_warning(settings):
    """Return a warning string when a REALITY dest is known to break clients."""
    dest = (settings.get('dest') or '').strip().lower()
    if not dest:
        return None
    host = dest.split(':')[0]
    reason = REALITY_BAD_DESTS.get(host)
    if not reason:
        return None
    return (f'REALITY dest "{host}" does not work: {reason}. '
            f'Clients will connect but carry no traffic. '
            f'Use one of: {", ".join(REALITY_GOOD_DESTS)}.')


@app.route('/api/inbounds/reality-check')
@login_required
def api_reality_check():
    """List every REALITY inbound whose dest is known to be unusable."""
    problems = []
    for ib in Inbound.query.all():
        if ib.transport != 'reality':
            continue
        warn = _reality_dest_warning(ib.get_settings())
        if warn:
            problems.append({
                'id': ib.id,
                'tag': ib.tag,
                'port': ib.port,
                'dest': ib.get_settings().get('dest', ''),
                'warning': warn,
            })
    return jsonify({
        'problems': problems,
        'ok': not problems,
        'suggested_dests': REALITY_GOOD_DESTS,
    })


@app.route('/api/inbounds/<int:iid>/routing-check')
@login_required
def api_inbound_routing_check(iid):
    """Diagnose whether this inbound's out-proxy is properly configured."""
    import socket
    ib = Inbound.query.get_or_404(iid)
    s  = ib.get_settings()
    out_id = str(s.get('out_server_id') or '').strip()

    if not out_id:
        return jsonify({'ok': True, 'routing': 'direct', 'message': 'No out server assigned — traffic exits from panel server directly'})

    try:
        srv = db.session.get(Server, int(out_id))
    except Exception:
        srv = None

    if not srv:
        return jsonify({'ok': False, 'routing': 'broken', 'message': f'Out server ID {out_id} not found in database'})

    sv = srv.get_settings()
    uid   = sv.get('out_proxy_uuid', '')
    port  = int(sv.get('out_proxy_port', 10001))
    proto = sv.get('out_proxy_protocol', 'vless')

    if not uid:
        return jsonify({
            'ok': False, 'routing': 'broken',
            'message': f'Out server "{srv.name}" has no UUID — open its Xray bridge card and click Activate to initialize',
            'server': srv.to_dict(),
        })

    # Test TCP reachability
    reachable = False
    try:
        sock = socket.create_connection((srv.ip, port), timeout=3)
        sock.close()
        reachable = True
    except Exception:
        pass

    # Check that the rule appears in current config
    cfg = build_config()
    tag = f'out-proxy-{out_id}'
    has_outbound = any(o.get('tag') == tag for o in cfg.get('outbounds', []))
    has_rule     = any(
        ib.tag in r.get('inboundTag', []) for r in cfg.get('routing', {}).get('rules', [])
    )

    return jsonify({
        'ok':          reachable and has_outbound and has_rule,
        'routing':     'active' if (has_outbound and has_rule) else 'missing',
        'reachable':   reachable,
        'has_outbound': has_outbound,
        'has_rule':    has_rule,
        'server':      srv.to_dict(),
        'uuid':        uid[:8] + '…',
        'port':        port,
        'protocol':    proto,
        'message': (
            f'✅ OK — traffic from "{ib.tag}" exits via {srv.name} ({srv.ip}:{port})'
            if (reachable and has_outbound and has_rule)
            else f'❌ Port {port} unreachable on {srv.ip}' if not reachable
            else '❌ Routing rule missing from config — try saving the inbound again'
        ),
    })


@app.route('/api/inbounds/<int:iid>/toggle', methods=['POST'])
@login_required
def api_toggle_inbound(iid):
    ib = Inbound.query.get_or_404(iid)
    ib.enabled = not ib.enabled
    db.session.commit()
    apply_config()
    return jsonify({'enabled': ib.enabled})


@app.route('/api/inbounds/<int:iid>', methods=['DELETE'])
@login_required
def api_delete_inbound(iid):
    ib = Inbound.query.get_or_404(iid)
    db.session.delete(ib)
    db.session.commit()
    apply_config()
    return jsonify({'ok': True})


def _extract_settings(d, protocol, transport):
    """Persist all inbound settings fields to JSON blob."""
    s = {}

    # Common
    s['listen']        = d.get('listen', '0.0.0.0')
    s['server_addr']   = d.get('server_addr', '').strip()
    raw_sp = d.get('server_port')
    s['server_port']   = int(raw_sp) if raw_sp and str(raw_sp).strip() else 0
    s['config_name']   = d.get('config_name', '').strip()
    # Two-letter country code, shown as a flag and plotted on the map in
    # the client apps. Blank means "unknown".
    s['country']       = (d.get('country', '') or '').strip().upper()[:2]
    s['out_server_id'] = str(d.get('out_server_id', '') or '').strip() or None

    # Security / TLS type — driven by the 'tls' field sent from UI (security tab)
    tls_mode = d.get('tls', 'none')  # 'none' | 'tls' | 'reality'
    if transport == 'reality':
        s['tls_type'] = 'reality'
    elif tls_mode == 'tls':
        s['tls_type'] = 'tls'
    else:
        s['tls_type'] = 'none'

    # TLS fields
    s['cert_file']          = d.get('cert_file', '')
    s['key_file']           = d.get('key_file', '')
    s['tls_server_name']    = d.get('tls_server_name', '')
    s['alpn']               = d.get('alpn', [])
    s['fingerprint']        = d.get('fingerprint', '')
    s['reject_unknown_sni'] = bool(d.get('reject_unknown_sni', False))

    # TCP
    s['accept_proxy_protocol'] = bool(d.get('accept_proxy_protocol', False))
    s['tcp_header_type']       = d.get('tcp_header_type', 'none')
    s['tcp_header_path']       = d.get('tcp_header_path', '/')
    s['tcp_header_host']       = d.get('tcp_header_host', '')

    # WS
    s['ws_path']      = d.get('ws_path', '/ws')
    s['ws_host']      = d.get('ws_host', '')
    s['ws_heartbeat'] = int(d.get('ws_heartbeat') or 0)

    # gRPC
    s['grpc_service']    = d.get('grpc_service', 'xray')
    s['grpc_authority']  = d.get('grpc_authority', '')
    s['grpc_multi_mode'] = bool(d.get('grpc_multi_mode', False))

    # mKCP
    s['kcp_mtu']       = int(d.get('kcp_mtu')      or 1350)
    s['kcp_tti']       = int(d.get('kcp_tti')       or 50)
    s['kcp_uplink']    = int(d.get('kcp_uplink')    or 5)
    s['kcp_downlink']  = int(d.get('kcp_downlink')  or 20)
    s['kcp_congestion']= bool(d.get('kcp_congestion', False))
    s['kcp_read_buf']  = int(d.get('kcp_read_buf')  or 2)
    s['kcp_write_buf'] = int(d.get('kcp_write_buf') or 2)

    # HTTPUpgrade
    s['hu_path']         = d.get('hu_path', '/')
    s['hu_host']         = d.get('hu_host', '')
    s['hu_accept_proxy'] = bool(d.get('hu_accept_proxy', False))

    # XHTTP (replaces WebSocket for H2/H3)
    s['xhttp_path']  = d.get('xhttp_path', '/')
    s['xhttp_host']  = d.get('xhttp_host', '')
    s['xhttp_mode']  = d.get('xhttp_mode', 'auto')
    s['xhttp_extra'] = d.get('xhttp_extra', '')

    # Reality
    s['private_key'] = d.get('private_key', '')
    s['public_key']  = d.get('public_key', '')
    s['sni']         = d.get('sni', 'www.cloudflare.com')
    s['dest']        = d.get('dest', 'www.cloudflare.com:443')
    s['short_id']    = d.get('short_id', '')

    # Sniffing
    s['sniffing_enabled'] = bool(d.get('sniffing_enabled', False))
    s['sniff_http']       = bool(d.get('sniff_http',   True))
    s['sniff_tls']        = bool(d.get('sniff_tls',    True))
    s['sniff_quic']       = bool(d.get('sniff_quic',   False))
    s['sniff_fakedns']    = bool(d.get('sniff_fakedns', False))
    s['sniff_route_only'] = bool(d.get('sniff_route_only', False))

    # Protocol-specific
    proto = protocol.lower()
    if proto == 'shadowsocks':
        s['method']   = d.get('ss_method')  or d.get('method',   'chacha20-ietf-poly1305')
        s['password'] = d.get('ss_password') or d.get('password', '')

    if proto == 'socks':
        s['auth']     = d.get('auth', 'noauth')
        s['udp']      = bool(d.get('udp', True))
        s['ip']       = d.get('ip', '')
        s['accounts'] = d.get('accounts', [])

    if proto == 'http':
        s['http_accounts']     = d.get('http_accounts', [])
        s['allow_transparent'] = bool(d.get('allow_transparent', False))

    return s


# ── API — Servers ─────────────────────────────────────────────────────────────

@app.route('/api/servers', methods=['GET'])
@login_required
def api_servers():
    return jsonify({'servers': [s.to_dict() for s in Server.query.order_by(Server.created_at.desc()).all()]})


@app.route('/api/servers', methods=['POST'])
@login_required
def api_create_server():
    d      = request.json or {}
    name   = d.get('name', '').strip()
    region = d.get('region', '').strip()
    code   = d.get('code', '').strip().upper()
    ip     = d.get('ip', '').strip()
    if not all([name, ip]):
        return jsonify({'error': 'name and ip are required'}), 400
    if not region: region = 'Unknown'
    if not code:   code   = 'XX'
    s = Server(
        name=name, region=region, code=code, ip=ip,
        server_type=d.get('server_type', 'out'),
        status=d.get('status', 'online'),
        notes=d.get('notes', '') or None,
    )
    db.session.add(s)
    db.session.commit()
    return jsonify(s.to_dict()), 201


@app.route('/api/servers/<int:sid>', methods=['PUT'])
@login_required
def api_update_server(sid):
    s = Server.query.get_or_404(sid)
    d = request.json or {}
    for k in ('name', 'region', 'code', 'ip', 'status', 'users', 'load', 'ping', 'server_type', 'notes'):
        if k in d: setattr(s, k, d[k])
    db.session.commit()
    return jsonify(s.to_dict())


@app.route('/api/servers/<int:sid>', methods=['DELETE'])
@login_required
def api_delete_server(sid):
    s = Server.query.get_or_404(sid)
    db.session.delete(s)
    db.session.commit()
    return jsonify({'ok': True})


def _init_out_proxy_settings(server):
    """Ensure out-proxy credentials exist in server settings. Returns settings dict."""
    s = server.get_settings()
    changed = False
    if not s.get('out_proxy_port'):
        s['out_proxy_port']  = 10001;  changed = True
    if not s.get('out_proxy_uuid'):
        s['out_proxy_uuid']  = str(uuid.uuid4());  changed = True
    if not s.get('out_proxy_protocol'):
        s['out_proxy_protocol'] = 'vless';  changed = True
    if not s.get('out_proxy_token'):
        s['out_proxy_token'] = os.urandom(16).hex();  changed = True
    if changed:
        server.set_settings(s)
        db.session.commit()
    return s


def _generate_out_proxy_script(server):
    """Generate an Xray bridge install script for the OUT server."""
    s      = _init_out_proxy_settings(server)
    port   = int(s['out_proxy_port'])
    uid    = s['out_proxy_uuid']
    proto  = s.get('out_proxy_protocol', 'vless')
    svcname = f"bridge-out-{server.id}"

    if proto == 'vmess':
        ib_settings = {"clients": [{"id": uid, "alterId": 0, "level": 0}]}
    else:
        ib_settings = {"clients": [{"id": uid, "level": 0}], "decryption": "none"}

    # Bind to the server's own address when it's a private/tunnel IP (e.g. a
    # backhaul bip TUN endpoint like 10.20.20.1) so the bridge is reachable only
    # through that tunnel and never exposed on the box's public interface.
    # Genuine public "out" servers keep 0.0.0.0 since their public IP is often
    # NAT'd and not actually bound to a local interface.
    try:
        import ipaddress
        bridge_listen = server.ip if ipaddress.ip_address(server.ip).is_private else "0.0.0.0"
    except ValueError:
        bridge_listen = "0.0.0.0"

    xray_cfg = json.dumps({
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": bridge_listen,
            "port": port,
            "protocol": proto,
            "settings": ib_settings,
            "streamSettings": {"network": "tcp"},
            "tag": svcname
        }],
        "outbounds": [
            {"protocol": "freedom",   "settings": {}, "tag": "direct"},
            {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
        ],
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]
        }
    }, indent=2)

    panel_ip   = get_setting('server_ip', '0.0.0.0')
    panel_port = os.environ.get('PORT', '5000')

    return f"""#!/bin/bash
# Bridge Panel — Xray OUT proxy bridge
# Server   : {server.name} ({server.ip})
# Bind     : {bridge_listen}{" (private/tunnel address — not reachable from the public internet)" if bridge_listen != "0.0.0.0" else ""}
# Port     : {port}
# Protocol : {proto.upper()}
# UUID     : {uid}
set -euo pipefail

# ── Install Xray ──────────────────────────────────────────────────────────────
if ! command -v xray &>/dev/null && ! [ -f /usr/local/bin/xray ]; then
    echo "[*] Installing Xray core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
    echo "[OK] Xray already installed: $(xray version 2>/dev/null | head -1)"
fi

# ── Open firewall port ────────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q active; then
    ufw allow {port}/tcp && echo "[OK] ufw: port {port} allowed"
fi
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port={port}/tcp && firewall-cmd --reload
fi

# ── Write bridge config ───────────────────────────────────────────────────────
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/{svcname}.json << 'XRAY_CFG'
{xray_cfg}
XRAY_CFG

# ── Systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/{svcname}.service << 'SVC'
[Unit]
Description=Bridge Xray OUT proxy {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/{svcname}.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}
systemctl restart {svcname}
sleep 2

if systemctl is-active --quiet {svcname}; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Xray bridge is RUNNING                              ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Protocol : {proto.upper():<44}║"
    echo "║  Port     : {port:<44}║"
    echo "║  UUID     : {uid[:44]:<44}║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "✅ Now go to the panel → Servers → {server.name} card"
    echo "   → expand 'Xray bridge' → click 'Activate'"
    echo "   This routes all VPN traffic through this server."
    echo ""
    echo "🔥 Make sure port {port} is reachable from the panel server:"
    echo "   nc -zv {server.ip} {port}"
else
    echo "[ERROR] Service failed to start — logs:"
    journalctl -u {svcname} -n 30 --no-pager
    exit 1
fi
"""


@app.route('/api/servers/<int:sid>/out-proxy', methods=['GET'])
@login_required
def api_server_out_proxy(sid):
    """Get/initialize out-proxy settings for a server."""
    s = Server.query.get_or_404(sid)
    cfg = _init_out_proxy_settings(s)
    active_id = get_setting('active_outbound_server_id', '')
    return jsonify({
        **cfg,
        'is_active': str(sid) == str(active_id),
        'script_url': f"{request.url_root.rstrip('/')}/setup/out-proxy/{sid}/{cfg['out_proxy_token']}",
    })


@app.route('/api/servers/<int:sid>/out-proxy', methods=['PUT'])
@login_required
def api_update_out_proxy(sid):
    """Update out-proxy settings (port, protocol, regenerate UUID)."""
    srv = Server.query.get_or_404(sid)
    d   = request.json or {}
    s   = srv.get_settings()
    if 'out_proxy_port'     in d: s['out_proxy_port']     = int(d['out_proxy_port'])
    if 'out_proxy_protocol' in d: s['out_proxy_protocol'] = d['out_proxy_protocol']
    if d.get('regen_uuid'):       s['out_proxy_uuid']     = str(uuid.uuid4())
    if d.get('regen_token'):      s['out_proxy_token']    = os.urandom(16).hex()
    srv.set_settings(s)
    db.session.commit()
    return jsonify(s)


@app.route('/api/servers/<int:sid>/set-active-outbound', methods=['POST'])
@login_required
def api_set_active_outbound(sid):
    """Add this server to the active outbound list and rebuild Xray config."""
    srv = Server.query.get_or_404(sid)
    _init_out_proxy_settings(srv)
    try:
        ids = json.loads(get_setting('active_outbound_server_ids', '[]'))
    except Exception:
        ids = []
    if str(sid) not in [str(x) for x in ids]:
        ids.append(str(sid))
    set_setting('active_outbound_server_ids', json.dumps(ids))
    set_setting('active_outbound_server_id', str(sid))  # backward compat
    _, msg = apply_config()
    return jsonify({'ok': True, 'xray': msg, 'server': srv.to_dict(), 'active_ids': ids})


@app.route('/api/servers/<int:sid>/remove-active-outbound', methods=['POST'])
@login_required
def api_remove_active_outbound(sid):
    """Remove this server from the active outbound list."""
    try:
        ids = json.loads(get_setting('active_outbound_server_ids', '[]'))
    except Exception:
        ids = []
    ids = [x for x in ids if str(x) != str(sid)]
    set_setting('active_outbound_server_ids', json.dumps(ids))
    if not ids:
        set_setting('active_outbound_server_id', '')
    _, msg = apply_config()
    return jsonify({'ok': True, 'xray': msg, 'active_ids': ids})


@app.route('/api/servers/clear-active-outbound', methods=['POST'])
@login_required
def api_clear_active_outbound():
    """Remove all active outbound proxies — traffic exits directly from panel server."""
    set_setting('active_outbound_server_ids', '[]')
    set_setting('active_outbound_server_id', '')
    _, msg = apply_config()
    return jsonify({'ok': True, 'xray': msg})


@app.route('/api/servers/<int:sid>/out-proxy-script')
@login_required
def api_out_proxy_script(sid):
    srv = Server.query.get_or_404(sid)
    script = _generate_out_proxy_script(srv)
    from flask import Response
    return Response(script, mimetype='text/plain; charset=utf-8',
        headers={'Content-Disposition': f'attachment; filename="bridge-out-proxy-{sid}.sh"'})


@app.route('/setup/out-proxy/<int:sid>/<token>')
def public_out_proxy_script(sid, token):
    """Public (no login) out-proxy script endpoint — authenticated via token."""
    from flask import Response, abort
    import hmac as _hmac
    srv = Server.query.filter_by(id=sid).first_or_404()
    s   = srv.get_settings()
    if not s.get('out_proxy_token') or not _hmac.compare_digest(str(s['out_proxy_token']), str(token)):
        abort(403)
    script = _generate_out_proxy_script(srv)
    return Response(script, mimetype='text/plain; charset=utf-8',
        headers={'Content-Disposition': f'inline; filename="bridge-out-proxy-{sid}.sh"'})


# ── API — Tunnels ─────────────────────────────────────────────────────────────

def _extract_tunnel_settings(d, method):
    """Extract method-specific tunnel settings from request dict."""
    s = {}
    if method == 'backhaul':
        s['backhaul_transport'] = d.get('backhaul_transport', 'tcp')
        s['backhaul_nodelay']   = bool(d.get('backhaul_nodelay', True))
        s['backhaul_keepalive'] = int(d.get('backhaul_keepalive') or 40)
        s['backhaul_mux_con']   = int(d.get('backhaul_mux_con')   or 8)
        s['backhaul_chan_size']  = int(d.get('backhaul_chan_size')  or 4096)
    elif method == 'backhaul_premium':
        s['bhp_transport']      = d.get('bhp_transport', 'tcp')
        s['bhp_nodelay']        = bool(d.get('bhp_nodelay', True))
        s['bhp_keepalive']      = int(d.get('bhp_keepalive') or 40)
        s['bhp_workers']        = int(d.get('bhp_workers') or 0)
        s['bhp_channel_size']   = int(d.get('bhp_channel_size') or 4096)
        s['bhp_tuning_profile'] = d.get('bhp_tuning_profile', 'balanced')
        s['bhp_auto_tuning']    = bool(d.get('bhp_auto_tuning', True))
        s['bhp_conn_pool']      = int(d.get('bhp_conn_pool') or 8)
        s['bhp_mux']            = bool(d.get('bhp_mux', False))
        s['bhp_mux_version']    = int(d.get('bhp_mux_version') or 2)
        s['bhp_mux_framesize']  = int(d.get('bhp_mux_framesize') or 32768)
        # IPX (raw-socket ICMP/BIP tunneling)
        s['bhp_ipx']            = bool(d.get('bhp_ipx', False))
        s['bhp_ipx_profile']    = d.get('bhp_ipx_profile', 'icmp')
        s['bhp_ipx_listen_ip']  = d.get('bhp_ipx_listen_ip', '0.0.0.0')
        s['bhp_ipx_interface']  = d.get('bhp_ipx_interface', 'eth0')
        s['bhp_ipx_icmp_type']  = int(d.get('bhp_ipx_icmp_type') or 0)
        s['bhp_ipx_icmp_code']  = int(d.get('bhp_ipx_icmp_code') or 0)
        # TLS
        s['bhp_tls_sni']        = d.get('bhp_tls_sni', '')
        s['bhp_tls_cert']       = d.get('bhp_tls_cert', '')
        s['bhp_tls_key']        = d.get('bhp_tls_key', '')
    elif method == 'frp':
        s['frp_protocol'] = d.get('frp_protocol', 'tcp')
    elif method == 'rathole':
        s['rathole_transport'] = d.get('rathole_transport', 'tcp')
    return s


@app.route('/api/tunnels', methods=['GET'])
@login_required
def api_tunnels():
    return jsonify({'tunnels': [t.to_dict() for t in Tunnel.query.order_by(Tunnel.created_at.desc()).all()]})


@app.route('/api/tunnels', methods=['POST'])
@login_required
def api_create_tunnel():
    d      = request.json or {}
    name   = d.get('name', '').strip()
    method = d.get('method', 'haproxy')
    if not name:
        return jsonify({'error': 'name is required'}), 400
    t = Tunnel(
        name          = name,
        in_server_id  = d.get('in_server_id') or None,
        out_server_id = d.get('out_server_id') or None,
        method        = method,
        in_port       = int(d.get('in_port', 0)),
        out_port      = int(d.get('out_port', 0)),
        secret        = d.get('secret') or str(uuid.uuid4())[:16],
        enabled       = bool(d.get('enabled', True)),
        notes         = d.get('notes', '') or None,
    )
    t.set_settings(_extract_tunnel_settings(d, method))
    db.session.add(t)
    db.session.commit()

    # Auto-create a VLESS/TCP inbound if requested.
    # The inbound listens on out_port (where the tunnel delivers traffic to TR/Xray),
    # NOT in_port (where users connect on the IN server).
    # server_addr is set to in_srv.ip so client links point to the IN server's IP.
    auto_ib = None
    if d.get('create_inbound') and t.out_port:
        if not Inbound.query.filter_by(port=t.out_port).first():
            in_srv = db.session.get(Server, t.in_server_id) if t.in_server_id else None
            ib_tag = f"tunnel-{t.name.lower().replace(' ', '-')[:20]}"
            ib = Inbound(tag=ib_tag, protocol='vless', transport='tcp', port=t.out_port)
            ib.set_settings({
                'server_addr': in_srv.ip if in_srv else '',
                'server_port': t.in_port,
                'listen': '0.0.0.0',
                'tls_type': 'none',
                'sniffing_enabled': False,
            })
            db.session.add(ib)
            db.session.commit()
            apply_config()
            auto_ib = ib.to_dict()

    result = t.to_dict()
    if auto_ib:
        result['auto_inbound'] = auto_ib
    return jsonify(result), 201


@app.route('/api/tunnels/<int:tid>', methods=['PUT'])
@login_required
def api_update_tunnel(tid):
    t = Tunnel.query.get_or_404(tid)
    d = request.json or {}
    if 'name'          in d: t.name          = d['name']
    if 'in_server_id'  in d: t.in_server_id  = d['in_server_id']  or None
    if 'out_server_id' in d: t.out_server_id = d['out_server_id'] or None
    if 'method'        in d: t.method        = d['method']
    if 'in_port'       in d: t.in_port       = int(d['in_port'])
    if 'out_port'      in d: t.out_port      = int(d['out_port'])
    if 'secret'        in d: t.secret        = d['secret'] or None
    if 'enabled'       in d: t.enabled       = bool(d['enabled'])
    if 'notes'         in d: t.notes         = d['notes'] or None
    t.set_settings(_extract_tunnel_settings(d, t.method))
    db.session.commit()
    return jsonify(t.to_dict())


@app.route('/api/tunnels/<int:tid>', methods=['DELETE'])
@login_required
def api_delete_tunnel(tid):
    t = Tunnel.query.get_or_404(tid)
    db.session.delete(t)
    db.session.commit()
    return jsonify({'ok': True})


@app.route('/api/tunnels/<int:tid>/script/<side>')
@login_required
def api_tunnel_script(tid, side):
    """Return the install/uninstall script for one side of a tunnel. Requires login."""
    if side not in ('in', 'out'):
        return jsonify({'error': 'side must be "in" or "out"'}), 400
    t = Tunnel.query.get_or_404(tid)
    action = request.args.get('action', 'install')
    if action not in ('install', 'uninstall', 'reinstall'):
        action = 'install'
    panel_url = request.url_root.rstrip('/')
    script = _generate_tunnel_script(t, side, action, panel_url)
    from flask import Response
    return Response(
        script,
        mimetype='text/plain; charset=utf-8',
        headers={
            'Content-Disposition': (
                f'attachment; filename="bridge-tunnel-{t.id}-{t.method}-{side}-{action}.sh"'
            ),
        }
    )


@app.route('/setup/binaries/<path:filename>')
def serve_binary(filename):
    """Public endpoint to serve cached tool binaries to remote servers."""
    from flask import send_from_directory, abort
    fpath = os.path.join(BINARIES_DIR, filename)
    if not os.path.isfile(fpath):
        abort(404)
    return send_from_directory(BINARIES_DIR, filename, as_attachment=False,
                               mimetype='application/octet-stream')


@app.route('/setup/backhaul-premium')
def serve_backhaul_premium():
    """Serve the backhaul_premium binary from the backhaul_p folder."""
    from flask import send_from_directory, abort
    fpath = os.path.join(BACKHAUL_P_DIR, 'backhaul_premium')
    if not os.path.isfile(fpath):
        abort(404)
    return send_from_directory(BACKHAUL_P_DIR, 'backhaul_premium',
                               as_attachment=False, mimetype='application/octet-stream')


@app.route('/api/binaries', methods=['GET'])
@login_required
def api_list_binaries():
    return jsonify({'binaries': _list_binaries()})


@app.route('/api/binaries/<path:filename>', methods=['DELETE'])
@login_required
def api_delete_binary(filename):
    fpath = os.path.join(BINARIES_DIR, filename)
    if not os.path.isfile(fpath):
        return jsonify({'error': 'File not found'}), 404
    os.remove(fpath)
    return jsonify({'ok': True})


@app.route('/api/binaries/fetch', methods=['POST'])
@login_required
def api_fetch_binary_route():
    """Download a tool binary from GitHub and cache it on the panel server."""
    d    = request.json or {}
    tool = d.get('tool', '')
    arch = d.get('arch', 'amd64')
    if not tool:
        return jsonify({'error': 'tool is required'}), 400
    ok, msg, saved = _fetch_binary_to_cache(tool, arch)
    return jsonify({'ok': ok, 'message': msg, 'saved': saved})


@app.route('/setup/tunnel/<int:tid>/<side>/<token>')
def public_tunnel_script(tid, side, token):
    """Public (no login) tunnel script endpoint — authenticated via tunnel secret.
    bash <(curl -fsSL http://PANEL/setup/tunnel/ID/in/SECRET?action=install|uninstall|reinstall)
    """
    from flask import Response, abort
    if side not in ('in', 'out'):
        abort(404)
    t = Tunnel.query.filter_by(id=tid).first_or_404()
    import hmac as _hmac
    if not t.secret or not _hmac.compare_digest(str(t.secret), str(token)):
        abort(403)
    action = request.args.get('action', 'install')
    if action not in ('install', 'uninstall', 'reinstall'):
        action = 'install'
    panel_url = request.url_root.rstrip('/')
    script = _generate_tunnel_script(t, side, action, panel_url)
    return Response(
        script,
        mimetype='text/plain; charset=utf-8',
        headers={
            'Content-Disposition': (
                f'inline; filename="bridge-tunnel-{t.id}-{t.method}-{side}-{action}.sh"'
            ),
        }
    )


def _generate_tunnel_script(tunnel, side, action='install', panel_url=''):
    """Generate a bash install/uninstall/reinstall script for one side of a tunnel."""
    from urllib.parse import urlparse as _urlparse
    method   = tunnel.method
    in_ip    = tunnel.in_server.ip  if tunnel.in_server  else 'IN_SERVER_IP'
    if tunnel.out_server:
        out_ip = tunnel.out_server.ip
    elif panel_url:
        try:
            out_ip = _urlparse(panel_url).hostname or 'PANEL_IP'
        except Exception:
            out_ip = 'PANEL_IP'
    else:
        out_ip = 'PANEL_IP'
    in_port  = tunnel.in_port
    out_port = tunnel.out_port
    secret   = tunnel.secret or str(uuid.uuid4())[:16]
    svcname  = f"bridge-{tunnel.id}-{method}"
    ts       = tunnel.get_settings()

    bh_transport   = ts.get('backhaul_transport', 'tcp')
    bh_nodelay     = 'true' if ts.get('backhaul_nodelay', True) else 'false'
    bh_keepalive   = int(ts.get('backhaul_keepalive', 40))
    bh_mux_con     = int(ts.get('backhaul_mux_con', 8))
    bh_chan_size    = int(ts.get('backhaul_chan_size', 4096))
    frp_proto      = ts.get('frp_protocol', 'tcp')
    rathole_trans  = ts.get('rathole_transport', 'tcp')

    action_label = {'install': 'Install', 'uninstall': 'Uninstall', 'reinstall': 'Reinstall'}.get(action, 'Install')

    header = f"""#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║   Bridge Panel — Tunnel Script                           ║
# ╠══════════════════════════════════════════════════════════╣
# ║  Tunnel : {tunnel.name:<46}║
# ║  Method : {method.upper():<46}║
# ║  Side   : {side.upper():<46}║
# ║  Action : {action_label:<46}║
# ║  In     : {str(in_ip)+':'+str(in_port):<46}║
# ║  Out    : {str(out_ip)+':'+str(out_port):<46}║
# ╚══════════════════════════════════════════════════════════╝
set -euo pipefail

"""

    # ── Uninstall helper (systemd-based services) ─────────────────────────────
    def _uninstall_systemd():
        return f"""\
echo "[*] Stopping and removing services for {svcname}..."
for svc in {svcname} {svcname}-server {svcname}-client {svcname}-frps {svcname}-frpc {svcname}-chisel {svcname}-rathole; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then systemctl stop "$svc" || true; fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then systemctl disable "$svc" || true; fi
    rm -f "/etc/systemd/system/$svc.service"
done
systemctl daemon-reload
rm -f "/usr/local/etc/xray/{svcname}.json"
for d in /etc/backhaul /etc/frp /etc/rathole; do
    rm -f "$d/{svcname}-"*.toml 2>/dev/null || true
done
echo "[OK] Services removed for {svcname}"
"""

    # ── Xray install helper (shared by xray method + out-server installs) ─────
    install_xray_snippet = """\
# Install Xray if not already present
if ! command -v xray &>/dev/null && ! [ -f /usr/local/bin/xray ]; then
    echo "[*] Installing Xray core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
"""

    # ── Backhaul install snippet ───────────────────────────────────────────────
    _bh_panel = f'{panel_url}/setup/binaries/backhaul-$SARCH' if panel_url else ''
    _bh_panel_check = f'curl -fsSL "{_bh_panel}" -o /usr/local/bin/backhaul 2>/dev/null' if _bh_panel else 'false'
    install_bh_snippet = f"""\
case "$(uname -m)" in x86_64) SARCH="amd64" ;; aarch64|arm64) SARCH="arm64" ;; *) SARCH="amd64" ;; esac
echo "[1/2] backhaul: checking panel cache ({_bh_panel if _bh_panel else 'no panel URL'})..."
if {_bh_panel_check}; then
    chmod +x /usr/local/bin/backhaul
    echo "[OK] ✅ backhaul loaded from panel cache"
else
    echo "[2/2] backhaul: not in panel cache — downloading from GitHub..."
    BH_VER=$(curl -sSL "https://api.github.com/repos/Musixal/Backhaul/releases/latest" \\
        | grep '"tag_name"' | head -1 | cut -d'"' -f4); BH_VER="${{BH_VER:-v0.9.1}}"
    mkdir -p /tmp/_bh_install
    curl -fsSL "https://github.com/Musixal/Backhaul/releases/download/${{BH_VER}}/backhaul_linux_${{SARCH}}.tar.gz" \\
        | tar -xz -C /tmp/_bh_install
    BH_BIN=$(find /tmp/_bh_install -maxdepth 3 -type f -name 'backhaul' | head -1)
    [ -z "$BH_BIN" ] && {{ echo "Binary not found in archive"; ls /tmp/_bh_install/; exit 1; }}
    cp "$BH_BIN" /usr/local/bin/backhaul && chmod +x /usr/local/bin/backhaul
    rm -rf /tmp/_bh_install
    echo "[OK] backhaul installed from GitHub ${{BH_VER}}."
fi
mkdir -p /etc/backhaul
"""

    # ── Build the body for each method ────────────────────────────────────────

    # ── HAProxy ────────────────────────────────────────────────────────────────
    if method == 'haproxy':
        def _install():
            if side == 'in':
                return f"""\
apt-get update -qq && apt-get install -y haproxy

if ! grep -q '# BEGIN {svcname}' /etc/haproxy/haproxy.cfg 2>/dev/null; then
cat >> /etc/haproxy/haproxy.cfg << 'HAPROXY_BLOCK'

# BEGIN {svcname}
frontend {svcname}_fe
    bind *:{in_port}
    mode tcp
    default_backend {svcname}_be

backend {svcname}_be
    mode tcp
    server main {out_ip}:{out_port} check
# END {svcname}
HAPROXY_BLOCK
fi
haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl restart haproxy
echo "[OK] HAProxy: *:{in_port} → {out_ip}:{out_port}"
"""
            else:
                return install_xray_snippet + f"""\
echo "[OK] OUT server ready — ensure Xray listens on port {out_port}."
"""
        def _uninstall():
            if side == 'in':
                return f"""\
if grep -q '# BEGIN {svcname}' /etc/haproxy/haproxy.cfg 2>/dev/null; then
    sed -i '/# BEGIN {svcname}/,/# END {svcname}/d' /etc/haproxy/haproxy.cfg
    haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl restart haproxy || true
    echo "[OK] Removed HAProxy block for {svcname}"
else
    echo "[INFO] No block found for {svcname} in haproxy.cfg"
fi
"""
            else:
                return 'echo "[INFO] Nothing to uninstall on OUT server for HAProxy tunnels."\n'

    # ── Xray dokodemo-door ─────────────────────────────────────────────────────
    elif method == 'xray':
        xray_cfg = json.dumps({
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "port": in_port, "protocol": "dokodemo-door",
                "settings": {"address": out_ip, "port": out_port,
                              "network": "tcp,udp", "followRedirect": False},
                "tag": svcname
            }],
            "outbounds": [{"protocol": "freedom", "tag": "direct"}]
        }, indent=2)
        def _install():
            if side == 'in':
                return install_xray_snippet + f"""\
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/{svcname}.json << 'XRAY_CFG'
{xray_cfg}
XRAY_CFG

cat > /etc/systemd/system/{svcname}.service << 'SVC'
[Unit]
Description=Bridge Xray Tunnel {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/{svcname}.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}
systemctl restart {svcname}
echo "[OK] Xray dokodemo: *:{in_port} → {out_ip}:{out_port}"
"""
            else:
                return install_xray_snippet + f"""\
echo "[OK] Xray installed/verified on OUT server. Ensure it listens on port {out_port}."
"""
        def _uninstall():
            return _uninstall_systemd()

    # ── GOST ──────────────────────────────────────────────────────────────────
    elif method == 'gost':
        _gost_panel = f'{panel_url}/setup/binaries/gost-$SARCH' if panel_url else ''
        _gost_check  = f'curl -fsSL "{_gost_panel}" -o /usr/local/bin/gost 2>/dev/null' if _gost_panel else 'false'
        def _install():
            if side == 'in':
                return f"""\
case "$(uname -m)" in x86_64) SARCH="amd64" ;; aarch64|arm64) SARCH="arm64" ;; *) SARCH="amd64" ;; esac
echo "[1/2] gost: checking panel cache..."
if {_gost_check}; then
    chmod +x /usr/local/bin/gost; echo "[OK] ✅ gost loaded from panel cache"
else
    echo "[2/2] gost: not in panel cache — downloading from GitHub..."
    GOST_VER=$(curl -sSL https://api.github.com/repos/go-gost/gost/releases/latest \\
        | grep '"tag_name"' | cut -d'"' -f4); GOST_VER="${{GOST_VER:-v3.0.0-rc.4}}"
    curl -fsSL "https://github.com/go-gost/gost/releases/download/${{GOST_VER}}/gost_${{GOST_VER#v}}_linux_${{SARCH}}.tar.gz" \\
        | tar -xz -C /usr/local/bin gost
    chmod +x /usr/local/bin/gost; echo "[OK] gost installed from GitHub ${{GOST_VER}}."
fi

cat > /etc/systemd/system/{svcname}.service << 'SVC'
[Unit]
Description=Bridge GOST Tunnel {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -L "tcp://:{in_port}/{out_ip}:{out_port}" -L "udp://:{in_port}/{out_ip}:{out_port}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}
systemctl restart {svcname}
echo "[OK] GOST: *:{in_port} → {out_ip}:{out_port}"
"""
            else:
                return install_xray_snippet + f'echo "[OK] OUT server ready on port {out_port}."\n'
        def _uninstall():
            return _uninstall_systemd()

    # ── Backhaul (reverse tunnel) ──────────────────────────────────────────────
    elif method == 'backhaul':
        ctrl_port = in_port + 10000   # control port lives on the IN server (AMS)
        # Build TLS extra lines for TOML if tls/wss transport
        tls_toml = ''
        if bh_transport in ('tls', 'wss'):
            bh_cert = ts.get('backhaul_tls_cert', '/etc/backhaul/server.crt')
            bh_key  = ts.get('backhaul_tls_key',  '/etc/backhaul/server.key')
            tls_toml = f'\ntls_cert         = "{bh_cert}"\ntls_key          = "{bh_key}"'

        # Correct roles:
        # IN server (AMS) = backhaul SERVER — users connect here, TR connects here
        # OUT server (TR) = backhaul CLIENT — connects outward to AMS, delivers to Xray
        def _install():
            if side == 'in':   # AMS — SERVER component
                return install_bh_snippet + f"""\
cat > /etc/backhaul/{svcname}-server.toml << 'TOML'
[server]
bind_addr        = "0.0.0.0:{ctrl_port}"
transport        = "{bh_transport}"
token            = "{secret}"
keepalive_period = {bh_keepalive}
nodelay          = {bh_nodelay}
chan_size         = {bh_chan_size}{tls_toml}

[[server.tunnels]]
name   = "{svcname}"
addr   = "0.0.0.0:{in_port}"
nodelay = {bh_nodelay}
TOML

cat > /etc/systemd/system/{svcname}-server.service << 'SVC'
[Unit]
Description=Bridge Backhaul Server {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/{svcname}-server.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-server
systemctl restart {svcname}-server
sleep 1
if systemctl is-active --quiet {svcname}-server; then
    echo "[OK] Backhaul SERVER on AMS — ctrl:{ctrl_port} user-port:{in_port} transport:{bh_transport}"
    echo "Now run the OUT script on TR."
else
    echo "[ERROR] Service failed. Check: journalctl -u {svcname}-server -n 30"
    journalctl -u {svcname}-server -n 20 --no-pager
fi
echo "Token: {secret}"
"""
            else:   # TR — CLIENT component, connects outward to AMS, delivers to Xray
                return install_bh_snippet + f"""\
cat > /etc/backhaul/{svcname}-client.toml << 'TOML'
[client]
remote_addr      = "{in_ip}:{ctrl_port}"
transport        = "{bh_transport}"
token            = "{secret}"
keepalive_period = {bh_keepalive}
nodelay          = {bh_nodelay}
connection       = {bh_mux_con}
chan_size         = {bh_chan_size}

[[client.tunnels]]
name   = "{svcname}"
addr   = "127.0.0.1:{out_port}"
nodelay = {bh_nodelay}
TOML

cat > /etc/systemd/system/{svcname}-client.service << 'SVC'
[Unit]
Description=Bridge Backhaul Client {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/{svcname}-client.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-client
systemctl restart {svcname}-client
sleep 1
if systemctl is-active --quiet {svcname}-client; then
    echo "[OK] Backhaul CLIENT on TR — connecting to {in_ip}:{ctrl_port} → Xray:{out_port}"
else
    echo "[ERROR] Service failed. Check: journalctl -u {svcname}-client -n 30"
    journalctl -u {svcname}-client -n 20 --no-pager
fi
echo "Token: {secret}"
"""
        def _uninstall():
            return _uninstall_systemd()

    # ── Backhaul Premium ───────────────────────────────────────────────────────
    elif method == 'backhaul_premium':
        ctrl_port      = in_port + 10000
        bhp_transport  = ts.get('bhp_transport', 'tcp')
        bhp_nodelay    = 'true' if ts.get('bhp_nodelay', True) else 'false'
        bhp_keepalive  = int(ts.get('bhp_keepalive', 40))
        bhp_workers    = int(ts.get('bhp_workers', 0))
        bhp_channel    = int(ts.get('bhp_channel_size', 4096))
        bhp_tuning     = ts.get('bhp_tuning_profile', 'balanced')
        bhp_auto       = 'true' if ts.get('bhp_auto_tuning', True) else 'false'
        bhp_pool       = int(ts.get('bhp_conn_pool', 8))
        bhp_ipx        = ts.get('bhp_ipx', False)
        bhp_ipx_prof   = ts.get('bhp_ipx_profile', 'icmp')
        bhp_ipx_lip    = ts.get('bhp_ipx_listen_ip', '0.0.0.0')
        bhp_ipx_iface  = ts.get('bhp_ipx_interface', 'eth0')
        bhp_ipx_ict    = int(ts.get('bhp_ipx_icmp_type', 0))
        bhp_ipx_icc    = int(ts.get('bhp_ipx_icmp_code', 0))
        bhp_mux        = ts.get('bhp_mux', False)
        bhp_mux_ver    = int(ts.get('bhp_mux_version', 2))
        bhp_mux_fsize  = int(ts.get('bhp_mux_framesize', 32768))
        bhp_tls_sni    = ts.get('bhp_tls_sni', '')
        bhp_tls_cert   = ts.get('bhp_tls_cert', '')
        bhp_tls_key    = ts.get('bhp_tls_key', '')

        # [transport] type is always the regular transport (tcp/tcpmux/wss/etc.)
        # [ipx] is an overlay section added alongside it, NOT a transport type
        eff_transport = bhp_transport

        def _bhp_ipx_section(mode):
            dst = in_ip if mode == 'client' else bhp_ipx_lip
            lines = [
                '[ipx]',
                f'mode    = "{mode}"',
                f'profile = "{bhp_ipx_prof}"',
                f'listen_ip = "{bhp_ipx_lip}"',
            ]
            if mode == 'client':
                lines.append(f'dst_ip    = "{in_ip}"')
            lines += [
                f'interface = "{bhp_ipx_iface}"',
            ]
            if bhp_ipx_prof == 'icmp':
                lines += [
                    f'icmp_type = {bhp_ipx_ict}',
                    f'icmp_code = {bhp_ipx_icc}',
                ]
            return '\n'.join(lines)

        def _bhp_tls_section():
            if not (bhp_tls_sni or bhp_tls_cert):
                return ''
            lines = ['[tls]']
            if bhp_tls_sni:  lines.append(f'sni      = "{bhp_tls_sni}"')
            if bhp_tls_cert: lines.append(f'tls_cert = "{bhp_tls_cert}"')
            if bhp_tls_key:  lines.append(f'tls_key  = "{bhp_tls_key}"')
            return '\n'.join(lines) + '\n'

        def _bhp_mux_section():
            if not bhp_mux:
                return ''
            return (f'[mux]\n'
                    f'mux_version       = {bhp_mux_ver}\n'
                    f'mux_framesize     = {bhp_mux_fsize}\n'
                    f'mux_recievebuffer = 4194304\n'
                    f'mux_streambuffer  = 2097152\n')

        _bhp_dl = f'{panel_url}/setup/backhaul-premium' if panel_url else ''
        install_bhp_snippet = f"""\
mkdir -p /root/backhaul-core
echo "[*] Downloading backhaul_premium binary..."
{"curl -fsSL " + _bhp_dl + " -o /root/backhaul-core/backhaul_premium && echo '[OK] Downloaded from panel'" if _bhp_dl else 'echo "[WARN] No panel URL — upload backhaul_premium manually to /root/backhaul-core/"'}
chmod +x /root/backhaul-core/backhaul_premium
"""
        svcname_bhp = f'backhaul-{in_port}-premium'

        def _bhp_uninstall():
            return f"""\
for svc in {svcname_bhp}-server {svcname_bhp}-client; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc.service"
done
systemctl daemon-reload
rm -f /root/backhaul-core/server-{in_port}.toml /root/backhaul-core/client-{in_port}.toml
echo "[OK] Backhaul Premium removed for port {in_port}"
"""

        def _install():
            if side == 'in':   # Iran/IN server → listener
                ipx_block  = (_bhp_ipx_section('server') + '\n\n') if bhp_ipx else ''
                tls_block  = _bhp_tls_section()
                mux_block  = _bhp_mux_section()
                return install_bhp_snippet + f"""\
cat > /root/backhaul-core/server-{in_port}.toml << 'TOML'
[listener]
bind_addr = ":{ctrl_port}"

[transport]
type             = "{eff_transport}"
nodelay          = {bhp_nodelay}
keepalive_period = {bhp_keepalive}
accept_udp       = false

{ipx_block}{mux_block}[security]
token = "{secret}"

{tls_block}[tuning]
auto_tuning    = {bhp_auto}
tuning_profile = "{bhp_tuning}"
workers        = {bhp_workers}
channel_size   = {bhp_channel}

[logging]
log_level = "info"

[ports]
mapping = [
    "{in_port}",
]
TOML

cat > /etc/systemd/system/{svcname_bhp}-server.service << 'SVC'
[Unit]
Description=Backhaul Premium Server port {in_port}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/backhaul-core/backhaul_premium -c /root/backhaul-core/server-{in_port}.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now {svcname_bhp}-server
sleep 1
systemctl is-active --quiet {svcname_bhp}-server \\
    && echo "[OK] Backhaul Premium SERVER running — ctrl:{ctrl_port} user-port:{in_port} transport:{eff_transport}" \\
    || (echo "[ERROR] Failed. Check:"; journalctl -u {svcname_bhp}-server -n 20 --no-pager)
echo "Token: {secret}"
"""
            else:   # TR/Panel → client, connects to IN server
                ipx_block = (_bhp_ipx_section('client') + '\n\n') if bhp_ipx else ''
                tls_block = _bhp_tls_section()
                mux_block = _bhp_mux_section()
                return install_bhp_snippet + f"""\
cat > /root/backhaul-core/client-{in_port}.toml << 'TOML'
[dialer]
remote_addr     = "{in_ip}:{ctrl_port}"
dial_timeout    = 10
retry_interval  = 3

[transport]
type             = "{eff_transport}"
nodelay          = {bhp_nodelay}
keepalive_period = {bhp_keepalive}
connection_pool  = {bhp_pool}

{ipx_block}{mux_block}[security]
token = "{secret}"

{tls_block}[tuning]
auto_tuning    = {bhp_auto}
tuning_profile = "{bhp_tuning}"
workers        = {bhp_workers}
channel_size   = {bhp_channel}

[logging]
log_level = "info"
TOML

cat > /etc/systemd/system/{svcname_bhp}-client.service << 'SVC'
[Unit]
Description=Backhaul Premium Client port {in_port}
After=network.target

[Service]
Type=simple
User=root
ExecStart=/root/backhaul-core/backhaul_premium -c /root/backhaul-core/client-{in_port}.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now {svcname_bhp}-client
sleep 1
systemctl is-active --quiet {svcname_bhp}-client \\
    && echo "[OK] Backhaul Premium CLIENT running — {in_ip}:{ctrl_port} → local:{out_port}" \\
    || (echo "[ERROR] Failed. Check:"; journalctl -u {svcname_bhp}-client -n 20 --no-pager)
echo "Token: {secret}"
"""

        def _uninstall():
            return _bhp_uninstall()

    # ── Socat ─────────────────────────────────────────────────────────────────
    elif method == 'socat':
        def _install():
            if side == 'in':
                return f"""\
apt-get update -qq && apt-get install -y socat

cat > /etc/systemd/system/{svcname}.service << 'SVC'
[Unit]
Description=Bridge Socat Tunnel {svcname}
After=network.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:{in_port},fork,reuseaddr TCP:{out_ip}:{out_port}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}
systemctl restart {svcname}
echo "[OK] Socat: *:{in_port} → {out_ip}:{out_port}"
"""
            else:
                return install_xray_snippet + f'echo "[OK] OUT server ready on port {out_port}."\n'
        def _uninstall():
            return _uninstall_systemd()

    # ── iptables DNAT ─────────────────────────────────────────────────────────
    elif method == 'iptables':
        def _install():
            if side == 'in':
                return f"""\
sysctl -w net.ipv4.ip_forward=1
grep -q 'ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Remove any existing rules for this tunnel
while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q '{svcname}'; do
    LINE=$(iptables -t nat -L PREROUTING -n --line-numbers | grep '{svcname}' | head -1 | awk '{{print $1}}')
    iptables -t nat -D PREROUTING $LINE
done

iptables -t nat -A PREROUTING -p tcp --dport {in_port} -j DNAT \\
    --to-destination {out_ip}:{out_port} -m comment --comment {svcname}
iptables -t nat -A PREROUTING -p udp --dport {in_port} -j DNAT \\
    --to-destination {out_ip}:{out_port} -m comment --comment {svcname}
iptables -t nat -A POSTROUTING -j MASQUERADE

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
elif command -v iptables-save &>/dev/null; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
fi
echo "[OK] iptables DNAT: *:{in_port} → {out_ip}:{out_port}"
"""
            else:
                return install_xray_snippet + f'echo "[OK] OUT server ready on port {out_port}."\n'
        def _uninstall():
            if side == 'in':
                return f"""\
while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q '{svcname}'; do
    LINE=$(iptables -t nat -L PREROUTING -n --line-numbers | grep '{svcname}' | head -1 | awk '{{print $1}}')
    iptables -t nat -D PREROUTING $LINE
done
if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save; fi
echo "[OK] Removed iptables rules for {svcname}"
"""
            else:
                return 'echo "[INFO] Nothing to uninstall on OUT server for iptables tunnels."\n'

    # ── Nginx stream ──────────────────────────────────────────────────────────
    elif method == 'nginx':
        def _install():
            if side == 'in':
                return f"""\
apt-get update -qq && apt-get install -y nginx
mkdir -p /etc/nginx/stream.d

cat > /etc/nginx/stream.d/{svcname}.conf << 'NGINX_BLOCK'
server {{
    listen {in_port};
    listen {in_port} udp;
    proxy_pass {out_ip}:{out_port};
    proxy_timeout 600s;
    proxy_connect_timeout 10s;
    proxy_buffer_size 16k;
}}
NGINX_BLOCK

if ! grep -q 'stream.d' /etc/nginx/nginx.conf; then
    echo 'stream {{ include /etc/nginx/stream.d/*.conf; }}' >> /etc/nginx/nginx.conf
fi
nginx -t && systemctl restart nginx
echo "[OK] Nginx stream: *:{in_port} → {out_ip}:{out_port}"
"""
            else:
                return install_xray_snippet + f'echo "[OK] OUT server ready on port {out_port}."\n'
        def _uninstall():
            if side == 'in':
                return f"""\
rm -f "/etc/nginx/stream.d/{svcname}.conf"
nginx -t && systemctl restart nginx || true
echo "[OK] Removed nginx config for {svcname}"
"""
            else:
                return 'echo "[INFO] Nothing to uninstall on OUT server for Nginx tunnels."\n'

    # ── FRP (Fast Reverse Proxy) ───────────────────────────────────────────────
    elif method == 'frp':
        ctrl_port = out_port + 10000
        _frps_panel = f'{panel_url}/setup/binaries/frps-$SARCH' if panel_url else ''
        _frpc_panel = f'{panel_url}/setup/binaries/frpc-$SARCH' if panel_url else ''
        _frp_check   = (f'curl -fsSL "{_frps_panel}" -o /usr/local/bin/frps 2>/dev/null && '
                        f'curl -fsSL "{_frpc_panel}" -o /usr/local/bin/frpc 2>/dev/null') if _frps_panel else 'false'
        install_frp = f"""\
case "$(uname -m)" in x86_64) SARCH="amd64" ;; aarch64|arm64) SARCH="arm64" ;; *) SARCH="amd64" ;; esac
echo "[1/2] frp: checking panel cache..."
if {_frp_check}; then
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc; echo "[OK] ✅ frp loaded from panel cache"
else
    echo "[2/2] frp: not in panel cache — downloading from GitHub..."
    FRP_VER=$(curl -sSL https://api.github.com/repos/fatedier/frp/releases/latest \\
        | grep '"tag_name"' | cut -d'"' -f4); FRP_VER="${{FRP_VER:-v0.61.1}}"
    curl -fsSL "https://github.com/fatedier/frp/releases/download/${{FRP_VER}}/frp_${{FRP_VER#v}}_linux_${{SARCH}}.tar.gz" \\
        | tar -xz --wildcards '*/frp[sc]' --strip-components=1 -C /usr/local/bin
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc 2>/dev/null || true
    echo "[OK] frp installed from GitHub ${{FRP_VER}}."
fi
mkdir -p /etc/frp
"""
        def _install():
            if side == 'out':
                return install_frp + f"""\
cat > /etc/frp/{svcname}-server.toml << 'TOML'
bindPort   = {ctrl_port}
transport.protocol = "{frp_proto}"
auth.token = "{secret}"
TOML

cat > /etc/systemd/system/{svcname}-frps.service << 'SVC'
[Unit]
Description=Bridge FRP Server {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/frps -c /etc/frp/{svcname}-server.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-frps
systemctl restart {svcname}-frps
echo "[OK] FRP server: ctrl:{ctrl_port} proto:{frp_proto} (token: {secret})"
"""
            else:
                return install_frp + f"""\
cat > /etc/frp/{svcname}-client.toml << 'TOML'
serverAddr         = "{out_ip}"
serverPort         = {ctrl_port}
transport.protocol = "{frp_proto}"
auth.token         = "{secret}"

[[proxies]]
name       = "{svcname}"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = {in_port}
remotePort = {in_port}
TOML

cat > /etc/systemd/system/{svcname}-frpc.service << 'SVC'
[Unit]
Description=Bridge FRP Client {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/frpc -c /etc/frp/{svcname}-client.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-frpc
systemctl restart {svcname}-frpc
echo "[OK] FRP client: :{in_port} → {out_ip}:{ctrl_port} (proto:{frp_proto})"
"""
        def _uninstall():
            return _uninstall_systemd()

    # ── Rathole ───────────────────────────────────────────────────────────────
    elif method == 'rathole':
        ctrl_port = in_port + 10001   # control port lives on the IN server (AMS)
        _rh_panel = f'{panel_url}/setup/binaries/rathole-$SARCH' if panel_url else ''
        _rh_check  = f'curl -fsSL "{_rh_panel}" -o /usr/local/bin/rathole 2>/dev/null' if _rh_panel else 'false'
        install_rh = f"""\
case "$(uname -m)" in x86_64) SARCH="amd64" ;; aarch64|arm64) SARCH="arm64" ;; *) SARCH="amd64" ;; esac
# x86_64 uses -gnu, aarch64 uses -musl (rathole-org/rathole v0.5.0 release)
case "$SARCH" in amd64) RARCH="x86_64-unknown-linux-gnu" ;; *) RARCH="aarch64-unknown-linux-musl" ;; esac
echo "[1/2] rathole: checking panel cache ({_rh_panel if _rh_panel else 'no panel URL'})..."
if {_rh_check}; then
    chmod +x /usr/local/bin/rathole; echo "[OK] ✅ rathole loaded from panel cache"
else
    echo "[2/2] rathole: not in panel cache — downloading from GitHub..."
    which unzip &>/dev/null || apt-get install -y unzip -qq
    RH_VER=$(curl -sSL https://api.github.com/repos/rathole-org/rathole/releases/latest \\
        | grep '"tag_name"' | cut -d'"' -f4); RH_VER="${{RH_VER:-v0.5.0}}"
    curl -fsSL "https://github.com/rathole-org/rathole/releases/download/${{RH_VER}}/rathole-${{RARCH}}.zip" \\
        -o /tmp/rathole.zip
    unzip -o /tmp/rathole.zip rathole -d /usr/local/bin/
    chmod +x /usr/local/bin/rathole
    rm /tmp/rathole.zip
    echo "[OK] rathole installed from GitHub ${{RH_VER}}."
fi
mkdir -p /etc/rathole
"""
        # Correct roles for the panel's architecture:
        # IN server (AMS) = rathole SERVER — users connect here, TR connects here
        # OUT server (TR) = rathole CLIENT — connects outward to AMS, delivers to Xray
        # This avoids binding out_port on TR (which would conflict with Xray).
        def _install():
            if side == 'in':   # AMS — runs the SERVER component
                return install_rh + f"""\
cat > /etc/rathole/{svcname}-server.toml << 'TOML'
[server]
bind_addr = "0.0.0.0:{ctrl_port}"

[server.transport]
type = "{rathole_trans}"

[server.services."{svcname}"]
token     = "{secret}"
bind_addr = "0.0.0.0:{in_port}"
TOML

cat > /etc/systemd/system/{svcname}-rathole.service << 'SVC'
[Unit]
Description=Bridge Rathole Server {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/rathole /etc/rathole/{svcname}-server.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-rathole
systemctl restart {svcname}-rathole
echo "[OK] Rathole SERVER on AMS: ctrl:{ctrl_port} user-port:{in_port} transport:{rathole_trans}"
echo "Now run the OUT script on TR to connect this tunnel."
"""
            else:   # TR — runs the CLIENT component, connects outward to AMS
                return install_rh + f"""\
cat > /etc/rathole/{svcname}-client.toml << 'TOML'
[client]
remote_addr = "{in_ip}:{ctrl_port}"

[client.transport]
type = "{rathole_trans}"

[client.services."{svcname}"]
token      = "{secret}"
local_addr = "127.0.0.1:{out_port}"
TOML

cat > /etc/systemd/system/{svcname}-rathole.service << 'SVC'
[Unit]
Description=Bridge Rathole Client {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/rathole /etc/rathole/{svcname}-client.toml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-rathole
systemctl restart {svcname}-rathole
echo "[OK] Rathole client: :{in_port} → {out_ip}:{ctrl_port} (transport:{rathole_trans})"
"""
        def _uninstall():
            return _uninstall_systemd()

    # ── Chisel ────────────────────────────────────────────────────────────────
    elif method == 'chisel':
        ctrl_port = out_port + 10002
        _ch_panel = f'{panel_url}/setup/binaries/chisel-$SARCH' if panel_url else ''
        _ch_check  = f'curl -fsSL "{_ch_panel}" -o /usr/local/bin/chisel 2>/dev/null' if _ch_panel else 'false'
        install_ch = f"""\
case "$(uname -m)" in x86_64) SARCH="amd64" ;; aarch64|arm64) SARCH="arm64" ;; *) SARCH="amd64" ;; esac
echo "[1/2] chisel: checking panel cache..."
if {_ch_check}; then
    chmod +x /usr/local/bin/chisel; echo "[OK] ✅ chisel loaded from panel cache"
else
    echo "[2/2] chisel: not in panel cache — downloading from GitHub..."
    CH_VER=$(curl -sSL https://api.github.com/repos/jpillora/chisel/releases/latest \\
        | grep '"tag_name"' | cut -d'"' -f4); CH_VER="${{CH_VER:-v1.9.1}}"
    curl -fsSL "https://github.com/jpillora/chisel/releases/download/${{CH_VER}}/chisel_${{CH_VER#v}}_linux_${{SARCH}}.gz" \\
        | gunzip > /usr/local/bin/chisel
    chmod +x /usr/local/bin/chisel; echo "[OK] chisel installed from GitHub ${{CH_VER}}."
fi
"""
        def _install():
            if side == 'out':
                return install_ch + f"""\
cat > /etc/systemd/system/{svcname}-chisel.service << 'SVC'
[Unit]
Description=Bridge Chisel Server {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/chisel server --port {ctrl_port} --auth "{secret}"
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-chisel
systemctl restart {svcname}-chisel
echo "[OK] Chisel server on port {ctrl_port} (auth: {secret})"
"""
            else:
                return install_ch + f"""\
cat > /etc/systemd/system/{svcname}-chisel.service << 'SVC'
[Unit]
Description=Bridge Chisel Client {svcname}
After=network.target

[Service]
ExecStart=/usr/local/bin/chisel client --auth "{secret}" {out_ip}:{ctrl_port} {in_port}:{out_ip}:{out_port}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable {svcname}-chisel
systemctl restart {svcname}-chisel
echo "[OK] Chisel client: :{in_port} → {out_ip}:{out_port}"
"""
        def _uninstall():
            return _uninstall_systemd()

    # ── Fallback ───────────────────────────────────────────────────────────────
    else:
        def _install():
            return f'echo "Script generation not yet supported for method: {method}"\n'
        def _uninstall():
            return f'echo "Nothing to uninstall for method: {method}"\n'

    # ── Dispatch by action ─────────────────────────────────────────────────────
    if action == 'uninstall':
        return header + _uninstall()
    elif action == 'reinstall':
        return (header
                + 'echo "=== Removing previous installation ==="\n'
                + _uninstall()
                + '\necho "=== Installing ==="\n'
                + _install())
    else:
        return header + _install()


# ── API — Xray ────────────────────────────────────────────────────────────────

@app.route('/api/xray/status')
@login_required
def api_xray_status():
    s, pid = xray_status()
    binary = get_setting('xray_binary', DEFAULT_BIN)
    return jsonify({'status': s, 'pid': pid, 'binary': binary,
                    'binary_exists': os.path.isfile(binary)})


@app.route('/api/xray/start', methods=['POST'])
@login_required
def api_xray_start():
    ok, msg = xray_start()
    s, pid = xray_status()
    return jsonify({'ok': ok, 'message': msg, 'status': s})


@app.route('/api/xray/stop', methods=['POST'])
@login_required
def api_xray_stop():
    ok, msg = xray_stop()
    return jsonify({'ok': ok, 'message': msg, 'status': 'stopped'})


@app.route('/api/xray/restart', methods=['POST'])
@login_required
def api_xray_restart():
    xray_stop()
    ok, msg = xray_start()
    s, pid = xray_status()
    return jsonify({'ok': ok, 'message': msg, 'status': s})


@app.route('/api/xray/logs')
@login_required
def api_xray_logs():
    n = min(int(request.args.get('n', 200)), 500)
    return jsonify({'logs': list(xray_log_buf)[-n:]})


@app.route('/api/xray/stats-debug')
@login_required
def api_stats_debug():
    """Run a live statsquery and return raw + parsed result for debugging."""
    binary = get_setting('xray_binary', DEFAULT_BIN)
    binary_ok = os.path.isfile(binary)
    raw_out = raw_err = ''
    rc = None
    parsed = None

    if binary_ok:
        try:
            res = subprocess.run(
                [binary, 'api', 'statsquery',
                 f'--server=127.0.0.1:{_XRAY_API_PORT}', '--pattern', ''],
                capture_output=True, text=True, timeout=5
            )
            rc      = res.returncode
            raw_out = res.stdout.strip()
            raw_err = res.stderr.strip()
            if rc == 0 and raw_out:
                parsed = json.loads(raw_out)
        except Exception as e:
            raw_err = str(e)

    xray_st, _ = xray_status()
    snap_users    = len(_stats_snapshot.get('__users__',    {}))
    snap_inbounds = len(_stats_snapshot.get('__inbounds__', {}))
    return jsonify({
        'xray_running':     xray_st == 'running',
        'binary':           binary,
        'binary_exists':    binary_ok,
        'api_port':         _XRAY_API_PORT,
        'returncode':       rc,
        'raw_stdout':       raw_out[:2000] if raw_out else '',
        'raw_stderr':       raw_err[:500]  if raw_err else '',
        'parsed_stats':     parsed,
        'snapshot_users':   snap_users,
        'snapshot_inbounds':snap_inbounds,
        'bw_history_pts':   len(_bw_history),
    })


@app.route('/api/xray/stats-poll', methods=['POST'])
@login_required
def api_stats_poll():
    """Manually trigger a stats poll right now (for testing)."""
    try:
        _update_stats()
        return jsonify({'ok': True, 'snapshot_keys': len(_stats_snapshot),
                        'bw_points': len(_bw_history)})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/xray/outbound-status')
@login_required
def api_outbound_status():
    """Show all active outbound proxy configurations and test connectivity."""
    import socket
    try:
        active_ids = json.loads(get_setting('active_outbound_server_ids', '[]'))
    except Exception:
        active_ids = []
    if not active_ids:
        single = get_setting('active_outbound_server_id', '').strip()
        if single:
            active_ids = [single]

    if not active_ids:
        return jsonify({'active': False, 'message': 'No active outbound proxy set', 'outbounds': []})

    cfg = build_config()
    results = []
    for srv_id in active_ids:
        try:
            out_srv = db.session.get(Server, int(srv_id))
            if not out_srv:
                continue
            s     = out_srv.get_settings()
            port  = int(s.get('out_proxy_port', 10001))
            uid   = s.get('out_proxy_uuid', '')
            proto = s.get('out_proxy_protocol', 'vless')
            reachable = False
            try:
                sock = socket.create_connection((out_srv.ip, port), timeout=3)
                sock.close()
                reachable = True
            except Exception:
                pass
            results.append({
                'server':    out_srv.to_dict(),
                'port':      port,
                'uuid':      uid,
                'protocol':  proto,
                'reachable': reachable,
                'message':   ('✅ Reachable' if reachable else f'❌ Port {port} unreachable'),
            })
        except Exception:
            pass

    # check routing in config
    has_route = any(
        r.get('outboundTag', '').startswith('out-proxy') or r.get('balancerTag') == 'out-balancer'
        for r in cfg.get('routing', {}).get('rules', [])
    )

    return jsonify({
        'active':    bool(results),
        'outbounds': results,
        'in_config': has_route,
        'count':     len(results),
        # legacy compat fields (first outbound)
        'server':    results[0]['server']   if results else None,
        'port':      results[0]['port']     if results else None,
        'uuid':      results[0]['uuid']     if results else None,
        'protocol':  results[0]['protocol'] if results else None,
        'reachable': all(r['reachable'] for r in results) if results else False,
        'message':   (f'✅ {len(results)} outbound(s) active' if results else 'No outbounds'),
    })


@app.route('/api/config/download')
@login_required
def api_config_download():
    cfg = build_config()
    buf = io.BytesIO(json.dumps(cfg, indent=2).encode())
    return send_file(buf, mimetype='application/json',
                     as_attachment=True, download_name='xray-config.json')


# ── API — Utilities ───────────────────────────────────────────────────────────

def _gen_x25519_keys():
    import base64
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, PrivateFormat, NoEncryption
    priv_obj = X25519PrivateKey.generate()
    pub_obj  = priv_obj.public_key()
    priv_raw = priv_obj.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    pub_raw  = pub_obj.public_bytes(Encoding.Raw, PublicFormat.Raw)
    return (base64.urlsafe_b64encode(priv_raw).rstrip(b'=').decode(),
            base64.urlsafe_b64encode(pub_raw).rstrip(b'=').decode())


@app.route('/api/generate-keys', methods=['GET', 'POST'])
@login_required
def api_generate_keys():
    try:
        priv, pub = _gen_x25519_keys()
        return jsonify({'private_key': priv, 'public_key': pub})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/uuid')
@login_required
def api_uuid():
    return jsonify({'uuid': str(uuid.uuid4())})


# ── API — Settings ────────────────────────────────────────────────────────────

@app.route('/api/settings', methods=['GET'])
@login_required
def api_get_settings():
    panel_port = int(os.environ.get('PORT', 5000))
    try:
        active_out_ids = json.loads(get_setting('active_outbound_server_ids', '[]'))
    except Exception:
        active_out_ids = []
    return jsonify({'settings': {
        'server_ip':        get_setting('server_ip', ''),
        'xray_binary':      get_setting('xray_binary', DEFAULT_BIN),
        'panel_name':       get_setting('workspace_name', 'Bridge Panel'),
        'workspace_name':   get_setting('workspace_name', 'Bridge Panel'),
        'default_proto':    get_setting('default_protocol', 'VLESS'),
        'default_protocol': get_setting('default_protocol', 'VLESS'),
        'default_quota':    get_setting('default_quota', '100'),
        'default_expiry':   get_setting('default_expiry', '30'),
        'tls_cert_file':    get_setting('tls_cert_file', ''),
        'tls_key_file':     get_setting('tls_key_file', ''),
        'sub_info_entry':   get_setting('sub_info_entry', 'true'),
        'sub_domain':       get_setting('sub_domain', ''),
        'sub_path':         get_setting('sub_path', 'sub'),
        'sub_port':         get_setting('sub_port', str(panel_port)),
        'sub_scheme':       get_setting('sub_scheme', 'http'),
        'sub_extra_urls':              json.loads(get_setting('sub_extra_urls', '[]')),
        'active_outbound_server_id':   get_setting('active_outbound_server_id', ''),
        'active_outbound_server_ids':  active_out_ids,
        'telegram_bot_token':          get_setting('telegram_bot_token', ''),
        'telegram_chat_id':            get_setting('telegram_chat_id', ''),
        'backup_interval_hours':       get_setting('backup_interval_hours', '6'),
        'backup_last_sent':            get_setting('backup_last_sent', ''),
        'tc_iface':                    get_setting('tc_iface', ''),
        'client_android_version':      get_setting('client_android_version', ''),
        'client_android_url':          get_setting('client_android_url', ''),
        'client_windows_version':      get_setting('client_windows_version', ''),
        'client_windows_url':          get_setting('client_windows_url', ''),
        'client_linux_version':        get_setting('client_linux_version', ''),
        'client_linux_url':            get_setting('client_linux_url', ''),
        'client_macos_version':        get_setting('client_macos_version', ''),
        'client_macos_url':            get_setting('client_macos_url', ''),
        'client_release_notes':        get_setting('client_release_notes', ''),
        'client_update_mandatory':     get_setting('client_update_mandatory', 'false'),
        'ip_limit_enforce':            get_setting('ip_limit_enforce', 'true'),
        'admin_username':              current_user.username,
    }})


@app.route('/api/settings', methods=['POST'])
@login_required
def api_save_settings():
    d = request.json or {}
    if 'panel_name'     in d: set_setting('workspace_name',  d['panel_name'])
    elif 'workspace_name' in d: set_setting('workspace_name',  d['workspace_name'])
    if 'default_proto'  in d: set_setting('default_protocol', d['default_proto'])
    for key in ('server_ip', 'xray_binary', 'default_protocol', 'default_quota', 'default_expiry',
                'tls_cert_file', 'tls_key_file', 'sub_info_entry',
                'sub_domain', 'sub_path', 'sub_port', 'sub_scheme',
                'telegram_bot_token', 'telegram_chat_id', 'backup_interval_hours', 'tc_iface',
                # Client app releases, served by /api/client/update
                'client_android_version', 'client_android_url',
                'client_windows_version', 'client_windows_url',
                'client_linux_version',   'client_linux_url',
                'client_macos_version',   'client_macos_url',
                'client_release_notes',   'client_update_mandatory',
                # Applies each account's ip_limit to the tunnel itself, not just
                # to sign-ins. Turning it off leaves the limit advisory.
                'ip_limit_enforce'):
        if key in d: set_setting(key, d[key])
    if 'tc_iface' in d:
        global _tc_iface_cache
        _tc_iface_cache = None  # force re-detection next cycle
    if 'sub_extra_urls' in d:
        set_setting('sub_extra_urls', json.dumps(d['sub_extra_urls']))
    return jsonify({'ok': True, 'binary_exists': os.path.isfile(get_setting('xray_binary', DEFAULT_BIN))})


# ── API — VPS Console ─────────────────────────────────────────────────────────

@app.route('/api/console', methods=['POST'])
@login_required
def api_console():
    """Execute a shell command on the VPS and return output. Admin-only."""
    d   = request.json or {}
    cmd = d.get('command', '').strip()
    if not cmd:
        return jsonify({'error': 'Command is required'}), 400
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            cwd=os.path.dirname(os.path.abspath(__file__))
        )
        return jsonify({
            'stdout':     result.stdout,
            'stderr':     result.stderr,
            'returncode': result.returncode,
            'ok':         result.returncode == 0,
        })
    except Exception as e:
        return jsonify({'error': str(e), 'stdout': '', 'stderr': '', 'returncode': -1, 'ok': False})


@app.route('/api/sub-server-script')
@login_required
def api_sub_server_script():
    """Generate a nginx reverse-proxy script that relays /sub/ requests to this panel."""
    server_ip  = get_setting('server_ip', '0.0.0.0')
    panel_port = int(os.environ.get('PORT', 5000))
    sub_path   = get_setting('sub_path', 'sub').strip() or 'sub'
    listen_port = int(request.args.get('port', 80))
    nginx_conf = (
        f"server {{\n"
        f"    listen {listen_port};\n"
        f"    server_name _;\n\n"
        f"    location /{sub_path}/ {{\n"
        f"        proxy_pass http://{server_ip}:{panel_port}/{sub_path}/;\n"
        f"        proxy_set_header Host $host;\n"
        f"        proxy_set_header X-Real-IP $remote_addr;\n"
        f"        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        f"        proxy_read_timeout 300s;\n"
        f"    }}\n\n"
        f"    location / {{ return 404; }}\n"
        f"}}"
    )
    script = f"""#!/bin/bash
# Bridge Panel — Subscription Relay Server Install Script
# Installs nginx to proxy /{sub_path}/<token> requests to the panel.
set -euo pipefail

apt-get update -qq && apt-get install -y nginx

mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/bridge-sub.conf << 'NGINX_CONF'
{nginx_conf}
NGINX_CONF

# Remove default site if present
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t && systemctl restart nginx
MY_IP=$(curl -4 -fsSL ifconfig.me 2>/dev/null || hostname -I | awk '{{print $1}}')
echo "[OK] Subscription relay installed on port {listen_port}"
echo "Sub URL: http://$MY_IP:{listen_port}/{sub_path}/TOKEN"
"""
    from flask import Response
    return Response(script, mimetype='text/plain; charset=utf-8',
                   headers={'Content-Disposition': 'attachment; filename="bridge-sub-server.sh"'})


@app.route('/api/xray/core-version')
@login_required
def api_xray_core_version():
    """Return the current Xray binary version string."""
    binary = get_setting('xray_binary', DEFAULT_BIN)
    version = ''
    if os.path.isfile(binary):
        try:
            r = subprocess.run([binary, 'version'], capture_output=True, text=True, timeout=5)
            first = (r.stdout or r.stderr or '').splitlines()[0] if (r.stdout or r.stderr) else ''
            version = first.strip()
        except Exception as e:
            version = f'error: {e}'
    return jsonify({'version': version, 'binary': binary, 'exists': os.path.isfile(binary)})


@app.route('/api/xray/install', methods=['POST'])
@login_required
def api_xray_install():
    """Download and install a specific (or latest) Xray-core release.
    Body: {"version": "latest" | "v1.8.21", "install_path": "/usr/local/bin/xray"}
    Architecture is auto-detected from the running system.
    """
    import tarfile, zipfile, tempfile, shutil, platform as _plat
    d        = request.json or {}
    req_ver  = (d.get('version') or 'latest').strip().lstrip('v')
    req_ver  = 'latest' if req_ver == '' else req_ver

    # ── Detect architecture ──────────────────────────────────────────────────
    machine = _plat.machine().lower()
    if machine in ('x86_64', 'amd64'):
        arch_name = '64'            # Xray uses "Xray-linux-64.zip"
    elif machine in ('aarch64', 'arm64'):
        arch_name = 'arm64-v8a'
    elif machine.startswith('arm'):
        arch_name = 'arm32-v7a'
    else:
        arch_name = '64'            # best-effort fallback

    # ── Resolve version from GitHub ─────────────────────────────────────────
    import urllib.request
    api_url = 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
    tag     = ''
    assets  = []
    try:
        req = urllib.request.Request(api_url,
              headers={'User-Agent': 'bridge-panel/1.0',
                       'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data   = json.loads(resp.read())
            tag    = data.get('tag_name', '')
            assets = data.get('assets', [])
    except Exception as e:
        if req_ver == 'latest':
            return jsonify({'ok': False, 'error': f'Could not fetch GitHub releases: {e}'}), 500

    if req_ver == 'latest':
        ver = tag.lstrip('v') if tag else ''
        if not ver:
            return jsonify({'ok': False, 'error': 'Could not determine latest version'}), 500
    else:
        ver = req_ver

    ver_tag = f'v{ver}'

    # ── Build download URL ───────────────────────────────────────────────────
    zip_name    = f'Xray-linux-{arch_name}.zip'
    download_url = f'https://github.com/XTLS/Xray-core/releases/download/{ver_tag}/{zip_name}'

    # ── Determine install path ───────────────────────────────────────────────
    install_path = (d.get('install_path') or '').strip()
    if not install_path:
        install_path = get_setting('xray_binary', DEFAULT_BIN)
    if not install_path:
        install_path = '/usr/local/bin/xray'

    # ── Download ─────────────────────────────────────────────────────────────
    with tempfile.TemporaryDirectory() as tmpdir:
        archive = os.path.join(tmpdir, zip_name)
        ok, err = _curl_download(download_url, archive, timeout=120)
        if not ok or not os.path.isfile(archive) or os.path.getsize(archive) < 1024:
            return jsonify({'ok': False,
                            'error': f'Download failed ({download_url}): {err}'}), 500

        # ── Extract xray binary ──────────────────────────────────────────────
        try:
            with zipfile.ZipFile(archive) as zf:
                members = zf.namelist()
                target  = next((m for m in members
                                if os.path.basename(m) == 'xray' and not m.endswith('/')), None)
                if not target:
                    return jsonify({'ok': False,
                                    'error': f'xray binary not found in zip. Contents: {members[:10]}'}), 500
                extracted = os.path.join(tmpdir, 'xray')
                with zf.open(target) as src, open(extracted, 'wb') as dst:
                    import shutil as _sh
                    _sh.copyfileobj(src, dst)
        except Exception as e:
            return jsonify({'ok': False, 'error': f'Extraction error: {e}'}), 500

        # ── Install ──────────────────────────────────────────────────────────
        # Stop Xray BEFORE touching the binary — Linux raises ETXTBSY (errno 26)
        # if you try to overwrite an executing file.
        was_running = xray_status()[0] == 'running'
        if was_running:
            xray_stop()

        try:
            os.makedirs(os.path.dirname(os.path.abspath(install_path)), exist_ok=True)
            # Unlink the existing binary first so we're not overwriting a mapped file
            if os.path.isfile(install_path):
                os.remove(install_path)
            import shutil as _sh
            _sh.move(extracted, install_path)
            os.chmod(install_path, 0o755)
        except Exception as e:
            # Try to restart even if install failed (old binary still gone — bad state)
            if was_running:
                xray_start()
            return jsonify({'ok': False, 'error': f'Install error: {e}'}), 500

    # ── Update stored binary path & restart ─────────────────────────────────
    set_setting('xray_binary', install_path)

    if was_running:
        ok_start, msg_start = xray_start()
    else:
        ok_start, msg_start = True, 'not restarted (was stopped)'

    # Get installed version
    inst_version = ''
    try:
        r2 = subprocess.run([install_path, 'version'], capture_output=True, text=True, timeout=5)
        inst_version = (r2.stdout or r2.stderr or '').splitlines()[0].strip()
    except Exception:
        pass

    return jsonify({
        'ok':            True,
        'version':       inst_version or ver_tag,
        'install_path':  install_path,
        'restarted':     was_running,
        'xray_message':  msg_start,
    })


@app.route('/api/xray/releases')
@login_required
def api_xray_releases():
    """Return the last 10 Xray-core GitHub release tags."""
    import urllib.request
    try:
        req = urllib.request.Request(
            'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10',
            headers={'User-Agent': 'bridge-panel/1.0',
                     'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        releases = [{'tag': r['tag_name'], 'name': r.get('name', r['tag_name']),
                     'prerelease': r.get('prerelease', False)} for r in data]
        return jsonify({'ok': True, 'releases': releases})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e), 'releases': []})


@app.route('/api/systemd-service')
@login_required
def api_systemd_service():
    """Return a systemd service file for the panel."""
    panel_dir  = _PANEL_DIR
    panel_port = int(os.environ.get('PORT', 5000))
    python_bin = '/usr/bin/python3'
    content = f"""[Unit]
Description=Xray Bridge Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory={panel_dir}
ExecStart={python_bin} {os.path.join(panel_dir, 'app.py')}
Restart=always
RestartSec=5
Environment=PORT={panel_port}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""
    from flask import Response
    return Response(content, mimetype='text/plain; charset=utf-8',
                    headers={'Content-Disposition': 'attachment; filename="xray-panel.service"'})


# ── Telegram backup ───────────────────────────────────────────────────────────

def _create_backup_zip(full=False):
    """Create a backup zip. Returns path to temp file.

    full=False  → data-only backup (Telegram-safe, < a few MB in almost all cases):
                  panel.db, .secret_key, generated-config.json, requirements.txt
                  This is enough to fully restore all users / settings / tunnels.

    full=True   → everything including source files, templates, static assets.
                  Use for local download; can exceed Telegram's 50 MB limit.
    """
    import zipfile, tempfile

    ts  = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
    sfx = '-full' if full else '-data'
    tmp = tempfile.NamedTemporaryFile(
        suffix='.zip', prefix=f'panel-backup-{ts}{sfx}-', delete=False)
    tmp.close()

    with zipfile.ZipFile(tmp.name, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        if full:
            # ── Full backup: walk the whole panel directory ────────────────
            SKIP_DIRS = {'binaries', '__pycache__', '.git'}
            SKIP_EXTS = {'.pyc', '.pyo'}
            for root, dirs, files in os.walk(_PANEL_DIR):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for fname in files:
                    if os.path.splitext(fname)[1] in SKIP_EXTS:
                        continue
                    fpath = os.path.join(root, fname)
                    try:
                        zf.write(fpath, os.path.relpath(fpath, _PANEL_DIR))
                    except Exception:
                        pass
        else:
            # ── Data-only backup: just the irreplaceable files ────────────
            import sqlite3 as _sqlite3, tempfile as _tf

            # ── panel.db: use SQLite's backup API for a consistent snapshot ──
            # Raw file-copy while the app is running produces a 0-byte or
            # corrupt file because SQLAlchemy holds the connection open.
            db_orig = os.path.join(_PANEL_DIR, 'panel.db')
            db_tmp  = None
            if os.path.isfile(db_orig):
                try:
                    fd, db_tmp = _tf.mkstemp(suffix='.db', prefix='panel-db-bak-')
                    os.close(fd)
                    src = _sqlite3.connect(db_orig)
                    dst = _sqlite3.connect(db_tmp)
                    src.backup(dst)
                    src.close()
                    dst.close()
                    zf.write(db_tmp, 'panel.db')
                except Exception as _e:
                    app.logger.warning(f'DB backup via sqlite3.backup failed ({_e}), falling back to raw copy')
                    try:
                        zf.write(db_orig, 'panel.db')
                    except Exception:
                        pass
                finally:
                    if db_tmp and os.path.isfile(db_tmp):
                        try:
                            os.unlink(db_tmp)
                        except Exception:
                            pass

            # ── other data files ──────────────────────────────────────────
            data_files = [
                (os.path.join(_PANEL_DIR, '.secret_key'),            '.secret_key'),
                (os.path.join(_PANEL_DIR, 'generated-config.json'),  'generated-config.json'),
                (os.path.join(_PANEL_DIR, 'generated-users.json'),   'generated-users.json'),
                (os.path.join(_PANEL_DIR, 'requirements.txt'),       'requirements.txt'),
                (os.path.join(_PANEL_DIR, 'app.py'),                 'app.py'),
            ]
            for fpath, arcname in data_files:
                if os.path.isfile(fpath):
                    try:
                        zf.write(fpath, arcname)
                    except Exception:
                        pass

    return tmp.name


def _send_telegram_backup(token, chat_id, caption='Panel backup'):
    """Send a backup zip to Telegram using curl (streams the file — no memory load).
    Falls back to urllib multipart if curl is not available.
    Returns (ok, message).
    """
    import shutil as _sh, tempfile as _tmp
    zip_path = None
    try:
        zip_path = _create_backup_zip()
        filename = os.path.basename(zip_path)
        url      = f'https://api.telegram.org/bot{token}/sendDocument'

        # ── Try curl first (handles large files without loading into RAM) ──
        if _sh.which('curl'):
            result = subprocess.run([
                'curl', '-fsSL', '-X', 'POST', url,
                '-F', f'chat_id={chat_id}',
                '-F', f'caption={caption}',
                '-F', f'document=@{zip_path};filename={filename}',
            ], capture_output=True, text=True, timeout=120)
            if result.returncode == 0:
                return True, 'Backup sent successfully'
            err = (result.stderr or result.stdout or '').strip()[:300]
            return False, f'curl error: {err}'

        # ── Fallback: chunked multipart via http.client ────────────────────
        import http.client, ssl

        boundary = 'XrayPanelBoundary8675309'
        def _part(name, value_bytes, content_type=None, fname=None):
            cd = f'Content-Disposition: form-data; name="{name}"'
            if fname:
                cd += f'; filename="{fname}"'
            hdr = cd + '\r\n'
            if content_type:
                hdr += f'Content-Type: {content_type}\r\n'
            return f'--{boundary}\r\n'.encode() + hdr.encode() + b'\r\n' + value_bytes + b'\r\n'

        with open(zip_path, 'rb') as f:
            file_bytes = f.read()

        body = (
            _part('chat_id',  chat_id.encode())
            + _part('caption', caption.encode())
            + _part('document', file_bytes, 'application/zip', filename)
            + f'--{boundary}--\r\n'.encode()
        )

        ctx  = ssl.create_default_context()
        conn = http.client.HTTPSConnection('api.telegram.org', context=ctx, timeout=120)
        conn.request('POST', f'/bot{token}/sendDocument', body, {
            'Content-Type':   f'multipart/form-data; boundary={boundary}',
            'Content-Length': str(len(body)),
        })
        resp = conn.getresponse()
        text = resp.read().decode(errors='replace')
        conn.close()
        if resp.status == 200:
            return True, 'Backup sent successfully'
        return False, f'Telegram API {resp.status}: {text[:300]}'

    except Exception as e:
        return False, f'Backup error: {e}'
    finally:
        if zip_path and os.path.isfile(zip_path):
            try:
                os.unlink(zip_path)
            except Exception:
                pass


_backup_thread_started = False


def _backup_loop():
    """Background thread: send backup at configured interval."""
    while True:
        time.sleep(60)
        try:
            with app.app_context():
                interval_h = float(get_setting('backup_interval_hours', '6') or '0')
                if interval_h <= 0:
                    continue
                last_raw = get_setting('backup_last_sent', '')
                if last_raw:
                    try:
                        last_dt  = datetime.fromisoformat(last_raw)
                        elapsed  = (datetime.now(timezone.utc).replace(tzinfo=None) - last_dt).total_seconds()
                        if elapsed < interval_h * 3600:
                            continue
                    except Exception:
                        pass
                token   = get_setting('telegram_bot_token', '')
                chat_id = get_setting('telegram_chat_id', '')
                if not token or not chat_id:
                    continue
                ok, msg = _send_telegram_backup(token, chat_id, caption='Scheduled data backup (DB + config)')
                ts_str = datetime.now(timezone.utc).replace(tzinfo=None).isoformat()
                set_setting('backup_last_sent', ts_str)
                xray_log_buf.append({'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'),
                                     'line': f'[backup] {"OK" if ok else "FAIL"}: {msg}'})
        except Exception as e:
            pass


def _start_backup_thread():
    global _backup_thread_started
    if not _backup_thread_started:
        _backup_thread_started = True
        threading.Thread(target=_backup_loop, daemon=True).start()


@app.route('/api/backup/send', methods=['POST'])
@login_required
def api_backup_send():
    """Send a data-only backup to Telegram (DB + config + secret key)."""
    token   = get_setting('telegram_bot_token', '')
    chat_id = get_setting('telegram_chat_id', '')
    if not token or not chat_id:
        return jsonify({'ok': False, 'error': 'Telegram bot token and chat ID are not configured'}), 400
    ok, msg = _send_telegram_backup(token, chat_id, caption='Panel data backup (DB + config)')
    if ok:
        set_setting('backup_last_sent', datetime.now(timezone.utc).replace(tzinfo=None).isoformat())
    return jsonify({'ok': ok, 'message': msg})


@app.route('/api/backup/download')
@login_required
def api_backup_download():
    """Download a full backup zip (all source files + DB) directly in the browser."""
    zip_path = _create_backup_zip(full=True)
    fname    = os.path.basename(zip_path)
    return send_file(zip_path, mimetype='application/zip',
                     as_attachment=True, download_name=fname)


@app.route('/api/backup/test', methods=['POST'])
@login_required
def api_backup_test():
    """Send a test message to the configured Telegram bot."""
    import http.client, ssl, urllib.parse
    token   = get_setting('telegram_bot_token', '')
    chat_id = get_setting('telegram_chat_id', '')
    if not token or not chat_id:
        return jsonify({'ok': False, 'error': 'Token or chat ID not configured'}), 400
    try:
        msg_text = urllib.parse.quote('✅ Xray Panel Telegram test — backup notifications are working!')
        ctx  = ssl.create_default_context()
        conn = http.client.HTTPSConnection('api.telegram.org', context=ctx, timeout=10)
        conn.request('GET', f'/bot{token}/sendMessage?chat_id={chat_id}&text={msg_text}')
        resp = conn.getresponse()
        body = resp.read().decode(errors='replace')
        conn.close()
        ok = resp.status == 200
        return jsonify({'ok': ok, 'message': 'Test message sent' if ok else f'Error: {body[:200]}'})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/api/settings/password', methods=['POST'])
@login_required
def api_change_password():
    d   = request.json or {}
    cur = d.get('old_password') or d.get('current', '')
    new = d.get('new_password') or d.get('new', '')
    if not current_user.check_password(cur):
        return jsonify({'error': 'Current password is incorrect'}), 400
    if len(new) < 6:
        return jsonify({'error': 'Password must be at least 6 characters'}), 400
    current_user.set_password(new)
    db.session.commit()
    return jsonify({'ok': True})


# ── API — Traffic ────────────────────────────────────────────────────────────

@app.route('/api/traffic')
@login_required
def api_traffic():
    range_param = request.args.get('range', '24h')
    if range_param == '7d':
        cutoff = _utcnow() - timedelta(days=7)
    elif range_param == '30d':
        cutoff = _utcnow() - timedelta(days=30)
    else:
        cutoff = _utcnow() - timedelta(hours=24)

    records = TrafficRecord.query.filter(
        TrafficRecord.ts >= cutoff
    ).order_by(TrafficRecord.ts.asc()).all()

    ts_list   = [r.ts.strftime('%Y-%m-%d %H:%M') for r in records]
    down_list = [r.down_gb for r in records]
    up_list   = [r.up_gb   for r in records]

    # Per-user breakdown
    users = User.query.order_by(User.traffic_used.desc()).limit(20).all()
    user_breakdown = [
        {'name': u.name, 'used': round(u.traffic_used, 3), 'limit': u.traffic_limit}
        for u in users
    ]

    return jsonify({
        'range': range_param,
        'ts':    ts_list,
        'down':  down_list,
        'up':    up_list,
        'users': user_breakdown,
    })


# ── API — Resellers ───────────────────────────────────────────────────────────

@app.route('/api/resellers', methods=['GET'])
@login_required
def api_resellers():
    aid = _get_admin_id()
    if aid is not None:
        resellers = Reseller.query.filter_by(admin_id=aid).order_by(Reseller.created_at.desc()).all()
    else:
        resellers = Reseller.query.order_by(Reseller.created_at.desc()).all()
    return jsonify({'resellers': [r.to_dict() for r in resellers]})


@app.route('/api/resellers', methods=['POST'])
@login_required
def api_create_reseller():
    d = request.json or {}
    username = d.get('username', '').strip()
    password = d.get('password', '').strip()
    if not username or not password:
        return jsonify({'error': 'Username and password are required'}), 400
    if Reseller.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already exists'}), 400
    if Admin.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already exists'}), 400
    aid = _get_admin_id()
    if aid is not None:
        admin = db.session.get(Admin, aid)
        if admin:
            if Reseller.query.filter_by(admin_id=aid).count() >= admin.reseller_count:
                return jsonify({'error': f'Reseller quota reached ({admin.reseller_count} max)'}), 400
            # Check admin data pool: sum of existing resellers' data_limit_gb + new allocation
            existing_data = db.session.query(db.func.sum(Reseller.data_limit_gb)).filter_by(admin_id=aid).scalar() or 0.0
            new_data = float(d.get('data_limit_gb', 100.0))
            if existing_data + new_data > admin.data_limit_gb:
                remaining = max(0.0, admin.data_limit_gb - existing_data)
                return jsonify({'error': f'Admin data pool limit reached — only {remaining:.2f} GB remaining of {admin.data_limit_gb} GB'}), 400
    r = Reseller(
        username=username,
        user_count=int(d.get('user_count', 10)),
        active_user_count=int(d.get('active_user_count', 10)),
        data_limit_gb=float(d.get('data_limit_gb', 100.0)),
        used_limit_gb=float(d.get('used_limit_gb', d.get('data_limit_gb', 100.0))),
        default_traffic_gb=float(d.get('default_traffic_gb', 10.0)),
        default_days=int(d.get('default_days', 30)),
        allowed_inbound_ids=json.dumps(d.get('allowed_inbound_ids', [])),
        admin_id=aid,
    )
    r.set_password(password)
    db.session.add(r)
    _log_activity('create_reseller', username, f'pool={d.get("data_limit_gb",100)} GB, users={d.get("user_count",10)}')
    db.session.commit()
    return jsonify({'reseller': r.to_dict()}), 201


@app.route('/api/resellers/<int:rid>', methods=['PUT'])
@login_required
def api_update_reseller(rid):
    r = db.session.get(Reseller, rid)
    if not r:
        return jsonify({'error': 'Not found'}), 404
    aid = _get_admin_id()
    if aid is not None and r.admin_id != aid:
        return jsonify({'error': 'Access denied'}), 403
    d = request.json or {}
    if 'user_count'            in d: r.user_count            = int(d['user_count'])
    if 'active_user_count'     in d: r.active_user_count     = int(d['active_user_count'])
    if 'data_limit_gb' in d:
        new_dlimit = float(d['data_limit_gb'])
        if new_dlimit > r.data_limit_gb and r.admin_id is not None:
            admin = db.session.get(Admin, r.admin_id)
            if admin:
                other_sum = db.session.query(db.func.sum(Reseller.data_limit_gb)).filter(
                    Reseller.admin_id == r.admin_id, Reseller.id != r.id
                ).scalar() or 0.0
                if other_sum + new_dlimit > admin.data_limit_gb:
                    remaining = max(0.0, admin.data_limit_gb - other_sum)
                    return jsonify({'error': f'Admin data pool limit reached — only {remaining:.2f} GB remaining of {admin.data_limit_gb} GB'}), 400
        r.data_limit_gb = new_dlimit
    if 'used_limit_gb'         in d: r.used_limit_gb         = float(d['used_limit_gb'])
    if 'default_traffic_gb'    in d: r.default_traffic_gb    = float(d['default_traffic_gb'])
    if 'default_days'          in d: r.default_days          = int(d['default_days'])
    if 'allowed_inbound_ids'   in d: r.allowed_inbound_ids   = json.dumps(d['allowed_inbound_ids'])
    if d.get('password'):
        r.set_password(d['password'])
    _log_activity('update_reseller', r.username)
    db.session.commit()
    return jsonify({'reseller': r.to_dict()})


@app.route('/api/resellers/<int:rid>', methods=['DELETE'])
@login_required
def api_delete_reseller(rid):
    r = db.session.get(Reseller, rid)
    if not r:
        return jsonify({'error': 'Not found'}), 404
    aid = _get_admin_id()
    if aid is not None and r.admin_id != aid:
        return jsonify({'error': 'Access denied'}), 403
    _log_activity('delete_reseller', r.username)
    db.session.delete(r)
    db.session.commit()
    return jsonify({'ok': True})


# ── API — Reseller actions (toggle, reset) ────────────────────────────────────

@app.route('/api/resellers/<int:rid>/toggle', methods=['POST'])
@login_required
def api_toggle_reseller(rid):
    r = db.session.get(Reseller, rid)
    if not r:
        return jsonify({'error': 'Not found'}), 404
    aid = _get_admin_id()
    if aid is not None and r.admin_id != aid:
        return jsonify({'error': 'Access denied'}), 403
    r.active = not r.active
    _log_activity('toggle_reseller', r.username, 'suspended' if not r.active else 'activated')
    db.session.commit()
    return jsonify({'active': r.active})


@app.route('/api/resellers/<int:rid>/lock', methods=['POST'])
@login_required
def api_lock_reseller(rid):
    r = db.session.get(Reseller, rid)
    if not r:
        return jsonify({'error': 'Not found'}), 404
    aid = _get_admin_id()
    if aid is not None and r.admin_id != aid:
        return jsonify({'error': 'Access denied'}), 403
    r.locked = not r.locked
    _log_activity('lock_reseller', r.username, 'locked' if r.locked else 'unlocked')
    db.session.commit()
    return jsonify({'locked': r.locked})


@app.route('/api/resellers/lock-all', methods=['POST'])
@login_required
def api_lock_all_resellers():
    d = request.json or {}
    lock = bool(d.get('locked', True))
    aid = _get_admin_id()
    q = Reseller.query
    if aid is not None:
        q = q.filter_by(admin_id=aid)
    q.update({'locked': lock})
    _log_activity('lock_all_resellers', '', 'locked' if lock else 'unlocked')
    db.session.commit()
    return jsonify({'ok': True, 'locked': lock})


@app.route('/api/resellers/<int:rid>/reset-traffic', methods=['POST'])
@login_required
def api_reset_reseller_traffic(rid):
    r = db.session.get(Reseller, rid)
    if not r:
        return jsonify({'error': 'Not found'}), 404
    # Only admins and superadmins may reset a reseller's traffic pool
    if _get_reseller_id() is not None:
        return jsonify({'error': 'Access denied — only admins can reset reseller traffic'}), 403
    aid = _get_admin_id()
    if aid is not None and r.admin_id != aid:
        return jsonify({'error': 'Access denied'}), 403
    # Zero out the deleted-user accumulators
    r.deleted_users_used_gb      = 0.0
    r.deleted_users_allocated_gb = 0.0
    # Reset every live user's traffic and re-activate limit-blocked users
    users = User.query.filter_by(reseller_id=rid).all()
    for u in users:
        u.traffic_used = 0.0
        if u.status == 'limit':
            u.status = 'active'
    _log_activity('reset_traffic', r.username, f'{len(users)} users reset')
    db.session.commit()
    # Update today's snapshot to reflect the reset
    try:
        _upsert_reseller_snapshots()
    except Exception:
        pass
    apply_config()
    return jsonify({'ok': True, 'users_reset': len(users)})


# ── API — Reseller traffic history ────────────────────────────────────────────

@app.route('/api/resellers/traffic-history', methods=['GET'])
@login_required
def api_all_resellers_traffic_history():
    aid = _get_admin_id()
    if aid is not None:
        resellers = Reseller.query.filter_by(admin_id=aid).order_by(Reseller.created_at.desc()).all()
    else:
        resellers = Reseller.query.order_by(Reseller.created_at.desc()).all()
    result = []
    for r in resellers:
        logs = ResellerTrafficLog.query.filter_by(reseller_id=r.id).order_by(ResellerTrafficLog.date.desc()).all()
        result.append({
            'reseller_id': r.id,
            'reseller':    r.username,
            'admin_id':    r.admin_id,
            'history':     [{'date': l.date.isoformat(), 'allocated_gb': l.allocated_gb, 'used_gb': l.used_gb} for l in logs],
        })
    return jsonify({'resellers': result})


@app.route('/api/resellers/<int:rid>/traffic-history', methods=['GET'])
@login_required
def api_reseller_traffic_history(rid):
    r = db.session.get(Reseller, rid)
    if not r:
        return jsonify({'error': 'Not found'}), 404
    aid = _get_admin_id()
    if aid is not None and r.admin_id != aid:
        return jsonify({'error': 'Access denied'}), 403
    logs = ResellerTrafficLog.query.filter_by(reseller_id=rid).order_by(ResellerTrafficLog.date.desc()).all()
    return jsonify({
        'reseller_id': r.id,
        'reseller':    r.username,
        'history':     [{'date': l.date.isoformat(), 'allocated_gb': l.allocated_gb, 'used_gb': l.used_gb} for l in logs],
    })


# ── API — Admins (superadmin only) ────────────────────────────────────────────

@app.route('/api/admins', methods=['GET'])
@superadmin_required
def api_admins():
    admins = Admin.query.filter_by(role='admin').order_by(Admin.created_at.desc()).all()
    return jsonify({'admins': [a.to_dict() for a in admins]})


@app.route('/api/admins', methods=['POST'])
@superadmin_required
def api_create_admin():
    d = request.json or {}
    username = d.get('username', '').strip()
    password = d.get('password', '').strip()
    if not username or not password:
        return jsonify({'error': 'Username and password are required'}), 400
    if Admin.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already exists'}), 400
    if Reseller.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already exists'}), 400
    a = Admin(
        username=username,
        role='admin',
        reseller_count=int(d.get('reseller_count', 10)),
        data_limit_gb=float(d.get('data_limit_gb', 1000.0)),
        user_count=int(d.get('user_count', 1000)),
    )
    a.set_password(password)
    db.session.add(a)
    _log_activity('create_admin', username)
    db.session.commit()
    return jsonify({'admin': a.to_dict()}), 201


@app.route('/api/admins/<int:aid>', methods=['PUT'])
@superadmin_required
def api_update_admin(aid):
    a = db.session.get(Admin, aid)
    if not a or a.role == 'superadmin':
        return jsonify({'error': 'Not found'}), 404
    d = request.json or {}
    if 'reseller_count' in d: a.reseller_count = int(d['reseller_count'])
    if 'data_limit_gb'  in d: a.data_limit_gb  = float(d['data_limit_gb'])
    if 'user_count'     in d: a.user_count      = int(d['user_count'])
    if d.get('password'):
        a.set_password(d['password'])
    db.session.commit()
    return jsonify({'admin': a.to_dict()})


@app.route('/api/admins/<int:aid>/lock', methods=['POST'])
@superadmin_required
def api_lock_admin(aid):
    a = db.session.get(Admin, aid)
    if not a or a.role == 'superadmin':
        return jsonify({'error': 'Not found'}), 404
    a.locked = not a.locked
    _log_activity('lock_admin', a.username, 'locked' if a.locked else 'unlocked')
    db.session.commit()
    return jsonify({'locked': a.locked})


@app.route('/api/admins/lock-all', methods=['POST'])
@superadmin_required
def api_lock_all_admins():
    d = request.json or {}
    lock = bool(d.get('locked', True))
    Admin.query.filter_by(role='admin').update({'locked': lock})
    _log_activity('lock_all_admins', '', 'locked' if lock else 'unlocked')
    db.session.commit()
    return jsonify({'ok': True, 'locked': lock})


@app.route('/api/admins/<int:aid>', methods=['DELETE'])
@superadmin_required
def api_delete_admin(aid):
    a = db.session.get(Admin, aid)
    if not a or a.role == 'superadmin':
        return jsonify({'error': 'Not found'}), 404
    aname = a.username
    Reseller.query.filter_by(admin_id=aid).update({'admin_id': None})
    _log_activity('delete_admin', aname)
    db.session.delete(a)
    db.session.commit()
    return jsonify({'ok': True})


# ── Init ──────────────────────────────────────────────────────────────────────

def migrate_db():
    """Add columns / tables that may not exist in older databases."""
    from sqlalchemy import inspect as _inspect, text
    insp   = _inspect(db.engine)
    tables = set(insp.get_table_names())

    user_cols     = {col['name'] for col in insp.get_columns('user')}     if 'user'     in tables else set()
    server_cols   = {col['name'] for col in insp.get_columns('server')}   if 'server'   in tables else set()
    inbound_cols  = {col['name'] for col in insp.get_columns('inbound')}  if 'inbound'  in tables else set()
    reseller_cols = {col['name'] for col in insp.get_columns('reseller')} if 'reseller' in tables else set()
    admin_cols    = {col['name'] for col in insp.get_columns('admin')}    if 'admin'    in tables else set()

    with db.engine.connect() as conn:
        # ── admin table ──────────────────────────────────────────────────────
        if 'role' not in admin_cols:
            conn.execute(text("ALTER TABLE admin ADD COLUMN role TEXT NOT NULL DEFAULT 'superadmin'"))
            conn.commit()
        # Ensure the 'admin' username is always superadmin (handles DEFAULT propagation edge cases)
        conn.execute(text("UPDATE admin SET role='superadmin' WHERE username='admin'"))
        # If still no superadmin exists, promote the oldest account
        result = conn.execute(text("SELECT COUNT(*) FROM admin WHERE role='superadmin'")).scalar()
        if not result:
            conn.execute(text("UPDATE admin SET role='superadmin' WHERE id=(SELECT MIN(id) FROM admin)"))
        conn.commit()
        if 'reseller_count' not in admin_cols:
            conn.execute(text('ALTER TABLE admin ADD COLUMN reseller_count INTEGER NOT NULL DEFAULT 10'))
            conn.commit()
        if 'data_limit_gb' not in admin_cols:
            conn.execute(text('ALTER TABLE admin ADD COLUMN data_limit_gb REAL NOT NULL DEFAULT 1000.0'))
            conn.commit()
        if 'user_count' not in admin_cols:
            conn.execute(text('ALTER TABLE admin ADD COLUMN user_count INTEGER NOT NULL DEFAULT 1000'))
            conn.commit()
        if 'created_at' not in admin_cols:
            conn.execute(text("ALTER TABLE admin ADD COLUMN created_at TEXT DEFAULT NULL"))
            conn.commit()
        if 'locked' not in admin_cols:
            conn.execute(text('ALTER TABLE admin ADD COLUMN locked INTEGER NOT NULL DEFAULT 0'))
            conn.commit()

        # ── reseller admin_id column ─────────────────────────────────────────
        if 'admin_id' not in reseller_cols:
            conn.execute(text('ALTER TABLE reseller ADD COLUMN admin_id INTEGER REFERENCES admin(id) ON DELETE SET NULL'))
            conn.commit()
        # ── user table ──────────────────────────────────────────────────────
        if 'ip_limit' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN ip_limit INTEGER NOT NULL DEFAULT 0'))
            conn.commit()

        if 'sub_token' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN sub_token TEXT'))
            conn.commit()
            conn.execute(text(
                "UPDATE \"user\" SET sub_token = ("
                "lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||"
                "lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||"
                "lower(hex(randomblob(6)))"
                ") WHERE sub_token IS NULL"
            ))
            conn.commit()

        if 'sub_note' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN sub_note TEXT'))
            conn.commit()

        if 'access_mode' not in user_cols:
            conn.execute(text("ALTER TABLE \"user\" ADD COLUMN access_mode TEXT NOT NULL DEFAULT 'none'"))
            conn.execute(text("ALTER TABLE \"user\" ADD COLUMN access_domains TEXT NOT NULL DEFAULT '[]'"))
            conn.execute(text("ALTER TABLE \"user\" ADD COLUMN access_ips TEXT NOT NULL DEFAULT '[]'"))
            conn.commit()

        if 'access_type' not in user_cols:
            conn.execute(text("ALTER TABLE \"user\" ADD COLUMN access_type TEXT NOT NULL DEFAULT 'both'"))
            conn.commit()

        if 'date_start_mode' not in user_cols:
            conn.execute(text("ALTER TABLE \"user\" ADD COLUMN date_start_mode TEXT NOT NULL DEFAULT 'on_create'"))
            conn.commit()
        if 'expires_days' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN expires_days INTEGER NOT NULL DEFAULT 0'))
            conn.commit()
        if 'speed_limit_kbps' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN speed_limit_kbps INTEGER NOT NULL DEFAULT 0'))
            conn.commit()

        # ── App login credentials for the Veil client apps ────────────────────
        if 'vpn_username' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN vpn_username TEXT'))
            conn.execute(text('ALTER TABLE "user" ADD COLUMN vpn_password TEXT'))
            conn.commit()
        conn.execute(text(
            'CREATE UNIQUE INDEX IF NOT EXISTS ix_user_vpn_username '
            'ON "user" (vpn_username) WHERE vpn_username IS NOT NULL'))
        conn.commit()

        # ── inbound table ────────────────────────────────────────────────────
        if 'access_mode' not in inbound_cols:
            conn.execute(text("ALTER TABLE inbound ADD COLUMN access_mode TEXT NOT NULL DEFAULT 'none'"))
            conn.execute(text("ALTER TABLE inbound ADD COLUMN access_domains TEXT NOT NULL DEFAULT '[]'"))
            conn.execute(text("ALTER TABLE inbound ADD COLUMN access_ips TEXT NOT NULL DEFAULT '[]'"))
            conn.commit()

        # ── server table ─────────────────────────────────────────────────────
        if 'server_type' not in server_cols:
            conn.execute(text("ALTER TABLE server ADD COLUMN server_type TEXT NOT NULL DEFAULT 'out'"))
            conn.commit()

        if 'notes' not in server_cols:
            conn.execute(text("ALTER TABLE server ADD COLUMN notes TEXT"))
            conn.commit()

        if 'settings' not in server_cols:
            conn.execute(text("ALTER TABLE server ADD COLUMN settings TEXT DEFAULT '{}'"))
            conn.commit()

        # ── reseller table ───────────────────────────────────────────────────────
        if 'allowed_inbound_ids' not in reseller_cols:
            conn.execute(text("ALTER TABLE reseller ADD COLUMN allowed_inbound_ids TEXT NOT NULL DEFAULT '[]'"))
            conn.commit()
        if 'used_limit_gb' not in reseller_cols:
            conn.execute(text('ALTER TABLE reseller ADD COLUMN used_limit_gb REAL NOT NULL DEFAULT 100.0'))
            conn.execute(text('UPDATE reseller SET used_limit_gb = data_limit_gb'))
            conn.commit()
        if 'locked' not in reseller_cols:
            conn.execute(text('ALTER TABLE reseller ADD COLUMN locked INTEGER NOT NULL DEFAULT 0'))
            conn.commit()

        # ── user_inbound_assoc table (many-to-many) ───────────────────────────
        if 'user_inbound_assoc' not in tables:
            conn.execute(text('''
                CREATE TABLE user_inbound_assoc (
                    user_id    INTEGER NOT NULL,
                    inbound_id INTEGER NOT NULL,
                    PRIMARY KEY (user_id, inbound_id),
                    FOREIGN KEY (user_id)    REFERENCES "user"(id)    ON DELETE CASCADE,
                    FOREIGN KEY (inbound_id) REFERENCES inbound(id)   ON DELETE CASCADE
                )
            '''))
            conn.commit()
            conn.execute(text('''
                INSERT OR IGNORE INTO user_inbound_assoc (user_id, inbound_id)
                SELECT id, inbound_id FROM "user"
                WHERE inbound_id IS NOT NULL
                  AND inbound_id IN (SELECT id FROM inbound)
            '''))
            conn.commit()

        # ── tunnel table ──────────────────────────────────────────────────────
        if 'tunnel' not in tables:
            conn.execute(text('''
                CREATE TABLE tunnel (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    name          TEXT    NOT NULL,
                    in_server_id  INTEGER REFERENCES server(id) ON DELETE SET NULL,
                    out_server_id INTEGER REFERENCES server(id) ON DELETE SET NULL,
                    method        TEXT    NOT NULL DEFAULT 'haproxy',
                    in_port       INTEGER NOT NULL,
                    out_port      INTEGER NOT NULL,
                    secret        TEXT,
                    enabled       INTEGER NOT NULL DEFAULT 1,
                    notes         TEXT,
                    settings      TEXT    DEFAULT '{}',
                    created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
                )
            '''))
            conn.commit()
        else:
            tunnel_cols = {col['name'] for col in insp.get_columns('tunnel')}
            if 'settings' not in tunnel_cols:
                conn.execute(text("ALTER TABLE tunnel ADD COLUMN settings TEXT DEFAULT '{}'"))
                conn.commit()

        # ── reseller table ───────────────────────────────────────────────────
        if 'reseller' not in tables:
            conn.execute(text('''
                CREATE TABLE reseller (
                    id                         INTEGER PRIMARY KEY AUTOINCREMENT,
                    username                   TEXT    NOT NULL UNIQUE,
                    password_hash              TEXT    NOT NULL,
                    user_count                 INTEGER NOT NULL DEFAULT 10,
                    active_user_count          INTEGER NOT NULL DEFAULT 10,
                    data_limit_gb              REAL    NOT NULL DEFAULT 100.0,
                    default_traffic_gb         REAL    NOT NULL DEFAULT 10.0,
                    default_days               INTEGER NOT NULL DEFAULT 30,
                    deleted_users_allocated_gb REAL    NOT NULL DEFAULT 0.0,
                    deleted_users_used_gb      REAL    NOT NULL DEFAULT 0.0,
                    active                     INTEGER NOT NULL DEFAULT 1,
                    created_at                 TEXT    NOT NULL DEFAULT (datetime('now'))
                )
            '''))
            conn.commit()
        else:
            if 'deleted_users_allocated_gb' not in reseller_cols:
                conn.execute(text('ALTER TABLE reseller ADD COLUMN deleted_users_allocated_gb REAL NOT NULL DEFAULT 0.0'))
                conn.commit()
            if 'deleted_users_used_gb' not in reseller_cols:
                conn.execute(text('ALTER TABLE reseller ADD COLUMN deleted_users_used_gb REAL NOT NULL DEFAULT 0.0'))
                conn.commit()
            if 'active' not in reseller_cols:
                conn.execute(text('ALTER TABLE reseller ADD COLUMN active INTEGER NOT NULL DEFAULT 1'))
                conn.commit()

        # ── traffic_record table ─────────────────────────────────────────────
        if 'traffic_record' not in tables:
            conn.execute(text('''
                CREATE TABLE traffic_record (
                    id      INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts      TEXT    NOT NULL,
                    down_gb REAL    NOT NULL DEFAULT 0.0,
                    up_gb   REAL    NOT NULL DEFAULT 0.0
                )
            '''))
            conn.execute(text('CREATE INDEX IF NOT EXISTS ix_traffic_record_ts ON traffic_record (ts)'))
            conn.commit()

        # ── reseller_id column on user table ─────────────────────────────────
        if 'reseller_id' not in user_cols:
            conn.execute(text('ALTER TABLE "user" ADD COLUMN reseller_id INTEGER REFERENCES reseller(id) ON DELETE SET NULL'))
            conn.commit()

        # ── activity_log table ────────────────────────────────────────────────
        if 'activity_log' not in tables:
            conn.execute(text('''
                CREATE TABLE activity_log (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts         TEXT    NOT NULL DEFAULT (datetime('now')),
                    actor      TEXT    NOT NULL DEFAULT '',
                    actor_role TEXT    NOT NULL DEFAULT '',
                    action     TEXT    NOT NULL DEFAULT '',
                    target     TEXT,
                    detail     TEXT
                )
            '''))
            conn.execute(text('CREATE INDEX IF NOT EXISTS ix_activity_log_ts ON activity_log (ts)'))
            conn.commit()

        # ── reseller_traffic_log table ────────────────────────────────────────
        if 'reseller_traffic_log' not in tables:
            conn.execute(text('''
                CREATE TABLE reseller_traffic_log (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    reseller_id  INTEGER NOT NULL REFERENCES reseller(id) ON DELETE CASCADE,
                    date         TEXT    NOT NULL,
                    allocated_gb REAL    NOT NULL DEFAULT 0.0,
                    used_gb      REAL    NOT NULL DEFAULT 0.0,
                    UNIQUE (reseller_id, date)
                )
            '''))
            conn.execute(text('CREATE INDEX IF NOT EXISTS ix_rtl_reseller ON reseller_traffic_log (reseller_id)'))
            conn.execute(text('CREATE INDEX IF NOT EXISTS ix_rtl_date ON reseller_traffic_log (date)'))
            conn.commit()

    # Backfill app credentials for users created before that feature existed.
    _backfill_vpn_credentials()


def _backfill_vpn_credentials():
    """Give every user an app username/password if they don't have one yet."""
    try:
        pending = User.query.filter(
            db.or_(User.vpn_username.is_(None), User.vpn_username == '',
                   User.vpn_password.is_(None), User.vpn_password == '')
        ).order_by(User.id.asc()).all()
    except Exception as e:
        app.logger.warning(f'vpn credential backfill skipped: {e}')
        return
    if not pending:
        return
    for u in pending:
        _ensure_vpn_credentials(u)
    db.session.commit()
    print(f'  Assigned app credentials to {len(pending)} existing user(s)')


def _startup_ensure_binaries():
    """Background thread: check each tool binary for both amd64 and arm64.
    Download from GitHub if missing. Retries once on failure.
    """
    import time as _time
    with app.app_context():
        for tool in _TOOL_FETCH:
            for arch in ('amd64', 'arm64'):
                if tool == 'frp':
                    needed = [f'frps-{arch}', f'frpc-{arch}']
                else:
                    needed = [f'{tool}-{arch}']

                missing = [n for n in needed
                           if not os.path.isfile(os.path.join(BINARIES_DIR, n))]
                if not missing:
                    continue

                def _log(msg):
                    xray_log_buf.append({
                        'ts': datetime.now(timezone.utc).strftime('%H:%M:%S'), 'line': msg})

                _log(f'[binaries] {tool} ({arch}) missing — downloading…')
                ok, msg, saved = _fetch_binary_to_cache(tool, arch)
                if ok:
                    _log(f'[binaries] [OK] {tool} ({arch}): {msg}')
                else:
                    _log(f'[binaries] [WARN] {tool} ({arch}) attempt 1 failed: {msg}')
                    _time.sleep(5)
                    ok2, msg2, saved2 = _fetch_binary_to_cache(tool, arch)
                    label = '[OK]' if ok2 else '[ERR]'
                    _log(f'[binaries] {label} {tool} ({arch}) retry: {msg2}')


def init_db():
    with app.app_context():
        db.create_all()
        migrate_db()
        if not Admin.query.first():
            a = Admin(username='admin', role='superadmin')
            a.set_password('admin123')
            db.session.add(a)
            db.session.commit()
            print('\n  Default credentials → admin / admin123\n')
    # Download missing binaries in the background (non-blocking)
    threading.Thread(target=_startup_ensure_binaries, daemon=True).start()


if __name__ == '__main__':
    init_db()
    _start_stats_thread()
    _start_backup_thread()
    with app.app_context():
        ok, msg = xray_start()
        if ok:
            print(f'  Xray auto-started')
        else:
            print(f'  Xray auto-start: {msg}')
    port = int(os.environ.get('PORT', 5000))
    print(f'  Panel → http://0.0.0.0:{port}')
    app.run(host='0.0.0.0', port=port, debug=False)
