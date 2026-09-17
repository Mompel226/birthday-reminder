#!/usr/bin/env python3
# Copyright (c) 2026 Dr Daniel Mompel Riera
# Licensed under the GNU Affero General Public License v3.0.
# Free to use and change; if you pass on a changed version, or let anyone
# use it over a network, you must publish your source under the same licence.
# Commercial use needs my permission: dmompelriera@nlcsjeju.kr
"""Small local server so the calendar page can manage its own profiles.

    serve.py <base_dir>          prints "READY <url>" then serves until idle

Binds to 127.0.0.1 on a random port and requires a random token on every /api
call, so nothing else on the machine can reach it. Exits by itself once the
page stops sending heartbeats.
"""
import sys, os, re, json, secrets, socket, subprocess, threading, time, shutil, tempfile
import atexit, signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

BASE = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
RES = os.path.join(BASE, 'Birthday Reminder.app', 'Contents', 'Resources')
BUILD = os.path.join(BASE, 'Birthday Reminder.app', 'Contents', 'MacOS', 'build-calendar')
IMPORT = os.path.join(RES, 'import.py')
TOKEN = secrets.token_urlsafe(18)
IDLE_SECONDS = 150
def _sweep_old_uploads():
    """A previous run that was force-quit or lost to a power cut leaves the spreadsheets
    it was handed sitting in the temp folder. They hold every student's name and date of
    birth, so clear out anything older than half an hour before starting."""
    import glob as _g
    cutoff = time.time() - 1800
    for d in _g.glob(os.path.join(tempfile.gettempdir(), 'birthday-import-*')):
        try:
            if os.path.isdir(d) and os.path.getmtime(d) < cutoff:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


_sweep_old_uploads()
UPLOADS = tempfile.mkdtemp(prefix='birthday-import-')


def _clean_uploads(*_a):
    shutil.rmtree(UPLOADS, ignore_errors=True)


atexit.register(_clean_uploads)
for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    try:
        signal.signal(_sig, lambda s, f: (_clean_uploads(), os._exit(0)))
    except (ValueError, OSError):
        pass
last_seen = time.time()

MIME = {'.html':'text/html; charset=utf-8', '.jpg':'image/jpeg', '.jpeg':'image/jpeg',
        '.png':'image/png', '.css':'text/css', '.js':'text/javascript', '.csv':'text/csv'}


def profiles():
    d = os.path.join(BASE, 'Profiles')
    if not os.path.isdir(d): return []
    out = []
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if os.path.isdir(p) and os.path.isfile(os.path.join(p, 'students.csv')):
            try:
                with open(os.path.join(p, 'students.csv')) as f:
                    n_rows = max(0, sum(1 for _ in f) - 1)
            except OSError:
                n_rows = 0
            out.append({'name': n, 'students': n_rows})
    return out


def active():
    p = os.path.join(BASE, 'active_profile')
    if os.path.isfile(p):
        return open(p).read().strip()
    return ''


def set_active(name):
    with open(os.path.join(BASE, 'active_profile'), 'w') as f:
        f.write(name + '\n')


def rebuild():
    try:
        subprocess.run([BUILD], capture_output=True, timeout=120)
    except Exception:
        pass


def page():
    rebuild()
    f = os.path.join(BASE, 'Birthday Calendar.html')
    html = open(f, encoding='utf-8').read() if os.path.isfile(f) else '<h1>No calendar yet</h1>'
    inject = 'window.LIVE = true; window.TOKEN = %s;' % json.dumps(TOKEN)
    if '/*__LIVE__*/' in html:
        html = html.replace('/*__LIVE__*/', inject)
    else:
        html = html.replace('</head>', '<script>%s</script></head>' % inject, 1)
    return html.encode('utf-8')


def read_config():
    f = os.path.join(BASE, 'config.conf')
    out = {}
    if os.path.isfile(f):
        for line in open(f):
            m = re.match(r'\s*([A-Z_]+)\s*=\s*"?([^"#\n]*)"?', line)
            if m: out[m.group(1)] = m.group(2).strip()
    return out


def reminder_status():
    home = os.path.expanduser('~')
    plist = os.path.join(home, 'Library', 'LaunchAgents', 'uk.dmr.birthdayreminder.plist')
    state = os.path.join(home, 'Library', 'Application Support', 'BirthdayReminder')
    st = {'installed': os.path.isfile(plist), 'loaded': False, 'last_show': '', 'last_log': ''}
    try:
        r = subprocess.run(['launchctl', 'list'], capture_output=True, text=True, timeout=10)
        st['loaded'] = 'uk.dmr.birthdayreminder' in (r.stdout or '')
    except Exception:
        pass
    f = os.path.join(state, 'last_show')
    if os.path.isfile(f): st['last_show'] = open(f).read().strip()
    f = os.path.join(state, 'reminder.log')
    if os.path.isfile(f):
        try:
            lines = open(f, errors='replace').read().strip().splitlines()[-6:]
            st['last_log'] = '\n'.join(lines)
        except Exception:
            pass
    return st


