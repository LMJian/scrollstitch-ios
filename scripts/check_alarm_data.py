#!/usr/bin/env python3
"""Check shipped calendar bytes against an independent official-date oracle."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(directory, blog=None):
    directory = Path(directory)
    index = json.loads((directory / "index.json").read_text())
    assert index["schemaVersion"] == 1 and index["region"] == "CN"
    assert index["years"], "missing bundled years"
    years = set()
    for entry in index["years"]:
        year, revision = entry["year"], entry["revision"]
        assert year not in years
        years.add(year)
        assert entry["file"] == f"{year}.v{revision}.json"
        raw = (directory / entry["file"]).read_bytes()
        assert len(raw) <= 128 * 1024
        assert hashlib.sha256(raw).hexdigest() == entry["sha256"]
        data = json.loads(raw)
        assert (data["schemaVersion"], data["region"], data["timeZone"]) == (1, "CN", "Asia/Shanghai")
        assert (data["year"], data["revision"]) == (year, revision)
        actual = {}
        for item in data["overrides"]:
            date = dt.date.fromisoformat(item["date"])
            assert date.year == year and item["date"] not in actual
            assert item["kind"] in ("rest", "work") and item["name"]
            actual[item["date"]] = item["kind"]
        if year == 2026 and revision == 1:
            expected = {}
            for month, first, last in [(1, 1, 3), (2, 15, 23), (4, 4, 6), (5, 1, 5),
                                       (6, 19, 21), (9, 25, 27), (10, 1, 7)]:
                expected.update({f"2026-{month:02d}-{day:02d}": "rest" for day in range(first, last + 1)})
            expected.update({day: "work" for day in ["2026-01-04", "2026-02-14", "2026-02-28",
                                                    "2026-05-09", "2026-09-20", "2026-10-10"]})
            assert actual == expected, "official 2026 dates differ"
        if blog:
            assert raw == (Path(blog) / "assets/holidays/cn" / entry["file"]).read_bytes(), "App/blog bytes differ"
    print(f"PASS: bundled annual data, exact official dates and SHA256 ({sorted(years)})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, default=ROOT / "Resources/Holidays")
    parser.add_argument("--blog", type=Path)
    args = parser.parse_args()
    check(args.directory, args.blog)
