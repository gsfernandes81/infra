# This repo's stdout callback: one line per task as it starts, details only where they
# matter, wrapped to the terminal's width. ansible.cfg selects it (stdout_callback = infra);
# ANSIBLE_STDOUT_CALLBACK=default ansible-playbook … gives the stock output for one run.
#
# Written for this repo on 2026-10-24, with roots/ansible-output-prettify as the model for
# measuring the terminal and timing steps (that repo has no licence, so nothing is copied).
# It replaced a community.general.diy template block, which could not see the terminal's
# width, could not hide the titles of skipped steps, and called APIs ansible-core 2.23
# removes. docs/decisions.md § "Ansible output" has the reasoning.
#
# TWO MODES, chosen once from whether stdout is a terminal:
#   terminal  A task's title is drawn as it starts, with a timer ticking at its end. If
#             every host skips the task, the title is erased; otherwise it stays, with the
#             step's final time. Redrawing and erasing happen ONLY while this plugin's own
#             title is the last thing on screen: every other line Ansible prints (warnings,
#             deprecations, errors, prompts) goes through Display.display, which this
#             plugin watches, and that first commits the title with a newline. So nothing
#             another part of Ansible printed can ever be drawn over or erased.
#   piped     Plain text, no escape codes, nothing overwritten: a log or a pasted
#             transcript. A title prints with its task's first result, so a skipped task
#             leaves no line.
#
# What prints under a title: changed results (`~`), failures (`✘`, yellow when ignored),
# unreachable hosts, retries (`↻`), and the message of any debug task marked changed,
# lists included, in full. A plain ok or a skip prints nothing (as display_ok_hosts and
# display_skipped_hosts = False did). no_log results say only that they are hidden.

from __future__ import annotations

DOCUMENTATION = r"""
name: infra
type: stdout
short_description: one line per task as it starts, wrapped to the terminal
description:
  - The infra repo's own output; see the header of the file.
"""

import shutil
import sys
import textwrap
import threading
import time

from ansible import context
from ansible.plugins.callback import CallbackBase
from ansible.utils.color import stringc

