defmodule ExHdl.Stateful do
  @moduledoc """
  Functional, state-transformation hardware components.

  A component defines its state registers, ports, and a pure `step/2`
  transition function:

      defmodule MyLib.Counter do
        use ExHdl.Stateful

        ports do
          input :en, 1
          output :count, 8
        end

        state do
          reg :count, 8, reset: 0
        end

        def step(inputs, state) do
          next_count = mux(inputs.en == 1, add_wrap(state.count, 1, 8), state.count)
          outputs = %{count: state.count}
          next_state = %{state | count: next_count}
          {outputs, next_state}
        end
      end

  The module can be:
    * Elaborated to an `%ExHdl.RTL.Module{}` with `MyLib.Counter.build/1`.
    * Synthesized to SystemVerilog with `ExHdl.Backends.SystemVerilog.RTL`.
    * Simulated on the BEAM with `MyLib.Counter.simulate/2`.
  """

  alias ExHdl.RTL.{Builder, Expr, Ops}

  defmacro __using__(opts \\ []) do
    quote do
      import Kernel, except: unquote(Ops.kernel_excludes())
      import Bitwise, only: [band: 2, bor: 2, bnot: 1, bsl: 2, bsr: 2], warn: false
      import ExHdl.RTL.Ops, warn: false
      import ExHdl.Stateful.DSL
      import ExHdl.RTL.Expr, except: [mux: 2, mux: 3, add_wrap: 2, sub_wrap: 2]

      import ExHdl.Stateful,
        only: [
          stateful: 2,
          stateful: 3,
          unpack: 2,
          pack: 1,
          mux: 2,
          mux: 3,
          add_wrap: 2,
          add_wrap: 3,
          sub_wrap: 2,
          sub_wrap: 3,
          match: 2,
          match_cond: 1
        ]

      import ExHdl.RTL.Builder, only: [read_port: 2, write_port: 2]
      alias ExHdl.RTL.Interface

      Module.register_attribute(__MODULE__, :stateful_ports, accumulate: true)
      Module.register_attribute(__MODULE__, :stateful_regs, accumulate: true)
      Module.register_attribute(__MODULE__, :stateful_mems, accumulate: true)
      @stateful_opts unquote(opts)

      @before_compile ExHdl.Stateful
    end
  end

  defmacro __before_compile__(env) do
    ports = Module.get_attribute(env.module, :stateful_ports) |> Enum.reverse()
    regs = Module.get_attribute(env.module, :stateful_regs) |> Enum.reverse()
    mems = Module.get_attribute(env.module, :stateful_mems) |> Enum.reverse()

    struct_fields = for r <- regs, do: {r.name, r.opts[:reset] || 0}

    if ports != [] or regs != [] do
      quote do
        defstruct unquote(struct_fields)

        def __stateful_ports__, do: unquote(Macro.escape(ports))
        def __stateful_regs__, do: unquote(Macro.escape(regs))
        def __stateful_mems__, do: unquote(Macro.escape(mems))

        @doc "Elaborates the stateful component into an %ExHdl.RTL.Module{}."
        def build(opts \\ []) do
          ExHdl.Stateful.Compiler.build(__MODULE__, opts)
        end

        @doc "Simulates the component in pure Elixir on the BEAM."
        def simulate(input_stream, initial_state \\ nil) do
          init = initial_state || struct(__MODULE__)

          Enum.map_reduce(input_stream, init, fn in_cycle, st ->
            step(in_cycle, st)
          end)
        end
      end
    end
  end

  @doc """
  Builds a dynamic / parameterized stateful hardware module:

      stateful name, opts do
        ports do ... end
        state do ... end
        memory ...
        step fn inputs, state -> ... end
      end
  """
  defmacro stateful(name, opts \\ [], do: block) do
    quote do
      ExHdl.Stateful.Dynamic.build(unquote(name), unquote(opts), fn ->
        import Kernel, except: unquote(Ops.kernel_excludes())
        import Bitwise, only: [band: 2, bor: 2, bnot: 1, bsl: 2, bsr: 2], warn: false
        import ExHdl.RTL.Ops, warn: false
        import ExHdl.Stateful.DSL, except: [ports: 1, state: 1, memory: 2]
        import ExHdl.Stateful.Dynamic.DSL
        import ExHdl.RTL.Expr, except: [mux: 2, mux: 3, add_wrap: 2, sub_wrap: 2]

        import ExHdl.Stateful,
          only: [
            unpack: 2,
            pack: 1,
            mux: 2,
            mux: 3,
            add_wrap: 2,
            add_wrap: 3,
            sub_wrap: 2,
            sub_wrap: 3,
            match: 2,
            match_cond: 1
          ]

        unquote(block)
      end)
    end
  end

  # ===========================================================================
  # Dual Hardware / Software Operators
  # ===========================================================================

  @doc "Multiplexer that works on hardware expressions and pure software values."
  def mux(%Expr{} = c, a, b), do: Expr.mux(c, a, b)
  def mux(c, %Expr{} = a, b), do: Expr.mux(c, a, b)
  def mux(c, a, %Expr{} = b), do: Expr.mux(c, a, b)
  def mux(c, a, b) when is_boolean(c), do: if(c, do: a, else: b)
  def mux(c, a, b) when is_integer(c), do: if(c != 0, do: a, else: b)

  def mux(%Expr{} = sel, list), do: Expr.mux(sel, list)
  def mux(sel, list) when is_integer(sel) and is_list(list), do: Enum.at(list, sel)

  @doc """
  Functional pattern match expression across both software and hardware.
  """
  def match(subject, clauses) when is_integer(subject) or is_atom(subject) do
    Enum.find_value(clauses, fn
      {:default, val} ->
        val

      {:_, val} ->
        val

      {val_or_list, res} ->
        if subject in List.wrap(val_or_list), do: res
    end)
  end

  def match(%Expr{} = subject, clauses) do
    {default, cases} =
      case List.last(clauses) do
        {:default, def_val} -> {def_val, :lists.droplast(clauses)}
        {:_, def_val} -> {def_val, :lists.droplast(clauses)}
        _ -> {0, clauses}
      end

    Enum.reduce(Enum.reverse(cases), default, fn {cond_val, res_val}, acc ->
      cond_expr =
        case cond_val do
          list when is_list(list) ->
            Enum.reduce(list, Expr.const(0, {:u, 1}), fn item, or_acc ->
              Expr.lor(or_acc, Expr.eq(subject, item))
            end)

          single ->
            Expr.eq(subject, single)
        end

      mux_values(cond_expr, res_val, acc)
    end)
  end

  @doc """
  Multi-branch conditional match across hardware expressions and software values.
  Evaluates clauses sequentially, returning the value of the first true condition.
  Works transparently with scalar values, maps, and tuples.
  """
  def match_cond(clauses) when is_list(clauses) do
    {default, cases} =
      case List.last(clauses) do
        {:default, def_val} -> {def_val, :lists.droplast(clauses)}
        {:_, def_val} -> {def_val, :lists.droplast(clauses)}
        _ -> {0, clauses}
      end

    Enum.reduce(Enum.reverse(cases), default, fn {cond_expr, res_val}, acc ->
      mux_values(cond_expr, res_val, acc)
    end)
  end

  @doc false
  def mux_values(cond_expr, %Expr{} = a, b), do: mux(cond_expr, a, b)
  def mux_values(cond_expr, a, %Expr{} = b), do: mux(cond_expr, a, b)
  def mux_values(cond_expr, %{__struct__: _} = a, b), do: mux(cond_expr, a, b)

  def mux_values(cond_expr, %{} = a, %{} = b) do
    for {k, va} <- a, into: %{} do
      {k, mux_values(cond_expr, va, Map.fetch!(b, k))}
    end
  end

  def mux_values(cond_expr, {a1, a2}, {b1, b2}) do
    {mux_values(cond_expr, a1, b1), mux_values(cond_expr, a2, b2)}
  end

  def mux_values(cond_expr, {a1, a2, a3}, {b1, b2, b3}) do
    {mux_values(cond_expr, a1, b1), mux_values(cond_expr, a2, b2), mux_values(cond_expr, a3, b3)}
  end

  def mux_values(cond_expr, a, b) do
    mux(cond_expr, a, b)
  end

  @doc "Wrapping addition for hardware expressions and software integers."
  def add_wrap(%Expr{} = a, b), do: Expr.add_wrap(a, b)
  def add_wrap(a, %Expr{} = b), do: Expr.add_wrap(a, b)
  def add_wrap(a, b), do: add_wrap(a, b, 32)

  def add_wrap(%Expr{} = a, b, _w), do: Expr.add_wrap(a, b)
  def add_wrap(a, %Expr{} = b, _w), do: Expr.add_wrap(a, b)

  def add_wrap(a, b, w) when is_integer(a) and is_integer(b) and is_integer(w) do
    mod = Bitwise.bsl(1, w)
    rem(a + b, mod)
  end

  @doc "Wrapping subtraction for hardware expressions and software integers."
  def sub_wrap(%Expr{} = a, b), do: Expr.sub_wrap(a, b)
  def sub_wrap(a, %Expr{} = b), do: Expr.sub_wrap(a, b)
  def sub_wrap(a, b), do: sub_wrap(a, b, 32)

  def sub_wrap(%Expr{} = a, b, _w), do: Expr.sub_wrap(a, b)
  def sub_wrap(a, %Expr{} = b, _w), do: Expr.sub_wrap(a, b)

  def sub_wrap(a, b, w) when is_integer(a) and is_integer(b) and is_integer(w) do
    mod = Bitwise.bsl(1, w)
    rem(rem(a - b, mod) + mod, mod)
  end

  # ===========================================================================
  # Bit Packing and Unpacking Helpers (Hardware + Software)
  # ===========================================================================

  @doc """
  Unpacks a word into fields. Works seamlessly on `%ExHdl.RTL.Expr{}` hardware
  signals and software integers/binaries.
  """
  def unpack(word, fields) when is_list(fields) do
    is_keyword = Keyword.keyword?(fields)

    spec_list =
      if is_keyword do
        fields
      else
        Enum.map(fields, fn f -> {:_, f} end)
      end

    {_total_w, field_spans} =
      Enum.reduce(spec_list, {0, []}, fn {name, type}, {cur_offset, acc} ->
        w = type_width(type)
        span = {name, cur_offset, w, type}
        {cur_offset + w, [span | acc]}
      end)

    extracted =
      for {name, offset, w, type} <- Enum.reverse(field_spans) do
        val = extract_field(word, offset, w, type)
        {name, val}
      end

    if is_keyword do
      Map.new(extracted)
    else
      extracted |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
    end
  end

  @doc """
  Packs fields into a single word. Works on both hardware expressions and integers.
  """
  def pack(fields) when is_list(fields) do
    values =
      if Keyword.keyword?(fields) do
        Keyword.values(fields)
      else
        fields
      end

    if Enum.any?(values, &is_struct(&1, Expr)) do
      Expr.cat(
        Enum.map(values, fn
          v when is_integer(v) -> Expr.const(v, {:u, 1})
          %Expr{} = e -> e
        end)
      )
    else
      Enum.reduce(values, 0, fn val, acc ->
        w = integer_width(val)
        Bitwise.bor(Bitwise.bsl(acc, w), val)
      end)
    end
  end

  defp extract_field(%Expr{} = word, offset, width, {:s, _}) do
    Expr.as_signed(Expr.slice(word, offset, width))
  end

  defp extract_field(%Expr{} = word, offset, width, _type) do
    Expr.slice(word, offset, width)
  end

  defp extract_field(word, offset, width, {:s, _}) when is_integer(word) do
    raw = Bitwise.band(Bitwise.bsr(word, offset), Bitwise.bsl(1, width) - 1)

    if Bitwise.band(raw, Bitwise.bsl(1, width - 1)) != 0 do
      raw - Bitwise.bsl(1, width)
    else
      raw
    end
  end

  defp extract_field(word, offset, width, _type) when is_integer(word) do
    Bitwise.band(Bitwise.bsr(word, offset), Bitwise.bsl(1, width) - 1)
  end

  defp type_width({:s, w}), do: w
  defp type_width({:u, w}), do: w
  defp type_width(w) when is_integer(w), do: w

  defp integer_width(0), do: 1

  defp integer_width(n) when is_integer(n) do
    ExHdl.RTL.Builder.ceil_log2(n + 1)
  end
