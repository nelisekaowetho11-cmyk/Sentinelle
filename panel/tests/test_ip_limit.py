"""Exercises the tunnel-level device limit — the one that applies to traffic
rather than to sign-ins."""
import os, sys
from datetime import timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)

import app as panel  # noqa: E402


class FakeUser:
    def __init__(self, uuid, ip_limit):
        self.uuid = uuid
        self.ip_limit = ip_limit


fails = []


def check(label, cond):
    print(('  ok  ' if cond else 'FAIL  ') + label)
    if not cond:
        fails.append(label)


def reset():
    panel._user_active_ips.clear()


def blocks(users):
    """_recompute_ip_blocks() with the User query stubbed out.

    Assigning over `User.query` shadows flask-sqlalchemy's descriptor; deleting
    the attribute afterwards uncovers the real one again. Reading it first
    would need an app context and a database, which is exactly what this is
    avoiding.
    """
    class Query:
        def filter(self, *_):
            return self

        def all(self):
            return users

    try:
        panel.User.query = Query()
        return panel._recompute_ip_blocks()
    finally:
        del panel.User.query


print('addresses under the limit')
reset()
u = FakeUser('uuid-a', 2)
panel._touch_user_ip(u.uuid, '1.1.1.1')
panel._touch_user_ip(u.uuid, '2.2.2.2')
check('two addresses on a limit of two are all allowed', blocks([u]) == {})

print('\nthe address that arrived last is the one blocked')
panel._touch_user_ip(u.uuid, '3.3.3.3')
check('the newcomer is blocked', blocks([u]) == {'uuid-a': {'3.3.3.3'}})
check('an established address keeps its slot',
      '1.1.1.1' not in blocks([u])['uuid-a'])

print('\nre-using an address does not cost it its slot')
# The block rule keeps the connection in the log, so a blocked address goes on
# being seen. That must not promote it past the ones that got there first.
panel._touch_user_ip(u.uuid, '3.3.3.3')
panel._touch_user_ip(u.uuid, '1.1.1.1')
check('still the newcomer that is blocked',
      blocks([u]) == {'uuid-a': {'3.3.3.3'}})

print('\na slot freed by silence is taken by the blocked address')
stale = panel._utcnow() - timedelta(minutes=panel.IP_LIMIT_WINDOW_MIN + 1)
panel._user_active_ips[u.uuid]['1.1.1.1']['last'] = stale
panel._user_active_ips[u.uuid]['2.2.2.2']['last'] = stale
check('nothing is blocked once the others go quiet', blocks([u]) == {})
check('the quiet addresses are pruned',
      len(panel._active_user_ips(u.uuid)) == 1)

print('\nuncapped accounts')
reset()
free = FakeUser('uuid-b', 0)
for ip in ('1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4'):
    panel._touch_user_ip(free.uuid, ip)
# _recompute_ip_blocks only ever asks for users with a limit, so an uncapped
# account never reaches it — but if one did, it must not be blocked.
check('no limit means nothing blocked', blocks([free]) == {})

print('\nthe block reaches the generated config')
reset()
panel._ip_blocklist.clear()
panel._ip_blocklist['uuid-c'] = {'9.9.9.9'}
try:
    with panel.app.app_context():
        rules = panel.build_config()['routing']['rules']
finally:
    panel._ip_blocklist.clear()
rule = next((r for r in rules if r.get('user') == ['uuid-c']), None)
check('a rule is emitted for the blocked user', rule is not None)
if rule:
    check('it matches on the source address', rule.get('source') == ['9.9.9.9'])
    check('it sends that traffic nowhere', rule.get('outboundTag') == 'blocked')
    check('it is ahead of the catch-all private-IP rule',
          rules.index(rule) < len(rules) - 1)

print()
if fails:
    print(f'{len(fails)} FAILED: {fails}')
    sys.exit(1)
print('all tunnel device-limit checks passed')
