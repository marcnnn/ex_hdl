defmodule ExHdl.Test.SdrKernels do
  @moduledoc false
  # ex_sdr's DSP blocks in Q15, as listed for `mix ex_hdl.gen.sv`.

  alias NxFixed.Num

  def ex_hdl_kernels do
    f = Num.q(16, 15, rounding: :nearest, lut_bits: 10)
    s = %NxFixed.Fixed{t: Nx.template({}, :s16), frac: 15}
    line = %NxFixed.Fixed{t: Nx.template({30}, :s16), frac: 15}
    phase = Nx.template({}, :u16)

    taps =
      Mix.Project.deps_paths()[:ex_sdr]
      |> Path.join("test/dsp_cases/fir_ccf_31tap.json")
      |> File.read!()
      |> JSON.decode!()
      |> get_in(["params", "taps"])

    [
      [
        name: "ddc_q15",
        fun: &ExSdr.DSP.Blocks.ddc/5,
        args: [{s, s}, phase, phase, s, [format: f]],
        state: 1,
        param_names: ["phase_inc", "gain"]
      ],
      [
        name: "fir_complex_q15",
        fun: &ExSdr.DSP.Blocks.fir_complex/3,
        args: [{s, s}, {line, line}, [format: f, taps: taps]],
        state: 1
      ],
      [
        name: "one_pole_q15",
        fun: &ExSdr.DSP.Blocks.one_pole/4,
        args: [s, s, s, [format: f]],
        state: 1,
        ii: :auto,
        param_names: ["alpha"]
      ],
      [
        name: "one_pole_q15_ch5",
        fun: &ExSdr.DSP.Blocks.one_pole/4,
        args: [s, s, s, [format: f]],
        state: 1,
        channels: 5,
        param_names: ["alpha"]
      ]
    ]
  end
end