end

defmodule ExHdl.Stateful.DSL do
  @moduledoc "DSL macros for declaring stateful component ports, state registers, and memories."

  defmacro ports(do: block) do
    quote do
      import ExHdl.Stateful.DSL.Ports
      unquote(block)
    end
  end

  defmacro state(do: block) do
    quote do
      import ExHdl.Stateful.DSL.State
      unquote(block)
    end
  end

  defmacro memory(name, opts) do
    quote do
      @stateful_mems %{name: unquote(name), opts: unquote(opts)}
    end
  end
end

defmodule ExHdl.Stateful.DSL.Ports do
  @moduledoc false

  defmacro input(name, type, opts \\ []) do
    quote do
      @stateful_ports %{
        dir: :input,
        name: unquote(name),
        type: unquote(type),
        opts: unquote(opts)
      }
    end
  end

  defmacro output(name, type, opts \\ []) do
    quote do
      @stateful_ports %{
        dir: :output,
        name: unquote(name),
        type: unquote(type),
        opts: unquote(opts)
      }
    end
  end
end

defmodule ExHdl.Stateful.DSL.State do
  @moduledoc false

  defmacro reg(name, type, opts \\ []) do
    quote do
      @stateful_regs %{name: unquote(name), type: unquote(type), opts: unquote(opts)}
    end
  end
