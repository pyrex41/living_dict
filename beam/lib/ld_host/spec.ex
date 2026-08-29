defmodule LdHost.Spec do
  @moduledoc """
  Product spec: a yggdrasil-shaken Shen compiler (`shen/product/spec.shen`)
  plus the human sign gate. `compile/1` is not approval — unsigned compiled
  claims keep `check` refused. `sign/2` sets `source: "spec-derived"` and
  records `contract.approved`.

  `compile/1` and `compile_file/1` require `claims`, `globs`, `effects`,
  and `obligation_kinds` as lists (empty is deny-all). Missing lists are
  a compile error, not host defaults. Claim maps may carry the
  `atomize_claim/1` keys (`any`/`must`, `min_bytes`, `timeout_seconds`,
  `depends_on`); any other key is rejected.
  """

  alias LdHost.{Gates, Ledger}

  @approved_sources ~w(approved hidden spec-derived)
  @claim_keys ~w(id kind command path any must min_bytes timeout_seconds depends_on)

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
  (string-keyed JSON shapes also work). Returns `{:error, reason}` for
  unknown kinds or missing required lists.
  """
  def compile(:fixture) do
    ensure_booted!()
    decode_compiled(:kl_spec."compile-fixture"())
  end

  def compile(product) when is_map(product) do
    ensure_booted!()

    case encode_product(product) do
      {:ok, encoded} -> decode_compiled(:kl_spec."compile-product"(encoded))
      {:error, _} = err -> err
    end
  end

  def compile_file(path) do
    case from_json(path |> File.read!() |> JSON.decode!()) do
      {:ok, product} -> compile(product)
      {:error, _} = err -> err
    end
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

  defp from_json(%{"claims" => claims} = data) when is_list(claims) do
    with {:ok, globs} <- required_list(data, "globs"),
         {:ok, effects} <- required_list(data, "effects"),
         {:ok, kinds} <- required_list(data, "obligation_kinds") do
      {:ok, %{claims: claims, globs: globs, effects: effects, obligation_kinds: kinds}}
    end
  end

  defp from_json(_) do
    {:error, "product spec JSON needs claims[], globs[], effects[], obligation_kinds[]"}
  end

  defp required_list(data, key) do
    case Map.fetch(data, key) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "product spec JSON #{key} must be a list"}
      :error -> {:error, "product spec JSON needs #{key}[]"}
    end
  end

  # ---- shen-erl marshalling (same tagged strings as Critic) --------------

  defp shen_str(s), do: {:string, String.to_charlist(to_string(s))}

  defp encode_product(product) do
    with {:ok, claims} <- required_field(product, :claims, "claims"),
         {:ok, globs} <- required_field(product, :globs, "globs"),
         {:ok, effects} <- required_field(product, :effects, "effects"),
         {:ok, kinds} <- required_field(product, :obligation_kinds, "obligation_kinds"),
         {:ok, encoded_claims} <- encode_claims(claims),
         {:ok, encoded_effects} <- map_ok(effects, &encode_effect/1),
         {:ok, encoded_kinds} <- map_ok(kinds, &encode_okind/1) do
      {:ok,
       [
         encoded_claims,
         Enum.map(globs, &shen_str/1),
         encoded_effects,
         encoded_kinds
       ]}
    end
  end

  defp required_field(product, atom_key, name) do
    cond do
      is_list(product[atom_key]) -> {:ok, product[atom_key]}
      is_list(product[name]) -> {:ok, product[name]}
      Map.has_key?(product, atom_key) or Map.has_key?(product, name) ->
        {:error, "product #{name} must be a list"}
      true ->
        {:error, "product needs #{name}[]"}
    end
  end

  defp encode_claims(claims) do
    map_ok(claims, &encode_claim/1)
  end

  defp encode_claim(raw) when is_map(raw) do
    c = Map.new(raw, fn {k, v} -> {to_string(k), v} end)
    unknown = Map.keys(c) -- @claim_keys

    cond do
      unknown != [] ->
        {:error, "unknown claim field: #{hd(unknown)}"}

      true ->
        with {:ok, kind} <- encode_claimkind(c["kind"] || "source") do
          extra = [
            Enum.map(needles(c["any"] || c["must"]), &shen_str/1),
            int_or(c["min_bytes"], 0),
            int_or(c["timeout_seconds"], 60),
            Enum.map(List.wrap(c["depends_on"] || []), &shen_str/1)
          ]

          {:ok,
           [
             shen_str(c["id"] || "claim"),
             kind,
             shen_str(c["command"] || ""),
             shen_str(c["path"] || ""),
             extra
           ]}
        end
    end
  end

  defp encode_claim(_), do: {:error, "claim must be a map"}

  defp needles(nil), do: []
  defp needles(value) when is_binary(value), do: [value]
  defp needles(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp needles(value), do: [to_string(value)]

  defp int_or(value, _default) when is_integer(value), do: value

  defp int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp int_or(_, default), do: default

  defp encode_claimkind(kind) do
    case String.downcase(to_string(kind)) do
      "check" -> {:ok, :check}
      "source" -> {:ok, :source}
      "file" -> {:ok, :file}
      "absent" -> {:ok, :absent}
      _ -> {:error, "unknown claim kind: #{kind}"}
    end
  end

  defp encode_effect(effect) do
    case String.downcase(to_string(effect)) do
      "read" -> {:ok, :read}
      "write" -> {:ok, :write}
      "exec" -> {:ok, :exec}
      _ -> {:error, "unknown effect: #{effect}"}
    end
  end

  defp encode_okind(kind) do
    case String.downcase(to_string(kind)) do
      "node.ready" -> {:ok, :"node-ready"}
      "gate.result" -> {:ok, :"gate-result"}
      "critic.reject" -> {:ok, :"critic-reject"}
      "obligation" -> {:ok, :obligation}
      _ -> {:error, "unknown obligation kind: #{kind}"}
    end
  end

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
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

  defp claim_from_row([id, kind, command, path, [any, min_bytes, timeout, depends_on]]) do
    %{
      "id" => id,
      "kind" => kind,
      "command" => command,
      "path" => path,
      "any" => any,
      "min_bytes" => min_bytes,
      "timeout_seconds" => timeout,
      "depends_on" => depends_on
    }
  end

  defp plain({:string, chars}), do: to_string(chars)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(n) when is_float(n) and n == trunc(n), do: trunc(n)
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
