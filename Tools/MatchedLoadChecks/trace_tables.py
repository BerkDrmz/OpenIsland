"""Read xctrace's shared-schema exports with an independently checked TOC.

Some exports emit a schema only for the first (possibly empty) table. Later
tables have rows but no schema. Never guess their columns: validate each table's
one-based index against the saved TOC, then use the unique matching schema.
This does not change frozen acceptance rules or the original frame parser.
"""
import re
import xml.etree.ElementTree as ET

from matched import require


def table(path, expected_schema, toc_path):
    root = ET.parse(path).getroot()
    toc = ET.parse(toc_path).getroot()
    runs = toc.findall("run")
    definitions = {x.attrib["id"]: x for x in root.iter() if "id" in x.attrib}

    def resolve(value):
        seen = set()
        while "ref" in value.attrib:
            ref = value.attrib["ref"]
            require(ref not in seen and ref in definitions, "unresolved/cyclic trace reference")
            seen.add(ref)
            value = definitions[ref]
        return value

    nodes = list(root.iter("node"))
    schemas = {}
    for node in nodes:
        schema = node.find("schema")
        if schema is not None:
            schema = resolve(schema)
            name = schema.get("name")
            columns = tuple(x.findtext("mnemonic") for x in schema.findall("col"))
            require(bool(columns) and None not in columns and len(set(columns)) == len(columns),
                    "ambiguous trace columns")
            if name in schemas:
                require(schemas[name] == columns, "conflicting shared trace schemas")
            schemas[name] = columns

    require(expected_schema in schemas, "requested trace schema is missing")
    rows = []
    for node in nodes:
        match = re.fullmatch(r"//trace-toc\[1\]/run\[(\d+)\]/data\[1\]/table\[(\d+)\]",
                             node.get("xpath", ""))
        require(match is not None, "unsupported or ambiguous trace table path")
        run_index, table_index = map(int, match.groups())
        require(1 <= run_index <= len(runs), "trace run not present in TOC")
        tables = runs[run_index - 1].findall("./data/table")
        require(1 <= table_index <= len(tables), "trace table not present in TOC")
        actual = tables[table_index - 1].get("schema")
        explicit = node.find("schema")
        if explicit is not None:
            require(resolve(explicit).get("name") == actual, "schema contradicts independent TOC")
        require(actual == expected_schema, "unexpected table in requested trace export")
        columns = schemas[actual]
        for row in node.findall("row"):
            require(len(row) == len(columns), "trace row width differs from schema")
            result = {}
            for key, element in zip(columns, row):
                value = resolve(element)
                if value.tag == "sentinel":
                    result[key] = None
                elif key == "process":
                    pid = next((resolve(x).text for x in value.iter("pid")), None)
                    result[key] = int(pid) if pid is not None else None
                else:
                    result[key] = value.text
            rows.append(result)
    # An explicit, independently validated empty instrument table is distinct
    # from a missing instrument or an unsupported export. Callers decide scope.
    return rows


def unique_events(rows):
    """Remove identical event copies from overlapping export table queries.

    Keep different timestamps, processes, IDs and every other decoded field.
    Call explicitly for signpost exports; do not apply to frame ownership rows.
    """
    return list({tuple(sorted(row.items())): row for row in rows}.values())
