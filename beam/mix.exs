defmodule LdHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :ld_host,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {LdHost.Application, []}
    ]
  end

  defp deps do
    [
      # Lua-in-pure-Erlang: runs the yggdrasil-shaken Shen critic artifact
      # (openresty/dist/critic/app.lua) with zero non-BEAM dependencies.
      {:luerl, "~> 1.2"},
      # HTTP client for the xAI planner.
      {:req, "~> 0.5"},
      # Actor framework: obligation agents wrap Jido.Agent lifecycles.
      {:jido, "~> 2.3"}
    ]
  end
end
