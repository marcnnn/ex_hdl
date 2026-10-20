defmodule ExHdl.RTL.FSM do
  @moduledoc """
  State machines with named states (`ExHdl.RTL.fsm/3`).

      f =
        fsm :ctrl, reset: :idle do
          state :idle do
            if start, do: goto(:run)
          end

          state :run, outputs: [busy: 1] do
            count <~ add_wrap(count, 1)
            if count == 15, do: goto(:done)
          end

          state :done, outputs: [busy: 1, done: 1] do
            goto(:idle)
          end
        end

  The state register `<name>_state` (reset to `:reset`, default the first
  state) lives in `domain:` (default domain). `encoding:` is `:binary`
  (default, `ceil(log2(n))` bits) or `:one_hot` (`n` bits, state `i` is
  bit `i`; `in_state/2` tests a single bit). State
  bodies are synchronous statements in that domain: `goto/1` sets the next
  state, other assignments update registers. `outputs:` are Moore
  outputs: combinational assignments to signals declared before the FSM,
  `defaults:` (default 0) in states that do not list them.

  The handle (`%ExHdl.RTL.FSM{}`) works with `ExHdl.RTL.in_state/2` and as
  a `switch` subject with state atoms as case values.
  """
  alias ExHdl.RTL.{Builder, ElaborationError, Expr}

  defstruct [:name, :state, :states, :domain, encoding: :binary]

  @type t :: %__MODULE__{}

  @doc false
  def build(name, opts, fun) do
    name = Builder.name!(name)
    Builder.push_fsm(%{collect: []})
    fun.()
    %{collect: collected} = Builder.current_fsm()
    Builder.pop_fsm()
    states = Enum.reverse(collected)
    names = Enum.map(states, &elem(&1, 0))

    if names == [], do: raise(ElaborationError, "fsm #{name} has no states")

    if length(Enum.uniq(names)) != length(names),
      do: raise(ElaborationError, "fsm #{name}: duplicate state names")

    encoding = Keyword.get(opts, :encoding, :binary)

    {codes, width} =
      case encoding do
        :binary ->
          {Enum.with_index(names), max(Builder.ceil_log2(length(names)), 1)}

        :one_hot ->
          {names |> Enum.with_index() |> Enum.map(fn {n, i} -> {n, Bitwise.bsl(1, i)} end),
           length(names)}

        other ->
          raise ElaborationError,
                "fsm #{name}: encoding must be :binary or :one_hot, got #{inspect(other)}"
      end

    reset = Keyword.get(opts, :reset, hd(names))

    unless reset in names,
      do: raise(ElaborationError, "fsm #{name}: reset state #{inspect(reset)} is not a state")

    dom = Builder.resolve_domain(opts[:domain]).name
    reg = Builder.reg(:"#{name}_state", width, reset: codes[reset], domain: dom)
    fsm = %__MODULE__{name: name, state: reg, states: codes, domain: dom, encoding: encoding}
    Builder.add_fsm(fsm)

    Builder.push_fsm(%{fsm: fsm})

    Builder.sync(dom, fn ->
      Builder.switch(fsm, for({s, _, body} <- states, do: {fn -> s end, body}))
    end)

    Builder.pop_fsm()

    defaults = Keyword.get(opts, :defaults, [])
    outputs = states |> Enum.flat_map(fn {_, o, _} -> Keyword.keys(o) end) |> Enum.uniq()

    for o <- outputs do
      sig = Builder.signal(o)

      Builder.comb(fn ->
        Builder.assign(sig, Keyword.get(defaults, o, 0))

        Builder.switch(
          fsm,
          for {s, outs, _} <- states, Keyword.has_key?(outs, o) do
            {fn -> s end, fn -> Builder.assign(sig, outs[o]) end}
          end
        )
      end)
    end

    fsm
  end

  @doc false
  def state(name, opts, body) do
    case Builder.current_fsm() do
      %{collect: c} = f ->
        Builder.update_fsm(%{f | collect: [{name, Keyword.get(opts, :outputs, []), body} | c]})

      _ ->
        raise ElaborationError, "state/3 inside a state body"
    end

    nil
  end

  @doc false
  def goto(target) do
    case Builder.current_fsm() do
      %{fsm: f} ->
        code =
          Keyword.get(f.states, target) ||
            raise ElaborationError, "fsm #{f.name}: goto to unknown state #{inspect(target)}"

        Builder.assign(f.state, Builder.label_for(f.state, target, code))

      _ ->
        raise ElaborationError, "goto/1 belongs in a state body"
    end
  end

  @doc false
  def in_state(%__MODULE__{state: s, states: states} = f, name) do
    code =
      Keyword.get(states, name) ||
        raise ElaborationError, "fsm #{f.name} has no state #{inspect(name)}"

    case f.encoding do
      :one_hot -> Expr.slice(s, length(Integer.digits(code, 2)) - 1, 1)
      :binary -> Expr.eq(s, Expr.label(code, s.type, Builder.label_name(f.name, name)))
    end
  end
end
