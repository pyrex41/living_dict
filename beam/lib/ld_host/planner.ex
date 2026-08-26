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

  @endpoint "https://api.x.ai/v1/chat/completions"
  @model System.get_env("LIVINGDICT_MODEL") || "grok-4.6"

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
  - After sources exist, RUN-GATES. Failed claims are backpressure.
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
      messages = [
        %{role: "system", content: Keyword.get(opts, :system, @system)},
        %{role: "user", content: "GOAL:\n#{goal}\n\n#{observation}"}
      ]

      body = %{model: Keyword.get(opts, :model, @model), messages: messages, temperature: 0.2}

      case Req.post(@endpoint,
             json: body,
             auth: {:bearer, token},
             receive_timeout: 180_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"choices" => [choice | _]} = response}} ->
          text = get_in(choice, ["message", "content"]) || ""
          usage = response["usage"] || %{}

          telemetry = %{
            input_tokens: usage["prompt_tokens"] || 0,
            output_tokens: usage["completion_tokens"] || 0
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

  def credentials do
    case System.get_env("XAI_API_KEY", "") |> String.trim() do
      "" -> oauth_token()
      key -> {:ok, key}
    end
  end

  defp oauth_token do
    home = System.get_env("GROK_HOME") || Path.join(System.user_home!(), ".grok")
    path = Path.join(home, "auth.json")

    with {:ok, data} <- File.read(path),
         {:ok, decoded} <- JSON.decode(data),
         token when is_binary(token) and token != "" <- find_access_token(decoded) do
      {:ok, token}
    else
      _ ->
        {:error, "no planner credentials: export XAI_API_KEY or run: grok login --oauth"}
    end
  end

  defp find_access_token(%{} = decoded) do
    decoded
    |> Map.values()
    |> Enum.find_value(fn
      %{"access_token" => token} when is_binary(token) -> token
      _ -> nil
    end)
    |> case do
      nil -> Map.get(decoded, "access_token")
      token -> token
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
