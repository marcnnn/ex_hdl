defmodule ExHdl.PnRWrapperTest do
  @moduledoc "Wrapper generation and report parsing of ExHdl.Synth.PnR (no tools needed)."
  use ExUnit.Case, async: true

  alias ExHdl.Synth.PnR

  @core """
  module core (
    input  logic clk,
    input  logic rst_n,
    input  logic [15:0] a,
    output logic [15:0] y,
    output logic y_valid  // comment, with comma
  );
  endmodule
  """

  test "parses ANSI port lists" do
    assert {:ok, ports} = PnR.ports(%{"core.sv" => @core}, "core")

    assert Enum.map(ports, &{&1.dir, &1.name, &1.width}) == [
             {:input, "clk", 1},
             {:input, "rst_n", 1},
             {:input, "a", 16},
             {:output, "y", 16},
             {:output, "y_valid", 1}
           ]
  end

  test "wrapper has one input and one output pin" do
    assert {:ok, src} = PnR.wrapper(%{"core.sv" => @core}, "core")
    assert src =~ "module pnr_top"
    assert src =~ "logic [16:0] sr;"
    assert src =~ ".a(i_a)"
    assert src =~ "logic [16:0] obs;"
    assert src =~ "assign dout = par"
  end

  test "wrapper without clk is an error" do
    assert {:error, _} = PnR.wrapper(%{"c.sv" => "module c (input logic x, output logic y);\nendmodule"}, "c")
  end

  test "reads Fmax and utilisation from a nextpnr log" do
    log = """
    Info: Device utilisation:
    Info:             SLICE_LUTX:   120/  53200     0%
    Info:             SLICE_FFX:    200/ 106400     0%
    Info: Max frequency for clock 'clk_IBUF_BUFG': 250.00 MHz (PASS at 200.00 MHz)
    """

    r = PnR.parse_report(log, 200)
    assert r.fmax_mhz == 250.0
    assert r.met
    assert_in_delta r.slack_ns, 1.0, 1.0e-9
    assert r.utilization["SLICE_LUTX"] == {120, 53200}
  end
end
