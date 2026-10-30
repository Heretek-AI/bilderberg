#!/usr/bin/env python3
"""Merges verified multi-arch image build receipts into state/build-state.json."""

import json
from pathlib import Path

STATE_FILE = Path("state/build-state.json")
RECEIPTS_DIR = Path("receipts")


def merge_receipts(state_file: Path = STATE_FILE, receipts_dir: Path = RECEIPTS_DIR) -> int:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state = {}
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))

    if not receipts_dir.exists():
        print("No receipts directory found; nothing to update.")
        return 0

    updated = 0
    for receipt_file in sorted(receipts_dir.glob("*.json")):
        data = json.loads(receipt_file.read_text(encoding="utf-8"))
        key = data.pop("state_key")
        state[key] = data
        updated += 1

    if updated:
        state_file.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Updated {updated} entry/entries in {state_file}.")
    return updated


def main():
    merge_receipts()


if __name__ == "__main__":
    main()
