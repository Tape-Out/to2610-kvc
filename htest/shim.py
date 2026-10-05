"""照 report.json 的位表写测试台要的 tb：54 位焊盘总线经它接到交付的五口顶层上。

位表只写在 report.json 里一处，这里照着它生成，不另写一份。
"""
import json
import re
import sys

rep = json.load(open(sys.argv[1], encoding="utf-8"))
W = rep["pads"]["width"]
ins, outs = {}, []
for b in rep["pads"]["bits"]:
    if b["in"]:
        k = re.fullmatch(r"bidir_in\[(\d+)\]", b["in"]).group(1)
        ins[b["bit"]] = f"pad_in[{k}]"
    for role in ("out", "oe"):
        if b[role]:
            k = re.fullmatch(rf"bidir_{role}\[(\d+)\]", b[role]).group(1)
            outs.append(f"  assign pad_{role}[{k}] = io_{role}[{b['bit']}];")
io_in = ", ".join(ins.get(i, "1'b0") for i in range(W - 1, -1, -1))
print(f"""// 由 htest/shim.py 照 report.json 生成
module tb (
  input  wire        clk,
  input  wire        rst_n,
  input  wire [53:0] pad_in,
  output wire [53:0] pad_out,
  output wire [53:0] pad_oe
);
  wire [{W - 1}:0] io_out, io_oe;
  wire [{W - 1}:0] io_in = {{{io_in}}};
{chr(10).join(outs)}
  {rep["top"]} chip (.clock(clk), .reset(~rst_n), .io_in(io_in), .io_out(io_out), .io_oe(io_oe));
endmodule
""")
