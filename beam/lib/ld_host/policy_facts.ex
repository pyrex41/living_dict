defmodule LdHost.PolicyFacts do
  @moduledoc """
  Non-Forth policy facts from oracle-passing product writes.

  `INSTALL-*` is plumbing (copies artifact bytes). These facts record
  what the *file* encoded: alias maps, DEFAULTS keys, KeyError raises.
  They are not sequent theorems and do not go through Shen.

  Cross-job injection into observation is off unless `LD_POLICY_DICT=1`.
  Same-job facts always land on Run state for the next episode.
  """

  alias LdHost.{Extract, Policy, Retrieve}

  @excluded_exact MapSet.new(["claims.json"])
  @excluded_prefixes [".sb/", ".livingdict-run/", ".git/"]

  def dict_observe_enabled?(opts \\ []) do
    raw =
      case Keyword.fetch(opts, :policy_dict) do
        {:ok, value} -> value
        :error -> System.get_env("LD_POLICY_DICT") || "0"
      end

    cond do
      raw in [true, :true, 1, "1"] -> true
      is_binary(raw) and String.downcase(String.trim(raw)) in ["1", "true"] -> true
      true -> false
    end
  end

  @doc "Product paths only — same exclusions as extract."
  def product_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&excluded?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def excluded?(path) do
    rel = path |> to_string() |> String.trim_leading("/")

    MapSet.member?(@excluded_exact, rel) or
      Enum.any?(@excluded_prefixes, &String.starts_with?(rel, &1))
  end

  @doc """
  Build a fact from current workspace bytes vs optional previous contents.
  `written` is relative paths mutated this episode.
  """
  def extract(workspace, written, previous \\ %{}) do
    paths = product_paths(written)

    if paths == [] do
      nil
    else
      files =
        Map.new(paths, fn rel ->
          {rel, read_text(Path.join(workspace, rel))}
        end)

      aliases = paths |> Enum.map(&{&1, aliases_in(files[&1])}) |> Enum.reject(&is_nil(elem(&1, 1)))
      defaults = paths |> Enum.map(&{&1, defaults_keys(files[&1])}) |> Enum.reject(&(&1 |> elem(1) == []))

      %{
        "path_region" => paths,
        "aliases" => Map.new(aliases),
        "forbids_aliases" => Enum.any?(aliases, fn {_p, m} -> m == %{} end),
        "defaults_keys" => Map.new(defaults),
        "renames" => renames(previous, files),
        "must_raise_keyerror" => Enum.any?(Map.values(files), &keyerror?/1),
        "content_sha256" => content_digest(files)
      }
    end
  end

  def persist(_dictionary_dir, nil), do: :ok

  def persist(dictionary_dir, fact) when is_map(fact) do
    dir = Path.join(dictionary_dir, "policy")
    File.mkdir_p!(dir)
    slug = slug(fact["path_region"] || [])
    File.write!(Path.join(dir, slug <> ".json"), JSON.encode!(fact) <> "\n")
    :ok
  end

  def load(nil), do: []

  def load(dictionary_dir) do
    dir = Path.join(dictionary_dir, "policy")

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.flat_map(fn file ->
          case JSON.decode(File.read!(Path.join(dir, file))) do
            {:ok, %{} = fact} -> [fact]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  def matching(facts, grant_globs) when is_list(facts) do
    grant = grant_globs |> List.wrap() |> Enum.map(&to_string/1)

    Enum.filter(facts, fn fact ->
      region = List.wrap(fact["path_region"] || fact[:path_region]) |> Enum.map(&to_string/1)
      region != [] and glob_overlap?(region, grant)
    end)
  end

  def matching(_, _), do: []

  def format_observe(facts) when is_list(facts) and facts != [] do
    rows =
      Enum.map(facts, fn fact ->
        region = Enum.join(List.wrap(fact["path_region"]), ", ")
        aliases = inspect(fact["aliases"] || %{})
        keys = inspect(fact["defaults_keys"] || %{})
        forbids = fact["forbids_aliases"] == true
        raises = fact["must_raise_keyerror"] == true
        renames = inspect(fact["renames"] || %{})

        "- #{region}: forbids_aliases=#{forbids} must_raise_keyerror=#{raises} aliases=#{aliases} defaults_keys=#{keys} renames=#{renames}"
      end)

    "\nLAST SUCCESSFUL POLICY (from product files, not Forth; may not match THIS goal):\n" <>
      Enum.join(rows, "\n")
  end

  def format_observe(_), do: ""

  def plumbing_note(prelude_words) do
    if Enum.any?(List.wrap(prelude_words), &String.starts_with?(&1, "INSTALL-")) do
      "\nPLUMBING: INSTALL-* words copy the artifact bytes you emit at that path. " <>
        "They do not encode key names, aliases, or tests. Change the artifact to change the product.\n"
    else
      ""
    end
  end

  @doc "Unified-ish before/after for product paths. No command strings."
  def format_diffs(before, afters, paths) do
    chunks =
      product_paths(paths)
      |> Enum.map(fn rel ->
        old = Map.get(before || %{}, rel)
        new = Map.get(afters || %{}, rel)
        if old == new, do: nil, else: diff_block(rel, old, new)
      end)
      |> Enum.reject(&is_nil/1)

    if chunks == [] do
      ""
    else
      "\nPRODUCT DIFF:\n" <> Enum.join(chunks, "\n")
    end
  end

  def snapshot_texts(workspace, paths) do
    Map.new(product_paths(paths), fn rel ->
      {rel, read_text(Path.join(workspace, rel))}
    end)
  end

  def failed_checks(report) when is_map(report) do
    report
    |> Map.get(:claims, Map.get(report, "claims", []))
    |> List.wrap()
    |> Enum.reject(fn c -> truthy?(c[:passed] || c["passed"]) end)
    |> Enum.map(&sanitize_claim/1)
  end

  def failed_checks(_), do: []

  def format_failed_checks(report) do
    checks = failed_checks(report)
    parsed = Enum.flat_map(checks, & &1[:verifier_checks] || [])

    body =
      if parsed != [] do
        JSON.encode!(parsed)
      else
        JSON.encode!(checks)
      end

    "\nFAILED CHECKS:\n" <> body <> "\n"
  end

  defp sanitize_claim(claim) when is_map(claim) do
    id = claim[:id] || claim["id"]
    kind = claim[:kind] || claim["kind"]
    reason = claim[:reason] || claim["reason"]
    output = claim[:output] || claim["output"]
    verifier = claim[:verifier_checks] || claim["verifier_checks"] || parse_verifier_checks(output)

    %{
      id: id,
      kind: kind,
      reason: reason,
      output: output && String.slice(to_string(output), 0, 2000),
      verifier_checks: verifier
    }
  end

  def parse_verifier_checks(output) when is_binary(output) do
    case extract_json_object(output) do
      {:ok, %{"checks" => checks}} when is_list(checks) ->
        Enum.map(checks, fn c ->
          %{
            "id" => c["id"] || c["name"],
            "passed" => c["passed"],
            "detail" => c["detail"] || c["message"] || c["reason"]
          }
        end)

      _ ->
        []
    end
  end

  def parse_verifier_checks(_), do: []

  defp extract_json_object(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        slice = binary_part(text, start, byte_size(text) - start)

        case JSON.decode(slice) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> try_trim_json(slice)
        end

      :nomatch ->
        :error
    end
  end

  defp try_trim_json(slice) do
    case Regex.run(~r/\{(?:[^{}]|\{[^{}]*\})*\}/s, slice) do
      [obj] ->
        case JSON.decode(obj) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp aliases_in(nil), do: nil
  defp aliases_in(src), do: python_map(src, "ALIASES")

  defp defaults_keys(nil), do: []
  defp defaults_keys(src), do: python_map(src, "DEFAULTS") |> then(fn m -> if m, do: Map.keys(m) |> Enum.sort(), else: [] end)

  defp python_map(src, name) do
    case Regex.run(~r/#{name}\s*=\s*\{([^}]*)\}/s, src) do
      [_, inner] ->
        keys =
          Regex.scan(~r/['"]([A-Za-z_][A-Za-z0-9_]*)['"]\s*:/, inner)
          |> Enum.map(fn [_, k] -> k end)

        if inner =~ ~r/^\s*$/, do: %{}, else: Map.new(keys, &{&1, true})

      _ ->
        nil
    end
  end

  defp keyerror?(nil), do: false
  defp keyerror?(src), do: String.contains?(src, "KeyError")

  defp renames(previous, files) when is_map(previous) and is_map(files) do
    Enum.reduce(files, %{}, fn {rel, new_src}, acc ->
      old_keys = defaults_keys(Map.get(previous, rel))
      new_keys = defaults_keys(new_src)
      gone = old_keys -- new_keys
      added = new_keys -- old_keys

      cond do
        gone == [] or added == [] -> acc
        length(gone) == 1 and length(added) == 1 -> Map.put(acc, rel, %{hd(gone) => hd(added)})
        true -> Map.put(acc, rel, %{"removed" => gone, "added" => added})
      end
    end)
  end

  defp renames(_, _), do: %{}

  defp content_digest(files) do
    files
    |> Enum.sort()
    |> Enum.map(fn {k, v} -> k <> ":" <> Policy.sha256_hex(v || "") end)
    |> Enum.join(<<0>>)
    |> Policy.sha256_hex()
  end

  defp slug(paths) do
    Extract.word_name(product_paths(paths))
    |> String.replace_prefix("INSTALL-", "POLICY-")
  end

  defp glob_overlap?(region, grant) do
    dummy = %{"effects" => ["read", "write"], "path_region" => region}
    query = Retrieve.host_query(["read", "write"], grant, [])
    Retrieve.eligible?(dummy, query)
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, bin} -> if String.valid?(bin), do: bin, else: nil
      _ -> nil
    end
  end

  defp diff_block(rel, old, new) do
    old_s = old || ""
    new_s = new || ""

    """
    --- a/#{rel}
    +++ b/#{rel}
    <<< previous
    #{String.slice(old_s, 0, 4000)}
    >>> current
    #{String.slice(new_s, 0, 4000)}
    """
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
