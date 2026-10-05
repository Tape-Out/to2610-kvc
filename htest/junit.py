"""把各段仿真的结果写成 results.xml：流片说明的测试表从它生成。

用法：junit.py <results.xml> <名字>=<退出码>:<秒>:<说明> …
"""
import sys
from xml.sax.saxutils import escape, quoteattr

rows = []
for a in sys.argv[2:]:
    name, rest = a.split("=", 1)
    rc, secs, what = rest.split(":", 2)
    rows.append((name, int(rc), float(secs), what))
bad = sum(rc != 0 for _, rc, _, _ in rows)
out = [f'<testsuites name="results"><testsuite name="chip" tests="{len(rows)}" failures="{bad}">']
for name, rc, secs, what in rows:
    out.append(f'<testcase classname="chip" name={quoteattr(name)} time="{secs:.0f}">')
    out.append(f"<system-out>{escape(what)}</system-out>")
    if rc:
        out.append(f'<failure message="退出码 {rc}" />')
    out.append("</testcase>")
out.append("</testsuite></testsuites>")
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(out) + "\n")
