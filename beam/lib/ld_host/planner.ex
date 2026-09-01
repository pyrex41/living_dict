defmodule LdHost.Planner do
  @moduledoc """
  The only model-facing module. Calls xAI grok with the Forth-plan system
  prompt and parses the JSON envelope. Credentials: `XAI_API_KEY`, else
  the SpaceXAI OAuth session at `~/.grok/auth.json` (access token used
  as-is; refresh is the reference client's job — run `grok login --oauth`
  if expired).

  Unlike the Python client, host words are listed WITH their stack
  effects, and colon definitions MUST declare `( ins -- outs | effects )`
  contracts — the critic rejects mismatches and contractless words are
  never promoted.
  """

  @default_endpoint "https://api.x.ai/v1/chat/completions"
  @default_model "grok-4.6"

  alias LdHost.{CachePolicy, Policy}

  @doc """
  Model resolved at RUNTIME (not compile time): `LIVINGDICT_MODEL` env,
  else #{inspect(@default_model)}. Compile-time baking would freeze the
  build machine's env into a release.
  """
  def model, do: System.get_env("LIVINGDICT_MODEL") || @default_model

  @doc "Planner endpoint. Override only for an OpenAI-compatible recorder/proxy."
  def endpoint, do: System.get_env("LIVINGDICT_PLANNER_ENDPOINT") || @default_endpoint

  @system """
  You are the planner for a general coding harness whose plan language is
  Forth. Forth is the harness, not the product. The product is whatever
  the GOAL names — any software.

  Emit ONE JSON object only (no markdown) with keys:
    language: "forth"
    program: Forth using only the host words below and colon words you
      define here or that are listed under HARNESS DICTIONARY.
    artifacts: map of PRODUCT paths to FULL file contents
    rationale: one short sentence about THIS episode

  Host words and their stack effects (effects after the |):
    READ-FILE    ( path -- text | read )
    LIST-DIR     ( path -- listing | read )
    SEARCH       ( query -- hits | read )
    WRITE-FILE   ( content path -- receipt | write )
    USE-ARTIFACT ( key -- content | read )
    RUN-TESTS    ( -- report | exec )
    RUN-GATES    ( -- report | exec )
    RECEIPT      ( -- receipt )
    DUP ( a -- a a )  DROP ( a -- )  SWAP ( a b -- b a )  OVER ( a b -- a b a )
    + - * ( a b -- c )   IF ( flag -- ) ... ELSE ... THEN
    S" strings and integers push themselves.

  Contract rule: every colon definition MUST declare its stack effect
  immediately after the name:
    : INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;
  Inputs before --, outputs after, effects after | (read, write, exec).
  The critic rejects a declaration that does not match the body, echoing
  both contracts. Words without a contract are never persisted to the
  dictionary. Definitions must appear before their first call.

  Rules:
  - Follow the GOAL. Implement ONE increment — the next missing piece.
  - Install artifacts with: S" key" USE-ARTIFACT S" path" WRITE-FILE
  - If HARNESS DICTIONARY lists INSTALL, emit INSTALL not the zipper.
  - After sources exist, RUN-GATES. Failed claims are backpressure.
  - FIRST episode, when no approved contract exists: write claims.json —
    {"claims":[{"id","kind":"check","command","timeout_seconds"}]} —
    with at least one executable check that invokes the product and
    observes a result; RUN-GATES then measures it; failed claims are
    backpressure.
  - Use workspace-relative paths only; absolute paths are rejected.
  - Never weaken claims. Do not write .livingdict-run/**, .git/**,
    node_modules/**, dist/**.
  - End the program with RECEIPT.
  """

  def system_prompt, do: @system

  @doc """
  One planning call. Returns `{:ok, envelope_map, telemetry}` or
  `{:error, reason}`. `telemetry` is `%{input_tokens, output_tokens}`.
  """
  def plan(goal, observation, opts \\ []) do
    with {:ok, token} <- credentials() do
      {body, request_meta, headers} = request_shape(goal, observation, opts)

      # Hard episodes can legitimately reason for minutes; a tight
      # receive_timeout guillotines exactly the calls that matter most
      # (observed: repair-episode planning on parser-02 exceeding 180s
      # repeatedly while trivial episodes returned in seconds).
      request_json = JSON.encode!(body)
      started = System.monotonic_time(:millisecond)

      case Req.post(endpoint(),
             json: body,
             auth: {:bearer, token},
             headers: headers,
             receive_timeout: 600_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"choices" => [choice | _]} = response}} ->
          text = get_in(choice, ["message", "content"]) || ""
          usage = response["usage"] || %{}

          telemetry = %{
            input_tokens: usage["prompt_tokens"] || 0,
            output_tokens: usage["completion_tokens"] || 0,
            reasoning_tokens:
              get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0,
            cached_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0,
            total_tokens: usage["total_tokens"] || 0,
            duration_ms: System.monotonic_time(:millisecond) - started,
            request_bytes: byte_size(request_json),
            response_bytes: byte_size(JSON.encode!(response)),
            request_sha256: sha256(request_json),
            endpoint_host: endpoint_host(endpoint()),
            reasoning_effort: Keyword.get(opts, :reasoning_effort, "high"),
            cache_scope: request_meta.cache_scope,
            cache_phase: "planner",
            cache_key_fingerprint: request_meta.cache_key_fingerprint,
            message_prefix_sha256: request_meta.message_prefix_sha256,
            tool_schema_sha256: nil
          }

          case extract_json_object(text) do
            {:ok, envelope} -> {:ok, envelope, telemetry}
            {:error, reason} -> {:error, reason}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "planner HTTP #{status}: #{inspect(body, limit: 10)}"}

        {:error, reason} ->
          {:error, "planner request failed: #{inspect(reason)}"}
      end
    end
  end

  @doc false
  def request_shape(goal, observation, opts \\ []) do
    system = Keyword.get(opts, :system, @system)
    selected_model = Keyword.get(opts, :model, model())
    scope = CachePolicy.normalize(Keyword.get(opts, :cache_scope))

    # Goal and observation are separate messages so changing workspace state
    # does not invalidate the stable system+goal prefix.
    messages = [
      %{role: "system", content: system},
      %{role: "user", content: sanitize("GOAL:\n#{goal}")},
      %{role: "user", content: sanitize("OBSERVATION:\n#{observation}")}
    ]

    body = %{model: selected_model, messages: messages, temperature: 0.2}

    body =
      case Keyword.get(opts, :reasoning_effort) do
        effort when effort in ~w(low medium high xhigh) ->
          Map.put(body, :reasoning_effort, effort)

        _ ->
          body
      end

    schema = Policy.sha256_hex(system)

    key =
      Keyword.get(opts, :cache_key) ||
        cache_key(scope, opts, selected_model, schema)

    meta = %{
      cache_scope: Atom.to_string(scope),
      cache_key_fingerprint: CachePolicy.fingerprint(key),
      message_prefix_sha256: Policy.sha256_hex(JSON.encode!(Enum.take(messages, 2)))
    }

    {body, meta, cache_headers(key)}
  end

  defp cache_headers(key) do
    case key do
      key when is_binary(key) and key != "" -> [{"x-grok-conv-id", key}]
      _ -> []
    end
  end

  defp cache_key(:off, _opts, _model, _schema), do: nil

  defp cache_key(scope, opts, model, schema) do
    case Keyword.get(opts, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        CachePolicy.routing_key(scope,
          run_id: run_id,
          phase: "planner",
          model: model,
          schema: schema
        )

      _ ->
        nil
    end
  end

  def credentials do
    case System.get_env("XAI_API_KEY", "") |> String.trim() do
      "" -> oauth_token()
      key -> {:ok, key}
    end
  end

  # SpaceXAI OAuth session (port of the reference client's flow): the
  # record's `key` is the current access token; when `expires_at` has
  # passed, exchange `refresh_token` at auth.x.ai and persist the
  # rotated record back (atomic tmp+rename, 0600).
  @token_url "https://auth.x.ai/oauth2/token"

  defp oauth_token do
    home = System.get_env("GROK_HOME") || Path.join(System.user_home!(), ".grok")
    path = Path.join(home, "auth.json")

    with {:ok, data} <- File.read(path),
         {:ok, %{} = blob} <- JSON.decode(data),
         {rec_key, rec} when is_map(rec) <- find_oauth_record(blob) do
      if expired?(rec["expires_at"]) do
        refresh_oauth(path, blob, rec_key, rec)
      else
        {:ok, rec["key"]}
      end
    else
      _ ->
        {:error, "no planner credentials: export XAI_API_KEY or run: grok login --oauth"}
    end
  end

  defp find_oauth_record(blob) do
    Enum.find(blob, fn
      {_key, %{"key" => k, "refresh_token" => r}} when is_binary(k) and is_binary(r) -> true
      _ -> false
    end) || :none
  end

  defp expired?(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(String.replace(expires_at, "Z", "+00:00")) do
      {:ok, expires, _} -> DateTime.compare(expires, DateTime.utc_now()) != :gt
      _ -> false
    end
  end

  defp expired?(_), do: false

  defp refresh_oauth(path, blob, rec_key, rec) do
    client_id = rec["oidc_client_id"]
    refresh = rec["refresh_token"]

    if client_id == nil or refresh == nil do
      {:error, "oauth session is missing refresh_token; run: grok login --oauth"}
    else
      form = [grant_type: "refresh_token", refresh_token: refresh, client_id: client_id]

      case Req.post(@token_url, form: form, receive_timeout: 30_000, retry: false) do
        {:ok, %{status: 200, body: %{"access_token" => access} = payload}}
        when is_binary(access) ->
          rec =
            rec
            |> Map.put("key", access)
            |> maybe_put_str("refresh_token", payload["refresh_token"])
            |> put_expiry(payload["expires_in"])

          persist_auth(path, Map.put(blob, rec_key, rec))
          {:ok, access}

        {:ok, %{status: status}} ->
          {:error, "oauth refresh failed (#{status}); run: grok login --oauth"}

        {:error, reason} ->
          {:error, "oauth refresh failed: #{inspect(reason)}"}
      end
    end
  end

  defp maybe_put_str(map, _key, nil), do: map
  defp maybe_put_str(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put_str(map, _key, _), do: map

  defp put_expiry(rec, seconds) when is_number(seconds) do
    expires =
      DateTime.utc_now()
      |> DateTime.add(trunc(seconds), :second)
      |> DateTime.to_iso8601()
      |> String.replace("+00:00", "Z")

    Map.put(rec, "expires_at", expires)
  end

  defp put_expiry(rec, _), do: rec

  defp persist_auth(path, blob) do
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(blob) <> "\n")
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  @doc "Replace invalid UTF-8 bytes so downstream JSON encoding never rejects."
  def sanitize(text) when is_binary(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp endpoint_host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> "invalid"
    end
  end

  @doc "Pull the first JSON object out of model text (port of the reference)."
  def extract_json_object(text) do
    raw = text |> String.trim() |> strip_fences()

    case JSON.decode(raw) do
      {:ok, %{} = value} ->
        {:ok, value}

      _ ->
        with start when start != nil <- index_of(raw, "{"),
             stop when stop != nil and stop > start <- last_index_of(raw, "}"),
             {:ok, %{} = value} <- JSON.decode(String.slice(raw, start..stop)) do
          {:ok, value}
        else
          _ -> {:error, "model did not return a JSON object"}
        end
    end
  end

  defp strip_fences("```" <> _ = raw) do
    raw
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.reject(&(String.trim(&1) == "```"))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp strip_fences(raw), do: raw

  defp index_of(string, char) do
    case :binary.match(string, char) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp last_index_of(string, char) do
    case :binary.matches(string, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