def drop_uploads(paths):
    """The spreadsheets have done their job the moment the import succeeds. They are the
    only copy of your students outside the app folder, so they do not hang about."""
    for p in paths:
        try:
            if p and os.path.isfile(p) and os.path.dirname(os.path.abspath(p)) == UPLOADS:
                os.remove(p)
        except OSError:
            pass


def python_exe():
    for c in (sys.executable, '/usr/bin/python3', '/usr/local/bin/python3',
              '/opt/homebrew/bin/python3'):
        if c and os.path.exists(c): return c
    return 'python3'


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a): pass

    # ---------------------------------------------------------------- helpers
    def send(self, code, body=b'', ctype='application/json'):
        if isinstance(body, str): body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try: self.wfile.write(body)
        except BrokenPipeError: pass

    def js(self, obj, code=200): self.send(code, json.dumps(obj))

    def authed(self, q):
        return (q.get('t', [''])[0] == TOKEN or
                self.headers.get('X-Token', '') == TOKEN)

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        data, left = [], n
        while left > 0:
            chunk = self.rfile.read(min(left, 1 << 20))
            if not chunk: break
            data.append(chunk); left -= len(chunk)
        return b''.join(data)

    # ---------------------------------------------------------------- routes
    def do_GET(self):
        global last_seen
        u = urlparse(self.path); q = parse_qs(u.query)
        path = unquote(u.path)
        last_seen = time.time()

        if path in ('/', '/index.html'):
            return self.send(200, page(), 'text/html; charset=utf-8')

        if path == '/api/state':
            if not self.authed(q): return self.js({'error': 'bad token'}, 403)
            return self.js({'profiles': profiles(), 'active': active(),
                            'config': read_config(), 'status': reminder_status()})

        # any other path is a file inside the folder (photos, mostly)
        target = os.path.abspath(os.path.join(BASE, path.lstrip('/')))
        if not target.startswith(BASE + os.sep) or not os.path.isfile(target):
            return self.send(404, b'not found', 'text/plain')
        ext = os.path.splitext(target)[1].lower()
        with open(target, 'rb') as f: data = f.read()
        return self.send(200, data, MIME.get(ext, 'application/octet-stream'))

    def do_POST(self):
        global last_seen
        u = urlparse(self.path); q = parse_qs(u.query)
        last_seen = time.time()
        if not self.authed(q): return self.js({'error': 'bad token'}, 403)
        path = u.path

        if path == '/api/preferred':
            d = json.loads(self.body() or b'{}') or {}
            prof = os.path.join(BASE, 'Profiles', active(), 'students.csv')
            if not os.path.isfile(prof): return self.js({'error': 'no active class'}, 400)
            import csv as _csv
            with open(prof, newline='') as f:
                rows = list(_csv.DictReader(f)); cols = rows[0].keys() if rows else []
            n = 0
            for ch in d.get('changes', []):
                for r in rows:
                    if (r['surname'] == ch.get('surname') and r['forename'] == ch.get('forename')
                            and r['day'] == str(ch.get('day')) and r['month'] == str(ch.get('month'))):
                        r['preferred_name'] = str(ch.get('value', '')).strip(); n += 1
            if n:
                with open(prof, 'w', newline='') as f:
                    w = _csv.DictWriter(f, fieldnames=list(cols), lineterminator='\n')
                    w.writeheader(); w.writerows(rows)
                rebuild()
            return self.js({'ok': True, 'saved': n})

        if path == '/api/config':
            d = json.loads(self.body() or b'{}') or {}
            f = os.path.join(BASE, 'config.conf')
            if not os.path.isfile(f): return self.js({'error': 'config.conf is missing'}, 400)
            txt = open(f).read()
            for k, v in (d.get('values') or {}).items():
                if not re.fullmatch(r'[A-Z_]+', k): continue
                v = str(v).replace('"', '')
                if re.search(r'^%s=.*$' % k, txt, re.M):
                    txt = re.sub(r'^%s=.*$' % k, '%s="%s"' % (k, v), txt, flags=re.M)
                else:
                    txt += '\n%s="%s"\n' % (k, v)
            open(f, 'w').write(txt)
            return self.js({'ok': True, 'values': read_config()})

        if path == '/api/test':
            app = os.path.join(BASE, 'Birthday Reminder.app', 'Contents', 'MacOS', 'BirthdayReminder')
            try:
                subprocess.Popen([app, '--force'])
                return self.js({'ok': True})
            except Exception as e:
                return self.js({'error': str(e)[:200]}, 500)

        if path == '/api/heartbeat':
            return self.js({'ok': True})

        if path == '/api/switch':
            name = (json.loads(self.body() or b'{}') or {}).get('name', '')
            if not any(p['name'] == name for p in profiles()):
                return self.js({'error': 'no such profile'}, 400)
            set_active(name); rebuild()
            return self.js({'ok': True, 'active': name})

        if path == '/api/delete':
            name = (json.loads(self.body() or b'{}') or {}).get('name', '')
            d = os.path.abspath(os.path.join(BASE, 'Profiles', name))
            if not d.startswith(os.path.join(BASE, 'Profiles') + os.sep) or not os.path.isdir(d):
                return self.js({'error': 'no such profile'}, 400)
            shutil.rmtree(d, ignore_errors=True)
            if active() == name:
                left = profiles()
                set_active(left[0]['name'] if left else '')
            rebuild()
            return self.js({'ok': True, 'active': active(), 'profiles': profiles()})

        if path == '/api/upload':
            kind = q.get('kind', ['report'])[0]
            if kind not in ('report', 'badges', 'extra'): return self.js({'error': 'bad kind'}, 400)
            name = re.sub(r'[^A-Za-z0-9._-]', '_', q.get('name', [kind])[0])[-80:] or kind
            dest = os.path.join(UPLOADS, '%s_%s' % (kind, name))
            with open(dest, 'wb') as f: f.write(self.body())
            info = {'ok': True, 'path': dest, 'bytes': os.path.getsize(dest)}
            if kind in ('report', 'extra'):
                try:
                    r = subprocess.run([python_exe(), IMPORT, '--initials', dest],
                                       capture_output=True, text=True, timeout=120)
                    codes = []
                    for line in r.stdout.splitlines():
                        if '\t' in line:
                            c, n = line.split('\t')[:2]
                            codes.append({'code': c, 'count': int(n)})
                    info['initials'] = codes
                    if r.returncode != 0:
                        info['warning'] = (r.stderr or '').strip()[:400]
                except Exception as e:
                    info['warning'] = str(e)[:300]
            return self.js(info)

        if path == '/api/import':
            d = json.loads(self.body() or b'{}') or {}
            name = re.sub(r'[/:]', '-', str(d.get('name', '')).strip())
            if not name: return self.js({'error': 'give the class a name'}, 400)
            report, badges = d.get('report', ''), d.get('badges', '') or '-'
            extras = [e for e in (d.get('extras') or []) if e and os.path.isfile(e)]
            if not report or not os.path.isfile(report):
                # any spreadsheet with names and dates of birth will do as the roster,
                # so fall back to whatever else was sent rather than refusing
                report = extras.pop(0) if extras else ''
            if not report:
                return self.js({'error': 'no student list was received'}, 400)
            out = os.path.join(BASE, 'Profiles', name)
            os.makedirs(out, exist_ok=True)
            try:
                r = subprocess.run([python_exe(), IMPORT, report, badges, out,
                                    str(d.get('initials', '')).strip().upper()] + extras,
                                   capture_output=True, text=True, timeout=900)
            except Exception as e:
                return self.js({'error': str(e)[:300]}, 500)
            log = (r.stdout or '') + (r.stderr or '')
            if 'OK ' not in log:
                return self.js({'error': 'import failed', 'log': log[-1500:]}, 500)
            drop_uploads([report, badges] + extras)
            set_active(name); rebuild()
            return self.js({'ok': True, 'active': name, 'log': log,
                            'profiles': profiles()})

        return self.js({'error': 'unknown'}, 404)


