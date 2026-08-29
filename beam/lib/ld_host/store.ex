defmodule LdHost.Store do
  @moduledoc """
  Content-addressable objects and a derived datom view of events.jsonl.

  Port of `harness/src/livingdict/store.py` — blobs, canonical trees,
  `facts/1`, `as_of/2`. Iteration only; no query language, no GC, no daemon.
  """

  alias LdHost.Policy

  @sha256_hex ~r/^[0-9a-f]{64}$/

  def objects_root(run_dir) do
    case System.get_env("LIVINGDICT_OBJECTS") do
      env when is_binary(env) and env != "" -> env
      _ -> Path.join(run_dir, "objects")
    end
  end

  def intern(dir, data) when is_binary(data) do
    digest = Policy.sha256_hex(data)
    put_blob(dir, digest, data)
    digest
  end

  def intern_tree(dir, files) when is_map(files) do
    intern(dir, tree_bytes(files))
  end

  def intern_snapshot(dir, workspace, files) when is_map(files) do
    if is_binary(dir) and is_binary(workspace) do
      Enum.each(files, fn {rel, _} ->
        case File.read(Path.join(workspace, rel)) do
          {:ok, data} -> intern(dir, data)
          _ -> :ok
        end
      end)
    end

    intern_tree(dir, files)
  end

  def tree_bytes(files) when is_map(files) do
    inner =
      files
      |> Enum.map(fn {path, digest} -> {to_string(path), to_string(digest)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {path, digest} ->
        JSON.encode!(path) <> ":" <> JSON.encode!(digest)
      end)

    "{" <> inner <> "}"
  end

  def tree_digest(files), do: Policy.sha256_hex(tree_bytes(files))

  def put_blob(nil, _digest, _content), do: :ok

  def put_blob(dir, digest, content)
      when is_binary(dir) and is_binary(digest) and is_binary(content) do
    case blob_path(dir, digest) do
      nil ->
        :ok

      path ->
        if File.exists?(path) do
          :ok
        else
          File.mkdir_p!(Path.dirname(path))
          tmp = Path.join(Path.dirname(path), ".tmp-#{digest}-#{System.unique_integer([:positive])}")

          try do
            File.write!(tmp, content)

            case File.rename(tmp, path) do
              :ok ->
                :ok

              {:error, _} ->
                unless File.exists?(path), do: File.write!(path, content)
                :ok
            end
          after
            File.rm(tmp)
          end
        end
    end
  end

  def put_blob(_, _, _), do: :ok

  def get(dir, digest) do
    digest = to_string(digest)

    case blob_path(dir, digest) do
      nil ->
        {:error, :invalid}

      path ->
        case File.read(path) do
          {:ok, data} ->
            if Policy.sha256_hex(data) == digest, do: {:ok, data}, else: {:error, :corrupt}

          {:error, _} ->
            {:error, :missing}
        end
    end
  end

  def get_tree(dir, digest) do
    case get(dir, digest) do
      {:ok, data} ->
        case JSON.decode(data) do
          {:ok, map} when is_map(map) ->
            {:ok, Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)}

          _ ->
            {:error, :corrupt}
        end

      other ->
        other
    end
  end

  def has?(dir, digest) when is_binary(dir) do
    case blob_path(dir, to_string(digest)) do
      nil -> false
      path -> File.regular?(path)
    end
  end

  def has?(_, _), do: false

  @doc "Derived [e, a, v, tx] rows. tx is the event sequence. Never persisted."
  def facts(events, store \\ nil) do
    {rows, _episode, _last_sha} =
      Enum.reduce(events, {[], 0, %{}}, fn event, {rows, episode, last_sha} ->
        {kind, payload, seq} = event_fields(event)

        case kind do
          "episode.planned" ->
            episode = episode + 1

            rows =
              maybe_fact(rows, "episode/#{episode}", ":episode/fingerprint", field(payload, :fingerprint), seq)

            {rows, episode, hashes_or(payload, last_sha)}

          "critic.accepted" ->
            rows =
              if episode > 0,
                do: [{"episode/#{episode}", ":critic/verdict", ":accept", seq} | rows],
                else: rows

            {rows, episode, last_sha}

          "critic.rejected" ->
            rows =
              if episode > 0 do
                rows = [{"episode/#{episode}", ":critic/verdict", ":reject", seq} | rows]

                Enum.reduce(list_of(field(payload, :errors)), rows, fn err, acc ->
                  [{"episode/#{episode}", ":critic/error", to_string(err), seq} | acc]
                end)
              else
                rows
              end

            {rows, episode, last_sha}

          "artifacts.applied" ->
            last_sha = hashes_or(payload, last_sha)

            rows =
              Enum.reduce(list_of(field(payload, :keys)), rows, fn key, acc ->
                case Map.get(last_sha, to_string(key)) do
                  digest when is_binary(digest) and digest != "" ->
                    [{"ws/#{key}", ":file/content", "blob:#{digest}", seq} | acc]

                  _ ->
                    acc
                end
              end)

            {rows, episode, last_sha}

          "gates.measured" ->
            files =
              case measured_tree(payload, store) do
                {:replace, files} -> files
                :keep -> %{}
              end

            rows = [{"run", ":gates/passed", gates_passed(payload), seq} | rows]

            rows =
              Enum.reduce(Enum.sort(files), rows, fn {path, digest}, acc ->
                [{"ws/#{path}", ":file/content", "blob:#{digest}", seq} | acc]
              end)

            {rows, episode, last_sha}

          "dictionary.promoted" ->
            word = to_string(field(payload, :word) || "")
            digest = field(payload, :sha256)
            promo = field(payload, :episode) || episode

            rows =
              if word != "" and is_binary(digest) and digest != "" do
                [
                  {"word/#{word}", ":word/promoted-by", "episode/#{promo}", seq},
                  {"word/#{word}", ":word/content", "blob:#{digest}", seq}
                  | rows
                ]
              else
                rows
              end

            {rows, episode, last_sha}

          _ ->
            {rows, episode, last_sha}
        end
      end)

    Enum.reverse(rows)
  end

  @doc """
  Workspace tree `{path => sha256}` at or before `seq`.

  A measured tree replaces the whole view (it sees deletions); artifacts
  applied after the last measurement overlay it.
  """
  def as_of(events, seq, store \\ nil) do
    limit = seq_int(seq)

    {current, have_tree, last_hash, _last_sha} =
      Enum.reduce(events, {%{}, false, nil, %{}}, fn event, {current, have_tree, last_hash, last_sha} ->
        {kind, payload, event_seq} = event_fields(event)

        if event_seq > limit do
          {current, have_tree, last_hash, last_sha}
        else
          case kind do
            "episode.planned" ->
              {current, have_tree, last_hash, hashes_or(payload, last_sha)}

            "artifacts.applied" ->
              last_sha = hashes_or(payload, last_sha)

              current =
                Enum.reduce(list_of(field(payload, :keys)), current, fn key, acc ->
                  case Map.get(last_sha, to_string(key)) do
                    digest when is_binary(digest) and digest != "" ->
                      Map.put(acc, to_string(key), digest)

                    _ ->
                      acc
                  end
                end)

              {current, have_tree, last_hash, last_sha}

            "gates.measured" ->
              tree_hash = field(payload, :tree_after) || field(payload, :tree_before)
              last_hash = if is_binary(tree_hash) and tree_hash != "", do: tree_hash, else: last_hash

              # Explicit files (including %{}) replaces the view so deletions
              # to an empty tree are visible; missing files keep the overlay.
              case measured_tree(payload, store) do
                {:replace, files} -> {files, true, last_hash, last_sha}
                :keep -> {current, have_tree, last_hash, last_sha}
              end

            _ ->
              {current, have_tree, last_hash, last_sha}
          end
        end
      end)

    cond do
      have_tree ->
        current

      current != %{} ->
        current

      is_binary(last_hash) and store != nil ->
        case get_tree(store, last_hash) do
          {:ok, files} -> files
          _ -> current
        end

      true ->
        current
    end
  end

  defp maybe_fact(rows, _e, _a, value, _seq) when value in [nil, ""], do: rows
  defp maybe_fact(rows, e, a, value, seq), do: [{e, a, to_string(value), seq} | rows]

  defp hashes_or(payload, fallback) do
    case field(payload, :artifact_sha256) do
      hashes when is_map(hashes) -> Map.new(hashes, fn {k, v} -> {to_string(k), to_string(v)} end)
      _ -> fallback
    end
  end

  # {:replace, files} even when files is %{} — a measured empty tree is a
  # deletion, not "no snapshot". :keep means the payload had no tree.
  defp measured_tree(payload, store) do
    case field(payload, :files) do
      files when is_map(files) ->
        {:replace, Map.new(files, fn {k, v} -> {to_string(k), to_string(v)} end)}

      _ ->
        tree_hash = field(payload, :tree_after) || field(payload, :tree_before)

        if is_binary(store) and is_binary(tree_hash) and has?(store, tree_hash) do
          case get_tree(store, tree_hash) do
            {:ok, files} -> {:replace, files}
            _ -> :keep
          end
        else
          :keep
        end
    end
  end

  defp gates_passed(payload) do
    report = field(payload, :report)

    cond do
      is_map(report) ->
        truthy?(field(report, :passed) || field(report, :ok))

      true ->
        truthy?(field(payload, :ok) || field(payload, :passed))
    end
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp event_fields(event) when is_map(event) do
    kind = to_string(field(event, :kind) || "")
    payload = field(event, :payload) || %{}
    payload = if is_map(payload), do: payload, else: %{}
    {kind, payload, seq_int(field(event, :sequence))}
  end

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp list_of(nil), do: []
  defp list_of(list) when is_list(list), do: list
  defp list_of(other), do: [other]

  defp seq_int(seq) when is_integer(seq), do: seq

  defp seq_int(seq) when is_binary(seq) do
    case Integer.parse(seq) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp seq_int(_), do: 0

  defp blob_path(dir, sha) when is_binary(dir) and is_binary(sha) do
    if sha =~ @sha256_hex, do: Path.join([dir, String.slice(sha, 0, 2), sha])
  end

  defp blob_path(_, _), do: nil
end
