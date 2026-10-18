defmodule ExHdl.Types.Laws do
  @moduledoc """
  The laws of a set-theoretic type algebra, as data.

  A law is a proposition over type variables `:a`, `:b`, `:c` and an
  optional value `:v`:

      prop := {:equal, t, t} | {:subtype, t, t} | {:empty, t} | {:member, t, :v}
            | {:and, prop, prop} | {:or, prop, prop} | {:not, prop}
            | {:iff, prop, prop} | {:implies, prop, prop}
      t    := :a | :b | :c | :term | :none
            | {:union, t, t} | {:intersection, t, t} | {:difference, t, t} | {:negation, t}

  The same proposition is evaluated against any `ExHdl.Types.SetAlgebra`
  (`holds?/4`) and printed as a standalone Elixir reproducer
  (`reproducer/5`), so a failing case can be replayed on any Elixir release
  or attached to an upstream issue.
  """

  alias ExHdl.Types.Expr

  @laws [
    union_commutative: {:equal, {:union, :a, :b}, {:union, :b, :a}},
    union_associative: {:equal, {:union, :a, {:union, :b, :c}}, {:union, {:union, :a, :b}, :c}},
    union_idempotent: {:equal, {:union, :a, :a}, :a},
    intersection_commutative: {:equal, {:intersection, :a, :b}, {:intersection, :b, :a}},
    intersection_associative:
      {:equal, {:intersection, :a, {:intersection, :b, :c}},
       {:intersection, {:intersection, :a, :b}, :c}},
    intersection_idempotent: {:equal, {:intersection, :a, :a}, :a},
    absorption_union: {:equal, {:union, :a, {:intersection, :a, :b}}, :a},
    absorption_intersection: {:equal, {:intersection, :a, {:union, :a, :b}}, :a},
    distributive_intersection:
      {:equal, {:intersection, :a, {:union, :b, :c}},
       {:union, {:intersection, :a, :b}, {:intersection, :a, :c}}},
    distributive_union:
      {:equal, {:union, :a, {:intersection, :b, :c}},
       {:intersection, {:union, :a, :b}, {:union, :a, :c}}},
    excluded_middle: {:equal, {:union, :a, {:negation, :a}}, :term},
    non_contradiction: {:empty, {:intersection, :a, {:negation, :a}}},
    double_negation: {:equal, {:negation, {:negation, :a}}, :a},
    de_morgan_union:
      {:equal, {:negation, {:union, :a, :b}}, {:intersection, {:negation, :a}, {:negation, :b}}},
    de_morgan_intersection:
      {:equal, {:negation, {:intersection, :a, :b}}, {:union, {:negation, :a}, {:negation, :b}}},
    difference_definition: {:equal, {:difference, :a, :b}, {:intersection, :a, {:negation, :b}}},
    subtype_via_difference: {:iff, {:subtype, :a, :b}, {:empty, {:difference, :a, :b}}},
    union_upper_bound: {:subtype, :a, {:union, :a, :b}},
    intersection_lower_bound: {:subtype, {:intersection, :a, :b}, :a},
    none_bottom_term_top: {:and, {:subtype, :none, :a}, {:subtype, :a, :term}},
    equal_antisymmetric: {:iff, {:equal, :a, :b}, {:and, {:subtype, :a, :b}, {:subtype, :b, :a}}},
    member_union:
      {:iff, {:member, {:union, :a, :b}, :v}, {:or, {:member, :a, :v}, {:member, :b, :v}}},
    member_intersection:
      {:iff, {:member, {:intersection, :a, :b}, :v}, {:and, {:member, :a, :v}, {:member, :b, :v}}},
    member_negation: {:iff, {:member, {:negation, :a}, :v}, {:not, {:member, :a, :v}}},
    member_difference:
      {:iff, {:member, {:difference, :a, :b}, :v},
       {:and, {:member, :a, :v}, {:not, {:member, :b, :v}}}},
    member_subtype: {:implies, {:and, {:subtype, :a, :b}, {:member, :a, :v}}, {:member, :b, :v}}
  ]

  # Congruence: `:b` is generated as a semantically equal rewrite of `:a`
  # (see `ExHdl.Types.Rewrite`), so every operation must agree on both.
  @congruence [
    congruence_equal: {:equal, :a, :b},
    congruence_union: {:equal, {:union, :a, :c}, {:union, :b, :c}},
    congruence_intersection: {:equal, {:intersection, :a, :c}, {:intersection, :b, :c}},
    congruence_difference_left: {:equal, {:difference, :a, :c}, {:difference, :b, :c}},
    congruence_difference_right: {:equal, {:difference, :c, :a}, {:difference, :c, :b}},
    congruence_negation: {:equal, {:negation, :a}, {:negation, :b}},
    congruence_subtype: {:iff, {:subtype, :a, :c}, {:subtype, :b, :c}},
    congruence_supertype: {:iff, {:subtype, :c, :a}, {:subtype, :c, :b}},
    congruence_member: {:iff, {:member, :a, :v}, {:member, :b, :v}}
  ]

  @doc "All laws as `{name, proposition}`."
  def all, do: @laws ++ @congruence

  @doc "Whether `name` is a congruence law (`:b` must be a rewrite of `:a`)."
  def congruence?(name), do: Keyword.has_key?(@congruence, name)

  @doc "Type variables used by a proposition, in order."
  def type_vars(prop), do: [:a, :b, :c] |> Enum.filter(&uses?(prop, &1))

  @doc "Whether the proposition needs a value `:v`."
  def value?(prop), do: uses?(prop, :v)

  defp uses?(var, var), do: true
  defp uses?(t, var) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&uses?(&1, var))
  defp uses?(_, _), do: false

  @doc """
  Fills in `:b` for congruence cases: `env.rewrite` is a list of
  `{path, rule, x}` steps (`ExHdl.Types.Rewrite`) applied to `env.a`.
  """
  def materialize(%{rewrite: steps, a: a} = env) do
    b =
      Enum.reduce(steps, a, fn {path, rule, x}, e ->
        ExHdl.Types.Rewrite.apply_at(e, path, rule, x)
      end)

    env |> Map.delete(:rewrite) |> Map.put(:b, b)
  end

  def materialize(env), do: env

  @doc "Evaluates `prop` with `env` mapping variables to type expressions (and `:v` to a value)."
  def holds?(prop, alg, env) do
    types =
      Map.new(materialize(env), fn {k, v} ->
        if k == :v, do: {k, v}, else: {k, Expr.build(v, alg)}
      end)

    eval(prop, alg, types)
  end

  defp eval({:equal, l, r}, alg, env), do: alg.equal?(term(l, alg, env), term(r, alg, env))
  defp eval({:subtype, l, r}, alg, env), do: alg.subtype?(term(l, alg, env), term(r, alg, env))
  defp eval({:empty, t}, alg, env), do: alg.empty?(term(t, alg, env))
  defp eval({:member, t, :v}, alg, env), do: alg.member?(term(t, alg, env), env.v)
  defp eval({:and, p, q}, alg, env), do: eval(p, alg, env) and eval(q, alg, env)
  defp eval({:or, p, q}, alg, env), do: eval(p, alg, env) or eval(q, alg, env)
  defp eval({:not, p}, alg, env), do: not eval(p, alg, env)
  defp eval({:iff, p, q}, alg, env), do: eval(p, alg, env) == eval(q, alg, env)
  defp eval({:implies, p, q}, alg, env), do: not eval(p, alg, env) or eval(q, alg, env)

  defp term(var, _alg, env) when var in [:a, :b, :c], do: Map.fetch!(env, var)
  defp term(:term, alg, _env), do: alg.term()
  defp term(:none, alg, _env), do: alg.none()
  defp term({:negation, t}, alg, env), do: alg.negation(term(t, alg, env))
  defp term({op, l, r}, alg, env), do: apply(alg, op, [term(l, alg, env), term(r, alg, env)])

  @doc """
  A standalone Elixir script that rebuilds the types, evaluates the law and
  prints result and time. For `ExHdl.Types.ElixirDescr` it only depends on
  `Module.Types.Descr` (run with `elixir file.exs`); for other algebras it
  needs this project (`mix run file.exs`).
  """
  def reproducer(name, prop, alg, env, note) do
    mode = if alg == ExHdl.Types.ElixirDescr, do: :descr, else: :alg
    p = if mode == :descr, do: "D", else: "alg"

    bindings =
      env
      |> materialize()
      |> Enum.sort()
      |> Enum.map_join("\n", fn
        {:v, value} -> "v = #{inspect(value)}"
        {var, expr} -> "#{var} = #{Expr.to_code(expr, mode)}"
      end)

    header =
      cond do
        mode == :descr and value?(prop) ->
          value_type_helper() <> "alias Module.Types.Descr, as: D\n"

        mode == :descr ->
          "alias Module.Types.Descr, as: D\n"

        true ->
          "alg = #{inspect(alg)}\n"
      end

    """
    # Law #{name}: #{note}
    # Found on Elixir #{System.version()} / OTP #{System.otp_release()}
    # case: #{inspect(%{law: name, algebra: alg, env: env, problem: problem_kind(note)}, limit: :infinity, printable_limit: :infinity)}
    #{header}
    #{bindings}

    {us, holds} = :timer.tc(fn -> #{prop_code(prop, p, mode)} end)
    IO.puts("Elixir \#{System.version()}: law #{name} holds? \#{holds} (\#{div(us, 1000)} ms)")
    """
  end

  defp problem_kind("does not hold"), do: :violation
  defp problem_kind("exceeded" <> _), do: :slow
  defp problem_kind(_), do: :other

  @doc "Reads the `# case:` line of a reproducer script."
  def read_case(script) do
    [_, literal] = Regex.run(~r/^# case: (.*)$/m, script)
    {value, _} = Code.eval_string(literal)
    value
  end

  defp prop_code({:equal, l, r}, p, _m), do: "#{p}.equal?(#{term_code(l, p)}, #{term_code(r, p)})"

  defp prop_code({:subtype, l, r}, p, _m),
    do: "#{p}.subtype?(#{term_code(l, p)}, #{term_code(r, p)})"

  defp prop_code({:empty, t}, p, _m), do: "#{p}.empty?(#{term_code(t, p)})"

  defp prop_code({:member, t, :v}, "D", :descr),
    do: "D.subtype?(ExHdlValueType.of(v), #{term_code(t, "D")})"

  defp prop_code({:member, t, :v}, p, _m), do: "#{p}.member?(#{term_code(t, p)}, v)"
  defp prop_code({:and, a, b}, p, m), do: "(#{prop_code(a, p, m)} and #{prop_code(b, p, m)})"
  defp prop_code({:or, a, b}, p, m), do: "(#{prop_code(a, p, m)} or #{prop_code(b, p, m)})"
  defp prop_code({:not, a}, p, m), do: "not #{prop_code(a, p, m)}"
  defp prop_code({:iff, a, b}, p, m), do: "(#{prop_code(a, p, m)} == #{prop_code(b, p, m)})"

  defp prop_code({:implies, a, b}, p, m),
    do: "(not #{prop_code(a, p, m)} or #{prop_code(b, p, m)})"

  defp term_code(var, _p) when var in [:a, :b, :c], do: Atom.to_string(var)
  defp term_code(:term, p), do: "#{p}.term()"
  defp term_code(:none, p), do: "#{p}.none()"
  defp term_code({:negation, t}, p), do: "#{p}.negation(#{term_code(t, p)})"
  defp term_code({op, l, r}, p), do: "#{p}.#{op}(#{term_code(l, p)}, #{term_code(r, p)})"

  defp value_type_helper do
    """
    defmodule ExHdlValueType do
      alias Module.Types.Descr, as: D
      def of(v) when is_integer(v), do: D.integer()
      def of(v) when is_float(v), do: D.float()
      def of(v) when is_atom(v), do: D.atom([v])
      def of(v) when is_binary(v), do: D.binary()
      def of([]), do: D.empty_list()
      def of(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.map(&of/1) |> D.tuple()
    end
    """
  end
end
