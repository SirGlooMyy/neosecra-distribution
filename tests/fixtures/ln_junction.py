"""Test-only `ln -s` for Windows: directory symlinks as NTFS junctions.

Windows needs a privilege for real symlinks; junctions need none and Git Bash
treats them as links (test -L, readlink).  Handles ln -s / -sf / -sfn with an
absolute or link-relative directory target.  Anything else is not supported.
"""
import os
import subprocess
import sys

arguments = sys.argv[1:]
flags = ''.join(a[1:] for a in arguments if a.startswith('-') and len(a) > 1)
paths = [a for a in arguments if not (a.startswith('-') and len(a) > 1)]
if 's' not in flags or len(paths) != 2:
    sys.exit('ln_junction: unsupported arguments: %r' % (arguments,))
target, link = paths
if not os.path.isabs(target):
    target = os.path.join(os.path.dirname(os.path.abspath(link)), target)
target = os.path.normpath(target)
if os.path.lexists(link):
    if 'f' not in flags:
        sys.exit('ln_junction: %s exists' % link)
    os.rmdir(link)
result = subprocess.run(['cmd', '/c', 'mklink', '/J', link, target], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
if result.returncode:
    sys.exit('ln_junction: ' + result.stderr.strip())
