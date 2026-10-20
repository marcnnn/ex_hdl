defmodule ExHdl.RTL do
  @moduledoc ~S"""
  A register-transfer-level hardware DSL. Elixir code elaborates a module
  description (`ExHdl.RTL.Module`); the SystemVerilog backend
  (`ExHdl.Backends.SystemVerilog.RTL`), the BEAM simulator
  (`ExHdl.RTL.Sim`) and Verilator co-simulation (`ExHdl.RTL.Cosim`) take it
  from there. See `docs/rtl_dsl.md` for the design.

      defmodule MyLib.Counter do
        use ExHdl.RTL

        def build(width \\ 8) do
          module "counter_#{width}" do
            en = input :en, 1
            q = output :q, width
            count = reg :count, width, reset: 0

            sync do
              if en, do: count <~ add_wrap(count, 1)
            end

            q <~ count
          end
        end
      end

  Parameters are plain Elixir values and loops are Elixir loops: a
  generator function returns a module. Inside `module/3` (and `rtl/1`)
  the arithmetic, comparison, bitwise and logical operators build
  `ExHdl.RTL.Expr` values when an operand is hardware; `if`/`unless`
  with a hardware condition record a conditional; `target <~ value`
  assigns. Width rules are in `ExHdl.RTL.Expr`.

  ## Statements

    * `comb do ... end` - combinational logic. Last assignment wins; every
      target must be assigned on every path (no latches). `x <~ e` at
      module level is a one-line `comb`.
    * `sync domain do ... end` - register updates on the rising edge of
      the domain's clock, nonblocking: reads see the values before the
      edge. Unassigned registers hold. Reset (if the register has one and
      the domain a reset) loads the reset value.
    * `switch subject do 0 -> ...; [1, 2] -> ...; _ -> ... end` - case on
      constants (or FSM state atoms). Without a hardware subject it picks
      a clause at elaboration time.

  ## Declarations

    * `input/3`, `output/3` - ports. `output :q, 8, reset: 0` (or `reg:
      true`) is a registered output.
    * `reg/3` - register with `reset:` (default 0, `nil` for none),
      `domain:`, `async_reg: true` / `cdc: true` (may sample other domains:
      synchroniser stages only).
    * `wire/3` - a named combinational signal, declared with a type or
      defined by an expression.
    * `domain/2` - a clock domain (`ExHdl.RTL.Domain`). A module without
      domain declarations gets `:sys` (`clk`, synchronous active-low
      `rst_n`) on first use.
    * `instance/3`, `memory/2`, `read_port/2`, `write_port/2`,
      `master/3`, `slave/3`, `bundle/3`, `connect/2`, `fsm/3`.
  """

  alias ExHdl.RTL.{Builder, Interface}

  @expr_funs [
    u: 1,
    s: 1,
    const: 2,
    cat: 1,
    rep: 2,
    mux: 2,
    mux: 3,
    trunc: 2,
    zext: 2,
    sext: 2,
    resize: 2,
    as_signed: 1,
    as_unsigned: 1,
    to_signed: 1,
    add_wrap: 2,
    sub_wrap: 2,
    bxor: 2,
    reduce_and: 1,
    reduce_or: 1,
    reduce_xor: 1,
    slice: 3,
    part: 3,
    width: 1,
    signed?: 1
  ]

  @doc false
  def expr_funs, do: @expr_funs

  defmacro __using__(_opts) do
    quote do
      import ExHdl.RTL,
        only: [
          module: 2,
          module: 3,
          black_box: 2,
          black_box: 3,
          rtl: 1,
          domain: 1,
          domain: 2,
          input: 2,
          input: 3,
          output: 2,
          output: 3,
          reg: 2,
          reg: 3,
          wire: 2,
          wire: 3,
          signal: 1,
          comb: 1,
          sync: 1,
          sync: 2,
          switch: 2,
          instance: 2,
          instance: 3,
          memory: 2,
          read_port: 2,
          write_port: 2,
          master: 2,
          master: 3,
          slave: 2,
          slave: 3,
          bundle: 2,
          bundle: 3,
          connect: 2,
          fsm: 2,
          fsm: 3,
          state: 2,
          state: 3,
          goto: 1,
          in_state: 2
        ]

      import ExHdl.RTL.Expr, only: unquote(@expr_funs)
      alias ExHdl.RTL.Interface
    end
  end

  # -- modules ---------------------------------------------------------------------------

  @doc """
  Elaborates a module and returns the checked `ExHdl.RTL.Module`.

  Options: `attrs:` (keyword list of SV attributes on the module).
  Raises `ExHdl.RTL.WidthError`, `ExHdl.RTL.ElaborationError` or
  `ExHdl.RTL.DomainError` with the offending signal named.
  """
  defmacro module(name, opts \\ [], do: body) do
    quote do
      Builder.build(:module, unquote(name), unquote(opts), fn ->
        unquote(scoped(body))
      end)
    end
  end

  @doc """
  Declares an external module (vendor primitive or hand-written SV): only
  ports and domains, no logic.

      black_box "BUFGCE", params: [CE_TYPE: "SYNC"], model: MyModels.Bufgce do
        input :I, 1, domain: :async
        input :CE, 1, domain: :async
        output :O, 1, domain: :async, comb_from: [:I, :CE]
      end

  Options: `params:` SV parameters with defaults (integers, strings or
  `{:bits, width, value}`), overridable per instance; `sources:`
  `%{"file.sv" => text}` emitted with the design; `model:` a module
  implementing `ExHdl.RTL.Model` for the BEAM simulator. Output option
  `comb_from:` lists the inputs the output depends on combinationally
  (`:all` by default, `:none` for registered outputs).
  """
  defmacro black_box(name, opts \\ [], do: body) do
    quote do
      Builder.build(:black_box, unquote(name), unquote(opts), fn ->
        unquote(scoped(body))
      end)
    end
  end

  @doc """
  Hardware operators in a helper function outside `module/3`:

      def parity(a, b), do: rtl(do: reduce_xor(a) == b)
  """
  defmacro rtl(do: body), do: scoped(body)

  defp scoped(body) do
    quote do
      import Kernel, except: unquote(ExHdl.RTL.Ops.kernel_excludes())
      import Bitwise, only: [band: 2, bor: 2, bnot: 1, bsl: 2, bsr: 2], warn: false
      import ExHdl.RTL.Ops, warn: false
      unquote(body)
    end
  end

  # -- declarations ----------------------------------------------------------------------

  @doc "Declares a clock domain. Options in `ExHdl.RTL.Domain`; defaults `clk`/`rst_n` for `:sys`, `clk_<name>`/`rst_<name>_n` otherwise."
  def domain(name, opts \\ []), do: Builder.domain(name, opts)

  @doc "Input port. Options: `domain:` (domain name, `:async`, `:static`)."
  def input(name, type, opts \\ []), do: Builder.input(name, type, opts)

  @doc "Output port; registered with `reset:` or `reg: true` (then `domain:` picks its domain)."
  def output(name, type, opts \\ []), do: Builder.output(name, type, opts)

  @doc """
  Register. Options: `reset:` (default 0 in domains with a reset, `nil` =
  none), `domain:`, `async_reg:` / `cdc:` (may sample other domains),
  `attrs:` SV attributes, e.g. `[shreg_extract: "no"]`.
  """
  def reg(name, type, opts \\ []), do: Builder.reg(name, type, opts)

  @doc "Named combinational signal: `wire(:x, 8)` declares, `wire(:sum, a + b)` defines."
  def wire(name, type_or_expr, opts \\ []), do: Builder.wire(name, type_or_expr, opts)

  @doc "The handle of an already declared signal."
  def signal(name), do: Builder.signal(name)

  @doc "Combinational block."
  defmacro comb(do: body), do: quote(do: Builder.comb(fn -> unquote(body) end))

  @doc "Synchronous block in `domain` (default: the module's default domain)."
  defmacro sync(domain \\ nil, do: body),
    do: quote(do: Builder.sync(unquote(domain), fn -> unquote(body) end))

  @doc "Case statement on constants; `_` is the default clause."
  defmacro switch(subject, do: clauses) do
    clauses =
      Enum.map(clauses, fn
        {:->, _, [[{:when, _, _}], _]} ->
          raise ArgumentError, "switch clauses take constants, not guards"

        {:->, _, [[{:_, _, ctx}], body]} when is_atom(ctx) ->
          quote(do: {:default, fn -> unquote(body) end})

        {:->, _, [[value], body]} ->
          quote(do: {fn -> unquote(value) end, fn -> unquote(body) end})
      end)

    quote(do: Builder.switch(unquote(subject), unquote(clauses)))
  end

  @doc """
  Instantiates `module` as `name`. Returns a map of port handles
  (`u.q`, `u[:q]`; child bundles as bundles). Inputs are driven with
  `u.en <~ value` or `connect: [en: value]`.

  Options: `domains:` child domain => parent domain (default: same name,
  or the parent's default domain if the child has one domain);
  `params:` black-box parameters; `connect:`.
  """
  def instance(name, module, opts \\ []), do: Builder.instance(name, module, opts)

  @doc """
  A memory. Options: `width:`, `depth:` (required), `init:` (list or
  `%{addr => value}`, rest 0), `style:` (`:auto`, `:block`, `:ultra`,
  `:distributed`, `:registers`), `byte:` byte-enable granularity (8).
  """
  def memory(name, opts), do: Builder.memory(name, opts)

  @doc """
  Adds a read port and returns its data (unsigned, memory width).
  `kind: :sync` (default) registers the word at `addr` on the clock edge
  when `en:` (default 1), reading the contents before that edge's
  writes; `kind: :async` reads combinationally (LUTRAM). Options `addr:`,
  `en:`, `domain:`, `name:`.
  """
  def read_port(mem, opts), do: Builder.read_port(mem, opts)

  @doc "Adds a write port: `addr:`, `data:`, `en:` (default 1), `be:` byte enables, `domain:`."
  def write_port(mem, opts), do: Builder.write_port(mem, opts)

  @doc "Bundle ports driving `iface` as master (`<prefix>_<field>`)."
  def master(prefix, iface, opts \\ []), do: Interface.declare(prefix, iface, :master, opts)

  @doc "Bundle ports receiving `iface` as slave."
  def slave(prefix, iface, opts \\ []), do: Interface.declare(prefix, iface, :slave, opts)

  @doc "Internal bundle of wires (`<prefix>_<field>`)."
  def bundle(prefix, iface, opts \\ []), do: Interface.declare(prefix, iface, :wire, opts)

  @doc "Connects two bundles of the same interface, data flowing from `source` to `sink`."
  def connect(source, sink), do: Interface.connect(source, sink)

  @doc "State machine; see `ExHdl.RTL.FSM`."
  defmacro fsm(name, opts \\ [], do: body),
    do: quote(do: ExHdl.RTL.FSM.build(unquote(name), unquote(opts), fn -> unquote(body) end))

  @doc "A state of the enclosing `fsm/3`. Options: `outputs:`."
  defmacro state(name, opts \\ [], body) do
    {opts, body} =
      case {opts, body} do
        {[], kw} when is_list(kw) ->
          {b, o} = Keyword.pop(kw, :do)
          {o, b}

        {o, kw} ->
          {o, Keyword.get(kw, :do)}
      end

    quote(do: ExHdl.RTL.FSM.state(unquote(name), unquote(opts), fn -> unquote(body) end))
  end

  @doc "Next state of the enclosing FSM."
  def goto(state), do: ExHdl.RTL.FSM.goto(state)

  @doc "1-bit: the FSM is in `state`."
  def in_state(fsm, state), do: ExHdl.RTL.FSM.in_state(fsm, state)
end
