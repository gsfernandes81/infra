# This repo's stdout callback, styled after roots/ansible-output-prettify (the Laravel
# Artisan look): one line per task, dots out to a right-aligned time and status word.
# ansible.cfg selects it (stdout_callback = infra); ANSIBLE_STDOUT_CALLBACK=default
# ansible-playbook … gives Ansible's stock output for one run.
#
#     PLAY [Install and start garmin-mcp, then probe it]
#
#       ✓ Read the ssh user's home directory on one ........ 412ms DONE
#       ~ If .env is complete: start garmin-mcp, building
#       ↪ it only if the image is absent ................... 2m14s CHANGED
#       ● Probe /healthz through the tunnel ................. 47.3s RUNNING
#
#       one
#         ✓ 58 successful
#         ~ 4 changed
#
#     🚀 Deployment completed successfully in 3m02s
#
# prettify's symbols, colours, status words, PLAY header, Error: lines, per-host recap and
# closing line. It has no licence, so nothing is copied from it: this is a reimplementation
# of its look. Where this differs, on purpose (owner, 2026-10-24):
#   - a step that is running shows `● … 47.3s RUNNING`, its timer redrawn in tenths, in place,
#     up to ten times a second (terminal only);
#   - skipped steps are not shown at all (the recap still counts them);
#   - long lines wrap the way Helix soft-wraps: continuation keeps the line's indent, marked
#     with `↪`, and nothing is cut off;
#   - every status word starts in the same column, the furthest right it can (the longest
#     word is 7, so a host that cannot be reached is DOWN rather than UNREACHABLE), and the
#     terminal's last column stays empty so a redraw never meets an early line wrap;
#   - times read 412ms, 3.2s, 2m14s; the closing line says so when the run failed;
#   - debug messages print in full under their line, and a debug task is DONE, not CHANGED.
#
# TWO MODES, chosen once from whether stdout is a terminal:
#   terminal  The running step's line is drawn as it starts and redrawn as its timer ticks,
#             then replaced by its final line, or erased if every host skipped it. Drawing
#             happens ONLY while this plugin's line is the last thing on screen: every other
#             line Ansible prints (warnings, deprecations, errors, prompts, worker output)
#             goes through Display.display, which this plugin watches, and that first
#             leaves the step's name on screen with a newline. So nothing printed by any
#             other part of Ansible can be drawn over or erased.
#   piped     Plain text, no escape codes, nothing overwritten: a log or a pasted
#             transcript. A step's line prints when it finishes.
#
# KNOWN LIMIT: vars_prompt and --step read input() without going through Display, so on a
# terminal the timer would redraw over their prompt. This repo's plays do not prompt by
# policy (secrets come from files); a play that ever does should be run with
# ANSIBLE_STDOUT_CALLBACK=default.
#
# Workers are FORKED. A fork taken while the timer thread holds this plugin's lock would
# hand the child a lock nobody can release, and its first display call would hang the run
# (review, 2026-10-24; reproduced). So a forked child drops the lock and the redraw logic
# entirely: its output is proxied to the controller's display anyway.

from __future__ import annotations

DOCUMENTATION = r"""
name: infra
type: stdout
short_description: one line per task with a right-aligned time and status, prettify-style
description:
  - The infra repo's own output; see the header of the file.
"""

import atexit
import os
import pprint
import re
import shutil
import sys
import textwrap
import threading
import time

from ansible import context
from ansible.plugins.callback import CallbackBase
from ansible.utils import color as ansible_color

WORD_W = 7                  # the longest status word; every word starts at the same column
WRAP = '↪ '                 # Helix's wrap indicator, drawn in the indent of a continuation

ANSI = {'green': '0;32', 'red': '0;31', 'yellow': '0;33', 'cyan': '0;36', 'bright_red': '1;31',
        'blue': '0;34', 'purple': '1;35', 'gray': '0;90'}
