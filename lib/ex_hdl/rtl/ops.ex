defmodule ExHdl.RTL.Ops do
  @moduledoc """
  Operators that build `ExHdl.RTL.Expr` values when an operand is a
  hardware expression and fall back to `Kernel`/`Bitwise` otherwise, so
  generator code can mix elaboration-time integers and hardware freely.

  Imported (with the conflicting `Kernel` functions excluded) inside
  `ExHdl.RTL.module/3`, `ExHdl.RTL.black_box/3` and `ExHdl.RTL.rtl/1`
  blocks. Not usable in guards.

  `if`/`unless` with a hardware condition record a conditional statement
  (inside `comb`/`sync` only); with an Elixir value they behave as usual.
  `and`/`or`/`not`/`&&`/`||`/`!` work on 1-bit values. `target <~ value`
  assigns; it binds tighter than comparisons, `and`/`or` and the bitwise
  operators, so write `x <~ (a == b)` (forgetting the parentheses raises).
  """

  import Kernel,
    except: [
      +: 2,
      -: 2,
      -: 1,
      *: 2,
      ==: 2,
      !=: 2,
      <: 2,
      <=: 2,
      >: 2,
      >=: 2,
      and: 2,
      or: 2,
      not: 1,
      &&: 2,
      ||: 2,
      !: 1,
      if: 2,
      unless: 2
    ]

  alias ExHdl.RTL.{Assigned, Builder, Expr}
  alias __MODULE__, as: Ops

  @doc false
  def kernel_excludes,
    do: [
      +: 2,
      -: 2,
      -: 1,
      *: 2,
      ==: 2,
      !=: 2,
      <: 2,
      <=: 2,
      >: 2,
      >=: 2,
      and: 2,
      or: 2,
      not: 1,
      &&: 2,
      ||: 2,
      !: 1,
      if: 2,
      unless: 2
    ]

  defguardp num(a, b) when Kernel.and(is_number(a), is_number(b))

  def a + b when num(a, b), do: Kernel.+(a, b)
  def a + b, do: Expr.add(a, b)

  def a - b when num(a, b), do: Kernel.-(a, b)
  def a - b, do: Expr.sub(a, b)

  def -a when is_number(a), do: Kernel.-(a)
  def -a, do: Expr.neg(a)

  def a * b when num(a, b), do: Kernel.*(a, b)
  def a * b, do: Expr.mul(a, b)

  for {op, f} <- [==: :eq, !=: :ne, <: :lt, <=: :le, >: :gt, >=: :ge] do
    def unquote(op)(%Assigned{} = a, _b), do: Assigned.raise!(a)
    def unquote(op)(%Expr{} = a, b), do: Expr.unquote(f)(a, b)
    def unquote(op)(a, %Expr{} = b), do: Expr.unquote(f)(a, b)
    def unquote(op)(a, b), do: Kernel.unquote(op)(a, b)
  end

  def a &&& b when Kernel.and(is_integer(a), is_integer(b)), do: Bitwise.band(a, b)
  def a &&& b, do: Expr.band(a, b)

  def a ||| b when Kernel.and(is_integer(a), is_integer(b)), do: Bitwise.bor(a, b)
  def a ||| b, do: Expr.bor(a, b)

  def ~~~a when is_integer(a), do: Bitwise.bnot(a)
  def ~~~a, do: Expr.bnot(a)

  def a <<< b when Kernel.and(is_integer(a), is_integer(b)), do: Bitwise.bsl(a, b)
  def a <<< b, do: Expr.shl(a, b)

  def a >>> b when Kernel.and(is_integer(a), is_integer(b)), do: Bitwise.bsr(a, b)
  def a >>> b, do: Expr.shr(a, b)

  @doc "Assignment: combinational in `comb` and at module level, a register update in `sync`."
  def target <~ value, do: Builder.assign(target, value)

  defmacro left and right, do: quote(do: Ops.__and__(unquote(left), fn -> unquote(right) end))
  defmacro left or right, do: quote(do: Ops.__or__(unquote(left), fn -> unquote(right) end))
  defmacro not value, do: quote(do: Ops.__not__(unquote(value)))
  defmacro left && right, do: quote(do: Ops.__andand__(unquote(left), fn -> unquote(right) end))
  defmacro left || right, do: quote(do: Ops.__oror__(unquote(left), fn -> unquote(right) end))
  defmacro !value, do: quote(do: Ops.__bang__(unquote(value)))

  # Runtime dispatch (keeps short-circuit evaluation for Elixir values).
  @doc false
  def __and__(%Assigned{} = l, _r), do: Assigned.raise!(l)
  def __and__(%Expr{} = l, r), do: Expr.land(l, r.())
  def __and__(l, r), do: Kernel.and(l, r.())
  @doc false
  def __or__(%Assigned{} = l, _r), do: Assigned.raise!(l)
  def __or__(%Expr{} = l, r), do: Expr.lor(l, r.())
  def __or__(l, r), do: Kernel.or(l, r.())
  @doc false
  def __not__(%Expr{} = v), do: Expr.lnot(v)
  def __not__(v), do: Kernel.not(v)
  @doc false
  def __andand__(%Assigned{} = l, _r), do: Assigned.raise!(l)
  def __andand__(%Expr{} = l, r), do: Expr.land(l, r.())
  def __andand__(l, r), do: Kernel.&&(l, r.())
  @doc false
  def __oror__(%Assigned{} = l, _r), do: Assigned.raise!(l)
  def __oror__(%Expr{} = l, r), do: Expr.lor(l, r.())
  def __oror__(l, r), do: Kernel.||(l, r.())
  @doc false
  def __bang__(%Expr{} = v), do: Expr.lnot(v)
  def __bang__(v), do: Kernel.!(v)

  defmacro if(condition, clauses) do
    {then, other} = clauses!(clauses, "if")

    quote do
      Builder.if_(unquote(condition), fn -> unquote(then) end, fn -> unquote(other) end)
    end
  end

  defmacro unless(condition, clauses) do
    {then, other} = clauses!(clauses, "unless")

    quote do
      Builder.if_(unquote(condition), fn -> unquote(other) end, fn -> unquote(then) end)
    end
  end

  defp clauses!(clauses, name) do
    Kernel.unless(Kernel.and(Keyword.keyword?(clauses), Keyword.has_key?(clauses, :do)),
      do: raise(ArgumentError, "#{name} expects do/else clauses")
    )

    {Keyword.fetch!(clauses, :do), Keyword.get(clauses, :else)}
  end
end
