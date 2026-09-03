defmodule LdHost.Planner do
  @moduledoc """
  The only model-facing module. Supports xAI, OpenAI, and Anthropic while
  preserving the Forth-plan / Shen-critic boundary. OpenAI may use an API
  key or delegate to the official Codex CLI's OAuth session.

  Unlike the Python client, host words are listed WITH their stack
  effects, and colon definitions MUST declare `( ins -- outs | effects )`
  contracts — the critic rejects mismatches and contractless words are
  never promoted.
  """

  @providers %{
    "xai" => {"grok-4.6", "https://api.x.ai/v1/chat/completions"},
    "openai" => {"gpt-5", "https://api.openai.com/v1/responses"},
    "anthropic" => {"claude-sonnet-4-5", "https://api.anthropic.com/v1/messages"}
  }

  alias LdHost.{CachePolicy, Policy}

  @doc """
  Model and provider are resolved at runtime so releases remain portable.
  """
  def provider do
    case System.get_env("LIVINGDICT_PROVIDER", "xai") |> String.trim() |> String.downcase() do
      "grok" -> "xai"
      "codex" -> "openai"
      "claude" -> "anthropic"
      name when is_map_key(@providers, name) -> name
      name -> raise ArgumentError, "unsupported planner provider: #{name}"
    end
  end

  def model do
    configured = System.get_env("LIVINGDICT_MODEL", "") |> String.trim()
    if configured == "", do: elem(@providers[provider()], 0), else: configured
  end

  @doc "Planner endpoint; `LIVINGDICT_PLANNER_ENDPOINT` overrides provider defaults."
  def endpoint do
    System.get_env("LIVINGDICT_PLANNER_ENDPOINT") || elem(@providers[provider()], 1)
  end

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
    {body, request_meta, headers} = request_shape(goal, observation, opts)
    selected_provider = provider()
    request_json = JSON.encode!(body)
    started = System.monotonic_time(:millisecond)

    with {:ok, auth} <- credentials(),
         {:ok, text, usage, response} <- call_provider(selected_provider, auth, body, headers) do
      # Hard episodes can legitimately reason for minutes; a tight
      # receive_timeout guillotines exactly the calls that matter most
      # (observed: repair-episode planning on parser-02 exceeding 180s
      # repeatedly while trivial episodes returned in seconds).
      telemetry = %{
        input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
        output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
        reasoning_tokens:
          get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
            get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0,
        cached_tokens:
          get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
            get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
            usage["cache_read_input_tokens"] || 0,
        total_tokens:
          usage["total_tokens"] || (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0),
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

    body = request_body(provider(), selected_model, messages)

    body =
      case {provider(), Keyword.get(opts, :reasoning_effort)} do
        {"openai", effort} when effort in ~w(low medium high xhigh) ->
          Map.put(body, :reasoning, %{effort: effort})

        {"xai", effort} when effort in ~w(low medium high xhigh) ->
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

    {body, meta, cache_headers(provider(), key)}
  end

  defp request_body("openai", model, [system | messages]) do
    %{
      model: model,
      instructions: system.content,
      input: messages,
      text: %{format: %{type: "json_object"}}
    }
  end

  defp request_body("anthropic", model, [system | messages]) do
    %{model: model, system: system.content, messages: messages, max_tokens: 16_384}
  end

  defp request_body(_provider, model, messages),
    do: %{model: model, messages: messages, temperature: 0.2}

  defp cache_headers("xai", key) do
    case key do
      key when is_binary(key) and key != "" -> [{"x-grok-conv-id", key}]
      _ -> []
    end
  end

  defp cache_headers(_provider, _key), do: []

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

  defp call_provider("openai", :codex_oauth, body, _headers), do: call_codex(body)

  defp call_provider(name, {:api_key, token}, body, affinity_headers) do
    {auth, headers} =
      case name do
        "anthropic" -> {nil, [{"x-api-key", token}, {"anthropic-version", "2023-06-01"}]}
        _ -> {{:bearer, token}, affinity_headers}
      end

    options = [json: body, headers: headers, receive_timeout: 600_000, retry: false]
    options = if auth, do: Keyword.put(options, :auth, auth), else: options

    case Req.post(endpoint(), options) do
      {:ok, %{status: 200, body: response}} ->
        decode_provider_response(name, response)

      {:ok, %{status: status, body: response}} ->
        {:error, "planner HTTP #{status}: #{inspect(response, limit: 10)}"}

      {:error, reason} ->
        {:error, "planner request failed: #{inspect(reason)}"}
    end
  end

  defp decode_provider_response("openai", response) do
    text =
      for output <- response["output"] || [],
          part <- output["content"] || [],
          part["type"] == "output_text",
          into: "",
          do: part["text"] || ""

    {:ok, text, response["usage"] || %{}, response}
  end

  defp decode_provider_response("anthropic", response) do
    text =
      for part <- response["content"] || [],
          part["type"] == "text",
          into: "",
          do: part["text"] || ""

    {:ok, text, response["usage"] || %{}, response}
  end

  defp decode_provider_response(_name, %{"choices" => [choice | _]} = response) do
    {:ok, get_in(choice, ["message", "content"]) || "", response["usage"] || %{}, response}
  end

  defp decode_provider_response(name, response),
    do: {:error, "#{name} returned no model content: #{inspect(response, limit: 10)}"}

  defp call_codex(body) do
    with codex when is_binary(codex) <-
           System.find_executable(System.get_env("CODEX_BIN", "codex")) do
      prompt =
        (["SYSTEM:\n" <> body.instructions] ++
           Enum.map(body.input, fn message ->
             "#{message.role |> to_string() |> String.upcase()}:\n#{message.content}"
           end))
        |> Enum.join("\n\n")

      args = [
        "exec",
        "--json",
        "--ephemeral",
        "--ignore-rules",
        "--sandbox",
        "read-only",
        "--skip-git-repo-check",
        "-m",
        body.model,
        prompt
      ]

      {output, status} = System.cmd(codex, args, stderr_to_stdout: true)

      if status == 0 do
        {text, usage} =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce({"", %{}}, fn line, {text, usage} ->
            case JSON.decode(line) do
              {:ok,
               %{
                 "type" => "item.completed",
                 "item" => %{"type" => "agent_message", "text" => value}
               }} ->
                {value, usage}

              {:ok, %{"type" => "turn.completed", "usage" => value}} ->
                {text, value}

              _ ->
                {text, usage}
            end
          end)

        if text == "",
          do: {:error, "Codex OAuth returned no agent message"},
          else: {:ok, text, usage, %{transport: "codex_oauth"}}
      else
        {:error, "Codex OAuth invocation failed (#{status}): #{String.slice(output, -800, 800)}"}
      end
    else
      _ -> {:error, "OpenAI OAuth requires the Codex CLI; install it and run: codex login"}
    end
  end

  def credentials do
    case provider() do
      "openai" -> openai_credentials()
      "anthropic" -> env_credentials("ANTHROPIC_API_KEY")
      "xai" -> xai_credentials()
    end
  end

  defp openai_credentials do
    mode = System.get_env("LIVINGDICT_OPENAI_AUTH", "auto") |> String.trim() |> String.downcase()
    key = System.get_env("OPENAI_API_KEY", "") |> String.trim()

    cond do
      mode == "oauth" -> {:ok, :codex_oauth}
      mode == "api_key" and key != "" -> {:ok, {:api_key, key}}
      mode == "api_key" -> {:error, "OPENAI_API_KEY is not set"}
      mode == "auto" and key != "" -> {:ok, {:api_key, key}}
      mode == "auto" -> {:ok, :codex_oauth}
      true -> {:error, "LIVINGDICT_OPENAI_AUTH must be auto, api_key, or oauth"}
    end
  end

  defp env_credentials(name) do
    case System.get_env(name, "") |> String.trim() do
      "" -> {:error, "#{name} is not set"}
      key -> {:ok, {:api_key, key}}
    end
  end

  defp xai_credentials do
    case System.get_env("XAI_API_KEY", "") |> String.trim() do
      "" -> oauth_token()
      key -> {:ok, {:api_key, key}}
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
        {:ok, {:api_key, rec["key"]}}
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
          {:ok, {:api_key, access}}

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
