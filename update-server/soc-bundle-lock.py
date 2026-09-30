#!/usr/bin/env python3
"""Compatibility CLI for the registry-backed Docker bundle lock generator."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
from bundle_lock import main
if __name__ == '__main__':
    sys.argv.extend(['--registry', str(Path(__file__).resolve().parents[1] / 'products/soc.json')])
    main()
