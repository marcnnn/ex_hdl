defmodule ExHdl.Test.MemoryKernels do
  @moduledoc false
  # Stream kernels with large state (:memory hardware class).
  import Nx.Defn

  @doc """
  Forney convolutional interleaver (`ExSdr.Comm.ConvInterleaver`) on bytes:
  symbol n leaves through branch j = n mod I, delayed by I * j * M symbols
  (I * (I - 1 - j) * M deinterleaving). State: `{line, pos}`, the last
  I * (I - 1) * M input bytes (oldest first) and n mod I.
  """
  defn conv_interleave_step(x, state, opts \\ []) do
    opts = keyword!(opts, [:branches, :depth, inverse: false])
    {line, pos} = state
    i = opts[:branches]
    m = opts[:depth]
    hist = i * (i - 1) * m
    window = Nx.concatenate([line, Nx.reshape(x, {1})])
    j = pos |> Nx.remainder(i) |> Nx.as_type(:s32)
    branch_delay = if opts[:inverse], do: (i - 1 - j) * m, else: j * m
    out = Nx.take(window, hist - i * branch_delay)
    next_pos = Nx.remainder(Nx.as_type(pos, :u16) + 1, i) |> Nx.as_type(:u8)
    {out, {Nx.slice(window, [1], [hist]), next_pos}}
  end

  def conv_interleave_state(i, m, fill \\ 0),
    do: {Nx.broadcast(Nx.tensor(fill, type: :u8), {i * (i - 1) * m}), Nx.tensor(0, type: :u8)}
end
