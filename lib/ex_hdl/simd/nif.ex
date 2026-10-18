defmodule ExHdl.SIMD.NIF do
  @moduledoc false
  # Raw bindings to c_src/simd (see ExHdl.SIMD for the public API).
  @on_load :load

  def load do
    path = :filename.join(:code.priv_dir(:ex_hdl), ~c"native/libexhdl_simd")

    # Keep the module loadable without the NIF; ExHdl.SIMD.available?/0 tells.
    case :erlang.load_nif(path, 0) do
      :ok -> :persistent_term.put({__MODULE__, :loaded}, true)
      {:error, reason} -> :persistent_term.put({__MODULE__, :loaded}, {:error, reason})
    end

    :ok
  end

  def ddc_q15(_i, _q, _phase, _inc, _gain, _lut_bits, _round, _table),
    do: :erlang.nif_error(:not_loaded)

  def ddc_q15_scalar(_i, _q, _phase, _inc, _gain, _lut_bits, _round, _table),
    do: :erlang.nif_error(:not_loaded)

  def fir_q15(_history, _x, _taps, _round), do: :erlang.nif_error(:not_loaded)
  def one_pole_q15(_x, _y0, _alpha, _round), do: :erlang.nif_error(:not_loaded)
  def simd_target, do: :erlang.nif_error(:not_loaded)
end
