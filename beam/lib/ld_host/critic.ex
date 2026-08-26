defmodule LdHost.Critic do
  @moduledoc """
  The one critic, served to the BEAM host. One source of truth
  (`shen/critic/validate.shen`), consumed via a yggdrasil-shaken artifact.

  Engine order at boot:

  1. `:luerl` — the Lua artifact (`openresty/dist/critic/app.lua`) in
     pure-Erlang Lua. Currently blocked: the artifact's embedded TCO
     chunks use `goto`, which luerl's compiler cannot parse. The attempt
     is kept because it is cheap and becomes the zero-process path the
     moment either luerl grows goto support or the artifact drops it.
  2. `:node` — the JS artifact (`browser/dist/critic/app.js`) inside a
     persistent node process (`priv/critic_server.mjs`, JSONL protocol).
  3. A future shen-erl yggdrasil target slots in above both.

  Elixir callers see `{:accept, depth, effects}` /
  `{:reject, errors, depth, effects}` regardless of engine.
  """

  use GenServer

  @luerl_glue """
  local P = require("prims")
  local R = require("runtime")

  local function shen_list(arr)
    if R.from_table then return R.from_table(arr) end
    local acc = R.NIL
    for i = #arr, 1, -1 do acc = R.cons(arr[i], acc) end
    return acc
  end

  local function array_from_list(lst)
    local out = {}
    while R.is_cons(lst) do
      local h = lst[1]
      if R.is_cons(h) then
        out[#out + 1] = array_from_list(h)
      elseif R.is_symbol(h) then
        out[#out + 1] = h.name
      elseif h == R.NIL then
        out[#out + 1] = {}
      else
        out[#out + 1] = h
      end
      lst = lst[2]
    end
    return out
  end

  function ld_validate(program, effects, globs, forbidden, artifacts)
    local r = P.F["validate"](program, shen_list(effects), shen_list(globs),
                              shen_list(forbidden), shen_list(artifacts))
    return array_from_list(r)
  end
  """

  # ---- client -----------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Validate a Forth program. Returns
  `{:accept, depth, effects} | {:reject, errors, depth, effects}`,
  or `{:error, reason}` when no critic engine is available.
  """
  def validate(program, allowed_effects, allowed_globs, forbidden_globs, artifact_keys) do
    GenServer.call(
      __MODULE__,
      {:validate, program, allowed_effects, allowed_globs, forbidden_globs, artifact_keys},
      30_000
    )
  end

  def engine, do: GenServer.call(__MODULE__, :engine)

  def repo_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  def lua_artifact, do: Path.join([repo_root(), "openresty", "dist", "critic", "app.lua"])
  def js_artifact, do: Path.join([repo_root(), "browser", "dist", "critic", "app.js"])

  # ---- server -----------------------------------------------------------

  @impl true
  def init(opts) do
    state =
      case boot_luerl(Keyword.get(opts, :lua_artifact, lua_artifact())) do
        {:ok, lua} ->
          %{engine: :luerl, lua: lua}

        {:error, luerl_reason} ->
          case boot_node(Keyword.get(opts, :js_artifact, js_artifact())) do
            {:ok, port} ->
              %{engine: :node, port: port, next_id: 1, luerl_error: luerl_reason}

            {:error, node_reason} ->
              %{engine: :none, error: "luerl: #{luerl_reason}; node: #{node_reason}"}
          end
      end

    {:ok, state}
  end

  defp boot_luerl(artifact) do
    if File.regular?(artifact) do
      lua = :luerl.init()

      with {:ok, _res, lua} <- :luerl.dofile(String.to_charlist(artifact), lua),
           {:ok, _res, lua} <- :luerl.do(@luerl_glue, lua) do
        {:ok, lua}
      else
        {:error, reason, _lua} -> {:error, inspect(reason)}
      end
    else
      {:error, "no lua artifact at #{artifact}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, val -> {:error, "#{kind}: #{inspect(val, limit: 3)}"}
  end

  defp boot_node(artifact) do
    node = System.find_executable("node")
    server = Path.join(:code.priv_dir(:ld_host), "critic_server.mjs")

    cond do
      node == nil ->
        {:error, "node not on PATH"}

      not File.regular?(artifact) ->
        {:error, "no js artifact at #{artifact} — run make browser-shake"}

      true ->
        port =
          Port.open({:spawn_executable, node}, [
            :binary,
            :exit_status,
            {:line, 1_048_576},
            args: [server, artifact]
          ])

        receive do
          {^port, {:data, {:eol, line}}} ->
            case JSON.decode(line) do
              {:ok, %{"ready" => true}} -> {:ok, port}
              _ -> {:error, "critic server bad handshake: #{line}"}
            end

          {^port, {:exit_status, code}} ->
            {:error, "critic server exited #{code} at boot"}
        after
          15_000 -> {:error, "critic server boot timeout"}
        end
    end
  end

  @impl true
  def handle_call(:engine, _from, state), do: {:reply, state.engine, state}

  def handle_call({:validate, _p, _e, _g, _f, _a}, _from, %{engine: :none} = state) do
    {:reply, {:error, state.error}, state}
  end

  def handle_call({:validate, program, effects, globs, forbidden, artifacts}, _from, %{engine: :luerl} = state) do
    args = [program, effects, globs, forbidden, artifacts]

    case :luerl.call_function([:ld_validate], args, state.lua) do
      {:ok, [result], lua} -> {:reply, decode_lua(result), %{state | lua: lua}}
      {:error, reason, _lua} -> {:reply, {:reject, ["critic error: #{inspect(reason)}"], 0, []}, state}
    end
  rescue
    e -> {:reply, {:reject, ["critic error: #{Exception.message(e)}"], 0, []}, state}
  end

  def handle_call({:validate, program, effects, globs, forbidden, artifacts}, _from, %{engine: :node} = state) do
    id = state.next_id

    request =
      JSON.encode!(%{
        id: id,
        program: program,
        effects: effects,
        globs: globs,
        forbidden: forbidden,
        artifacts: artifacts
      })

    Port.command(state.port, request <> "\n")
    reply = await_node(state.port, id, [])
    {:reply, reply, %{state | next_id: id + 1}}
  end

  defp await_node(port, id, _acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case JSON.decode(line) do
          {:ok, %{"id" => ^id} = out} -> decode_node(out)
          {:ok, _other} -> await_node(port, id, [])
          {:error, _} -> await_node(port, id, [])
        end

      {^port, {:exit_status, code}} ->
        {:error, "critic server died (exit #{code})"}
    after
      25_000 -> {:error, "critic timeout"}
    end
  end

  defp decode_node(%{"tag" => "accept"} = out),
    do: {:accept, out["depth"] || 0, out["effects"] || []}

  defp decode_node(%{"tag" => "reject"} = out),
    do: {:reject, out["errors"] || [], out["depth"] || 0, out["effects"] || []}

  defp decode_node(%{"tag" => "error"} = out),
    do: {:reject, ["critic error: #{out["message"]}"], 0, []}

  # luerl returns Lua tables as [{index, value}] proplists.
  defp decode_lua(table) when is_list(table) do
    case Enum.map(table, fn {_k, v} -> plain(v) end) do
      ["accept", depth, effects] -> {:accept, trunc(depth), effects}
      ["reject", errors, depth, effects] -> {:reject, errors, trunc(depth), effects}
      other -> {:error, "unexpected critic result: #{inspect(other)}"}
    end
  end

  defp decode_lua(other), do: {:error, "unexpected critic result: #{inspect(other)}"}

  defp plain(value) when is_list(value), do: Enum.map(value, fn {_k, v} -> plain(v) end)
  defp plain(value) when is_float(value), do: if(value == trunc(value), do: trunc(value), else: value)
  defp plain(value), do: value
end
