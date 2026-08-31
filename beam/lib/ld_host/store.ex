defmodule LdHost.Store do
  @moduledoc """
  Content-addressable object store. Blobs live at `<root>/<aa>/<sha256>`.
  Bytes are verified against the address on every load.

  `facts/1` and `as_of/2` are derived views over the kernel event log.
  Identity records are not a load gate here — this module interns BLOBS.
  """

  alias LdHost.Policy

  defstruct [:root]

  @digest ~r/^[0-9a-f]{64}$/

  def open(root) when is_binary(root) do
    File.mkdir_p!(root)
    %__MODULE__{root: Path.expand(root)}
  end

  def digest(bytes) when is_binary(bytes), do: Policy.sha256_hex(bytes)

  def digest?(digest) when is_binary(digest),
    do: byte_size(digest) == 64 and digest =~ @digest

  def digest?(_), do: false

  def blob_path(%__MODULE__{root: root}, digest), do: blob_path(root, digest)

  def blob_path(root, digest) when is_binary(root) and is_binary(digest) do
    Path.join([root, String.slice(digest, 0, 2), digest])
  end

  @doc "Intern raw bytes. Idempotent. Returns the sha256 hex."
  def intern(%__MODULE__{} = store, bytes) when is_binary(bytes) do
    digest = digest(bytes)
    dest = blob_path(store, digest)

    unless File.exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      tmp = dest <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        File.write!(tmp, bytes)
        File.rename!(tmp, dest)
      after
        File.rm(tmp)
      end
    end

    digest
  end

  @doc "Load and verify bytes. Never returns a payload that does not hash to `digest`."
  def get(%__MODULE__{} = store, digest) when is_binary(digest) do
    digest = String.downcase(digest)

    cond do
      not digest?(digest) ->
        {:error, {:malformed, "digest"}}

      true ->
        case File.read(blob_path(store, digest)) do
          {:error, :enoent} ->
            {:error, {:missing, digest}}

          {:ok, bytes} ->
            actual = digest(bytes)

            if actual == digest do
              {:ok, bytes}
            else
              {:error, {:corrupt, digest, actual}}
            end
        end
    end
  end

  @doc "Derived [e, a, v, tx] rows. Never persisted."
  def facts(events) when is_list(events) do
    Enum.flat_map(events, &fact_rows/1)
  end

  @doc "Workspace tree `{path => sha256}` at or before `seq`. Iteration only."
  def as_of(events, seq) when is_list(events) and is_integer(seq) do
    Enum.reduce(events, %{}, fn event, current ->
      {kind, payload, event_seq} = fields(event)

      cond do
        event_seq > seq ->
          current

        kind == "gates.measured" ->
          case payload["tree_after"] do
            tree when is_map(tree) -> stringify(tree)
            _ -> current
          end

        kind == "artifacts.applied" ->
          hashes = payload["artifact_sha256"] || %{}
          keys = payload["keys"] || Map.keys(hashes)

          Enum.reduce(List.wrap(keys), current, fn key, acc ->
            digest = hashes[key] || hashes[to_string(key)]
            if is_binary(digest), do: Map.put(acc, to_string(key), digest), else: acc
          end)

        true ->
          current
      end
    end)
  end

  defp fact_rows(event) do
    {kind, payload, seq} = fields(event)

    cond do
      kind == "episode.planned" ->
        episode = payload["episode"] || seq
        fp = payload["fingerprint"]
        used = payload["used_words"] || []

        (if(fp, do: [{"episode/#{episode}", ":episode/fingerprint", to_string(fp), seq}], else: []) ++
           Enum.map(List.wrap(used), fn word ->
             {"episode/#{episode}", ":episode/used_word", to_string(word), seq}
           end))

      kind == "critic.accepted" ->
        episode = payload["episode"] || seq
        [{"episode/#{episode}", ":critic/verdict", ":accept", seq}]

      kind == "critic.rejected" ->
        episode = payload["episode"] || seq

        [{"episode/#{episode}", ":critic/verdict", ":reject", seq}] ++
          Enum.map(List.wrap(payload["errors"] || []), fn err ->
            {"episode/#{episode}", ":critic/error", to_string(err), seq}
          end)

      kind == "artifacts.applied" ->
        hashes = payload["artifact_sha256"] || %{}
        keys = payload["keys"] || Map.keys(hashes)

        Enum.flat_map(List.wrap(keys), fn key ->
          digest = hashes[key] || hashes[to_string(key)]

          if is_binary(digest) do
            [{"ws/#{key}", ":file/content", "blob:#{digest}", seq}]
          else
            []
          end
        end)

      kind == "gates.measured" ->
        passed = payload["ok"] == true or payload["ok"] == "true"
        tree = payload["tree_after"] || %{}

        [{"run", ":gates/passed", passed, seq}] ++
          Enum.map(tree, fn {path, digest} ->
            {"ws/#{path}", ":file/content", "blob:#{digest}", seq}
          end)

      kind == "dictionary.promoted" ->
        word = payload["name"] || payload["word"]
        digest = payload["sha256"]
        promo = payload["episode"]

        if word && digest do
          [
            {"word/#{word}", ":word/content", "blob:#{digest}", seq},
            {"word/#{word}", ":word/promoted-by", "episode/#{promo}", seq}
          ]
        else
          []
        end

      true ->
        []
    end
  end

  defp fields(%{kind: kind, payload: payload, sequence: seq}),
    do: {to_string(kind), stringify(payload), seq}

  defp fields(%{"kind" => kind, "payload" => payload, "sequence" => seq}),
    do: {kind, stringify(payload), seq}

  defp fields(_), do: {nil, %{}, 0}

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