def idle_watch(httpd):
    while True:
        time.sleep(15)
        if time.time() - last_seen > IDLE_SECONDS:
            shutil.rmtree(UPLOADS, ignore_errors=True)
            httpd.shutdown(); return


def daemonize(errfile):
    """Detach fully. Backgrounding with & is not enough: the launcher lives inside
    an .app bundle, and when that exits macOS takes the whole process group with it."""
    if os.fork() > 0: os._exit(0)
    os.setsid()
    if os.fork() > 0: os._exit(0)
    sys.stdout.flush(); sys.stderr.flush()
    null = os.open(os.devnull, os.O_RDWR); os.dup2(null, 0)
    err = os.open(errfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(err, 1); os.dup2(err, 2)


def main():
    urlfile = errfile = None
    if '--daemon' in sys.argv:
        i = sys.argv.index('--daemon')
        urlfile = sys.argv[i + 1]
        errfile = sys.argv[i + 2] if len(sys.argv) > i + 2 else os.devnull
        daemonize(errfile)

    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
    httpd = ThreadingHTTPServer(('127.0.0.1', port), H)
    threading.Thread(target=idle_watch, args=(httpd,), daemon=True).start()
    url = 'http://127.0.0.1:%d/?t=%s' % (port, TOKEN)
    if urlfile:
        tmp = urlfile + '.tmp'
        with open(tmp, 'w') as f: f.write(url + '\n')
        os.replace(tmp, urlfile)          # the launcher only ever sees a complete file
    else:
        print('READY ' + url, flush=True)
    try:
        httpd.serve_forever()
    finally:
        shutil.rmtree(UPLOADS, ignore_errors=True)
        if urlfile:
            try: os.remove(urlfile)
            except OSError: pass


if __name__ == '__main__':
    main()
