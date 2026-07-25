#!/usr/bin/env python3
"""Convert actionlint's plain output into SARIF 2.1.0.

actionlint has no SARIF writer. Without this, workflow problems land in a
separate job that nobody opens, instead of in the same gate as everything
else. Being in one place is most of the value of a gate.

Usage: actionlint-to-sarif.py <input.txt> <output.sarif>

Input is one finding per line, "path:line:message", which is what the
-format template in security.yml produces.
"""

import json
import pathlib
import sys

SCHEMA = "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json"


def parse(line):
    """Split "path:line:message" without breaking on colons in the message."""
    parts = line.split(":", 2)
    if len(parts) != 3:
        return None
    path, lineno, message = parts
    try:
        lineno = int(lineno)
    except ValueError:
        return None
    return path, lineno, message.strip()


def rule_id(message):
    """Derive a stable rule ID from the message.

    actionlint reports its rule name in brackets at the end of the message,
    e.g. "... [shellcheck]". Using it keeps findings groupable in the gate;
    without it every message becomes its own rule and the report is unreadable.
    """
    if message.endswith("]") and "[" in message:
        return "actionlint/" + message[message.rindex("[") + 1:-1]
    return "actionlint/general"


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    src, dst = pathlib.Path(argv[1]), pathlib.Path(argv[2])
    results, rules = [], {}

    for line in src.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        parsed = parse(line)
        if parsed is None:
            continue
        path, lineno, message = parsed

        rid = rule_id(message)
        rules.setdefault(rid, {
            "id": rid,
            "shortDescription": {"text": rid.split("/", 1)[1].replace("-", " ")},
            "helpUri": "https://github.com/rhysd/actionlint/blob/main/docs/checks.md",
            # Workflow problems are real but rarely critical; 5.0 puts them in
            # the medium band so they warn rather than block by default.
            "properties": {"security-severity": "5.0", "tags": ["ci", "actions"]},
        })

        results.append({
            "ruleId": rid,
            "level": "warning",
            "message": {"text": message},
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": {"uri": path},
                    "region": {"startLine": max(lineno, 1)},
                }
            }],
        })

    log = {
        "$schema": SCHEMA,
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {
                "name": "actionlint",
                "informationUri": "https://github.com/rhysd/actionlint",
                "rules": sorted(rules.values(), key=lambda r: r["id"]),
            }},
            "results": results,
        }],
    }

    dst.write_text(json.dumps(log, indent=2) + "\n", encoding="utf-8")
    print(f"{len(results)} finding(s) -> {dst}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
