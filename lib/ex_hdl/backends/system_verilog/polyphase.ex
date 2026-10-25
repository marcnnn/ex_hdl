defmodule ExHdl.Backends.SystemVerilog.Polyphase do
  @moduledoc """
  Streaming modules for linear multirate filters (`ExHdl.IR.Multirate`):
  decimating and interpolating FIRs, rational resamplers, polyphase
  filter banks. Bit-exact: products and sums are exact integers, the one
  rounding (shift with the kernel's rounding constant) and the saturation
  come at the end, as in the Nx reference.

  Two structures:

    * `:polyphase_decimator` (one output per period, `l = 1`): one input
      per cycle, `ceil(k / d)` multipliers per term. Multiplier `j` holds
      taps `j*d .. j*d + d - 1` and accumulates `d` products per period
      (coefficient from a `d`-entry ROM indexed by the input's phase); at
      the start of a period its accumulator takes the partial sum of
      multiplier `j + 1` instead of its own, so the partial sums move down
      the chain once per period (a transposed FIR whose taps are time
      shared `d` times). No delay line: the history lives in the
      accumulators.
    * `:direct` (everything else): a window register of the last `k`
      inputs and `k` multipliers per term with coefficients from an
      `l`-entry ROM indexed by the output phase, summed by a pipelined
      adder tree. One input per cycle when `d >= l` (decimating
      resamplers), one output per cycle otherwise (interpolators). A small
      sequencer decides per cycle whether the next output's newest input
      is in the window (emit) or one more input is needed (accept).

  A term is one input component times one tap set: a real filter has one,
  complex data with real taps two, complex taps on complex data four.
  Taps that are zero in every phase have no multiplier. Products and
  accumulators have the widths their tap sums prove.

  The module streams AXI4-Stream like the stream kernels (tdata fields per
  item component, clock enable from a small output buffer, no
  combinational ready path).
  """

  import Bitwise

  alias ExHdl.Backends.SystemVerilog.Stream
  alias ExHdl.IR.Multirate

  @doc """
  Generates the module. Options: `:name`, `:structure` (`:auto`,
  `:direct`). Returns a `%ExHdl.Backends.SystemVerilog.Scan.Design{}`
  with `dsp` the multiplier count.
  """
  def generate(%Multirate{} = ir, opts \\ []) do
    name = Keyword.get(opts, :name, "multirate")
    {in_fields, in_width} = Stream.fields(Enum.map(ir.inputs, & &1.type))
    {out_fields, out_width} = Stream.fields(Enum.map(ir.outputs, & &1.type))

    structure =
      case Keyword.get(opts, :structure, :auto) do
        :auto -> if decimator?(ir), do: :polyphase_decimator, else: :direct
        :direct -> :direct
        :polyphase_decimator -> if decimator?(ir), do: :polyphase_decimator, else: :direct
      end

    {body, latency, mults} =
      case structure do
        :polyphase_decimator -> decimator(ir, in_fields, out_fields)
        :direct -> direct(ir, in_fields, out_fields)
      end

    comment = [
      "#{name}: #{ir.d} inputs -> #{ir.l} outputs, #{ir.k} taps per output, #{structure}, #{mults} multipliers",
      "s_axis_tdata: " <> Enum.map_join(in_fields, ", ", &"#{inspect(&1.type)} @#{&1.offset}"),
      "m_axis_tdata: " <> Enum.map_join(out_fields, ", ", &"#{inspect(&1.type)} @#{&1.offset}")
    ]

    source = [Stream.header(name, comment, in_width, out_width), body, Stream.footer()]

    Stream.design(name, source, in_fields, out_fields, in_width, out_width,
      latency: latency,
      dsp: mults
    )
    |> Map.put(:structure, structure)
  end

  defp decimator?(%Multirate{l: 1, init: init}),
    do: Enum.all?(List.flatten(init), &(&1 == 0))

  defp decimator?(_), do: false

  # -- polyphase decimator ------------------------------------------------------------

  defp decimator(ir, in_fields, out_fields) do
    d = ir.d
    [a] = ir.anchors
    m = div(ir.k + d - 1, d)
    pw = Stream.clog2(d)

    # terms with their per-multiplier coefficient ROMs (index: phase s)
    terms =
      for {o, oi} <- Enum.with_index(ir.outputs),
          {t, ti} <- Enum.with_index(o.terms) do
        [taps] = t.taps
        f = Enum.at(in_fields, t.input)
        tap = fn i -> if i < ir.k, do: Enum.at(taps, i), else: 0 end

        roms =
          for j <- 0..(m - 1) do
            for s <- 0..(d - 1), do: tap.(j * d + d - 1 - s)
          end

        %{
          out: oi,
          id: "t#{oi}_#{ti}",
          field: f,
          xb: Stream.field_bits(f),
          roms: roms,
          bound:
            Enum.sum(Enum.map(taps, &abs/1)) * max(abs(f_lo(ir, t.input)), abs(f_hi(ir, t.input)))
        }
      end

    decl_inputs =
      for {f, c} <- Enum.with_index(in_fields) do
        b = Stream.field_bits(f)
        "  logic signed [#{b - 1}:0] x0_#{c}, x1_#{c};\n"
      end

    term_code =
      for t <- terms do
        aw = Stream.signed_bits(-t.bound, t.bound)

        cw =
          t.roms |> List.flatten() |> then(&Stream.signed_bits(Enum.min(&1), Enum.max(&1)))

        pw2 = t.xb + cw

        mults =
          t.roms
          |> Enum.with_index()
          |> Enum.map(fn {rom, j} ->
            c = "#{t.id}_#{j}"
            x = "x1_#{t.field.index}"

            if Enum.all?(rom, &(&1 == 0)) do
              [
                "  logic signed [#{aw - 1}:0] acc_#{c};\n",
                "  logic signed [#{pw2 - 1}:0] p_#{c};\n",
                "  assign p_#{c} = '0;\n"
              ]
            else
              [
                "  logic signed [#{cw - 1}:0] k_#{c};\n",
                "  logic signed [#{pw2 - 1}:0] p_#{c};\n",
                "  logic signed [#{aw - 1}:0] acc_#{c};\n",
                rom_logic("k_#{c}", "s0", rom, cw, pw),
                "  always_ff @(posedge clk) if (ce) p_#{c} <= #{x} * k_#{c};\n"
              ]
            end
          end)

        accs =
          for j <- 0..(m - 1) do
            c = "#{t.id}_#{j}"
            chain = if j == m - 1, do: "#{aw}'sd0", else: "acc_#{t.id}_#{j + 1}"

            [
              "  always_ff @(posedge clk)\n",
              "    if (!rst_n) acc_#{c} <= '0;\n",
              "    else if (ce && v2) acc_#{c} <= #{aw}'(p_#{c}) + (s2 == #{pw}'d0 ? #{chain} : acc_#{c});\n"
            ]
          end

        [mults, accs]
      end

    # sum of the terms of every output component, rounding and saturation
    {sums, sum_bits} =
      out_fields
      |> Enum.zip(ir.outputs)
      |> Enum.with_index()
      |> Enum.map(fn {{_f, o}, oi} ->
        mine = Enum.filter(terms, &(&1.out == oi))
        bound = Enum.sum(Enum.map(mine, & &1.bound)) + abs(o.const)
        sb = Stream.signed_bits(-bound, bound)

        parts =
          Enum.map(mine, fn t -> "#{sb}'(acc_#{t.id}_0)" end) ++ ["#{Stream.lit(o.const, sb)}"]

        {"  always_ff @(posedge clk) if (ce) sum_#{oi} <= " <> Enum.join(parts, " + ") <> ";\n",
         sb}
      end)
      |> Enum.unzip()

    {round_code, data} = finish(ir, out_fields, sum_bits)

    body = [
      "  logic ce;\n",
      decl_inputs,
      "  logic [#{pw - 1}:0] ph, s0, s1, s2;\n",
      "  logic v0, v1, v2, v3, v4, v5;\n",
      Enum.with_index(sum_bits, fn b, oi -> "  logic signed [#{b - 1}:0] sum_#{oi};\n" end),
      "  assign s_axis_tready = ce;\n",
      "  // input phase within the period; the period ends with phase #{d - 1}\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) ph <= #{pw}'d#{rem(d - 1 - a + d, d)};\n",
      "    else if (ce && s_axis_tvalid) ph <= ph == #{pw}'d#{d - 1} ? '0 : ph + #{pw}'d1;\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) begin\n",
      "      v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0; v5 <= 1'b0;\n",
      "    end else if (ce) begin\n",
      "      v0 <= s_axis_tvalid;\n",
      "      v1 <= v0;\n",
      "      v2 <= v1;\n",
      "      v3 <= v2 && s2 == #{pw}'d#{d - 1};\n",
      "      v4 <= v3;\n",
      "      v5 <= v4;\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (ce) begin\n",
      "      s0 <= ph;\n",
      "      s1 <= s0;\n",
      "      s2 <= s1;\n",
      for {f, c} <- Enum.with_index(in_fields) do
        "      x0_#{c} <= #{Stream.field("s_axis_tdata", f)};\n      x1_#{c} <= x0_#{c};\n"
      end,
      "    end\n",
      term_code,
      sums,
      round_code,
      Stream.out_buffer(data, out_width(out_fields), "v5")
    ]

    {body, 7, count_mults(terms)}
  end

  defp count_mults(terms),
    do:
      terms
      |> Enum.map(fn t -> Enum.count(t.roms, &Enum.any?(&1, fn c -> c != 0 end)) end)
      |> Enum.sum()

  # -- direct form --------------------------------------------------------------------

  defp direct(ir, in_fields, out_fields) do
    %Multirate{d: d, l: l, k: k, anchors: anchors} = ir
    mw = Stream.clog2(l)
    deltas = for m <- 0..(l - 1), do: delta(anchors, m, d)
    ew = Stream.signed_bits(-1, Enum.max([d + 1 | deltas]))

    terms =
      for {o, oi} <- Enum.with_index(ir.outputs),
          {t, ti} <- Enum.with_index(o.terms) do
        f = Enum.at(in_fields, t.input)
        r = max(abs(f_lo(ir, t.input)), abs(f_hi(ir, t.input)))

        bound =
          t.taps |> Enum.map(fn taps -> Enum.sum(Enum.map(taps, &abs/1)) end) |> Enum.max()

        # tap j over the phases: ROM of l entries
        roms = for j <- 0..(k - 1), do: Enum.map(t.taps, &Enum.at(&1, j))

        %{
          out: oi,
          id: "t#{oi}_#{ti}",
          field: f,
          xb: Stream.field_bits(f),
          roms: roms,
          bound: bound * r
        }
      end

    window =
      for {f, c} <- Enum.with_index(in_fields) do
        b = Stream.field_bits(f)
        init = Enum.at(ir.init, c)

        [
          "  logic signed [#{b - 1}:0] win_#{c} [#{k}];\n",
          "  logic signed [#{b - 1}:0] wn_#{c} [#{k}];\n",
          "  logic signed [#{b - 1}:0] a1_#{c} [#{k}];\n",
          "  logic signed [#{b - 1}:0] a2_#{c} [#{k}];\n",
          "  always_comb begin\n",
          "    wn_#{c}[0] = accept ? #{Stream.field("s_axis_tdata", f)} : win_#{c}[0];\n",
          "    for (int j = 1; j < #{k}; j++) wn_#{c}[j] = accept ? win_#{c}[j - 1] : win_#{c}[j];\n",
          "  end\n",
          "  always_ff @(posedge clk)\n",
          "    if (!rst_n) begin\n",
          for {v, j} <- Enum.with_index(init) do
            "      win_#{c}[#{j}] <= #{Stream.lit(v, b)};\n"
          end,
          "    end else if (ce) begin\n",
          "      for (int j = 0; j < #{k}; j++) win_#{c}[j] <= wn_#{c}[j];\n",
          "    end\n",
          "  always_ff @(posedge clk)\n",
          "    if (ce) begin\n",
          "      for (int j = 0; j < #{k}; j++) begin\n",
          "        a1_#{c}[j] <= wn_#{c}[j];\n",
          "        a2_#{c}[j] <= a1_#{c}[j];\n",
          "      end\n",
          "    end\n"
        ]
      end

    # products, then per output component a pipelined adder tree
    {products, by_out} =
      terms
      |> Enum.map(fn t ->
        cw = t.roms |> List.flatten() |> then(&Stream.signed_bits(Enum.min(&1), Enum.max(&1)))
        pb = t.xb + cw

        {code, names} =
          t.roms
          |> Enum.with_index()
          |> Enum.reject(fn {rom, _} -> Enum.all?(rom, &(&1 == 0)) end)
          |> Enum.map(fn {rom, j} ->
            c = "#{t.id}_#{j}"

            {[
               "  logic signed [#{cw - 1}:0] k_#{c};\n",
               "  logic signed [#{pb - 1}:0] p_#{c};\n",
               rom_logic("k_#{c}", "m1", rom, cw, mw),
               "  always_ff @(posedge clk) if (ce) p_#{c} <= a2_#{t.field.index}[#{j}] * k_#{c};\n"
             ], {"p_#{c}", pb}}
          end)
          |> Enum.unzip()

        {code, {t.out, names}}
      end)
      |> Enum.unzip()

    {trees, sum_bits, tree_depth} =
      out_fields
      |> Enum.zip(ir.outputs)
      |> Enum.with_index()
      |> Enum.map(fn {{_f, o}, oi} ->
        mine = Enum.filter(terms, &(&1.out == oi))
        bound = Enum.sum(Enum.map(mine, & &1.bound)) + abs(o.const)
        sb = Stream.signed_bits(-bound, bound)
        names = for {^oi, ns} <- by_out, n <- ns, do: n
        const = {Stream.lit(o.const, sb), sb}
        adder_tree("sum_#{oi}", names ++ [const], sb)
      end)
      |> unzip3()

    depth = Enum.max(tree_depth)

    # pad shallower trees so all components arrive together
    trees =
      Enum.zip([trees, tree_depth, sum_bits])
      |> Enum.with_index()
      |> Enum.map(fn {{code, td, sb}, oi} ->
        [code, delay("sum_#{oi}", "sum_#{oi}_d", sb, depth - td)]
      end)

    {round_code, data} = finish(ir, out_fields, sum_bits, fn oi -> "sum_#{oi}_d" end)

    # valid: emit -> v1 (a1, m1) -> v2 (k, a2) -> v3 (p) -> tree -> v_sum -> round -> push
    vn = 3 + depth

    body = [
      "  logic ce, accept, emit;\n",
      "  logic signed [#{ew - 1}:0] e, e_in;\n",
      "  logic [#{mw - 1}:0] m, m1;\n",
      "  logic [#{vn}:0] v;\n",
      "  // e: inputs still needed before output m can be computed\n",
      "  assign s_axis_tready = ce && e > #{ew}'sd0;\n",
      "  assign accept = s_axis_tvalid && s_axis_tready;\n",
      "  assign e_in = accept ? e - #{ew}'sd1 : e;\n",
      "  assign emit = ce && e_in == #{ew}'sd0;\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) begin\n",
      "      e <= #{Stream.lit(hd(anchors) + 1, ew)};\n",
      "      m <= '0;\n",
      "    end else if (ce) begin\n",
      "      if (emit) begin\n",
      "        case (m)\n",
      for mm <- 0..(l - 1) do
        "          #{mw}'d#{mm}: begin e <= e_in + #{Stream.lit(Enum.at(deltas, mm), ew)}; m <= #{mw}'d#{rem(mm + 1, l)}; end\n"
      end,
      "          default: begin e <= e_in; m <= m; end\n",
      "        endcase\n",
      "      end else begin\n",
      "        e <= e_in;\n",
      "      end\n",
      "    end\n",
      "  always_ff @(posedge clk)\n",
      "    if (!rst_n) v <= '0;\n",
      "    else if (ce) v <= {v[#{vn - 1}:0], emit};\n",
      "  always_ff @(posedge clk) if (ce) m1 <= m;\n",
      window,
      products,
      trees,
      round_code,
      Stream.out_buffer(data, out_width(out_fields), "v[#{vn}]")
    ]

    {body, vn + 2, count_direct(terms)}
  end

  defp count_direct(terms),
    do:
      terms
      |> Enum.map(fn t -> Enum.count(t.roms, &Enum.any?(&1, fn c -> c != 0 end)) end)
      |> Enum.sum()

  defp delta(anchors, m, d) do
    l = length(anchors)

    if m < l - 1,
      do: Enum.at(anchors, m + 1) - Enum.at(anchors, m),
      else: d + hd(anchors) - Enum.at(anchors, l - 1)
  end

  defp unzip3(list),
    do: {Enum.map(list, &elem(&1, 0)), Enum.map(list, &elem(&1, 1)), Enum.map(list, &elem(&1, 2))}

  # Registered binary adder tree over `{name, bits}` operands (strings with
  # the operand width); returns {code, result bits, depth}. The constant
  # joins the first level.
  defp adder_tree(out, operands, bits) do
    level(out, operands, bits, 0, [])
  end

  defp level(out, [{single, _}], bits, depth, code) when depth > 0 do
    {[code, "  logic signed [#{bits - 1}:0] #{out};\n  assign #{out} = #{single};\n"], bits,
     depth}
  end

  defp level(out, operands, bits, depth, code) do
    pairs = Enum.chunk_every(operands, 2)

    {next, new_code} =
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {pair, i} ->
        n = "#{out}_l#{depth}_#{i}"
        expr = Enum.map_join(pair, " + ", fn {x, _} -> "#{bits}'(#{x})" end)

        {{n, bits},
         [
           "  logic signed [#{bits - 1}:0] #{n};\n",
           "  always_ff @(posedge clk) if (ce) #{n} <= #{expr};\n"
         ]}
      end)
      |> Enum.unzip()

    level(out, next, bits, depth + 1, [code, new_code])
  end

  defp delay(from, to, bits, 0),
    do: ["  logic signed [#{bits - 1}:0] #{to};\n  assign #{to} = #{from};\n"]

  defp delay(from, to, bits, n) do
    [
      "  logic signed [#{bits - 1}:0] #{to}_p [#{n}];\n",
      "  always_ff @(posedge clk) if (ce) begin\n",
      "    #{to}_p[0] <= #{from};\n",
      for(i <- 1..(n - 1)//1, do: "    #{to}_p[#{i}] <= #{to}_p[#{i - 1}];\n"),
      "  end\n",
      "  logic signed [#{bits - 1}:0] #{to};\n",
      "  assign #{to} = #{to}_p[#{n - 1}];\n"
    ]
  end

  # -- shared ---------------------------------------------------------------------------

  # Coefficient register loaded from a constant ROM at `index` (one entry: a constant).
  defp rom_logic(reg, _index, [c], cw, _iw),
    do: "  always_ff @(posedge clk) if (ce) #{reg} <= #{Stream.lit(c, cw)};\n"

  defp rom_logic(reg, index, rom, cw, iw) do
    [
      "  always_ff @(posedge clk)\n",
      "    if (ce)\n",
      "      case (#{index})\n",
      rom
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> "        #{iw}'d#{i}: #{reg} <= #{Stream.lit(c, cw)};\n" end),
      "        default: #{reg} <= '0;\n",
      "      endcase\n"
    ]
  end

  # Rounding shift and saturation per output component, one register stage.
  defp finish(ir, out_fields, sum_bits, src \\ fn oi -> "sum_#{oi}" end) do
    code =
      for {{f, o}, oi} <- Enum.with_index(Enum.zip(out_fields, ir.outputs)) do
        sb = Enum.at(sum_bits, oi)
        b = f.bits
        sh = "sh_#{oi}"

        [
          "  logic signed [#{sb - 1}:0] #{sh};\n",
          "  logic [#{b - 1}:0] y_#{oi};\n",
          "  assign #{sh} = #{src.(oi)} >>> #{o.shift};\n",
          "  always_ff @(posedge clk)\n",
          "    if (ce) y_#{oi} <= #{sh} > #{Stream.lit(o.hi, sb)} ? #{b}'(#{o.hi}) : #{sh} < #{Stream.lit(o.lo, sb)} ? #{b}'(#{lit_u(o.lo, b)}) : #{b}'(#{sh});\n"
        ]
      end

    data =
      "{" <>
        (0..(length(out_fields) - 1) |> Enum.reverse() |> Enum.map_join(", ", &"y_#{&1}")) <> "}"

    pad = out_width(out_fields) - Enum.sum(Enum.map(out_fields, & &1.bits))
    data = if pad > 0, do: "{#{pad}'d0, #{String.slice(data, 1..-2//1)}}", else: data
    {code, data}
  end

  defp lit_u(v, b) when v < 0, do: (1 <<< b) + v
  defp lit_u(v, _b), do: v

  defp out_width(fields), do: Stream.byte_align(Enum.sum(Enum.map(fields, & &1.bits)))

  defp f_lo(ir, c), do: Enum.at(ir.inputs, c).lo
  defp f_hi(ir, c), do: Enum.at(ir.inputs, c).hi
end