INDENT = 3          # " ▸ " and the continuation of a title
DETAIL = 15         # where a result's text starts: "   ~ " + 9-column host + " "
TIMER_ROOM = 7      # columns kept free at the end of a title for "  123s"


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'infra'

    def __init__(self):
        super().__init__()
        self._tty = sys.stdout.isatty()
        self._lock = threading.RLock()
        self._ours = False          # True while this plugin itself is writing
        self._task = None           # the current task's title text, or None
        self._start = 0.0
        self._ran = False           # some host ran the current task (not all skipped)
        self._shown = False         # the title has been printed for good
        self._live = 0              # lines of a live, uncommitted title on screen (tty)
        self._tick = -1
        self._check = bool(context.CLIARGS.get('check'))
        self._watch_display()
        if self._tty:
            self._stop = threading.Event()
            threading.Thread(target=self._ticker, name='infra-timer', daemon=True).start()

    # ── output plumbing ───────────────────────────────────────────────────────
    def _watch_display(self):
        """Wrap Display.display so foreign output first commits a live title."""
        original = self._display.display

        def display(*args, **kwargs):
            with self._lock:
                if not self._ours and self._live:
                    self._commit_live()
                return original(*args, **kwargs)

        self._display.display = display

    def _say(self, text, color=None):
        with self._lock:
            self._ours = True
            try:
                self._display.display(text, color=color)
            finally:
                self._ours = False

    def _write(self, raw):
        sys.stdout.write(raw)
        sys.stdout.flush()

    @staticmethod
    def _width():
        return max(shutil.get_terminal_size((80, 24)).columns, 40)

    def _wrap(self, text, first, rest, width):
        lines = []
        for para in str(text).split('\n') or ['']:
            lines += textwrap.wrap(para, width=width, initial_indent=first, subsequent_indent=rest,
                                   break_on_hyphens=False) or [first.rstrip()]
            first = rest
        return lines

    @staticmethod
    def _secs(seconds):
        return f'{seconds:.0f}s' if seconds < 100 else f'{seconds / 60:.0f}m'

    # ── the task title ────────────────────────────────────────────────────────
    def _title_lines(self, timer=''):
        w = self._width()
        lines = self._wrap(self._task, ' ▸ ', ' ' * INDENT, w - TIMER_ROOM)
        if timer:
            lines[-1] = lines[-1] + '  ' + timer
        return lines

    def _draw_live(self, timer):
        """Draw (or redraw) the live title, cursor left at the end of its last line."""
        up = ('\r' + '\x1b[1A' * (self._live - 1) + '\x1b[J') if self._live else ''
        lines = self._title_lines(timer)
        self._write(up + '\n'.join(stringc(l, 'cyan') for l in lines))
        self._live = len(lines)

    def _commit_live(self):
        """Leave the live title on screen for good, with its time so far if over a second."""
        elapsed = time.time() - self._start
        self._draw_live(self._secs(elapsed) if elapsed >= 1 else '')
        self._write('\n')
        self._live = 0
        self._shown = True

    def _erase_live(self):
        self._write('\r' + '\x1b[1A' * (self._live - 1) + '\x1b[J')
        self._live = 0

    def _show_title(self):
        """Make sure the title is on screen for good before a result line under it."""
        if self._task is None or self._shown:
            return
        if self._live:
            self._commit_live()
            return
        elapsed = time.time() - self._start
        timer = self._secs(elapsed) if elapsed >= 1 else ''
        for line in self._title_lines(timer):
            self._say(line, color='cyan')
        self._shown = True

    def _ticker(self):
        while not self._stop.wait(0.25):
            with self._lock:
                if self._live and self._task is not None:
                    tick = int(time.time() - self._start)
                    if tick != self._tick:
                        self._tick = tick
                        self._ours = True
                        try:
                            self._draw_live(f'{tick}s')
                        finally:
                            self._ours = False

    def _begin(self, title):
        with self._lock:
            self._finish()
            self._task, self._start = title, time.time()
            self._ran = self._shown = False
            self._tick = 0
            if self._tty:
                self._ours = True
                try:
                    self._draw_live('0s')
                finally:
                    self._ours = False

    def _finish(self):
        """Close the current task: keep its title if it ran, erase it if every host skipped."""
        if self._task is None:
            return
        if self._live:
            self._ours = True
            try:
                self._commit_live() if self._ran else self._erase_live()
            finally:
                self._ours = False
        elif self._ran and not self._shown:
            self._show_title()
        self._task = None

    # ── result lines ──────────────────────────────────────────────────────────
    def _line(self, mark, host, text, color):
        with self._lock:
            self._ran = True
            self._show_title()
            w = self._width()
            head = f'   {mark} {host:<9} '
            lines = self._wrap(text, head, ' ' * DETAIL, w)
            for l in lines:
                self._say(l, color=color)

    def _detail(self, lines, color):
        w = self._width()
        for item in lines:
            for l in self._wrap(item, ' ' * DETAIL, ' ' * DETAIL, w):
                self._say(l, color=color)

    @staticmethod
    def _host(result):
        return result._host.get_name()

    def _message(self, res):
        if res.get('censored'):
            return 'hidden (no_log)'
        return res.get('msg', '')

    def _changed(self, result):
        res = result._result
        msg = self._message(res)
        if res.get('censored'):
            self._line('~', self._host(result), 'changed · hidden (no_log)', 'yellow')
        elif isinstance(msg, str) and msg and '\n' not in msg and len(msg) <= self._width() - DETAIL:
            self._line('~', self._host(result), msg, 'yellow')
        elif isinstance(msg, (list, tuple)) or (isinstance(msg, str) and msg):
            self._line('~', self._host(result), 'changed', 'yellow')
            self._detail([str(m) for m in msg] if isinstance(msg, (list, tuple)) else msg.split('\n'), 'yellow')
        else:
            self._line('~', self._host(result), 'changed', 'yellow')

    def _failed(self, result, ignored, label=None):
        res = result._result
        text = ('failed (ignored)' if ignored else 'failed') + ' · '
        if label is not None:
            text = f'{label} · ' + text
        msg = self._message(res) or res.get('reason', '')
        color = 'yellow' if ignored else 'bright red'
        self._line('✘', self._host(result), text + str(msg).split('\n')[0], color)
        rest = str(msg).split('\n')[1:]
        err = res.get('stderr') or res.get('module_stderr') or ''
        tail = rest + (str(err).strip().split('\n')[-10:] if err else [])
        if tail and not res.get('censored'):
            self._detail(tail, color)

    # ── callback events ───────────────────────────────────────────────────────
    def v2_playbook_on_play_start(self, play):
        with self._lock:
            self._finish()
            w = self._width()
            name = play.get_name().strip() or 'play'
            mark = ' · DRY RUN' if self._check else ''
            lines = self._wrap(name + mark, '━━ ', ' ' * INDENT, w - 4)
            last = lines[-1] + ' '
            lines[-1] = last + '━' * max(w - len(last), 2)
            self._say('')
            for l in lines:
                self._say(l, color='bright blue')

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._begin(task.get_name().strip() or task.action)

    def v2_playbook_on_handler_task_start(self, task):
        self._begin('handler · ' + (task.get_name().strip() or task.action))

    def v2_playbook_on_no_hosts_matched(self):
        self._say(' ▸ (no hosts matched)', color='dark gray')

    def v2_runner_on_ok(self, result):
        self._handle_warnings(result._result)
        if 'results' in result._result:      # a loop: its items printed on their own
            with self._lock:
                self._ran = True
            return
        if result._result.get('changed'):
            self._changed(result)
        else:
            with self._lock:
                self._ran = True

    def v2_runner_item_on_ok(self, result):
        if result._result.get('changed'):
            label = self._get_item_label(result._result)
            self._line('~', self._host(result), str(label), 'yellow')
        else:
            with self._lock:
                self._ran = True

    def v2_runner_on_failed(self, result, ignore_errors=False):
        self._handle_warnings(result._result)
        if 'results' in result._result:
            with self._lock:
                self._ran = True
            if not ignore_errors:
                self._failed(result, False)
            return
        self._failed(result, ignore_errors)

    def v2_runner_item_on_failed(self, result):
        self._failed(result, bool(result._task.ignore_errors), label=self._get_item_label(result._result))

    def v2_runner_on_unreachable(self, result):
        self._line('✘', self._host(result), 'unreachable · ' + str(result._result.get('msg', '')), 'bright red')

    def v2_runner_retry(self, result):
        res = result._result
        left = int(res.get('retries', 0)) - int(res.get('attempts', 0))
        self._line('↻', self._host(result), f'retrying · {left} left', 'dark gray')

    def v2_runner_on_skipped(self, result):
        pass

    def v2_runner_item_on_skipped(self, result):
        pass

    def v2_on_file_diff(self, result):
        diff = result._result.get('diff')
        if diff and self._display.verbosity >= 0 and context.CLIARGS.get('diff'):
            with self._lock:
                self._ran = True
                self._show_title()
                self._say(self._get_diff(diff))

    def v2_playbook_on_stats(self, stats):
        with self._lock:
            self._finish()
            if self._tty:
                self._stop.set()
            w = self._width()
            self._say('')
            self._say('━━ Recap ' + '━' * max(w - 9, 2), color='bright blue')
            for h in sorted(stats.processed):
                s = stats.summarize(h)
                line = (f'   {h:<9} ok={s["ok"]} changed={s["changed"]} skipped={s["skipped"]} '
                        f'failed={s["failures"]} ignored={s["ignored"]}')
                if s.get('unreachable'):
                    line += f' unreachable={s["unreachable"]}'
                for l in self._wrap(line, '', ' ' * DETAIL, w):
                    self._say(l, color='bright red' if s['failures'] or s.get('unreachable') else 'bright blue')
