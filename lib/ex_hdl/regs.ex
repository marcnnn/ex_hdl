defmodule ExHdl.Regs do
  @moduledoc ~S"""
  Register maps: one declaration gives the AXI4-Lite slave
  (`ExHdl.Regs.RTL`), host-side encode/decode helpers (this module), a C
  header (`ExHdl.Regs.CHeader`) and a Markdown table
  (`ExHdl.Regs.Markdown`).

      defmodule Mixer.Regs do
        use ExHdl.Regs

        defregs "mixer_regs" do
          register :id, doc: "Identification" do
            field :version, 0..15, :ro, const: 0x0102
          end

          register :ctrl, strobe: :write do
            field :enable, 0, :rw, reset: 1, doc: "Mixer running"
            field :mode, 1..2, :rw, enum: [off: 0, mono: 1, stereo: 2]
          end

          register :irq, offset: 0x10 do
            field :overflow, 0, :w1c, doc: "Sample FIFO overflowed"
          end

          register :gain, count: 8 do
            field :value, 0..15, :rw, reset: 0x4000
          end

          window :coeffs, offset: 0x1000, size: 0x400, latency: 1
        end
      end

      Mixer.Regs.offset(:gain, 3)                    #=> 0x20
      Mixer.Regs.encode(:ctrl, mode: :stereo)       #=> 0b101
      Mixer.Regs.decode(:ctrl, 0b101)               #=> %{enable: 1, mode: :stereo}
      Mixer.Regs.rtl()                              #=> %ExHdl.RTL.Module{name: "mixer_regs"}

  `defregs/3` evaluates the map at compile time and defines `regmap/0`,
  `offset/1,2`, `window_offset/2`, `encode/2`, `decode/2`, `update/3`,
  `reset_value/1`, `rtl/0`, `c_header/0` and `markdown/0` in the calling
  module. `regmap/3` builds the same `%ExHdl.Regs{}` at run time (for maps
  that depend on parameters); the functions of this module take it as
  first argument.

  ## Registers

  `register name, opts do fields end`. Options:

    * `offset:` byte offset (multiple of 4). Default: the first free word
      after the previously declared register or window.
    * `count:` makes an array of registers `name[0..count-1]`, `stride:`
      bytes apart (default 4).
    * `strobe:` `:write`, `:read`, `:both` or `false` (default): adds
      registered pulse outputs `<reg>_wr` (high in the cycle the written
      value appears on the field outputs) and `<reg>_rd` (one cycle after
      a read).
    * `doc:`.

  Registers are 32 bits wide.

  ## Fields

  `field name, bits, access \\ :rw, opts \\ []` where `bits` is a bit
  number or an ascending range `lo..hi`. Access types and their hardware:

  | Access | Software | Hardware ports |
  |---|---|---|
  | `:rw` | read/write | output `<reg>_<field>` |
  | `:ro` | read only | input `<reg>_<field>` (none with `const:`) |
  | `:wo` | write only, reads 0 | output `<reg>_<field>` |
  | `:w1c` | read, write 1 clears | output, input `<reg>_<field>_set` |
  | `:w1s` | read, write 1 sets | output, input `<reg>_<field>_clr` |
  | `:rc` | read clears | output, input `<reg>_<field>_set` |

  Hardware set/clear inputs act bitwise every cycle. When software and
  hardware act on a bit in the same cycle, the event that would be lost
  otherwise wins: a hardware set beats a `w1c` write or an `rc` read, a
  software `w1s` write beats a hardware clear. Writes honour `wstrb` byte
  lanes for all writable access types.

  Options: `reset:` (default 0), `enum:` (`[name: value]`), `const:` (for
  `:ro`), `doc:`. Array elements use ports `<reg>_<i>_<field>`.

  ## Memory windows

  `window name, size: bytes, offset: bytes, latency: 1, access: :rw`
  forwards an address range to a RAM port (`ExHdl.RTL.Interface.mem_port/1`
  as master, prefix `<window>`, word address `log2(size) - 2` bits, byte
  enables). `size` is a power of two of at least 8 bytes and `offset` a
  multiple of it. `latency` is the cycles from `en` to valid `rdata`
  (1 for a block RAM without output register). `access: :ro` never
  writes, `:wo` reads 0 without accessing the RAM.
  """

  import Bitwise

  alias __MODULE__.{Field, Register, Window}

  defstruct [:name, :addr_width, data_width: 32, registers: [], windows: [], doc: nil]

  @type t :: %__MODULE__{}

  @accesses [:rw, :ro, :wo, :w1c, :w1s, :rc]

  defmodule Field do
    @moduledoc "A field of an `ExHdl.Regs` register: bits `lo..lo + width - 1`."
    defstruct [:name, :lo, :width, :access, reset: 0, enum: [], const: nil, doc: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Register do
    @moduledoc "A register (or an array of `count` registers `stride` bytes apart)."
    defstruct [:name, :offset, count: nil, stride: 4, fields: [], strobe: false, doc: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Window do
    @moduledoc "A memory window: `size` bytes at `offset` forwarded to a RAM port."
    defstruct [:name, :offset, :size, latency: 1, access: :rw, doc: nil]
    @type t :: %__MODULE__{}
  end

  # -- DSL -------------------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      import ExHdl.Regs,
        only: [
          defregs: 2,
          defregs: 3,
          regmap: 2,
          regmap: 3,
          register: 2,
          register: 3,
          field: 2,
          field: 3,
          field: 4,
          window: 2
        ]
    end
  end

  @doc """
  Defines the register map `name` at compile time plus host helpers in the
  calling module (see the moduledoc). Options: `addr_width:` AXI address
  bits (default: enough for the highest address), `doc:`.
  """
  defmacro defregs(name, opts \\ [], do: body) do
    quote do
      @__ex_hdl_regs__ ExHdl.Regs.build(unquote(name), unquote(opts), fn -> unquote(body) end)

      @doc "The register map (`%ExHdl.Regs{}`)."
      def regmap, do: @__ex_hdl_regs__

      @doc "Byte offset of register `reg` (element `index` of an array)."
      def offset(reg, index \\ nil), do: ExHdl.Regs.offset(@__ex_hdl_regs__, reg, index)

      @doc "Byte offset of word `word` of memory window `window`."
      def window_offset(window, word),
        do: ExHdl.Regs.window_offset(@__ex_hdl_regs__, window, word)

      @doc "Register word from field values (unnamed fields take their reset value)."
      def encode(reg, fields), do: ExHdl.Regs.encode(@__ex_hdl_regs__, reg, fields)

      @doc "Field values of a register word read from hardware."
      def decode(reg, word), do: ExHdl.Regs.decode(@__ex_hdl_regs__, reg, word)

      @doc "`word` with the given fields replaced."
      def update(reg, word, fields), do: ExHdl.Regs.update(@__ex_hdl_regs__, reg, word, fields)

      @doc "Reset value of a register."
      def reset_value(reg), do: ExHdl.Regs.reset_value(@__ex_hdl_regs__, reg)

      @doc "The AXI4-Lite slave (`ExHdl.Regs.RTL.build/1`)."
      def rtl, do: ExHdl.Regs.RTL.build(@__ex_hdl_regs__)

      @doc "C header text (`ExHdl.Regs.CHeader`)."
      def c_header, do: ExHdl.Regs.CHeader.render(@__ex_hdl_regs__)

      @doc "Markdown documentation (`ExHdl.Regs.Markdown`)."
      def markdown, do: ExHdl.Regs.Markdown.render(@__ex_hdl_regs__)
    end
  end

  @doc "Builds a register map at run time: `regmap \"name\", opts do ... end`."
  defmacro regmap(name, opts \\ [], do: body) do
    quote do
      ExHdl.Regs.build(unquote(name), unquote(opts), fn -> unquote(body) end)
    end
  end

  @doc "Declares a register; see the moduledoc."
  defmacro register(name, opts \\ [], do: body) do
    quote do
      ExHdl.Regs.__register__(unquote(name), unquote(opts), fn -> unquote(body) end)
    end
  end

  @doc "Declares a field of the enclosing register; see the moduledoc."
  def field(name, bits, access \\ :rw, opts \\ [])

  def field(name, bits, opts, []) when is_list(opts), do: field(name, bits, :rw, opts)

  def field(name, bits, access, opts) do
    {lo, width} =
      case bits do
        b when is_integer(b) and b >= 0 ->
          {b, 1}

        %Range{first: lo, last: hi, step: 1} when lo >= 0 and hi >= lo ->
          {lo, hi - lo + 1}

        other ->
          raise ArgumentError,
                "field #{inspect(name)}: bits must be a bit number or an ascending range lo..hi, " <>
                  "got #{inspect(other)}"
      end

    unless access in @accesses,
      do:
        raise(
          ArgumentError,
          "field #{inspect(name)}: access must be one of #{inspect(@accesses)}, got #{inspect(access)}"
        )

    f = %Field{
      name: name!(name, "field"),
      lo: lo,
      width: width,
      access: access,
      reset: Keyword.get(opts, :reset, 0),
      enum: Keyword.get(opts, :enum, []),
      const: Keyword.get(opts, :const),
      doc: Keyword.get(opts, :doc)
    }

    case Process.get(:ex_hdl_regs_fields) do
      nil -> raise ArgumentError, "field/4 belongs inside a register block"
      fs -> Process.put(:ex_hdl_regs_fields, [f | fs])
    end

    nil
  end

  @doc "Declares a memory window; see the moduledoc."
  def window(name, opts) do
    w = %Window{
      name: name!(name, "window"),
      offset: Keyword.get(opts, :offset),
      size: Keyword.fetch!(opts, :size),
      latency: Keyword.get(opts, :latency, 1),
      access: Keyword.get(opts, :access, :rw),
      doc: Keyword.get(opts, :doc)
    }

    push({:window, w})
  end

  @doc false
  def __register__(name, opts, fun) do
    if Process.get(:ex_hdl_regs_fields),
      do: raise(ArgumentError, "register #{inspect(name)} inside another register")

    Process.put(:ex_hdl_regs_fields, [])

    fields =
      try do
        fun.()
        Process.get(:ex_hdl_regs_fields)
      after
        Process.delete(:ex_hdl_regs_fields)
      end

    r = %Register{
      name: name!(name, "register"),
      offset: Keyword.get(opts, :offset),
      count: Keyword.get(opts, :count),
      stride: Keyword.get(opts, :stride, 4),
      fields: Enum.sort_by(fields, & &1.lo),
      strobe: Keyword.get(opts, :strobe, false),
      doc: Keyword.get(opts, :doc)
    }

    push({:register, r})
  end

  defp push(item) do
    case Process.get(:ex_hdl_regs_items) do
      nil -> raise ArgumentError, "register/3 and window/2 belong inside defregs/3 or regmap/3"
      items -> Process.put(:ex_hdl_regs_items, [item | items])
    end

    nil
  end

  @doc "Runs `fun` (register and window declarations) and returns the checked map."
  @spec build(String.t() | atom(), keyword(), (-> any())) :: t()
  def build(name, opts, fun) do
    outer = Process.get(:ex_hdl_regs_items)
    Process.put(:ex_hdl_regs_items, [])

    items =
      try do
        fun.()
        Process.get(:ex_hdl_regs_items) |> Enum.reverse()
      after
        if outer,
          do: Process.put(:ex_hdl_regs_items, outer),
          else: Process.delete(:ex_hdl_regs_items)
      end

    name = to_string(name)

    unless name =~ ~r/^[A-Za-z][A-Za-z0-9_]*$/,
      do: raise(ArgumentError, "register map name #{inspect(name)} is not an identifier")

    {items, _} = Enum.map_reduce(items, 0, &place/2)
    regs = for {:register, r} <- items, do: check_register!(r)
    wins = for {:window, w} <- items, do: w

    check_overlaps!(items)
    check_names!(regs, wins)

    top = items |> Enum.map(&item_end/1) |> Enum.max(fn -> 4 end)
    needed = max(ExHdl.RTL.Builder.ceil_log2(top), 3)
    aw = Keyword.get(opts, :addr_width, needed)

    unless is_integer(aw) and aw >= needed and aw <= 64,
      do:
        raise(
          ArgumentError,
          "#{name}: addr_width #{inspect(aw)} too small; the map needs #{needed} bits"
        )

    %__MODULE__{name: name, addr_width: aw, registers: regs, windows: wins, doc: opts[:doc]}
  end

  # Assigns offsets in declaration order; returns the next free byte.
  defp place({:register, r}, next) do
    off = r.offset || next
    check_aligned!(r.name, off, 4)

    unless r.count == nil or (is_integer(r.count) and r.count >= 1),
      do: raise(ArgumentError, "register #{r.name}: count must be a positive integer")

    unless is_integer(r.stride) and r.stride >= 4 and rem(r.stride, 4) == 0,
      do: raise(ArgumentError, "register #{r.name}: stride must be a multiple of 4")

    r = %{r | offset: off}
    {{:register, r}, max(next, item_end({:register, r}))}
  end

  defp place({:window, w}, next) do
    unless is_integer(w.size) and w.size >= 8 and band(w.size, w.size - 1) == 0,
      do: raise(ArgumentError, "window #{w.name}: size must be a power of two >= 8 bytes")

    unless is_integer(w.latency) and w.latency >= 1,
      do: raise(ArgumentError, "window #{w.name}: latency must be >= 1")

    unless w.access in [:rw, :ro, :wo],
      do: raise(ArgumentError, "window #{w.name}: access must be :rw, :ro or :wo")

    off = w.offset || div(next + w.size - 1, w.size) * w.size
    check_aligned!(w.name, off, w.size)
    w = %{w | offset: off}
    {{:window, w}, max(next, item_end({:window, w}))}
  end

  defp check_aligned!(name, off, align) do
    unless is_integer(off) and off >= 0 and rem(off, align) == 0,
      do: raise(ArgumentError, "#{name}: offset #{inspect(off)} is not a multiple of #{align}")
  end

  defp item_end({:register, r}), do: r.offset + (r.count || 1) * r.stride - r.stride + 4
  defp item_end({:window, w}), do: w.offset + w.size

  defp spans({:register, r}),
    do: for(i <- 0..((r.count || 1) - 1), do: {r.offset + i * r.stride, 4, r.name})

  defp spans({:window, w}), do: [{w.offset, w.size, w.name}]

  defp check_overlaps!(items) do
    items
    |> Enum.flat_map(&spans/1)
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{a, sa, na}, {b, _, nb}] ->
      if a + sa > b,
        do:
          raise(ArgumentError, "#{na} and #{nb} overlap at offset 0x#{Integer.to_string(b, 16)}")
    end)
  end

  defp check_names!(regs, wins) do
    names = Enum.map(regs, & &1.name) ++ Enum.map(wins, & &1.name)
    dup = names -- Enum.uniq(names)
    if dup != [], do: raise(ArgumentError, "duplicate register/window names #{inspect(dup)}")
  end

  defp check_register!(r) do
    if r.fields == [], do: raise(ArgumentError, "register #{r.name} has no fields")

    names = Enum.map(r.fields, & &1.name)
    dup = names -- Enum.uniq(names)
    if dup != [], do: raise(ArgumentError, "register #{r.name}: duplicate fields #{inspect(dup)}")

    unless r.strobe in [false, :write, :read, :both],
      do: raise(ArgumentError, "register #{r.name}: strobe must be :write, :read, :both or false")

    r.fields
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      if a.lo + a.width > b.lo,
        do: raise(ArgumentError, "register #{r.name}: fields #{a.name} and #{b.name} overlap")
    end)

    Enum.each(r.fields, &check_field!(r, &1))
    r
  end

  defp check_field!(r, f) do
    where = "#{r.name}.#{f.name}"
    max = (1 <<< f.width) - 1

    if f.lo + f.width > 32, do: raise(ArgumentError, "#{where}: bits beyond 31")

    unless is_integer(f.reset) and f.reset in 0..max,
      do: raise(ArgumentError, "#{where}: reset #{inspect(f.reset)} does not fit #{f.width} bits")

    if f.const != nil do
      unless f.access == :ro,
        do: raise(ArgumentError, "#{where}: const: is only for :ro fields")

      unless is_integer(f.const) and f.const in 0..max,
        do: raise(ArgumentError, "#{where}: const #{inspect(f.const)} does not fit")
    end

    unless Keyword.keyword?(f.enum) and
             Enum.all?(f.enum, fn {_, v} -> is_integer(v) and v in 0..max end),
           do: raise(ArgumentError, "#{where}: enum values must be integers that fit the field")

    vals = Keyword.values(f.enum)

    if length(Enum.uniq(vals)) != length(vals),
      do: raise(ArgumentError, "#{where}: duplicate enum values")
  end

  defp name!(name, what) do
    unless is_atom(name) and Atom.to_string(name) =~ ~r/^[a-z][a-z0-9_]*$/,
      do:
        raise(
          ArgumentError,
          "#{what} names are lowercase atoms (letters, digits, _), got #{inspect(name)}"
        )

    name
  end

  # -- lookup ----------------------------------------------------------------------------

  @doc "The register named `name`."
  @spec register!(t(), atom()) :: Register.t()
  def register!(%__MODULE__{registers: rs, name: m}, name) do
    Enum.find(rs, &(&1.name == name)) ||
      raise ArgumentError, "#{m} has no register #{inspect(name)}"
  end

  @doc "The window named `name`."
  @spec window!(t(), atom()) :: Window.t()
  def window!(%__MODULE__{windows: ws, name: m}, name) do
    Enum.find(ws, &(&1.name == name)) ||
      raise ArgumentError, "#{m} has no window #{inspect(name)}"
  end

  @doc "The field `field` of register `reg`."
  @spec field!(t(), atom(), atom()) :: Field.t()
  def field!(%__MODULE__{} = m, reg, field) do
    r = register!(m, reg)

    Enum.find(r.fields, &(&1.name == field)) ||
      raise ArgumentError, "#{m.name}.#{reg} has no field #{inspect(field)}"
  end

  @doc "In-place mask of a field."
  def mask(%Field{lo: lo, width: w}), do: ((1 <<< w) - 1) <<< lo

  @doc "True when software reads the field's value (`:wo` reads 0)."
  def readable?(%Field{access: a}), do: a != :wo

  @doc "True when software writes affect the field."
  def writable?(%Field{access: a}), do: a in [:rw, :wo, :w1c, :w1s]

  @doc "Concrete registers: `[{name, index_or_nil, offset}]` with arrays expanded."
  def instances(%Register{count: nil} = r), do: [{r.name, nil, r.offset}]

  def instances(%Register{} = r),
    do: for(i <- 0..(r.count - 1), do: {r.name, i, r.offset + i * r.stride})

  # -- host helpers ----------------------------------------------------------------------

  @doc "Byte offset of register `reg` (`index` for arrays)."
  @spec offset(t(), atom(), non_neg_integer() | nil) :: non_neg_integer()
  def offset(%__MODULE__{} = m, reg, index \\ nil) do
    r = register!(m, reg)

    case {r.count, index} do
      {nil, nil} ->
        r.offset

      {nil, _} ->
        raise ArgumentError, "#{reg} is not an array"

      {_, nil} ->
        raise ArgumentError, "#{reg} is an array of #{r.count}; give an index"

      {n, i} when is_integer(i) and i >= 0 and i < n ->
        r.offset + i * r.stride

      {n, i} ->
        raise ArgumentError, "#{reg}: index #{inspect(i)} outside 0..#{n - 1}"
    end
  end

  @doc "Byte offset of word `word` in window `window`."
  def window_offset(%__MODULE__{} = m, window, word) do
    w = window!(m, window)
    n = div(w.size, 4)

    unless is_integer(word) and word >= 0 and word < n,
      do: raise(ArgumentError, "#{window}: word #{inspect(word)} outside 0..#{n - 1}")

    w.offset + 4 * word
  end

  @doc "Reset value of a register as read back (constants included, `ro` inputs as 0)."
  def reset_value(%__MODULE__{} = m, reg) do
    m
    |> register!(reg)
    |> Map.fetch!(:fields)
    |> Enum.reduce(0, fn f, acc ->
      v =
        cond do
          f.const != nil -> f.const
          f.access in [:ro, :wo] -> 0
          true -> f.reset
        end

      acc ||| v <<< f.lo
    end)
  end

  @doc """
  The word to write to `reg`. `fields` (map or keyword list) give values
  by name: integers, enum names, or booleans for 1-bit fields. Writable
  fields not named take their reset value (0 for `w1c`/`w1s`, so
  unnamed status bits are left alone). Read-only fields cannot be named.
  """
  @spec encode(t(), atom(), map() | keyword()) :: non_neg_integer()
  def encode(%__MODULE__{} = m, reg, fields) do
    r = register!(m, reg)
    given = Map.new(fields)
    check_names!(m, r, given)

    Enum.reduce(r.fields, 0, fn f, acc ->
      case Map.fetch(given, f.name) do
        {:ok, v} ->
          if f.access in [:ro, :rc],
            do: raise(ArgumentError, "#{reg}.#{f.name} is #{f.access}; it cannot be written")

          acc ||| value!(reg, f, v) <<< f.lo

        :error ->
          if f.access in [:rw, :wo], do: acc ||| f.reset <<< f.lo, else: acc
      end
    end)
  end

  @doc "`word` with the named fields replaced (read-modify-write); other bits unchanged."
  @spec update(t(), atom(), non_neg_integer(), map() | keyword()) :: non_neg_integer()
  def update(%__MODULE__{} = m, reg, word, fields) do
    r = register!(m, reg)
    word!(word)
    given = Map.new(fields)
    check_names!(m, r, given)

    Enum.reduce(given, word, fn {name, v}, acc ->
      f = Enum.find(r.fields, &(&1.name == name))
      (acc &&& bnot(mask(f))) ||| value!(reg, f, v) <<< f.lo
    end)
    |> band(0xFFFF_FFFF)
  end

  @doc """
  Field values of a word read from `reg`: a map of every readable field,
  enum fields as their name (or the integer when no name matches).
  """
  @spec decode(t(), atom(), non_neg_integer()) :: %{atom() => integer() | atom()}
  def decode(%__MODULE__{} = m, reg, word) do
    word!(word)

    for f <- register!(m, reg).fields, readable?(f), into: %{} do
      v = word >>> f.lo &&& (1 <<< f.width) - 1

      name =
        Enum.find_value(f.enum, v, fn {n, ev} -> if ev == v, do: n end)

      {f.name, name}
    end
  end

  defp word!(w) do
    unless is_integer(w) and w in 0..0xFFFF_FFFF,
      do: raise(ArgumentError, "register words are 32-bit unsigned, got #{inspect(w)}")
  end

  defp check_names!(m, r, given) do
    case Map.keys(given) -- Enum.map(r.fields, & &1.name) do
      [] -> :ok
      bad -> raise ArgumentError, "#{m.name}.#{r.name} has no field(s) #{inspect(bad)}"
    end
  end

  defp value!(reg, f, v) do
    v =
      cond do
        is_boolean(v) and f.width == 1 ->
          if v, do: 1, else: 0

        is_atom(v) ->
          Keyword.get(f.enum, v) ||
            raise ArgumentError, "#{reg}.#{f.name}: unknown enum value #{inspect(v)}"

        true ->
          v
      end

    unless is_integer(v) and v in 0..((1 <<< f.width) - 1),
      do: raise(ArgumentError, "#{reg}.#{f.name}: #{inspect(v)} does not fit #{f.width} bits")

    v
  end
end
