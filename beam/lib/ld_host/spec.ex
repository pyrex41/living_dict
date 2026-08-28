defmodule LdHost.Spec do
  @moduledoc """
  Product spec: a yggdrasil-shaken Shen compiler (`shen/product/spec.shen`)
  plus the human sign gate. `compile/1` is not approval — unsigned compiled
  claims keep `check` refused. `sign/2` sets `source: "spec-derived"` and
  records `contract.approved`.
  """

  alias LdHost.{Gates, Ledger}

  @approved_sources ~w(approved hidden spec-derived)

  def approved_source?(source) when source in @approved_sources, do: true
  def approved_source?(_), do: false

  def repo_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  def source_file, do: Path.join([repo_root(), "shen", "product", "spec.shen"])

  def artifact_dir, do: Path.join([repo_root(), "beam", "priv", "spec-erl"])

  def beam_artifact, do: Path.join([artifact_dir(), "app-erlang", "ebin"])

  def resolve_beam_artifact do
    System.get_env("LD_SPEC_BEAM") ||
      (File.exists?(Path.join(beam_artifact(), "kl_spec.beam")) && beam_artifact())
  end

  @doc """
  Compile a product to the maps Gates/Host consume.

  Accepts `:fixture` (the yggdrasil-checked product in spec.shen) or a
  map with `:claims` / `:globs` / `:effects` / `:obligation_kinds`
  (string-keyed JSON shapes also work).
  """
  def compile(:fixture) do
    ensure_booted!()
    decode_compiled(:kl_spec."compile-fixture"())
  end

  def compile(product) when is_map(product) do
    ensure_booted!()
    decode_compiled(:kl_spec."compile-product"(encode_product(product)))
  end

  def compile_file(path) do
    compile(from_json(path |> File.read!() |> JSON.decode!()))
  end

  @doc """
  Human gate. `ledger` may be a Ledger pid (commits `contract.approved`)
  or `nil` (CLI defers the commit to `Run.run/2`).
  """
  def sign(compiled, ledger) do
    contract = %{
      claims: Enum.map(compiled.claims, &Gates.atomize_claim/1),
      source: "spec-derived",
      allowed_globs: compiled.globs,
      allowed_effects: compiled.effects,
      obligation_kinds: compiled.obligation_kinds
    }

    if is_pid(ledger) do
      {:ok, _} =
        Ledger.commit(ledger, "contract.approved", %{
          claims: length(contract.claims),
          source: "spec-derived"
        })
    end

    contract
  end

  defp from_json(%{"claims" => claims} = data) do
    %{
      claims: claims,
      globs: data["globs"] || ["**"],
      effects: data["effects"] || ["read", "write", "exec"],
      obligation_kinds: data["obligation_kinds"] || ["obligation"]
    }
  end

  defp from_json(claims) when is_list(claims) do
    %{claims: claims, globs: ["**"], effects: ["read", "write", "exec"], obligation_kinds: ["obligation"]}
  end

  # ---- shen-erl marshalling (same tagged strings as Critic) --------------

  defp shen_str(s), do: {:string, String.to_charlist(to_string(s))}

  defp encode_product(product) do
    claims = product[:claims] || product["claims"] || []
    globs = product[:globs] || product["globs"] || []
    effects = product[:effects] || product["effects"] || []
    kinds = product[:obligation_kinds] || product["obligation_kinds"] || []

    [
      Enum.map(claims, &encode_claim/1),
      Enum.map(globs, &shen_str/1),
      Enum.map(effects, &encode_effect/1),
      Enum.map(kinds, &encode_okind/1)
    ]
  end

  defp encode_claim(raw) do
    c = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    [
      shen_str(c["id"] || "claim"),
      encode_claimkind(c["kind"] || "source"),
      shen_str(c["command"] || ""),
      shen_str(c["path"] || "")
    ]
  end

  defp encode_claimkind(kind) do
    case String.downcase(to_string(kind)) do
      "check" -> :check
      "source" -> :source
      "file" -> :file
      "absent" -> :absent
    end
  end

  defp encode_effect(effect) do
    case to_string(effect) do
      "read" -> :read
      "write" -> :write
      "exec" -> :exec
    end
  end

  defp encode_okind(kind) do
    case to_string(kind) do
      "node.ready" -> :"node-ready"
      "gate.result" -> :"gate-result"
      "critic.reject" -> :"critic-reject"
      "obligation" -> :obligation
    end
  end

  defp decode_compiled([claims, globs, effects, kinds]) do
    globs = plain(globs)
    effects = plain(effects)

    %{
      claims: Enum.map(plain(claims), &claim_from_row/1),
      globs: globs,
      effects: effects,
      allowed_globs: globs,
      allowed_effects: effects,
      obligation_kinds: plain(kinds),
      source: "unsigned"
    }
  end

  defp claim_from_row([id, kind, command, path]) do
    %{
      "id" => id,
      "kind" => kind,
      "command" => command,
      "path" => path
    }
  end

  defp plain({:string, chars}), do: to_string(chars)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(other), do: other

  # ---- boot -------------------------------------------------------------

  defp ensure_booted! do
    if :persistent_term.get({__MODULE__, :booted}, false) do
      :ok
    else
      boot!()
      :persistent_term.put({__MODULE__, :booted}, true)
    end
  end

  defp boot! do
    ebin = resolve_beam_artifact() || raise_missing()
    true = :code.add_patha(String.to_charlist(ebin))

    cond do
      Process.whereis(LdHost.Critic) && LdHost.Critic.engine() == :beam ->
        case LdHost.Critic.boot_modules([:kl_spec]) do
          :ok -> :ok
          {:error, reason} -> raise "kl_spec boot failed: #{reason}"
        end

      :ets.whereis(:_kl_funs_store) == :undefined ->
        :ok = :shen_erl_global_stores.init()
        :shen_erl_kl_primitives.set(:"*stoutput*", :standard_io)
        :shen_erl_kl_primitives.set(:"*stinput*", :standard_io)
        :ok = :shen_erl_kl_compiler.boot_shaken([:kl_kernel, :kl_spec])
        :ok = :shen_erl_kl_compiler.run_shaken([:kl_kernel, :kl_spec])

      true ->
        raise "shen-erl stores exist but critic engine is not :beam — cannot register kl_spec"
    end
  end

  defp raise_missing do
    raise "no shen-erl spec artifact at #{beam_artifact()} — run make spec-erl"
  end
end