end

defmodule ExHdl.Stateful.Compiler do
  @moduledoc "Elaborates an ExHdl.Stateful module into an %ExHdl.RTL.Module{}."

  alias ExHdl.RTL.Builder

  def build(module, opts) do
    name = Keyword.get(opts, :name, default_name(module))
    ports_spec = module.__stateful_ports__()
    regs_spec = module.__stateful_regs__()
    mems_spec = module.__stateful_mems__()

    out_names = for p <- ports_spec, p.dir == :output, do: p.name
    reg_names = for r <- regs_spec, do: r.name

    Builder.build(:module, name, opts, fn ->
      # 1. Declare memories
      _mem_handles =
        for m <- mems_spec, into: %{} do
          {m.name, Builder.memory(m.name, m.opts)}
        end

      # 2. Declare ports & registers (handling registered outputs)
      input_handles =
        for p <- ports_spec, p.dir == :input, into: %{} do
          {p.name, Builder.input(p.name, p.type, p.opts)}
        end

      reg_handles =
        for r <- regs_spec, into: %{} do
          handle =
            if r.name in out_names do
              # Registered output port
              out_port = Enum.find(ports_spec, &(&1.name == r.name and &1.dir == :output))
              merged_opts = [reg: true, reset: r.opts[:reset] || 0] ++ out_port.opts ++ r.opts
              Builder.output(r.name, r.type, merged_opts)
            else
              # Internal register
              Builder.reg(r.name, r.type, r.opts)
            end

          {r.name, handle}
        end

      comb_out_handles =
        for p <- ports_spec, p.dir == :output, p.name not in reg_names, into: %{} do
          {p.name, Builder.output(p.name, p.type, p.opts)}
        end

      # 3. Prepare symbolic state struct
      symbolic_state = struct(module, reg_handles)

      # 4. Evaluate the pure step/2 function!
      {outputs, next_state} = module.step(input_handles, symbolic_state)

      # 5. Connect purely combinational outputs
      for {out_name, out_handle} <- comb_out_handles do
        case Map.fetch(outputs, out_name) do
          {:ok, val} ->
            Builder.assign(out_handle, val)

          :error ->
            :ok
        end
      end

      # 6. Connect next state updates inside synchronous block
      Builder.sync(:sys, fn ->
        for r <- regs_spec do
          reg_handle = reg_handles[r.name]
          next_val = Map.get(next_state, r.name)

          if next_val != nil do
            Builder.assign(reg_handle, next_val)
          end
        end
      end)
    end)
  end

  defp default_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end

