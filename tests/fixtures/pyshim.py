"""Test-only python launcher for Windows.

Windows cannot open a directory for fsync, which the shared state scripts do on
purpose to make link switches durable.  This launcher makes directory fsyncs a
no-op for the test run only; it changes nothing else.  Usage: pyshim.py - <args>
(script on stdin) or pyshim.py <script.py> <args>.
"""
import os
import runpy
import sys

_open, _fsync = os.open, os.fsync


def _open_dir_tolerant(path, flags, *args, **kwargs):
    if os.path.isdir(path):
        return _open(os.devnull, os.O_RDONLY)
    return _open(path, flags, *args, **kwargs)


def _fsync_tolerant(fd):
    try:
        _fsync(fd)
    except OSError:
        pass


os.open, os.fsync = _open_dir_tolerant, _fsync_tolerant
arguments = sys.argv[1:]
if arguments and arguments[0] == '-':
    sys.argv = ['-'] + arguments[1:]
    exec(compile(sys.stdin.read(), '<stdin>', 'exec'), {'__name__': '__main__'})
elif arguments and arguments[0] == '-c':
    sys.argv = ['-c'] + arguments[2:]
    exec(compile(arguments[1], '<string>', 'exec'), {'__name__': '__main__'})
else:
    sys.argv = arguments
    runpy.run_path(arguments[0], run_name='__main__')
