#!/usr/bin/env python3
"""Write the shader library fingerprints whose static shader name matches a pattern, for MetalTrace's skip test.

    scripts/skip_list.py 'REBLUR_|RELAX_|SIGMA_' [--tentative] > <plugin dir>/skip-fingerprints.txt

Only verified names by default (shader_index.py); --tentative also takes names paired by table order only. The
matching names go to stderr.
"""
import json
import os
import re
import sys

pattern = re.compile(sys.argv[1])
statuses = {"verified", "order"} if "--tentative" in sys.argv else {"verified"}
index = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "shader_index.json")))
names = set()
for fp, entry in sorted(index.items()):
    if isinstance(entry, dict) and entry["status"] in statuses and pattern.search(entry["name"]):
        print(fp)
        names.add(entry["name"])
print(f"{len(names)} shaders: {', '.join(sorted(names))}", file=sys.stderr)
