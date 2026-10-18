defmodule ExHdl.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_hdl,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end,
      make_clean: ["clean"],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nx, "~> 1.0"},
      # SIMD NIF (c_src/simd): C++ NIF helpers and the make-based build.
      {:fine, "~> 0.1.6", runtime: false},
      {:elixir_make, "~> 0.9", runtime: false},
      # Optional: fast CPU execution of stream kernels (ExHdl.DSP.run_scan/5, compiler: EXLA).
      {:exla, "~> 1.0", optional: true},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end
end
