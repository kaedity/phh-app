#!/usr/bin/env python3
"""Seed one synthetic md in an explicitly selected Simulator's local Files provider.

Does not edit provider databases, app configuration, entitlements or permissions.
Run only against an isolated UI-test Simulator; never a user device.
"""
import argparse
from pathlib import Path
import subprocess
from uuid import UUID

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator-id', required=True)
args = parser.parse_args()
device = str(UUID(args.simulator_id)).upper()
groups = subprocess.check_output(
    ['xcrun', 'simctl', 'get_app_container', device, 'com.apple.DocumentsApp', 'groups'],
    text=True,
)
paths = [Path(line.split('\t', 1)[1]) for line in groups.splitlines()
         if line.startswith('group.com.apple.FileProvider.LocalStorage\t')]
if len(paths) != 1 or f'/CoreSimulator/Devices/{device}/' not in str(paths[0]):
    raise SystemExit('Expected the selected Simulator local Files provider only')
folder = paths[0] / 'File Provider Storage' / 'PHH Synthetic Input'
folder.mkdir(exist_ok=True)
content = '\n'.join(f'## Session {number} {("Push-A", "Pull-A", "Leg-A")[(number-1)%3]}'
                    for number in range(1, 10))
(folder / 'synthetic-plan.md').write_text(content, encoding='utf-8')
print(f'Seeded synthetic-plan.md in PHH Synthetic Input on Simulator {device}')