defmodule ExHdl.Stateful.Dynamic do
  @moduledoc "Dynamic builder for parameterized stateful hardware modules."

  alias ExHdl.RTL.Builder

  @key {__MODULE__, :context}

  def build(name, opts, fun) do
    ctx = %{
      ports: [],
      regs: [],
      mems: %{},
      step_fn: nil
    }

    prev = Process.get(@key)
    Process.put(@key, ctx)

    try do
      # 1. Execute elaboration block
      fun.()
      ctx = Process.get(@key)

      ports_spec = Enum.reverse(ctx.ports)
      regs_spec = Enum.reverse(ctx.regs)
      step_fn = ctx.step_fn || raise(ArgumentError, "stateful #{name}: missing step function")

      out_names = for p <- ports_spec, p.dir == :output, do: p.name
      reg_names = for r <- regs_spec, do: r.name

      Builder.build(:module, name, opts, fn ->
        input_handles =
          for p <- ports_spec, p.dir == :input, into: %{} do
            {p.name, Builder.input(p.name, p.type, p.opts)}
          end

        reg_handles =
          for r <- regs_spec, into: %{} do
            handle =
              if r.name in out_names do
                out_port = Enum.find(ports_spec, &(&1.name == r.name and &1.dir == :output))
                merged_opts = [reg: true, reset: r.opts[:reset] || 0] ++ out_port.opts ++ r.opts
                Builder.output(r.name, r.type, merged_opts)
              else
                Builder.reg(r.name, r.type, r.opts)
              end

            {r.name, handle}
          end

        comb_out_handles =
          for p <- ports_spec, p.dir == :output, p.name not in reg_names, into: %{} do
            {p.name, Builder.output(p.name, p.type, p.opts)}
          end

        # Evaluate pure step function!
        {outputs, next_state} = step_fn.(input_handles, reg_handles)

        # Drive combinational outputs
        for {out_name, out_handle} <- comb_out_handles do
          case Map.fetch(outputs, out_name) do
            {:ok, val} -> Builder.assign(out_handle, val)
            :error -> :ok
          end
        end

        # Drive next state inside sync
        Builder.sync(:sys, fn ->
          for r <- regs_spec do
            reg_handle = reg_handles[r.name]
            next_val = Map.get(next_state, r.name)

            if next_val != nil do
              Builder.assign(reg_handle, next_val)
            end
          end
        end)
      end)
    after
      Process.put(@key, prev)
    end
  end

  def add_port(dir, name, type, opts) do
    ctx = Process.get(@key)
    Process.put(@key, %{ctx | ports: [%{dir: dir, name: name, type: type, opts: opts} | ctx.ports]})
  end

  def add_reg(name, type, opts) do
    ctx = Process.get(@key)
    Process.put(@key, %{ctx | regs: [%{name: name, type: type, opts: opts} | ctx.regs]})
  end

  def set_step(fun) do
    ctx = Process.get(@key)
    Process.put(@key, %{ctx | step_fn: fun})
  end

  defmodule DSL do
    @moduledoc false

    defmacro ports(do: block) do
      quote do
        import ExHdl.Stateful.Dynamic.DSL.Ports
        unquote(block)
      end
    end

    defmacro state(do: block) do
      quote do
        import ExHdl.Stateful.Dynamic.DSL.State
        unquote(block)
      end
    end

    def memory(name, opts) do
      Builder.memory(name, opts)
    end

    def wire(name, expr) do
      Builder.wire(name, expr, [])
    end

    def read_port(mem, opts) do
      Builder.read_port(mem, opts)
    end

    def write_port(mem, opts) do
      Builder.write_port(mem, opts)
    end

    def step(fun) when is_function(fun, 2) do
      ExHdl.Stateful.Dynamic.set_step(fun)
    end

    defmodule Ports do
      @moduledoc false

      def input(name, type, opts \\ []) do
        ExHdl.Stateful.Dynamic.add_port(:input, name, type, opts)
      end

      def output(name, type, opts \\ []) do
        ExHdl.Stateful.Dynamic.add_port(:output, name, type, opts)
      end
    end

    defmodule State do
      @moduledoc false

      def reg(name, type, opts \\ []) do
        ExHdl.Stateful.Dynamic.add_reg(name, type, opts)
      end
    end
  end
end