SYMBOL = {'done': '✓', 'changed': '~', 'failed': '✗', 'ignored': '✗', 'down': '⚠', 'running': '●', 'skipped': '→'}
WORD = {'done': 'DONE', 'changed': 'CHANGED', 'failed': 'FAILED', 'ignored': 'IGNORED',
        'down': 'DOWN', 'running': 'RUNNING', 'skipped': 'SKIPPED'}
COLOUR = {'done': 'green', 'changed': 'yellow', 'failed': 'red', 'ignored': 'yellow',
          'down': 'bright_red', 'running': 'blue', 'skipped': 'cyan'}
RANK = ['done', 'changed', 'ignored', 'down', 'failed']          # worst last


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'infra'

    def __init__(self):
        super().__init__()
        self._tty = sys.stdout.isatty()
        self._colour = self._tty and bool(getattr(ansible_color, 'ANSIBLE_COLOR', True))
        self._lock = threading.RLock()
        self._ours = False          # True while this plugin itself is writing
        self._child = False         # True in a forked worker
        self._check = bool(context.CLIARGS.get('check'))
        self._kind = 'Playbook'
        self._run_start = time.time()
        self._task = None           # the running step's name, or None
        self._hosts = {}            # host -> {'status': …, 'details': [(colour, text)…], 'retries': n}
        self._named = False         # the step's name is on screen for good (output interrupted it)
        self._live = 0              # lines of the drawn, uncommitted step line (terminal)
        self._live_width = 0
        self._tick = -1
        os.register_at_fork(after_in_child=self._after_fork)
        # A run that ends without reaching stats (Ctrl-C, an error escaping the strategy)
        # would lose the running step's buffered results; print them on the way out.
        atexit.register(self._at_exit)
        self._watch_display()
        if self._tty:
            self._stop = threading.Event()
            threading.Thread(target=self._ticker, name='infra-timer', daemon=True).start()

    # ── plumbing ──────────────────────────────────────────────────────────────
    def _at_exit(self):
        if self._child:
            return
        with self._lock:
            self._finish()

    def _after_fork(self):
        self._lock = threading.RLock()
        self._child = True
        self._live = 0

    # TaskResult's _result/_host/_task are deprecated for removal in ansible-core 2.23;
    # result/host/task replace them. Older cores have only the underscored names.
    @staticmethod
    def _res(result):
        return result.result if hasattr(type(result), 'result') else result._result

    @staticmethod
    def _task_of(result):
        return result.task if hasattr(type(result), 'task') else result._task

    def _host(self, result):
        host = result.host if hasattr(type(result), 'host') else result._host
        return host.get_name()

    def _watch_display(self):
        """Wrap Display.display so another part of Ansible printing first fixes our line."""
        original = self._display.display

        def display(*args, **kwargs):
            if self._child:
                return original(*args, **kwargs)
            with self._lock:
                if not self._ours and self._task is not None and not self._named:
                    self._name_on_screen()
                return original(*args, **kwargs)

        self._display.display = display

    @staticmethod
    def _plain(text):
        return re.sub(r'\x1b\[[0-9;]*m', '', text)

    def _say(self, text):
        """Print one already-coloured line: colour to the screen, plain text to the log."""
        with self._lock:
            self._ours = True
            try:
                if self._colour:
                    self._display.display(text, screen_only=True)
                    self._display.display(self._plain(text), log_only=True)
                else:
                    self._display.display(text)
            finally:
                self._ours = False

    def _write(self, raw):
        sys.stdout.write(raw)
        sys.stdout.flush()

    def _c(self, text, colour):
        return f'\x1b[{ANSI[colour]}m{text}\x1b[0m' if self._colour and colour and text else text

    @staticmethod
    def _width():
        """Usable columns: the terminal's, less the last, which stays empty."""
        return max(shutil.get_terminal_size((80, 24)).columns, 40) - 1

    @staticmethod
    def _fmt(seconds, live=False):
        """Times as shown: 412ms, 3.2s, 2m14s; while running, tenths: 3.4s, 2m04.3s. Rounded
        ONCE at the precision shown, then split, so 59.97s reads 1m00.0s and never 60.0s."""
        if live:
            mins, tenths = divmod(round(seconds * 10), 600)
            return f'{tenths / 10:.1f}s' if mins == 0 else f'{mins}m{tenths / 10:04.1f}s'
        ms = round(seconds * 1000)
        if ms < 1000:
            return f'{ms}ms'
        tenths = round(seconds * 10)
        if tenths < 600:
            return f'{tenths / 10:.1f}s'
        mins, secs = divmod(round(seconds), 60)
        return f'{mins}m{secs:02d}s'

    def _fmt(seconds, live=False):
        if live:                 # tenths while a step runs: 3.4s, then 2m04.3s
            if seconds < 60:
                return f'{seconds:.1f}s'
            return f'{int(seconds) // 60}m{seconds % 60:04.1f}s'
        if seconds < 1:
            return f'{seconds * 1000:.0f}ms'
        if seconds < 60:
            return f'{seconds:.1f}s'
        return f'{int(seconds) // 60}m{int(seconds) % 60:02d}s'

    def _helix(self, text, indent, width, first=None):
        """Wrap `text` Helix-style: continuations keep the indent, marked with the wrap
        indicator in the indent's last two columns. `first` replaces the first line's indent
        (e.g. "  ✓ "). Returns plain lines."""
        first = first if first is not None else ' ' * indent
        rest = ' ' * (indent - len(WRAP)) + WRAP if indent >= len(WRAP) else ' ' * indent
        out = []
        for para in str(text).split('\n'):
            out += textwrap.wrap(para, width=width, initial_indent=first, subsequent_indent=rest,
                                 break_on_hyphens=False, drop_whitespace=True) or [first.rstrip()]
            first = ' ' * indent
        return out

    # ── the step line ─────────────────────────────────────────────────────────
    def _step_lines(self, status, timer, name=None, prefix=None):
        """The step's line(s): name, gray dots, the time, the status word at the column."""
        w = self._width()
        col = w - WORD_W
        name = self._task if name is None else name
        head = prefix if prefix is not None else '  ' + SYMBOL[status] + ' '
        lines = self._helix(name, len(head), col - 1, first=head)
        # The dots, time and status go on the last line; when it is too full for three dots
        # and the time, they move to a continuation line of their own.
        if col - len(lines[-1] + ' ') - len(timer) - 2 < 3:
            lines.append(' ' * (len(head) - len(WRAP)) + WRAP.rstrip())
        last = lines[-1] + ' '
        dots = col - len(last) - len(timer) - 2
        out = []
        for i, l in enumerate(lines):
            if i == 0 and prefix is None:
                l = '  ' + self._c(SYMBOL[status], COLOUR[status]) + ' ' + l[4:]
            elif l.startswith(' ' * (len(head) - 2) + WRAP):
                l = l[:len(head) - 2] + self._c(WRAP, 'gray') + l[len(head):]
            out.append(l)
        out[-1] = out[-1] + ' ' + self._c('.' * dots, 'gray') + ' ' + self._c(timer, 'gray') \
            + (' ' if timer else ' ') + self._c(WORD[status], COLOUR[status])
        return out

    def _name_lines(self):
        """The step's name alone (no dots, time or status): left when output interrupts it."""
        head = '  ' + self._c(SYMBOL['running'], COLOUR['running']) + ' '
        lines = self._helix(self._task, 4, self._width(), first='  ● ')
        return [head + lines[0][4:]] + [l[:2] + self._c(WRAP, 'gray') + l[4:] if l.startswith('  ' + WRAP) else l
                                         for l in lines[1:]]

    def _draw_live(self):
        """Draw or redraw the running step's line, cursor left at the end of its last line."""
        if self._live and self._width() != self._live_width:
            # Resized (a phone rotated): the terminal re-flowed the line, so counting lines
            # back up would land on the wrong ones. Leave the name, stop redrawing this step.
            self._write('\n')
            self._live = 0
            self._named = True
            return
        lines = self._step_lines('running', self._fmt(time.time() - self._start, live=True))
        if self._live and len(lines) == self._live:
            # Same shape as on screen (the dots absorb the timer's length): overwrite in place,
            # clearing only what is left at each line's end, so ten redraws a second do not flicker.
            up = '\r' + '\x1b[1A' * (self._live - 1)
            self._write(up + '\x1b[K\n'.join(lines) + '\x1b[K')
        else:
            up = ('\r' + '\x1b[1A' * (self._live - 1) + '\x1b[J') if self._live else ''
            self._write(up + '\n'.join(lines))
        self._live = len(lines)
        self._live_width = self._width()

    def _erase_live(self):
        if not self._live:
            return
        if self._width() != self._live_width:
            self._write('\n')
            self._named = True
        else:
            self._write('\r' + '\x1b[1A' * (self._live - 1) + '\x1b[J')
        self._live = 0

    def _name_on_screen(self):
        """Something else is about to print: leave the step's name, and only its name."""
        self._ours = True
        try:
            if self._live:
                self._erase_live()
            if not self._named:
                for l in self._name_lines():
                    if self._tty:
                        self._write(l + '\n')
                        self._display.display(self._plain(l), log_only=True)
                    else:
                        self._display.display(l)
                # Display does not flush, and piped stdout is block-buffered while stderr is
                # not: without this, in a `2>&1` log the warning lands above the name it follows.
                sys.stdout.flush()
                self._named = True
        finally:
            self._ours = False

    def _ticker(self):
        while not self._stop.wait(0.05):
            with self._lock:
                if self._live and self._task is not None and not self._named:
                    tick = self._fmt(time.time() - self._start, live=True)
                    if tick != self._tick:       # redraw only when the shown time changes
                        self._tick = tick
                        self._ours = True
                        try:
                            self._draw_live()
                        finally:
                            self._ours = False

    def _begin(self, name):
        with self._lock:
            self._finish()
            self._task, self._start = name, time.time()
            self._hosts, self._named, self._tick = {}, False, None
            if self._tty:
                self._ours = True
                try:
                    self._draw_live()
                finally:
                    self._ours = False

    def _finish(self):
        """The step is over: print its final line and details, or nothing if all skipped."""
        if self._task is None:
            return
        self._ours = True
        try:
            if self._live:
                self._erase_live()
            if self._hosts:
                self._print_step()
            elif self._named:     # the name went up, then every host skipped: close it
                for l in self._continuation('skipped', self._fmt(time.time() - self._start)):
                    self._say(l)
        finally:
            self._ours = False
        self._task = None

    def _continuation(self, status, timer):
        """A `↪ ……… time STATUS` line, for a step whose name is already on screen."""
        lines = self._step_lines(status, timer, name='', prefix='  ' + WRAP)
        return ['  ' + self._c(WRAP, 'gray') + l[4:] if l.startswith('  ' + WRAP) else l for l in lines]

    def _print_step(self):
        statuses = [h['status'] for h in self._hosts.values()]
        status = max(statuses, key=RANK.index)
        timer = self._fmt(time.time() - self._start)
        if self._named:          # the name is already up, above whatever interrupted it
            lines = self._continuation(status, timer)
        else:
            lines = self._step_lines(status, timer)
        for l in lines:
            self._say(l)
        many = len(self._hosts) > 1
        if many and len(set(statuses)) > 1:
            for host, h in self._hosts.items():
                for l in self._step_lines(h['status'], '', name=host, prefix='    '):
                    self._say(l)
        for host, h in self._hosts.items():
            if h['retries']:
                h['details'].insert(0, ('gray', f'↻ retried {h["retries"]} time' + ('s' if h['retries'] != 1 else '')))
            for colour, text in h['details']:
                text = f'{host} · {text}' if many else text
                for l in self._helix(text, 4, self._width()):
                    if l.startswith('  ' + WRAP):
                        self._say('  ' + self._c(WRAP, 'gray') + self._c(l[4:], colour))
                    else:
                        self._say('    ' + self._c(l[4:], colour))

    # ── recording results ─────────────────────────────────────────────────────
    def _entry(self, result):
        return self._hosts.setdefault(self._host(result), {'status': 'done', 'details': [], 'retries': 0})

    def _set(self, result, status):
        with self._lock:
            e = self._entry(result)
            if RANK.index(status) > RANK.index(e['status']):
                e['status'] = status
            return e

    def _add(self, result, colour, text):
        with self._lock:
            self._entry(result)['details'].append((colour, str(text)))

    def _message(self, result):
        res = self._res(result)
        if res.get('censored'):
            return 'hidden (no_log)'
        task = self._task_of(result)
        msg = res.get('msg', '')
        if task.action.split('.')[-1] == 'debug' and 'msg' not in res:
            var = task.args.get('var')
            if var is not None and var in res:     # debug: var=… — the value IS the point
                msg = f'{var}: ' + pprint.pformat(res[var], width=max(self._width() - 4, 20))
        if isinstance(msg, dict):
            msg = pprint.pformat(msg, width=max(self._width() - 4, 20))
        return msg

    def _is_debug(self, result):
        return self._task_of(result).action.split('.')[-1] == 'debug'

    def _failure(self, result, ignored, label=None):
        res = self._res(result)
        self._set(result, 'ignored' if ignored else 'failed')
        colour = 'yellow' if ignored else 'red'
        msg = 'hidden (no_log)' if res.get('censored') else (res.get('msg') or res.get('reason') or 'failed')
        self._add(result, colour, (f'{label} · ' if label is not None else '') + f'Error: {msg}')
        if res.get('censored'):
            return
        # The cause is not always in msg: a failed command's own output, and for a MODULE
        # FAILURE the remote's stdout (a missing interpreter says so there), not stderr.
        for key in ('stdout', 'module_stdout', 'stderr', 'module_stderr'):
            val = str(res.get(key) or '').strip()
            if val:
                for line in val.split('\n')[-10:]:
                    self._add(result, colour, line)
        # Ansible's own exception block (an [ERROR] with the task's source excerpt) repeats the
        # cause shown above at length; it prints with -v, as the stock callback's detail does.
        if res.get('exception') and self._display.verbosity >= 1:
            with self._lock:
                self._handle_exception(res)

    def _warnings(self, res):
        self._handle_warnings(res)

    # ── callback events ───────────────────────────────────────────────────────
    def v2_playbook_on_start(self, playbook):
        name = os.path.basename(getattr(playbook, '_file_name', '') or '').lower()
        self._kind = 'Dry run' if self._check else ('Deployment' if 'deploy' in name
                                                    else 'Provisioning' if 'provision' in name else 'Playbook')
        self._run_start = time.time()

    def v2_playbook_on_play_start(self, play):
        with self._lock:
            self._finish()
            name = play.get_name().strip() or 'Unnamed play'
            mark = ' · DRY RUN' if self._check else ''
            self._say('')
            for l in self._helix(f'PLAY [{name}]{mark}', 0, self._width()):
                self._say(self._c(l, 'blue'))
            self._say('')

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._begin(task.get_name().strip() or task.action)

    def v2_playbook_on_handler_task_start(self, task):
        self._begin('handler · ' + (task.get_name().strip() or task.action))

    def v2_playbook_on_no_hosts_matched(self):
        self._say(self._c('  → no hosts matched', 'cyan'))

    def v2_runner_on_ok(self, result):
        res = self._res(result)
        self._warnings(res)
        if 'results' in res:                 # a loop: its items were recorded one by one
            self._set(result, 'changed' if res.get('changed') and not self._is_debug(result) else 'done')
            return
        if self._is_debug(result):
            self._set(result, 'done')
            if res.get('changed'):           # a debug marked changed: its message is the point
                msg = self._message(result)
                for line in (msg if isinstance(msg, (list, tuple)) else str(msg).split('\n')):
                    self._add(result, None, line)
            return
        if res.get('changed'):
            self._set(result, 'changed')
            msg = self._message(result)
            if isinstance(msg, str) and msg:
                self._add(result, None, msg)
            elif isinstance(msg, (list, tuple)):
                for line in msg:
                    self._add(result, None, line)
        else:
            self._set(result, 'done')

    def v2_runner_item_on_ok(self, result):
        res = self._res(result)
        self._warnings(res)
        self._set(result, 'done')
        if res.get('changed'):
            self._add(result, 'yellow', f'~ {self._get_item_label(res)}')

    def v2_runner_on_failed(self, result, ignore_errors=False):
        res = self._res(result)
        self._warnings({k: v for k, v in res.items() if k != 'exception'})
        if 'results' in res:                 # a loop whose items failed: recorded per item
            self._set(result, 'ignored' if ignore_errors else 'failed')
            return
        self._failure(result, ignore_errors)

    def v2_runner_item_on_failed(self, result):
        res = self._res(result)
        self._warnings({k: v for k, v in res.items() if k != 'exception'})
        self._failure(result, bool(self._task_of(result).ignore_errors), label=self._get_item_label(res))

    def v2_runner_on_unreachable(self, result):
        res = self._res(result)
        self._warnings(res)
        self._set(result, 'down')
        self._add(result, 'bright_red', f'Error: unreachable · {res.get("msg", "")}')

    def v2_runner_retry(self, result):
        with self._lock:
            self._entry(result)['retries'] += 1

    def v2_runner_on_skipped(self, result):
        self._warnings(self._res(result))

    def v2_runner_item_on_skipped(self, result):
        self._warnings(self._res(result))

    def v2_on_file_diff(self, result):
        res = self._res(result)
        # A loop's diffs are per item, under `results` (as the default callback reads them).
        items = res.get('results') if 'results' in res else [res]
        for r in items or []:
            if r.get('diff') and r.get('changed', False):
                text = self._get_diff(r['diff'])
                for line in text.rstrip('\n').split('\n'):
                    self._add(result, None, line)

    def v2_playbook_on_stats(self, stats):
        with self._lock:
            self._finish()
            if self._tty:
                self._stop.set()
            failed = False
            self._say('')
            for h in sorted(stats.processed):
                s = stats.summarize(h)
                failed = failed or bool(s['failures'] or s.get('unreachable'))
                self._say(self._c(f'  {h}', 'blue'))
                for n, sym, word, colour in ((s['ok'], '✓', 'successful', 'green'),
                                             (s['changed'], '~', 'changed', 'yellow'),
                                             (s['failures'], '✗', 'failed', 'red'),
                                             (s.get('unreachable', 0), '⚠', 'unreachable', 'bright_red'),
                                             (s['skipped'], '→', 'skipped', 'cyan'),
                                             (s.get('ignored', 0), '✗', 'ignored', 'yellow')):
                    if n:
                        self._say('    ' + self._c(f'{sym} {n} {word}', colour))
            took = self._fmt(time.time() - self._run_start)
            self._say('')
            if failed:
                self._say(self._c(f'✗ {self._kind} failed after {took}', 'red'))
            else:
                icon = {'Deployment': '🚀', 'Provisioning': '⚙️'}.get(self._kind, '✅')
                self._say(self._c(f'{icon} {self._kind} completed successfully in {took}', 'green'))
            self._say('')
