defmodule LdHost.Gates do
  @moduledoc """
  Success gates: measure the goal's claims against the workspace.

  Port of the goal layer of `harness/src/livingdict/gates.py`:

  - The approved (frozen) contract on the host is authoritative when
    present; only then do `check` claims execute. Model-authored
    claims.json is measured too, but its checks are refused with the
    reference's exact reason, and the report is labeled with judge
    provenance so a run judged by the model's own claims says so loudly.
  - Benchmark (advisory) mode: when the host has `allow_model_checks:
    true` and no approved contract, model-authored `check` claims DO
    execute. Every executed check entry carries `advisory: true` and the
    judge label stays "model-authored claims" — the pass/fail is the
    model's self-judgment (it terminates the loop and gates promotion);
    a hidden benchmark verifier still judges the task.
  - Claim kinds: check (sh command, exit 0, timeout, depends_on
    blocking), source (substring evidence), file (existence/min_bytes),
    absent.
  """

  alias LdHost.{Host, Cmd, Policy, RuntimeProfiles}

  def run(%Host{} = host, opts \\ []) do
    persist? = Keyword.get(opts, :persist?, true)

    {claims, provenance, allow_check?, advisory?} =
      case host.contract do
        %{claims: claims} when is_list(claims) and claims != [] ->
          {claims, "approved contract", true, false}

        _ ->
          advisory? = host.allow_model_checks == true
          {workspace_claims(host.workspace), "model-authored claims", advisory?, advisory?}
      end

    report =
      case claims do
        nil ->
          %{
            name: "claims",
            ok: false,
            layer: "goal",
            reason: "no claims.json — the planner must write goal-shaped success claims"
          }

        [] ->
          %{name: "claims", ok: false, layer: "goal", reason: "claims.json has no claims[]"}

        list ->
          measure_claims(host, list, allow_check?, advisory?)
      end
      |> Map.put(:judge, provenance)

    report = Map.put(report, :timed_out, timed_out?(report))

    if persist? do
      dir = Path.join(host.workspace, ".sb")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "discharge_report.json"), JSON.encode!(report))
    end

    report
  end

  defp workspace_claims(workspace) do
    path = Path.join(workspace, "claims.json")

    with {:ok, data} <- File.read(path),
         {:ok, %{"claims" => claims}} when is_list(claims) <- JSON.decode(data) do
      Enum.map(claims, &atomize_claim/1)
    else
      _ -> nil
    end
  end

  @doc "Normalize a claim map (string or atom keys) to the shape the runner uses."
  def atomize_claim(raw) when is_map(raw) do
    claim = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    %{
      id: to_string(claim["id"] || "claim"),
      kind: String.downcase(to_string(claim["kind"] || "source")),
      command: claim["command"],
      path: to_string(claim["path"] || ""),
      any: needles(claim["any"] || claim["must"]),
      min_bytes: int_or(claim["min_bytes"], 0),
      timeout_seconds: int_or(claim["timeout_seconds"], 60),
      depends_on: List.wrap(claim["depends_on"] || []) |> Enum.map(&to_string/1),
      profile: claim["profile"] && to_string(claim["profile"]),
      config: claim["config"] && to_string(claim["config"]),
      requires: requires_or_invalid(claim["requires"]),
      must: List.wrap(claim["must"] || []) |> Enum.map(&to_string/1)
    }
  end

  # A runtime claim's `requires` is dimension => string | [string]. Anything
  # else is not silently dropped: the claim is marked invalid and fails.
  defp requires_or_invalid(nil), do: %{}

  defp requires_or_invalid(r) when is_map(r) do
    ok? =
      Enum.all?(r, fn
        {k, v} when is_binary(k) and is_binary(v) -> true
        {k, v} when is_binary(k) and is_list(v) -> Enum.all?(v, &is_binary/1)
        _ -> false
      end)

    if ok?, do: r, else: :invalid
  end

  defp requires_or_invalid(_), do: :invalid

  defp needles(nil), do: []
  defp needles(value) when is_binary(value), do: [String.downcase(value)]

  defp needles(value) when is_list(value),
    do: value |> Enum.map(&String.downcase(to_string(&1))) |> Enum.reject(&(&1 == ""))

  defp int_or(value, _default) when is_integer(value), do: value

  defp int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp int_or(_, default), do: default

  defp measure_claims(host, claims, allow_check?, advisory?) do
    {results, _failed} =
      Enum.reduce(claims, {[], MapSet.new()}, fn claim, {results, failed} ->
        entry = measure_claim(host, claim, failed, allow_check?, advisory?)
        failed = if entry.passed, do: failed, else: MapSet.put(failed, entry.id)
        {[entry | results], failed}
      end)

    results = Enum.reverse(results)
    failed = Enum.reject(results, & &1.passed)

    if failed == [] do
      %{name: "claims", ok: true, layer: "goal", claims: results, measure: "goal claims"}
    else
      ids = failed |> Enum.map(& &1.id) |> Enum.join(", ")
      %{name: "claims", ok: false, layer: "goal", reason: "failed " <> ids, claims: results}
    end
  end

  defp measure_claim(host, %{kind: "file"} = claim, _failed, _allow, _advisory) do
    target = Path.join(host.workspace, claim.path)

    ok =
      File.regular?(target) and
        (claim.min_bytes == 0 or file_size(target) >= claim.min_bytes) and
        (claim.any == [] or Enum.any?(claim.any, &String.contains?(read_lower(target), &1)))

    %{id: claim.id, passed: ok, kind: "file", path: claim.path}
  end

  defp measure_claim(host, %{kind: "absent"} = claim, _failed, _allow, _advisory) do
    ok = claim.path != "" and not File.exists?(Path.join(host.workspace, claim.path))
    %{id: claim.id, passed: ok, kind: "absent", path: claim.path}
  end

  defp measure_claim(host, %{kind: "check"} = claim, failed, allow_check?, advisory?) do
    command = String.trim(to_string(claim.command || ""))
    blocked_by = Enum.filter(claim.depends_on, &MapSet.member?(failed, &1))

    cond do
      command == "" ->
        %{id: claim.id, passed: false, kind: "check", reason: "check claim has no command"}

      blocked_by != [] ->
        %{
          id: claim.id,
          passed: false,
          kind: "check",
          command: command,
          blocked_by: blocked_by,
          reason: "blocked by failed prerequisite"
        }

      not allow_check? ->
        %{
          id: claim.id,
          passed: false,
          kind: "check",
          command: command,
          reason: "check claims execute only under an approved or hidden contract"
        }

      true ->
        outcome = Cmd.sh(command, host.workspace, claim.timeout_seconds * 1000)

        entry = %{
          id: claim.id,
          passed: outcome.returncode == 0 and not outcome.timed_out,
          kind: "check",
          command: command,
          returncode: outcome.returncode,
          timed_out: outcome.timed_out
        }

        entry = if advisory?, do: Map.put(entry, :advisory, true), else: entry

        tail = String.trim(outcome.output)
        if tail == "", do: entry, else: Map.put(entry, :output, String.slice(tail, -400, 400))
    end
  end

  defp measure_claim(_host, %{kind: "runtime"} = claim, _failed, false, _advisory) do
    %{
      id: claim.id,
      passed: false,
      kind: "runtime",
      reason: "runtime claims execute only under an approved or hidden contract"
    }
  end

  defp measure_claim(host, %{kind: "runtime"} = claim, _failed, true, _advisory) do
    %{id: claim.id, kind: "runtime"}
    |> Map.merge(RuntimeProfiles.run(host.workspace, claim))
  end

  defp measure_claim(host, claim, _failed, _allow, _advisory) do
    cond do
      claim.any == [] ->
        %{id: claim.id, passed: false, kind: "source", reason: "source claim has no any/must"}

      claim.path != "" ->
        target = Path.join(host.workspace, claim.path)
        floor = if claim.min_bytes == 0, do: 120, else: claim.min_bytes

        cond do
          not File.regular?(target) ->
            %{id: claim.id, passed: false, kind: "source", reason: "missing #{claim.path}"}

          file_size(target) < floor ->
            %{
              id: claim.id,
              passed: false,
              kind: "source",
              reason: "#{claim.path} is #{file_size(target)} bytes, need #{floor}"
            }

          true ->
            hay = read_lower(target)
            hit = Enum.filter(claim.any, &String.contains?(hay, &1))

            %{
              id: claim.id,
              passed: hit != [],
              kind: "source",
              hit: hit,
              wanted: claim.any,
              path: claim.path
            }
        end

      true ->
        hay = whole_source(host.workspace)
        hit = Enum.filter(claim.any, &String.contains?(hay, &1))
        %{id: claim.id, passed: hit != [], kind: "source", hit: hit, wanted: claim.any, path: ""}
    end
  end

  defp whole_source(workspace) do
    workspace
    |> Policy.snapshot()
    |> Map.keys()
    |> Enum.map(&read_lower(Path.join(workspace, &1)))
    |> Enum.join("\n")
  end

  defp read_lower(path) do
    case File.read(path) do
      {:ok, data} -> if String.valid?(data), do: String.downcase(data), else: ""
      _ -> ""
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp timed_out?(%{claims: claims}) when is_list(claims),
    do: Enum.any?(claims, &(&1[:timed_out] == true))

  defp timed_out?(_), do: false
end
