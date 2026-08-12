"""Exercises the panel's device-limit logic against the real app module."""
import os, sys
from datetime import timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)

import app as panel  # noqa: E402


class FakeUser:
    def __init__(self, uid=1, ip_limit=2):
        self.id = uid
        self.ip_limit = ip_limit
        self.status = 'active'

    def is_expired(self):
        return False

    def is_over_limit(self):
        return False


def reset():
    panel._client_devices.clear()


def touch(u, did, name='n', plat='p'):
    with panel.app.test_request_context('/', headers={'X-Real-IP': '1.2.3.4'}):
        panel._client_touch_device(u.id, did, name, plat)


def allowed(u, did):
    with panel.app.test_request_context('/'):
        return panel._client_device_allowed(u, did)


fails = []


def check(label, cond):
    print(('  ok  ' if cond else 'FAIL  ') + label)
    if not cond:
        fails.append(label)


print('device limit')
reset()
u = FakeUser(ip_limit=2)

check('first device is allowed', allowed(u, 'A')[0])
touch(u, 'A')
check('second device is allowed', allowed(u, 'B')[0])
touch(u, 'B')
check('third device is refused', not allowed(u, 'C')[0])
check('a device already holding a slot is still allowed', allowed(u, 'A')[0])
check('count reflects both devices', allowed(u, 'A')[1] == 2)

print('\nunlimited accounts')
reset()
un = FakeUser(uid=2, ip_limit=0)
touch(un, 'A'); touch(un, 'B'); touch(un, 'C')
check('no limit means never refused', allowed(un, 'D')[0])

print('\nlegacy clients without a device id')
reset()
u2 = FakeUser(uid=3, ip_limit=1)
touch(u2, 'A')
check('an app that sends no id is not blocked', allowed(u2, '')[0])

print('\nslots free up when a device goes quiet')
reset()
u3 = FakeUser(uid=4, ip_limit=1)
touch(u3, 'A')
check('limit reached while active', not allowed(u3, 'B')[0])
stale = panel._utcnow() - timedelta(minutes=panel.CLIENT_DEVICE_WINDOW_MIN + 1)
panel._client_devices[u3.id]['A']['ts'] = stale
check('stale device releases its slot', allowed(u3, 'B')[0])
check('stale device is pruned from the list',
      len(panel._client_active_devices(u3.id)) == 0)

print('\nstatus and blocked reason')
reset()
u4 = FakeUser(uid=5, ip_limit=1)
touch(u4, 'A')
with panel.app.test_request_context('/'):
    check('status is active for the registered device',
          panel._client_status(u4, 'A') == 'active')
    check('status is devices for a new one',
          panel._client_status(u4, 'B') == 'devices')
    check('can_connect false for a new one',
          not panel._client_can_connect(u4, 'B'))
    reason = panel._client_blocked_reason(u4, 'B')
    check('reason names the limit', '1 device' in reason)
    check('no device id means no device check',
          panel._client_status(u4, None) == 'active')

print('\nheaders')
with panel.app.test_request_context(
        '/', headers={'X-Device-Id': 'abc', 'X-Device-Name': 'Laptop',
                      'X-Device-Platform': 'windows'}):
    did, name, plat = panel._client_device_headers()
    check('reads the device headers',
          (did, name, plat) == ('abc', 'Laptop', 'windows'))

with panel.app.test_request_context(
        '/', headers={'X-Forwarded-For': '9.9.9.9, 10.0.0.1'}):
    check('honours the proxy header', panel._client_request_ip() == '9.9.9.9')

print()
if fails:
    print(f'{len(fails)} FAILED: {fails}')
    sys.exit(1)
print('all device-limit checks passed')
