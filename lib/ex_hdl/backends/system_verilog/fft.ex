defmodule ExHdl.Backends.SystemVerilog.FFT do
  @moduledoc """
  SystemVerilog for `ExHdl.FFT`: a radix-2 SDF pipeline (one stage per
  FFT stage, the reference's butterflies and rounding) and an optional
  reorder buffer to natural order. See `ExHdl.FFT` for the interface and
  the architecture; this module only writes the text.

  Per stage `s` (`h = n / 2^(s+1)`):

    * input counter `c` (position in the symbol); bit `log2(h)` says
      first or second half of the current block, the bits above it are
      the block number (the twiddle ROM address, the ROM holds the
      twiddles in block order).
    * memory `am` (`h` words): first halves, written on arrival, read
      when the partner arrives.
    * butterfly pipeline: a, b, w registered (memory and ROM read), four
      products, their sums, the rounding shift, `a +- t`, halving and
      saturation (stage 0: no multiplication).
    * memory `bm` (`h` words): the differences, written as they leave
      the butterfly and read in the cycles after the block's last sum,
      one per cycle. The output register takes the sum when there is one,
      else the next difference.
  """

  import Bitwise

  alias ExHdl.Backends.SystemVerilog.Stream
  alias ExHdl.FFT

  @doc "Generates the module for `spec` (`%ExHdl.FFT{}`). Option: `:name`."
  def generate(%FFT{} = spec, opts \\ []) do
    name = Keyword.get(opts, :name, "fft#{spec.n}")
    b = spec.format.bits
    type = {:s, b}
    {fields, width} = Stream.fields([type, type])

    stages = for s <- 0..(spec.stages - 1), do: stage(spec, s)
    {reorder, out_v, out_d, out_last, reorder_latency} = output(spec)

    {re, im} = {"s_axis_tdata[#{b - 1}:0]", "s_axis_tdata[#{2 * b - 1}:#{b}]"}
    input = if spec.inverse, do: "{#{re}, #{im}}", else: "{#{im}, #{re}}"

    data =
      if spec.inverse,
        do: "{#{out_d}[#{b - 1}:0], #{out_d}[#{2 * b - 1}:#{b}]}",
        else: out_d

    data = if width > 2 * b, do: "{#{width - 2 * b}'d0, #{data}}", else: data

    mults = 4 * (spec.stages - 1)

    comment = [
      "#{name}: #{spec.n}-point #{if spec.inverse, do: "IFFT", else: "FFT"}, radix-2 SDF, " <>
        "#{spec.stages} stages, #{spec.shifts} halving, #{spec.order} order, #{mults} multipliers",
      "data q(#{b}, #{spec.format.frac}) #{spec.format.rounding}, " <>
        "twiddles q(#{spec.twiddle.bits}, #{spec.twiddle.frac})",
      "s_axis_tdata, m_axis_tdata: {im, re}, #{b} bits each"
    ]

    sdf_latency = stages |> Enum.map(& &1.latency) |> Enum.sum()

    source = [
      Stream.header(name, comment, width, width, frame: true),
      "  logic ce;\n",
      "  assign s_axis_tready = ce;\n",
      "  logic iv_0;\n",
      "  logic [#{2 * b - 1}:0] id_0;\n",
      "  assign iv_0 = s_axis_tvalid;\n",
      "  assign id_0 = #{input};\n",
      Enum.map(stages, & &1.code),
      reorder,
      Stream.out_buffer(data, width, out_v, last: out_last),
      Stream.footer()
    ]

    Stream.design(name, source, fields, fields, width, width,
      latency: sdf_latency + reorder_latency + 2,
      dsp: mults,
      frame: true
    )
  end

  # -- one SDF stage ------------------------------------------------------------------

  # Stages with at least this many words per half keep first halves and
  # differences in one memory.
  @share_min 256

  defp stage(%FFT{} = spec, s) do
    sb = spec.stages
    h = spec.n >>> (s + 1)
    m = 1 <<< s
    b = spec.format.bits
    w2 = 2 * b
    hb = max(Stream.clog2(h), 1)
    halve? = s >= sb - spec.shifts
    i = s

    # d: cycles from a partner's arrival to the write of its difference
    {bf_code, d} =
      if s == 0, do: butterfly0(spec, i, halve?), else: butterfly(spec, i, halve?, m)

    shared? = h >= @share_min and h > d

    v = %{i: i, h: h, hb: hb, w2: w2, d: d, sb: sb, s: s}

    code = [
      "\n  // stage #{s}: blocks of #{2 * h}, ",
      if(s == 0, do: "no twiddles", else: "#{m} twiddles"),
      if(halve?, do: ", halving", else: ""),
      if(shared?, do: ", one memory", else: ""),
      "\n",
      "  logic [#{sb - 1}:0] c_#{i};\n",
      "  logic sh_#{i};\n",
      "  assign sh_#{i} = c_#{i}[#{sb - 1 - s}];\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) c_#{i} <= '0;\n",
      "    else if (ce && iv_#{i}) c_#{i} <= c_#{i} + #{sb}'d1;\n",
      "  logic [#{w2 - 1}:0] a1_#{i}, b1_#{i};\n",
      "  logic v1_#{i};\n",
      "  always_ff @(posedge clk) if (ce) b1_#{i} <= id_#{i};\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) v1_#{i} <= 1'b0;\n",
      "    else if (ce) v1_#{i} <= iv_#{i} && sh_#{i};\n",
      if(shared?, do: shared_memory(v), else: two_memories(v)),
      bf_code
    ]

    # cycles from a symbol's last input to its last output of this stage
    %{code: code, latency: h + d + 1}
  end

  defp mem_addr(%{h: 1}, _var), do: "0"
  defp mem_addr(%{hb: hb}, var), do: "#{var}[#{hb - 1}:0]"

  # First halves in am (written on arrival), differences in bm (written as
  # they leave the butterfly, read in the cycles after the block's last sum).
  defp two_memories(%{i: i, h: h, hb: hb, w2: w2} = v) do
    next = i + 1

    [
      "  logic [#{w2 - 1}:0] am_#{i} [#{h}];\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce && iv_#{i} && !sh_#{i}) am_#{i}[#{mem_addr(v, "c_#{i}")}] <= id_#{i};\n",
      "  always_ff @(posedge clk) if (ce) a1_#{i} <= am_#{i}[#{mem_addr(v, "c_#{i}")}];\n",
      "  // sums leave at once, differences after the block\n",
      "  logic [#{w2 - 1}:0] bm_#{i} [#{h}];\n",
      "  logic [#{hb - 1}:0] cw_#{i}, e_#{i};\n",
      "  logic ph_#{i}, tv_#{i}, bv_#{i};\n",
      "  logic [#{w2 - 1}:0] top_#{i}, rd_#{i};\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) begin\n",
      "      cw_#{i} <= '0; e_#{i} <= '0; ph_#{i} <= 1'b0; tv_#{i} <= 1'b0; bv_#{i} <= 1'b0;\n",
      "    end else if (ce) begin\n",
      "      tv_#{i} <= bfv_#{i};\n",
      "      bv_#{i} <= ph_#{i};\n",
      if h == 1 do
        [
          "      if (bfv_#{i}) ph_#{i} <= 1'b1;\n",
          "      else if (ph_#{i}) ph_#{i} <= 1'b0;\n"
        ]
      else
        [
          "      if (bfv_#{i}) cw_#{i} <= cw_#{i} + #{hb}'d1;\n",
          "      if (bfv_#{i} && cw_#{i} == #{hb}'d#{h - 1}) ph_#{i} <= 1'b1;\n",
          "      else if (ph_#{i} && e_#{i} == #{hb}'d#{h - 1}) ph_#{i} <= 1'b0;\n",
          "      if (ph_#{i}) e_#{i} <= e_#{i} + #{hb}'d1;\n"
        ]
      end,
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      if (bfv_#{i}) bm_#{i}[#{mem_addr(v, "cw_#{i}")}] <= bfb_#{i};\n",
      "      rd_#{i} <= bm_#{i}[#{mem_addr(v, "e_#{i}")}];\n",
      "      top_#{i} <= bft_#{i};\n",
      "    end\n",
      "  logic iv_#{next};\n",
      "  logic [#{w2 - 1}:0] id_#{next};\n",
      "  assign iv_#{next} = tv_#{i} || bv_#{i};\n",
      "  assign id_#{next} = tv_#{i} ? top_#{i} : rd_#{i};\n"
    ]
  end

  # One memory of h words. A first half is written d cycles after it
  # arrives, a difference d cycles after its partner arrived, so the one
  # write port never sees both. The differences of a block are read in the
  # h cycles after its last partner arrived (the next block's first halves
  # come in meanwhile and overwrite them only later), and go out through
  # d registers, so they leave after the block's sums and before the next
  # block's. Needs h > d.
  defp shared_memory(%{i: i, h: h, hb: hb, w2: w2, d: d} = v) do
    next = i + 1

    [
      "  logic [#{w2 - 1}:0] mm_#{i} [#{h}];\n",
      "  logic [#{w2 - 1}:0] ad_#{i} [#{d}];\n",
      "  logic [#{hb - 1}:0] aa_#{i} [#{d}];\n",
      "  logic [#{d - 1}:0] av_#{i};\n",
      "  logic [#{hb - 1}:0] cw_#{i}, e_#{i};\n",
      "  logic pe_#{i}, tv_#{i};\n",
      "  logic [#{d}:0] ev_#{i};\n",
      "  logic [#{w2 - 1}:0] er_#{i} [#{d}];\n",
      "  logic [#{w2 - 1}:0] top_#{i};\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) begin\n",
      "      av_#{i} <= '0; ev_#{i} <= '0; cw_#{i} <= '0; e_#{i} <= '0; pe_#{i} <= 1'b0; tv_#{i} <= 1'b0;\n",
      "    end else if (ce) begin\n",
      "      av_#{i} <= {av_#{i}[#{d - 2}:0], iv_#{i} && !sh_#{i}};\n",
      "      ev_#{i} <= {ev_#{i}[#{d - 1}:0], pe_#{i}};\n",
      "      tv_#{i} <= bfv_#{i};\n",
      "      if (bfv_#{i}) cw_#{i} <= cw_#{i} + #{hb}'d1;\n",
      "      if (iv_#{i} && sh_#{i} && c_#{i}[#{hb - 1}:0] == #{hb}'d#{h - 1}) pe_#{i} <= 1'b1;\n",
      "      else if (pe_#{i} && e_#{i} == #{hb}'d#{h - 1}) pe_#{i} <= 1'b0;\n",
      "      if (pe_#{i}) e_#{i} <= e_#{i} + #{hb}'d1;\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      ad_#{i}[0] <= id_#{i};\n",
      "      aa_#{i}[0] <= #{mem_addr(v, "c_#{i}")};\n",
      "      for (int k = 1; k < #{d}; k++) begin\n",
      "        ad_#{i}[k] <= ad_#{i}[k - 1];\n",
      "        aa_#{i}[k] <= aa_#{i}[k - 1];\n",
      "      end\n",
      "      if (av_#{i}[#{d - 1}]) mm_#{i}[aa_#{i}[#{d - 1}]] <= ad_#{i}[#{d - 1}];\n",
      "      else if (bfv_#{i}) mm_#{i}[cw_#{i}] <= bfb_#{i};\n",
      "      a1_#{i} <= mm_#{i}[pe_#{i} ? e_#{i} : #{mem_addr(v, "c_#{i}")}];\n",
      "      er_#{i}[0] <= a1_#{i};\n",
      "      for (int k = 1; k < #{d}; k++) er_#{i}[k] <= er_#{i}[k - 1];\n",
      "      top_#{i} <= bft_#{i};\n",
      "    end\n",
      "  logic iv_#{next};\n",
      "  logic [#{w2 - 1}:0] id_#{next};\n",
      "  assign iv_#{next} = tv_#{i} || ev_#{i}[#{d}];\n",
      "  assign id_#{next} = tv_#{i} ? top_#{i} : er_#{i}[#{d - 1}];\n"
    ]
  end

  # Stage 0: w = 1, {a + b, a - b}; returns the code and its pipeline length.
  defp butterfly0(spec, i, halve?) do
    b = spec.format.bits
    sw = b + 2

    code = [
      "  logic signed [#{sw - 1}:0] str_#{i}, sti_#{i}, sbr_#{i}, sbi_#{i};\n",
      "  logic v2_#{i};\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      str_#{i} <= #{sw}'(#{re("a1_#{i}", b)}) + #{sw}'(#{re("b1_#{i}", b)});\n",
      "      sti_#{i} <= #{sw}'(#{im("a1_#{i}", b)}) + #{sw}'(#{im("b1_#{i}", b)});\n",
      "      sbr_#{i} <= #{sw}'(#{re("a1_#{i}", b)}) - #{sw}'(#{re("b1_#{i}", b)});\n",
      "      sbi_#{i} <= #{sw}'(#{im("a1_#{i}", b)}) - #{sw}'(#{im("b1_#{i}", b)});\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) v2_#{i} <= 1'b0;\n",
      "    else if (ce) v2_#{i} <= v1_#{i};\n",
      finish(spec, i, sw, halve?, "v2_#{i}")
    ]

    {code, 3}
  end

  # Stage s > 0: t = round(b * w), {a + t, a - t}.
  defp butterfly(spec, i, halve?, m) do
    b = spec.format.bits
    tb = spec.twiddle.bits
    ft = spec.twiddle.frac
    pw = b + tb
    tw = pw + 1
    rw = tw - ft + 1
    sw = max(rw, b) + 2
    s = i
    sb = spec.stages

    rom =
      spec
      |> FFT.twiddles(s)
      |> List.to_tuple()

    # ROM in block order: block r of the stage is row bitrev(r)
    entries =
      for r <- 0..(m - 1) do
        {wr, wi} = elem(rom, FFT.bitrev(r, s))
        "      tw_#{i}[#{r}] = {#{lit_u(wi, tb)}, #{lit_u(wr, tb)}};\n"
      end

    radd = "c_#{i}[#{sb - 1}:#{sb - s}]"
    rnd = if ft > 0 and spec.format.rounding == :nearest, do: 1 <<< (ft - 1), else: 0
    shift = fn x -> if ft == 0, do: x, else: "(#{x} + #{tw}'sd#{rnd}) >>> #{ft}" end

    code = [
      "  logic [#{2 * tb - 1}:0] tw_#{i} [#{m}];\n",
      "  initial begin\n",
      entries,
      "  end\n",
      "  logic [#{2 * tb - 1}:0] w1_#{i};\n",
      "  always_ff @(posedge clk) if (ce) w1_#{i} <= tw_#{i}[#{radd}];\n",
      "  logic signed [#{pw - 1}:0] prr_#{i}, pii_#{i}, pri_#{i}, pir_#{i};\n",
      "  logic signed [#{tw - 1}:0] tr_#{i}, ti_#{i};\n",
      "  logic signed [#{rw - 1}:0] rr_#{i}, ri_#{i};\n",
      "  logic signed [#{sw - 1}:0] str_#{i}, sti_#{i}, sbr_#{i}, sbi_#{i};\n",
      "  logic [#{2 * b - 1}:0] a2_#{i}, a3_#{i}, a4_#{i};\n",
      "  logic v2_#{i}, v3_#{i}, v4_#{i}, v5_#{i};\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      prr_#{i} <= #{pw}'(#{re("b1_#{i}", b)}) * #{pw}'(#{re("w1_#{i}", tb)});\n",
      "      pii_#{i} <= #{pw}'(#{im("b1_#{i}", b)}) * #{pw}'(#{im("w1_#{i}", tb)});\n",
      "      pri_#{i} <= #{pw}'(#{re("b1_#{i}", b)}) * #{pw}'(#{im("w1_#{i}", tb)});\n",
      "      pir_#{i} <= #{pw}'(#{im("b1_#{i}", b)}) * #{pw}'(#{re("w1_#{i}", tb)});\n",
      "      a2_#{i} <= a1_#{i};\n",
      "      tr_#{i} <= #{tw}'(prr_#{i}) - #{tw}'(pii_#{i});\n",
      "      ti_#{i} <= #{tw}'(pri_#{i}) + #{tw}'(pir_#{i});\n",
      "      a3_#{i} <= a2_#{i};\n",
      "      rr_#{i} <= #{rw}'(#{shift.("tr_#{i}")});\n",
      "      ri_#{i} <= #{rw}'(#{shift.("ti_#{i}")});\n",
      "      a4_#{i} <= a3_#{i};\n",
      "      str_#{i} <= #{sw}'(#{re("a4_#{i}", b)}) + #{sw}'(rr_#{i});\n",
      "      sti_#{i} <= #{sw}'(#{im("a4_#{i}", b)}) + #{sw}'(ri_#{i});\n",
      "      sbr_#{i} <= #{sw}'(#{re("a4_#{i}", b)}) - #{sw}'(rr_#{i});\n",
      "      sbi_#{i} <= #{sw}'(#{im("a4_#{i}", b)}) - #{sw}'(ri_#{i});\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) begin\n",
      "      v2_#{i} <= 1'b0; v3_#{i} <= 1'b0; v4_#{i} <= 1'b0; v5_#{i} <= 1'b0;\n",
      "    end else if (ce) begin\n",
      "      v2_#{i} <= v1_#{i}; v3_#{i} <= v2_#{i}; v4_#{i} <= v3_#{i}; v5_#{i} <= v4_#{i};\n",
      "    end\n",
      finish(spec, i, sw, halve?, "v5_#{i}")
    ]

    {code, 6}
  end

  # halving (rounded per format) and saturation of the sums: bft/bfb, bfv
  defp finish(spec, i, sw, halve?, v) do
    b = spec.format.bits
    lo = -(1 <<< (b - 1))
    hi = (1 <<< (b - 1)) - 1
    one = if spec.format.rounding == :nearest, do: 1, else: 0

    h = fn x -> if halve?, do: "((#{x} + #{sw}'sd#{one}) >>> 1)", else: x end

    sat = fn x ->
      "(#{h.(x)} > #{Stream.lit(hi, sw)} ? #{b}'(#{hi}) : #{h.(x)} < #{Stream.lit(lo, sw)} ? #{b}'(#{lit_u(lo, b)}) : #{b}'(#{h.(x)}))"
    end

    [
      "  logic [#{2 * b - 1}:0] bft_#{i}, bfb_#{i};\n",
      "  logic bfv_#{i};\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      bft_#{i} <= {#{sat.("sti_#{i}")}, #{sat.("str_#{i}")}};\n",
      "      bfb_#{i} <= {#{sat.("sbi_#{i}")}, #{sat.("sbr_#{i}")}};\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) bfv_#{i} <= 1'b0;\n",
      "    else if (ce) bfv_#{i} <= #{v};\n"
    ]
  end

  # -- output order ---------------------------------------------------------------------

  # Returns {code, push, data, last, latency}.
  defp output(%FFT{order: :bit_reversed} = spec) do
    i = spec.stages
    sb = spec.stages

    code = [
      "\n  // bit-reversed order: output p is bin bitrev(p)\n",
      "  logic [#{sb - 1}:0] p_out;\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) p_out <= '0;\n",
      "    else if (ce && iv_#{i}) p_out <= p_out + #{sb}'d1;\n"
    ]

    {code, "iv_#{i}", "id_#{i}", "p_out == #{sb}'d#{spec.n - 1}", 0}
  end

  defp output(%FFT{order: :natural} = spec) do
    i = spec.stages
    sb = spec.stages
    n = spec.n
    w2 = 2 * spec.format.bits
    rev = fn var -> "{" <> Enum.map_join(0..(sb - 1), ", ", &"#{var}[#{&1}]") <> "}" end

    code = [
      "\n  // reorder to natural order: one memory, frames alternate between\n",
      "  // natural and bit-reversed write addresses, read the other way\n",
      "  logic [#{w2 - 1}:0] ro [#{n}];\n",
      "  logic [#{sb - 1}:0] wp, rq, wa, ra;\n",
      "  logic wpar, rpar, ract, rgo, rv, rlast, done;\n",
      "  logic [1:0] pend;\n",
      "  logic [#{w2 - 1}:0] rdata;\n",
      "  assign wa = wpar ? #{rev.("wp")} : wp;\n",
      "  assign ra = rpar ? rq : #{rev.("rq")};\n",
      "  assign done = iv_#{i} && wp == #{sb}'d#{n - 1};\n",
      "  assign rgo = ract || pend != 2'd0;\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      if (iv_#{i}) ro[wa] <= id_#{i};\n",
      "      rdata <= ro[ra];\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) begin\n",
      "      wp <= '0; wpar <= 1'b0; rq <= '0; rpar <= 1'b0; ract <= 1'b0;\n",
      "      rv <= 1'b0; rlast <= 1'b0; pend <= 2'd0;\n",
      "    end else if (ce) begin\n",
      "      if (iv_#{i}) begin\n",
      "        wp <= wp + #{sb}'d1;\n",
      "        if (done) wpar <= !wpar;\n",
      "      end\n",
      "      rv <= rgo;\n",
      "      rlast <= rgo && rq == #{sb}'d#{n - 1};\n",
      "      if (rgo) begin\n",
      "        rq <= rq + #{sb}'d1;\n",
      "        if (rq == #{sb}'d#{n - 1}) rpar <= !rpar;\n",
      "      end\n",
      "      ract <= rgo && rq != #{sb}'d#{n - 1};\n",
      "      pend <= pend + 2'(done) - 2'(!ract && pend != 2'd0);\n",
      "    end\n"
    ]

    {code, "rv", "rdata", "rlast", n + 2}
  end

  # -- helpers --------------------------------------------------------------------------

  defp re(word, b), do: "$signed(#{word}[#{b - 1}:0])"
  defp im(word, b), do: "$signed(#{word}[#{2 * b - 1}:#{b}])"

  defp lit_u(v, b) when v < 0, do: "#{b}'d#{(1 <<< b) + v}"
  defp lit_u(v, b), do: "#{b}'d#{v}"
end
