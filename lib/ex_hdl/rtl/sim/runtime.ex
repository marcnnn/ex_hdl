defmodule ExHdl.RTL.Sim.Runtime do
  @moduledoc false
  # Helpers called by the simulator engines (and by generated code).

  import Bitwise

  alias ExHdl.RTL.Expr

  @doc "Calls `model.outputs/2` and checks the values; returns them as a tuple in `outputs` order."
  def model_outputs(model, state, inputs, outputs) do
    outs = model.outputs(state, inputs)

    outputs
    |> Enum.map(fn {p, _id, t} ->
      v =
        Map.get(outs, p) ||
          raise ArgumentError, "model #{inspect(model)} returned no value for output #{p}"

      unless is_integer(v) and v in Expr.range(t),
        do:
          raise(
            ArgumentError,
            "model #{inspect(model)}: #{p} = #{inspect(v)} does not fit #{Expr.fmt(t)}"
          )

      v
    end)
    |> List.to_tuple()
  end

  @doc "Bit mask of the bytes enabled in `be` (`n` bytes of `byte` bits)."
  def byte_mask(be, n, byte) do
    m = (1 <<< byte) - 1

    Enum.reduce(0..(n - 1)//1, 0, fn i, acc ->
      if (be >>> i &&& 1) == 1, do: acc ||| m <<< (i * byte), else: acc
    end)
  end

  @doc "Writes `data` under `mask` at `addr` of a memory map (ignored beyond `depth`)."
  def mem_write(words, addr, _data, _mask, depth) when addr >= depth, do: words

  def mem_write(words, addr, data, mask, _depth) do
    old = Map.get(words, addr, 0)
    Map.put(words, addr, (old &&& ~~~mask) ||| (data &&& mask))
  end

  @doc "Parity of a non-negative integer."
  def parity(v), do: parity(v, 0)
  defp parity(0, acc), do: acc
  defp parity(v, acc), do: parity(v &&& v - 1, bxor(acc, 1))

  @doc "Evaluates `e` (whose sub-expressions in `subs` order are replaced by `values`) with `Expr.eval/3`."
  def eval(%Expr{} = e, values) do
    {e, []} = replace(e, values)
    Expr.eval(e, fn _ -> raise "unreachable" end)
  end

  defp replace(%Expr{args: args} = e, values) do
    {args, values} = Enum.map_reduce(args, values, &replace_arg/2)
    {%{e | args: args}, values}
  end

  defp replace_arg(%Expr{type: t}, [v | rest]), do: {%Expr{op: :const, args: [v], type: t}, rest}

  defp replace_arg(l, values) when is_list(l), do: Enum.map_reduce(l, values, &replace_arg/2)
  defp replace_arg(v, values), do: {v, values}
end
