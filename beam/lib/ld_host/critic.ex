defmodule LdHost.Critic do
  @moduledoc """
  The one critic, served to the BEAM host. One source of truth
  (`shen/critic/validate.shen`), consumed via a yggdrasil-shaken artifact.

  Engine order at boot:

  1. `:beam` — the shen-erl artifact (`openresty/dist/critic-erl/`,
     yggdrasil `--target erlang`): the typed Shen critic compiled to
     actual BEAM modules (`kl_kernel`, `kl_validate`) loaded into THIS
     VM. Shen strings are `{:string, charlist}`, cons cells are native
     lists, `validate/5` is a plain exported function. Zero processes,
     zero marshalling layers beyond tagged strings.
  2. `:luerl` — the Lua artifact in pure-Erlang Lua (blocked on luerl
     goto support; kept as a cheap probe).
  3. `:node` — the JS artifact in a persistent node process.

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
    validate(program, allowed_effects, allowed_globs, forbidden_globs, artifact_keys, [])
  end

  @doc """
  Validate `program` against an optional catalog of already-bound word
  rows `{name, in, out, effects}` (or vocab tuples). Empty catalog is
  `validate/5`.
  """
  def validate(program, allowed_effects, allowed_globs, forbidden_globs, artifact_keys, catalog) do
    GenServer.call(
      __MODULE__,
      {:validate, program, allowed_effects, allowed_globs, forbidden_globs, artifact_keys, catalog},
      30_000
    )
  end

  def engine, do: GenServer.call(__MODULE__, :engine)

  def repo_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  def lua_artifact, do: Path.join([repo_root(), "openresty", "dist", "critic", "app.lua"])
  def js_artifact, do: Path.join([repo_root(), "browser", "dist", "critic", "app.js"])
  def beam_artifact, do: Path.join([repo_root(), "openresty", "dist", "critic-erl", "app-erlang", "ebin"])

  # Artifact resolution order: explicit opt -> env var -> the app's priv
  # dir (a mix release ships the artifacts there) -> the dev checkout's
  # dist paths. priv_dir is consulted at RUNTIME: at compile time the
  # release's priv dir does not exist yet.
  def resolve_beam_artifact(opts \\ []) do
    Keyword.get(opts, :beam_artifact) ||
      System.get_env("LD_CRITIC_BEAM") ||
      priv_artifact(["critic-erl", "ebin"]) ||
      beam_artifact()
  end

  def resolve_js_artifact(opts \\ []) do
    Keyword.get(opts, :js_artifact) ||
      System.get_env("LD_CRITIC_JS") ||
      priv_artifact(["critic", "app.js"]) ||
      js_artifact()
  end

  defp priv_artifact(segments) do
    case :code.priv_dir(:ld_host) do
      {:error, _} ->
        nil

      priv ->
        path = Path.join([to_string(priv) | segments])
        if File.exists?(path), do: path
    end
  end

  # ---- server -----------------------------------------------------------

  @impl true
  def init(opts) do
    state =
      with {:error, beam_reason} <- boot_beam(resolve_beam_artifact(opts)),
           {:error, luerl_reason} <- boot_luerl(Keyword.get(opts, :lua_artifact, lua_artifact())),
           {:error, node_reason} <- boot_node(resolve_js_artifact(opts)) do
        %{engine: :none, error: "beam: #{beam_reason}; luerl: #{luerl_reason}; node: #{node_reason}"}
      else
        {:ok, :beam} -> %{engine: :beam}
        {:ok, lua} -> %{engine: :luerl, lua: lua}
        {:ok, :node, port} -> %{engine: :node, port: port, next_id: 1}
      end

    {:ok, state}
  end

  # shen-erl boot, mirroring the launcher's --shaken path: named ETS
  # stores (owned by this GenServer; a restart re-creates them), stdio
  # globals, MFA registration + kernel init, then user toplevels.
  defp boot_beam(ebin) do
    if File.dir?(ebin) and File.exists?(Path.join(ebin, "kl_validate.beam")) do
      true = :code.add_patha(String.to_charlist(ebin))
      :ok = :shen_erl_global_stores.init()
      :shen_erl_kl_primitives.set(:"*stoutput*", :standard_io)
      :shen_erl_kl_primitives.set(:"*stinput*", :standard_io)
      :ok = :shen_erl_kl_compiler.boot_shaken([:kl_kernel, :kl_validate])
      :ok = :shen_erl_kl_compiler.run_shaken([:kl_kernel, :kl_validate])
      {:ok, :beam}
    else
      {:error, "no shen-erl artifact at #{ebin} — run yggdrasil build --target erlang"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, val -> {:error, "#{kind}: #{inspect(val, limit: 3)}"}
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
              {:ok, %{"ready" => true}} -> {:ok, :node, port}
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

  def handle_call({:validate, _p, _e, _g, _f, _a, _c}, _from, %{engine: :none} = state) do
    {:reply, {:error, state.error}, state}
  end

  def handle_call({:validate, program, effects, globs, forbidden, artifacts}, from, state) do
    handle_call({:validate, program, effects, globs, forbidden, artifacts, []}, from, state)
  end

  def handle_call({:validate, program, effects, globs, forbidden, artifacts, catalog}, _from, %{engine: :beam} = state) do
    tokens = apply(:kl_validate, :"tokenise-program", [shen_str(program)])
    rows = shen_catalog(catalog)

    result =
      apply(:kl_validate, :"validate-catalog", [
        tokens,
        rows,
        shen_strs(effects),
        shen_strs(globs),
        shen_strs(forbidden),
        shen_strs(artifacts)
      ])

    {:reply, decode_beam(result), state}
  rescue
    e -> {:reply, {:reject, ["critic error: #{Exception.message(e)}"], 0, []}, state}
  catch
    {:simple_error, message} -> {:reply, {:reject, [to_string(message)], 0, []}, state}
    kind, val -> {:reply, {:reject, ["critic error: #{kind} #{inspect(val, limit: 3)}"], 0, []}, state}
  end

  def handle_call({:validate, _p, _e, _g, _f, _a, catalog}, _from, %{engine: engine} = state)
      when engine in [:luerl, :node] and catalog != [] do
    {:reply, {:error, "catalog validate requires the beam critic"}, state}
  end

  def handle_call({:validate, program, effects, globs, forbidden, artifacts, _catalog}, _from, %{engine: :luerl} = state) do
    args = [program, effects, globs, forbidden, artifacts]

    case :luerl.call_function([:ld_validate], args, state.lua) do
      {:ok, [result], lua} -> {:reply, decode_lua(result), %{state | lua: lua}}
      {:error, reason, _lua} -> {:reply, {:reject, ["critic error: #{inspect(reason)}"], 0, []}, state}
    end
  rescue
    e -> {:reply, {:reject, ["critic error: #{Exception.message(e)}"], 0, []}, state}
  end

  def handle_call({:validate, program, effects, globs, forbidden, artifacts, _catalog}, _from, %{engine: :node} = state) do
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

  # ---- shen-erl marshalling: {:string, charlist} strings, native lists.

  defp shen_str(s), do: {:string, String.to_charlist(s)}
  defp shen_strs(list), do: Enum.map(list, &shen_str/1)

  defp shen_catalog(rows) when is_list(rows) do
    Enum.flat_map(rows, fn row ->
      case shen_catalog_row(row) do
        nil -> []
        wordrow -> [wordrow]
      end
    end)
  end

  defp shen_catalog(_), do: []

  defp shen_catalog_row({name, _tokens, {ins, outs, effects}, _source})
       when is_list(ins) and is_list(outs) and is_list(effects) do
    shen_wordrow(name, length(ins), length(outs), effects)
  end

  defp shen_catalog_row({name, inn, out, effects})
       when is_integer(inn) and is_integer(out) and is_list(effects) do
    shen_wordrow(name, inn, out, effects)
  end

  defp shen_catalog_row([name, inn, out, effects])
       when is_integer(inn) and is_integer(out) and is_list(effects) do
    shen_wordrow(name, inn, out, effects)
  end

  defp shen_catalog_row(_), do: nil

  defp shen_wordrow(name, inn, out, effects) do
    [shen_str(to_string(name) |> String.upcase()), inn, out, shen_strs(effects)]
  end

  defp decode_beam([:accept, depth, effects]), do: {:accept, depth, plain_beam(effects)}

  defp decode_beam([:reject, errors, depth, effects]),
    do: {:reject, plain_beam(errors), depth, plain_beam(effects)}

  defp decode_beam(other), do: {:error, "unexpected critic result: #{inspect(other, limit: 5)}"}

  defp plain_beam({:string, chars}), do: to_string(chars)
  defp plain_beam(list) when is_list(list), do: Enum.map(list, &plain_beam/1)
  defp plain_beam(other), do: other

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
