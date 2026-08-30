defmodule LdHost.Store do
  @moduledoc """
  Layer A content-addressable objects: blobs at `<root>/<aa>/<sha256>`.

  Identity dictionaries intern as canonical JSON (HARNESS_CARTRIDGE §3).
  `as_of` stays workspace `{path: sha256}` only — this is not dictionary-as-of.
  """

  defstruct [:root]

  @sha256_hex ~r/^[0-9a-f]{64}$/

  def new(root), do: %__MODULE__{root: Path.expand(root)}

  @doc "SHA-256 hex of `data`. Writes `<aa>/<hex>` once; identical bytes are a no-op."
  def intern(%__MODULE__{root: root}, data) when is_binary(data) do
    digest = LdHost.Policy.sha256_hex(data)
    dest = blob_path(root, digest)

    unless File.exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      tmp = dest <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        File.write!(tmp, data)

        case File.rename(tmp, dest) do
          :ok -> :ok
          {:error, _} -> File.rm(tmp)
        end
      after
        File.rm(tmp)
      end
    end

    digest
  end

  def get(%__MODULE__{root: root}, digest) when is_binary(digest) do
    hex = LdHost.Dictionary.digest_hex(digest)

    if hex && Regex.match?(@sha256_hex, hex) do
      path = blob_path(root, hex)

      case File.read(path) do
        {:ok, data} ->
          actual = LdHost.Policy.sha256_hex(data)

          if actual == hex do
            {:ok, data}
          else
            {:error, :corrupt}
          end

        {:error, _} ->
          {:error, :missing}
      end
    else
      {:error, :missing}
    end
  end

  def has?(%__MODULE__{} = store, digest) do
    match?({:ok, _}, get(store, digest))
  end

  @doc """
  Canonical JSON: UTF-8, keys sorted lexicographically at every level,
  separators `(',', ':')` — Python `json.dumps(..., sort_keys=True,
  separators=(',', ':'))`.
  """
  def canonical_json(term), do: IO.iodata_to_binary(encode(term))

  @doc """
  Derived `[e, a, v, tx]` rows. Overlay kinds project as HARNESS_CARTRIDGE §9.
  `dictionary.overlay.rejected` errors are skipped when already projected
  from `critic.rejected`.
  """
  def facts(events) when is_list(events) do
    {rows, _episode, _seen} =
      Enum.reduce(events, {[], 0, MapSet.new()}, fn event, {rows, episode, seen} ->
        kind = field(event, "kind")
        payload = field(event, "payload") || %{}
        seq = field(event, "sequence")

        case kind do
          "episode.planned" ->
            {rows, episode + 1, seen}

          "critic.rejected" ->
            ep = field(payload, "episode") || episode
            errors = List.wrap(field(payload, "errors") || [])

            {rows, seen} =
              Enum.reduce(errors, {rows, seen}, fn err, {rs, se} ->
                key = {ep, to_string(err)}

                if MapSet.member?(se, key) do
                  {rs, se}
                else
                  {[{e(ep), ":critic/error", to_string(err), seq} | rs], MapSet.put(se, key)}
                end
              end)

            {rows, episode, seen}

          "dictionary.overlay.proposed" ->
            oh = LdHost.Dictionary.digest_hex(field(payload, "overlay_hash"))
            parent = LdHost.Dictionary.digest_hex(field(payload, "parent") || field(payload, "parent_hash"))
            pc = LdHost.Dictionary.digest_hex(field(payload, "primitive_contract"))

            rows =
              rows
              |> maybe_row(oh && parent, {"overlay/#{oh}", ":overlay/parent", "dict/#{parent}", seq})
              |> maybe_row(oh && pc, {"overlay/#{oh}", ":overlay/primitive-contract", pc, seq})

            {rows, episode, seen}

          "dictionary.overlay.admitted" ->
            oh = LdHost.Dictionary.digest_hex(field(payload, "overlay_hash"))
            dh = LdHost.Dictionary.digest_hex(field(payload, "dictionary_hash"))
            parent = LdHost.Dictionary.digest_hex(field(payload, "parent") || field(payload, "parent_hash"))
            effects = sorted_join(field(payload, "effects") || field(payload, "predicted_effects"))

            rows =
              rows
              |> maybe_row(oh, {"overlay/#{oh}", ":overlay/verdict", ":admit", seq})
              |> maybe_row(oh && effects, {"overlay/#{oh}", ":overlay/effects", effects, seq})
              |> maybe_row(dh && parent, {"dict/#{dh}", ":dict/parent", "dict/#{parent}", seq})

            {rows, episode, seen}

          "dictionary.overlay.rejected" ->
            oh = LdHost.Dictionary.digest_hex(field(payload, "overlay_hash"))
            ep = field(payload, "episode") || episode
            errors = List.wrap(field(payload, "errors") || [])

            rows = maybe_row(rows, oh, {"overlay/#{oh}", ":overlay/verdict", ":reject", seq})

            {rows, seen} =
              Enum.reduce(errors, {rows, seen}, fn err, {rs, se} ->
                key = {ep, to_string(err)}

                if MapSet.member?(se, key) do
                  {rs, se}
                else
                  {[{e(ep), ":critic/error", to_string(err), seq} | rs], MapSet.put(se, key)}
                end
              end)

            {rows, episode, seen}

          "dictionary.promoted" ->
            word = to_string(field(payload, "word") || "")
            digest = LdHost.Dictionary.digest_hex(field(payload, "sha256"))
            promo = field(payload, "episode") || episode
            contract = field(payload, "contract")
            dict = LdHost.Dictionary.digest_hex(field(payload, "parent_dict") || field(payload, "dictionary_hash"))
            effects = sorted_join(field(payload, "effects"))
            region = sorted_join(field(payload, "path_region"))

            rows =
              if word != "" and digest do
                [
                  {"word/#{word}", ":word/content", "blob:#{digest}", seq},
                  {"word/#{word}", ":word/promoted-by", e(promo), seq}
                  | rows
                ]
              else
                rows
              end

            rows =
              rows
              |> maybe_row(word != "" and contract, {"word/#{word}", ":word/contract", contract, seq})
              |> maybe_row(word != "" and dict, {"word/#{word}", ":word/dict", "dict/#{dict}", seq})
              |> maybe_row(word != "" and effects, {"word/#{word}", ":word/effects", effects, seq})
              |> maybe_row(word != "" and region, {"word/#{word}", ":word/region", region, seq})

            {rows, episode, seen}

          "dictionary.narrowed" ->
            word = to_string(field(payload, "word") || "")
            old = LdHost.Dictionary.digest_hex(field(payload, "from") || field(payload, "narrowed_from"))
            cex = field(payload, "counterexample") || field(payload, "task_id")

            rows =
              rows
              |> maybe_row(word != "" and old, {"word/#{word}", ":word/narrowed-from", "dict/#{old}", seq})
              |> maybe_row(word != "" and cex, {"word/#{word}", ":word/counterexample", cex, seq})

            {rows, episode, seen}

          "dictionary.discarded" ->
            oh = LdHost.Dictionary.digest_hex(field(payload, "overlay_hash"))
            {maybe_row(rows, oh, {"overlay/#{oh}", ":overlay/verdict", ":discard", seq}), episode, seen}

          _ ->
            {rows, episode, seen}
        end
      end)

    Enum.reverse(rows)
  end

  defp blob_path(root, digest), do: Path.join([root, String.slice(digest, 0, 2), digest])

  defp e(n), do: "episode/#{n}"

  defp maybe_row(rows, pred, row) do
    if pred, do: [row | rows], else: rows
  end

  defp sorted_join(nil), do: nil
  defp sorted_join(""), do: nil

  defp sorted_join(list) when is_list(list) do
    case list |> Enum.map(&to_string/1) |> Enum.sort() do
      [] -> nil
      items -> Enum.join(items, ", ")
    end
  end

  defp sorted_join(other), do: to_string(other)

  defp field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom, do: Map.get(map, atom)
    end
  end

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(s) when is_binary(s), do: JSON.encode!(s)

  defp encode(list) when is_list(list) do
    [?[, Enum.map_join(list, ",", &encode/1), ?]]
  end

  defp encode(map) when is_map(map) do
    keys =
      map
      |> Map.keys()
      |> Enum.map(&key_string/1)
      |> Enum.sort()

    inner =
      Enum.map_join(keys, ",", fn k ->
        [JSON.encode!(k), ?:, encode(map_fetch(map, k))]
      end)

    [?{, inner, ?}]
  end

  defp key_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_string(k) when is_binary(k), do: k

  defp map_fetch(map, k) when is_binary(k) do
    cond do
      Map.has_key?(map, k) -> Map.fetch!(map, k)
      true -> Map.fetch!(map, String.to_existing_atom(k))
    end
  rescue
    ArgumentError -> Map.fetch!(map, k)
  end
end
