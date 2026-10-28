"""Synthetic Instruments schema/ownership tests; not an app frame benchmark."""
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import frame_export as frames
from matched import Rejected


def xml_table(schema, columns, rows):
    root = ET.Element("trace-query-result"); node = ET.SubElement(root, "node")
    definition = ET.SubElement(node, "schema", name=schema)
    for name in columns:
        ET.SubElement(ET.SubElement(definition, "col"), "mnemonic").text = name
    for values in rows:
        row = ET.SubElement(node, "row")
        for key, value in zip(columns, values):
            if key == "process":
                element = ET.SubElement(row, "process"); ET.SubElement(element, "pid").text = str(value)
            else:
                ET.SubElement(row, "value").text = str(value)
    return ET.tostring(root, encoding="unicode")


class FrameExportChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.life = self.root / "lifetimes.xml"; self.updates = self.root / "updates.xml"
        self.life.write_text(xml_table("hitches-frame-lifetimes", ["start", "duration", "display", "swap-id", "surface-id"],
                                       [[100, 20_000_000, "D1", "swap", "surface"]]))
        self.write_updates([[100, 42, "D1", "swap", "surface"]])

    def tearDown(self): self.tmp.cleanup()

    def write_updates(self, rows):
        self.updates.write_text(xml_table("hitches-updates", ["start", "process", "display", "swap-id", "surface-id"], rows))

    def extract(self): return frames.extract(self.life, self.updates, 42, 0, 30_000_000)

    def test_owned_nanoseconds_to_milliseconds(self):
        x = self.extract(); self.assertEqual(x["frames"][0]["lifetime_ms"], 20)

    def test_wrong_process_is_not_zero_frame_time(self):
        self.write_updates([[100, 99, "D1", "swap", "surface"]])
        x = self.extract(); self.assertEqual(x["status"], "UNAVAILABLE"); self.assertFalse(x["frames"])

    def test_ambiguous_surface_owners_excluded(self):
        self.write_updates([[100, 42, "D1", "swap", "surface"], [100, 99, "D1", "swap", "surface"]])
        self.assertFalse(self.extract()["frames"])

    def test_other_display_excluded(self):
        self.write_updates([[100, 42, "D2", "swap", "surface"]])
        self.assertFalse(self.extract()["frames"])

    def test_incomplete_frame_at_phase_boundary_excluded(self):
        self.assertFalse(frames.extract(self.life, self.updates, 42, 0, 1000)["frames"])

    def test_unknown_schema_refused(self):
        self.life.write_text(self.life.read_text().replace("hitches-frame-lifetimes", "capture-pts"))
        with self.assertRaises(Rejected): self.extract()

    def test_reference_resolution(self):
        text = self.life.read_text().replace('<value>100</value>', '<value id="1">100</value>')
        text = text.replace('</node>', '<row><value ref="1"/><value>1000000</value><value>D1</value><value>swap</value><value>surface</value></row></node>')
        self.life.write_text(text)
        self.assertEqual(len(self.extract()["frames"]), 2)

    def test_missing_reference_refused(self):
        self.life.write_text(self.life.read_text().replace('<value>100</value>', '<value ref="missing"/>'))
        with self.assertRaises(Rejected): self.extract()


if __name__ == "__main__": unittest.main()
