defmodule ExHdl.Block do
  @moduledoc """
  Hardware for signal processing blocks described as `%NxFixed.Block{}`
  (`:stream` kind): the kernel's argument templates come from the block's
  item type and number format, so a block generates without further
  description.

      block = ExSdr.Filters.block(:fir_filter_fff, taps: taps, format: NxFixed.Num.q(16, 15))
      {:ok, design} = ExHdl.Block.scan_to_sv(block, name: "fir63")

  Items map to samples as follows (`format` is the block's `:format` option):

    * `:real` - a scalar in `format` (`NxFixed.Fixed`), `:complex` - `{re, im}` of those
    * `:real_pair`, `:complex_pair` - a tuple of two such items (two-input blocks)
    * `:bit`, `:byte`, `:symbol` - an unsigned 8-bit integer
    * `:none` - sources: an unused `u8` sample that paces the output

  Blocks without state (`init: nil`) get a `u8` zero as state, as in
  `NxFixed.Block.run/4`. Parameter ports are named `param0`, `param1`, ...
  unless `:param_names` is given. Float formats are rejected: hardware
  needs a fixed-point `:format`.
  """

  alias NxFixed.Block
  alias NxFixed.Num
  alias NxFixed.Num.Format

  defmodule Error do
    defexception [:message]
  end

  @doc "The template of one input sample of `block`."
  def sample_template(%Block{item: {item, _}} = block), do: item_template(item, format(block))

  @doc "The template of one item of type `item` in `format` (`nil` for integer items)."
  def item_template(item, format) do
    case item do
      :real -> real(format)
      :complex -> {real(format), real(format)}
      :real_pair -> {real(format), real(format)}
      :complex_pair -> {{real(format), real(format)}, {real(format), real(format)}}
      i when i in [:bit, :byte, :symbol, :none] -> Nx.template({}, :u8)
      other -> raise Error, "no hardware sample for items of type #{inspect(other)}"
    end
  end

  @doc "The initial state (a `u8` zero for stateless blocks)."
  def init(%Block{init: nil}), do: Nx.tensor(0, type: :u8)
  def init(%Block{init: init}), do: init

  @doc "Argument templates for `ExHdl.DSP.analyze_scan/3` (the state is argument 1)."
  def args(%Block{} = block) do
    check_stream!(block)
    template = &Nx.Defn.Composite.traverse(&1, fn t -> Nx.to_template(Nx.tensor(t)) end)

    [sample_template(block), template.(init(block)) | Enum.map(block.params, template)] ++
      [block.opts]
  end

  @doc "`ExHdl.DSP.analyze_scan/3` for a block; `opts` as there (`:ii`, `:channels`, timing)."
  def analyze(%Block{} = block, opts \\ []) do
    ExHdl.DSP.analyze_scan(block.fun, args(block), [state: 1] ++ opts)
  end

  @doc """
  Generates the module of a block (`ExHdl.DSP.scan_to_sv/3`). Options as
  there; `:name` defaults to the block name, `:init` to the block's.
  """
  def scan_to_sv(%Block{} = block, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, Atom.to_string(block.name))
      |> Keyword.put_new(:init, init(block))

    ExHdl.DSP.scan_to_sv(block.fun, args(block), [state: 1] ++ opts)
  end

  defp check_stream!(%Block{kind: :stream}), do: :ok

  defp check_stream!(%Block{kind: kind, name: name}),
    do:
      raise(
        Error,
        "#{name}: only :stream blocks generate as stream kernels, this one is #{inspect(kind)}"
      )

  defp format(%Block{opts: opts}), do: Keyword.get(opts, :format)

  defp real(%Format{kind: :fixed} = f), do: Num.zeros({}, f) |> template()

  defp real(%Format{kind: :float}),
    do: raise(Error, "float format: hardware needs a fixed-point :format (NxFixed.Num.q/3)")

  defp real(nil), do: raise(Error, "the block has no :format option for its real items")

  defp template(container), do: Nx.Defn.Composite.traverse(container, &Nx.to_template/1)
end
