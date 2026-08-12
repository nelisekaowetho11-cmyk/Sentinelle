"""Exercises access_type — whether an account may use the subscription URL,
the client apps, or both.

The point of the feature is that it holds even for someone who already has a
token or already has the link, so the checks live on the request paths rather
than only in the sign-in form. These tests hit the same helpers those paths do.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
os.chdir(ROOT)

import app as panel  # noqa: E402


class FakeUser:
    def __init__(self, access_type='both', status='active'):
        self.id = 1
        self.ip_limit = 0
        self.status = status
        self.access_type = access_type

    def is_expired(self):
        return False

    def is_over_limit(self):
        return False


fails = []


def check(label, cond):
    print(('  ok  ' if cond else 'FAIL  ') + label)
    if not cond:
        fails.append(label)


print('defaults')
check('a user with no access_type set may use both',
      panel._sub_allowed(FakeUser(access_type=None))
      and panel._app_allowed(FakeUser(access_type=None)))
check('an unrecognised value falls back to both',
      panel._access_type(FakeUser(access_type='nonsense')) == 'both')

print('\nboth')
u = FakeUser('both')
check('subscription allowed', panel._sub_allowed(u))
check('app allowed', panel._app_allowed(u))
check('status is unaffected', panel._client_status(u) == 'active')

print('\nsubscription only')
u = FakeUser('sub')
check('subscription allowed', panel._sub_allowed(u))
check('app refused', not panel._app_allowed(u))
check('status says so', panel._client_status(u) == 'sub_only')
check('cannot connect from the app', not panel._client_can_connect(u))
check('the refusal explains where the configs are',
      'subscription' in panel._client_blocked_reason(u).lower())

print('\napp only')
u = FakeUser('app')
check('subscription refused', not panel._sub_allowed(u))
check('app allowed', panel._app_allowed(u))
check('status is unaffected', panel._client_status(u) == 'active')

print('\nthe restriction outranks the other reasons')
# A paused sub-only account must still be told the useful thing — that the app
# is not its route — rather than a quota message it cannot act on.
u = FakeUser('sub', status='paused')
check('sub-only wins over paused', panel._client_status(u) == 'sub_only')

print('\nthe subscription route refuses an app-only token')
with panel.app.test_request_context('/sub/whatever'):
    check('_sub_allowed is what the route branches on',
          panel._sub_allowed(FakeUser('app')) is False)

print()
if fails:
    print(f'{len(fails)} check(s) failed:')
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('all access-type checks passed')
