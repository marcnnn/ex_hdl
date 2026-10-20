defmodule ExHdl.RTL.ElaborationError do
  @moduledoc "Raised when a module description is inconsistent (drivers, latches, loops, names)."
  defexception [:message]
end

defmodule ExHdl.RTL.DomainError do
  @moduledoc "Raised when logic mixes clock domains outside a CDC cell."
  defexception [:message]
end

defmodule ExHdl.RTL.Domain do
  @moduledoc """
  A clock domain: a clock signal and an optional reset.

    * `clock`, `reset` - signal handles (`ExHdl.RTL.Expr`); with
      `clock_port: false` / `reset_port: false` they are internal wires the
      module drives itself (e.g. from an MMCM black box or a reset
      synchroniser).
    * `reset_kind` - `:sync` or `:async`; `reset_active` - `:low` or `:high`.

  Domains sharing a clock signal are synchronous to each other.
  """
  defstruct [
    :name,
    :clock,
    :reset,
    reset_kind: :sync,
    reset_active: :low,
    clock_port: true,
    reset_port: true
  ]

  @type t :: %__MODULE__{}
end

defmodule ExHdl.RTL.Memory do
  @moduledoc """
  A memory array (`ExHdl.RTL.memory/2`). `style` maps to the `ram_style`
  attribute: `:block` (BRAM), `:ultra` (URAM), `:distributed` (LUTRAM),
  `:registers`, or `:auto` (no attribute).
  """
  defstruct [
    :name,
    :width,
    :depth,
    :addr_width,
    :init,
    :byte,
    style: :auto,
    read_ports: [],
    write_ports: []
  ]

  @type t :: %__MODULE__{}
end

defmodule ExHdl.RTL.Module do
  @moduledoc """
  An elaborated, checked hardware module (the result of
  `ExHdl.RTL.module/3` or `ExHdl.RTL.black_box/3`). Plain data: the SV
  backend, the simulator and other generators read it.

    * `name` - SystemVerilog module name; `kind` - `:module` or `:black_box`.
    * `ports` - ordered `%{name, dir, type, domain, role}`; `role` is
      `:clock`, `:reset` or `:data`. `domain` is a domain name, `:async`
      (driven from any domain, only CDC cells), `:static` (quasi-static,
      no domain) or `nil` (constant / no clocked source).
    * `signals` - name => `%{name, type, kind, domain, reset, attrs}`;
      `decls` the declaration order.
    * `domains` - `ExHdl.RTL.Domain` list, `default_domain` its name.
    * `comb` - `[{target, statements}]` in evaluation order.
    * `sync` - `[{domain, statements}]`.
    * `instances`, `memories`, `bundles`, `fsms`.
    * `params`, `sources`, `model` - black boxes: SV parameters, attached
      SV files, Elixir simulation model.
    * `comb_paths` - output port => input ports it depends on combinationally.
  """
  defstruct [
    :name,
    kind: :module,
    ports: [],
    signals: %{},
    decls: [],
    domains: [],
    default_domain: nil,
    comb: [],
    sync: [],
    instances: [],
    memories: [],
    bundles: [],
    fsms: [],
    params: [],
    sources: %{},
    model: nil,
    comb_paths: %{},
    attrs: []
  ]

  @type t :: %__MODULE__{}

  @doc "The port named `name`."
  def port(%__MODULE__{ports: ports, name: m}, name) do
    Enum.find(ports, &(&1.name == name)) ||
      raise ArgumentError, "module #{m} has no port #{inspect(name)}"
  end

  @doc "Input ports that are neither clocks nor resets."
  def data_inputs(%__MODULE__{ports: ports}),
    do: Enum.filter(ports, &(&1.dir == :input and &1.role == :data))

  @doc "All output ports."
  def outputs(%__MODULE__{ports: ports}), do: Enum.filter(ports, &(&1.dir == :output))

  @doc "The domain named `name`."
  def domain(%__MODULE__{domains: ds, name: m}, name) do
    Enum.find(ds, &(&1.name == name)) ||
      raise ArgumentError, "module #{m} has no domain #{inspect(name)}"
  end

  @doc "All distinct modules of the hierarchy below and including `mod`, children first."
  def hierarchy(%__MODULE__{} = mod) do
    {list, _} = collect(mod, {[], %{}})
    Enum.reverse(list)
  end

  defp collect(%{name: name} = mod, {list, seen}) do
    case seen do
      %{^name => ^mod} ->
        {list, seen}

      %{^name => _other} ->
        raise ExHdl.RTL.ElaborationError,
              "two different modules are named #{mod.name}; give parameterised modules distinct names"

      _ ->
        {list, seen} =
          Enum.reduce(mod.instances, {list, Map.put(seen, mod.name, mod)}, fn i, acc ->
            collect(i.module, acc)
          end)

        {[mod | list], seen}
    end
  end
end
