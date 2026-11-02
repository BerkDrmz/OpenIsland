"""Join Instruments frame lifetimes to process-owned updates, not capture PTS.

Frame lifetime rows have no PID in this Instruments schema. A launch/attach PID
alone is not sufficient ownership evidence. Match display + surface + swap to
the updates table and exclude ambiguous/unowned rows rather than attributing
system-wide compositor work to OpenIsland.
"""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

from matched import Rejected, require


def table(path, expected_schema):
    tree = ET.parse(path).getroot()
    definitions = {element.attrib["id"]: element for element in tree.iter() if "id" in element.attrib}

    def resolve(element):
        seen = set()
        while "ref" in element.attrib:
            reference = element.attrib["ref"]
            require(reference not in seen and reference in definitions, "unresolved/cyclic Instruments reference")
            seen.add(reference)
            element = definitions[reference]
        return element

    rows = []
    for node in tree.iter("node"):
        schema = node.find("schema")
        if schema is None or schema.get("name") != expected_schema:
            continue
        columns = [column.findtext("mnemonic") for column in schema.findall("col")]
        require(len(set(columns)) == len(columns), "ambiguous Instruments columns")
        for row in node.findall("row"):
            require(len(row) == len(columns), "Instruments schema changed")
            mapped = {key: resolve(value) for key, value in zip(columns, row)}
            result = {}
            for key, value in mapped.items():
                if value.tag == "sentinel":
                    result[key] = None
                elif key == "process":
                    pid = next((resolve(x).text for x in value.iter("pid")), None)
                    result[key] = int(pid) if pid is not None else None
                else:
                    result[key] = value.text
            rows.append(result)
    require(bool(rows), "requested Instruments table has no rows")
    return rows


def extract(lifetimes_path, updates_path, pid, start_ns, end_ns):
    require(pid > 0 and 0 <= start_ns < end_ns, "invalid PID/phase")
    updates = table(updates_path, "hitches-updates")
    owners = {}
    key_for = lambda row: (row.get("display"), row.get("surface-id"), row.get("swap-id"))
    for row in updates:
        if row.get("process") is not None:
            owners.setdefault(key_for(row), set()).add(row["process"])
    rows = table(lifetimes_path, "hitches-frame-lifetimes")
    included, excluded = [], {"outside_phase": 0, "unowned_or_ambiguous": 0, "missing_timing": 0}
    for row in rows:
        try:
            start, duration = int(row["start"]), int(row["duration"])
        except (TypeError, ValueError, KeyError):
            excluded["missing_timing"] += 1
            continue
        if duration <= 0 or start < start_ns or start + duration > end_ns:
            excluded["outside_phase"] += 1
            continue
        if owners.get(key_for(row)) != {pid}:
            excluded["unowned_or_ambiguous"] += 1
            continue
        included.append({"start_ns": start, "lifetime_ms": duration / 1_000_000,
                         "display": row["display"], "surface_id": row["surface-id"], "swap_id": row["swap-id"]})
    return {"status": "OWNED_FRAME_LIFETIMES" if included else "UNAVAILABLE",
            "source": "xctrace:hitches-frame-lifetimes", "pid": pid,
            "phase_ns": [start_ns, end_ns], "frames": included, "excluded": excluded,
            "warning": "Frame lifetime, not capture interval, input latency, GPU utilization, or battery power. Empty is unavailable, not zero."}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--lifetimes", required=True); ap.add_argument("--updates", required=True)
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--start-ns", type=int, required=True); ap.add_argument("--end-ns", type=int, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    try:
        result = extract(args.lifetimes, args.updates, args.pid, args.start_ns, args.end_ns)
        with Path(args.out).open("x") as stream:
            json.dump(result, stream, indent=2)
        print(result["status"], "frames=", len(result["frames"]))
    except (Rejected, ET.ParseError) as error:
        ap.exit(2, "REFUSED: " + str(error) + "\n")
