"""Synthetic export-format checks, not product performance results."""
from pathlib import Path
import tempfile
import unittest

from matched import Rejected
import trace_tables


class SharedSchemaChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.xml = self.root / "export.xml"
        self.toc = self.root / "toc.xml"
        self.toc.write_text('<trace-toc><run><data><table schema="events"/>'
                            '<table schema="events"/></data></run></trace-toc>')
        self.xml.write_text('''<trace-query-result>
<node xpath="//trace-toc[1]/run[1]/data[1]/table[1]">
<schema name="events"><col><mnemonic>time</mnemonic></col>
<col><mnemonic>process</mnemonic></col></schema></node>
<node xpath="//trace-toc[1]/run[1]/data[1]/table[2]">
<row><value>123</value><process><pid>42</pid></process></row></node>
</trace-query-result>''')

    def tearDown(self):
        self.tmp.cleanup()

    def read(self):
        return trace_tables.table(self.xml, "events", self.toc)

    def test_empty_first_node_does_not_hide_later_shared_schema_rows(self):
        self.assertEqual(self.read(), [{"time": "123", "process": 42}])

    def test_incompatible_toc_table_cannot_inherit_columns(self):
        self.toc.write_text(self.toc.read_text().replace('schema="events"', 'schema="other"'))
        with self.assertRaises(Rejected): self.read()

    def test_missing_toc_index_refused(self):
        self.xml.write_text(self.xml.read_text().replace("table[2]", "table[99]"))
        with self.assertRaises(Rejected): self.read()

    def test_missing_schema_refused(self):
        self.xml.write_text(self.xml.read_text().replace('name="events"', 'name="other"'))
        with self.assertRaises(Rejected): self.read()

    def test_bad_row_width_refused(self):
        self.xml.write_text(self.xml.read_text().replace("<value>123</value>", ""))
        with self.assertRaises(Rejected): self.read()

    def test_missing_reference_refused(self):
        self.xml.write_text(self.xml.read_text().replace("<value>123</value>", '<value ref="absent"/>'))
        with self.assertRaises(Rejected): self.read()

    def test_explicit_empty_table_is_not_a_missing_instrument(self):
        text = self.xml.read_text()
        text = text.replace('<row><value>123</value><process><pid>42</pid></process></row>', '')
        self.xml.write_text(text)
        self.assertEqual(self.read(), [])

    def test_identical_export_event_copies_can_be_explicitly_deduplicated(self):
        row = {"time": "123", "process": 42, "identifier": "9"}
        self.assertEqual(trace_tables.unique_events([row, dict(row)]), [row])

    def test_different_times_processes_and_ids_are_never_dropped(self):
        row = {"time": "123", "process": 42, "identifier": "9"}
        values = [row, dict(row, time="124"), dict(row, process=43), dict(row, identifier="10")]
        self.assertEqual(len(trace_tables.unique_events(values)), 4)


if __name__ == "__main__":
    unittest.main()
