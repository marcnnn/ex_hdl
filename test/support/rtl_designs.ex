defmodule ExHdl.Test.RTLDesigns do
  @moduledoc false
  # Designs for the RTL tests that do not belong in the library.
  use ExHdl.RTL

  alias ExHdl.RTL.CDC

  @doc """
  Asynchronous FIFO, first-word fall-through: dual-clock memory with an
  asynchronous read port, Gray pointers through `CDC.sync_ff`. Shows the
  primitives are enough for ex_hdl_cores' FIFOs.
  """
  def async_fifo(width \\ 8, aw \\ 3) do
    module "async_fifo_#{width}x#{aw}" do
      domain(:wr, clock: :clk_wr, reset: :rst_wr_n)
      domain(:rd, clock: :clk_rd, reset: :rst_rd_n)
      wr_en = input(:wr_en, 1, domain: :wr)
      wr_data = input(:wr_data, width, domain: :wr)
      full = output(:full, 1)
      rd_en = input(:rd_en, 1, domain: :rd)
      rd_data = output(:rd_data, width)
      empty = output(:empty, 1)

      wptr = reg(:wptr, aw + 1, domain: :wr)
      rptr = reg(:rptr, aw + 1, domain: :rd)
      wgray = reg(:wgray, aw + 1, domain: :wr)
      rgray = reg(:rgray, aw + 1, domain: :rd)

      w2r = instance(:w2r, CDC.sync_ff(width: aw + 1), domains: [dst: :rd])
      r2w = instance(:r2w, CDC.sync_ff(width: aw + 1), domains: [dst: :wr])
      w2r.d <~ wgray
      r2w.d <~ rgray

      mem = memory(:mem, width: width, depth: Bitwise.bsl(1, aw), style: :distributed)
      push = wire(:push, wr_en and not full)
      pop = wire(:pop, rd_en and not empty)
      write_port(mem, domain: :wr, addr: wptr[0..(aw - 1)], data: wr_data, en: push)
      rd_data <~ read_port(mem, kind: :async, addr: rptr[0..(aw - 1)])

      wnext = wire(:wnext, add_wrap(wptr, push))
      rnext = wire(:rnext, add_wrap(rptr, pop))

      sync :wr do
        wptr <~ wnext
        wgray <~ CDC.gray(wnext)
      end

      sync :rd do
        rptr <~ rnext
        rgray <~ CDC.gray(rnext)
      end

      top = cat([~~~r2w.q[(aw - 1)..aw], r2w.q[0..(aw - 2)]])
      full <~ (wgray == top)
      empty <~ (rgray == w2r.q)
    end
  end

  @doc "True dual-port RAM, one port per clock domain."
  def tdp_ram do
    module "tdp_ram" do
      domain(:a, clock: :clk_a, reset: nil)
      domain(:b, clock: :clk_b, reset: nil)
      mem = memory(:mem, width: 16, depth: 256, style: :block)

      for p <- [:a, :b] do
        we = input(:"#{p}_we", 1, domain: p)
        addr = input(:"#{p}_addr", 8, domain: p)
        wdata = input(:"#{p}_wdata", 16, domain: p)
        rdata = output(:"#{p}_rdata", 16)
        write_port(mem, domain: p, addr: addr, data: wdata, en: we)
        rdata <~ read_port(mem, domain: p, addr: addr)
      end
    end
  end

  defmodule DelayModel do
    @moduledoc false
    @behaviour ExHdl.RTL.Model
    def init(params), do: List.duplicate(0, Keyword.fetch!(params, :DEPTH))
    def outputs(state, _inputs), do: %{q: List.last(state)}
    def clock(:sys, state, %{d: d}), do: [d | Enum.drop(state, -1)]
  end

  @doc "A black box shift register with an Elixir model and a hand-written SV source."
  def delay_box(depth \\ 3) do
    src = """
    module delay_line #(parameter int DEPTH = 3) (
      input  logic       clk,
      input  logic [7:0] d,
      output logic [7:0] q
    );
      logic [7:0] r [DEPTH];
      always_ff @(posedge clk) begin
        r[0] <= d;
        for (int i = 1; i < DEPTH; i++) r[i] <= r[i-1];
      end
      assign q = r[DEPTH-1];
    endmodule
    """

    black_box "delay_line",
      params: [DEPTH: depth],
      sources: %{"delay_line.sv" => src},
      model: DelayModel do
      domain(:sys, reset: nil)
      input(:d, 8)
      output(:q, 8, comb_from: :none)
    end
  end

  @doc "Wraps the delay box: q = delayed d + 1."
  def delay_top(depth \\ 3) do
    module "delay_top_#{depth}" do
      d = input(:d, 8)
      q = output(:q, 8)
      u = instance(:u, delay_box(depth), params: [DEPTH: depth], connect: [d: d])
      q <~ add_wrap(u.q, 1)
    end
  end
end

defmodule ExHdl.Test.RTLDesigns.Gen do
  @moduledoc false
  def ex_hdl_rtl, do: [ExHdl.RTL.Examples.counter(), ExHdl.Test.RTLDesigns.async_fifo()]
end
