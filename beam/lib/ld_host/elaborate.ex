defmodule LdHost.Elaborate do
  @moduledoc """
  Architecture-level judgments over an `ld-system/v1` manifest.

  Produces a canonical derivation rather than a bare accept/reject: every
  rule application is a step with its subject and outcome, obligations that
  later phases must discharge are named and content-addressed, and the whole
  derivation is hashed so the ledger can carry it.

  Rules apply in a fixed order and every step is recorded even after the
  first failure, so two elaborations of the same manifest are byte-identical
  and a rejection names every unmet judgment, not only the first.

  Judgments:

      component C : Contract T                        (R1 component-well-formed)
      channel A.p -> B.q : Delivery D                 (R2 channel-endpoints)
      effect E owned-by C under Protocol P            (R3 effect-owner)
      substrate S satisfies requires(C)               (R4 substrate-satisfies)
      substrate S may back claims                     (R5 substrate-admissible)
      invariant I mentions only declared names        (R6 invariant-scope)
      failure f in vocabulary                         (R7 failure-model)

  The typed Shen critic remains the plan-level authority; this module is the
  Elixir elaborator the plan's Phase 2 specifies, pending its port to Shen.
  """

  alias LdHost.{JCS, Substrates, SystemManifest}

  @schema "ld.derivation/v1"

  # A protocol implies a minimum substrate guarantee for external effects.
  @protocol_requirement %{
    "durable-intent-commit" => "durable-intent-commit",
    "recorded" => "recorded",
    "ambient" => "ambient"
  }

  def derive(manifest) when is_map(manifest) do
    with {:ok, manifest} <- SystemManifest.validate(manifest) do
      {:ok, derivation(manifest)}
    end
  end

  def derive_file(path) do
    with {:ok, manifest} <- SystemManifest.load(path) do
      {:ok, derivation(manifest)}
    end
  end

  defp derivation(m) do
    steps =
      []
      |> r1(m)
      |> r2(m)
      |> r3(m)
      |> r4(m)
      |> r5(m)
      |> r6(m)
      |> r7(m)
      |> Enum.reverse()

    accepted = Enum.all?(steps, & &1["ok"])
    obligations = if accepted, do: obligations(m), else: []

    body = %{
      "schema" => @schema,
      "manifest_hash" => SystemManifest.hash(m),
      "system" => m["system"],
      "verdict" => if(accepted, do: "accepted", else: "rejected"),
      "steps" => steps,
      "failed" => steps |> Enum.reject(& &1["ok"]) |> Enum.map(&"#{&1["rule"]}:#{&1["subject"]}"),
      "assumptions" => [
        "substrate vectors as registered in LdHost.Substrates",
        "port types compose only when equal"
      ],
      "obligations" => obligations,
      "unresolved" => Enum.map(obligations, & &1["id"])
    }

    Map.put(body, "derivation_hash", JCS.hash!(body))
  end

  defp step(steps, rule, subject, ok, detail),
    do: [%{"rule" => rule, "subject" => subject, "ok" => ok, "detail" => detail} | steps]

  # R1: every component names a registered substrate.
  defp r1(steps, m) do
    m["components"]
    |> sorted()
    |> Enum.reduce(steps, fn {name, c}, acc ->
      known = match?({:ok, _}, Substrates.profile(c["substrate"]))

      step(
        acc,
        "component-well-formed",
        name,
        known,
        if(known,
          do: "contract #{c["contract"]} on #{c["substrate"]}",
          else: "unknown substrate #{c["substrate"]}"
        )
      )
    end)
  end

  # R2: channel endpoints exist, out -> in, equal port types.
  defp r2(steps, m) do
    m["channels"]
    |> sorted()
    |> Enum.reduce(steps, fn {name, ch}, acc ->
      from = port(m, ch["from"])
      to = port(m, ch["to"])

      {ok, detail} =
        cond do
          is_nil(from) ->
            {false, "from endpoint #{ch["from"]} is not a declared port"}

          is_nil(to) ->
            {false, "to endpoint #{ch["to"]} is not a declared port"}

          from["direction"] != "out" ->
            {false, "from endpoint must be an out port"}

          to["direction"] != "in" ->
            {false, "to endpoint must be an in port"}

          from["type"] != to["type"] ->
            {false, "port types do not compose: #{from["type"]} vs #{to["type"]}"}

          true ->
            {true,
             "#{ch["from"]} -> #{ch["to"]} : #{from["type"]} #{ch["delivery"]}/#{ch["ordering"]}"}
        end

      step(acc, "channel-endpoints", name, ok, detail)
    end)
  end

  # R3: each effect has exactly one owning component whose substrate can
  # carry the declared protocol; host-derived identity needs the durable
  # protocol.
  defp r3(steps, m) do
    m["effects"]
    |> sorted()
    |> Enum.reduce(steps, fn {name, e}, acc ->
      owner = m["components"][e["owner"]]
      required = @protocol_requirement[e["protocol"]]

      {ok, detail} =
        cond do
          is_nil(owner) ->
            {false, "owner #{e["owner"]} is not a component"}

          e["identity"] == "host-derived" and e["protocol"] != "durable-intent-commit" ->
            {false, "host-derived identity requires the durable-intent-commit protocol"}

          not is_nil(e["target"]) and not Map.has_key?(m["externals"], e["target"]) ->
            {false, "target #{e["target"]} is not a declared external"}

          match?(:error, Substrates.profile(owner["substrate"])) ->
            {false, "substrate #{owner["substrate"]} unknown"}

          true ->
            case Substrates.satisfies(%{external_effects: required}, owner["substrate"]) do
              :ok ->
                {true, "owned by #{e["owner"]} under #{e["protocol"]}"}

              {:error, [{dim, req, sup}]} ->
                {false, "#{dim} needs #{fmt(req)} got #{fmt(sup)} on #{owner["substrate"]}"}

              {:error, _} ->
                {false, "substrate #{owner["substrate"]} unknown"}
            end
        end

      step(acc, "effect-owner", name, ok, detail)
    end)
  end

  # R4: every component's requires vector is met by its substrate. Each
  # unmet dimension is its own step so the rejection names the dimension.
  defp r4(steps, m) do
    m["components"]
    |> sorted()
    |> Enum.reduce(steps, fn {name, c}, acc ->
      requires = c["requires"] || %{}

      case Substrates.satisfies(requires, c["substrate"]) do
        :ok ->
          step(
            acc,
            "substrate-satisfies",
            name,
            true,
            "#{map_size(requires)} dimension(s) met by #{c["substrate"]}"
          )

        {:error, unmet} ->
          Enum.reduce(unmet, acc, fn {dim, req, sup}, a ->
            step(
              a,
              "substrate-satisfies",
              "#{name}.#{dim}",
              false,
              "needs #{fmt(req)} got #{fmt(sup)} on #{c["substrate"]}"
            )
          end)
      end
    end)
  end

  # R5: the substrate may back runtime claims (experimental profiles may not).
  defp r5(steps, m) do
    m["components"]
    |> sorted()
    |> Enum.reduce(steps, fn {name, c}, acc ->
      case Substrates.executor(c["substrate"]) do
        {:ok, _} ->
          step(acc, "substrate-admissible", name, true, "#{c["substrate"]} may back claims")

        {:error, reason} ->
          step(acc, "substrate-admissible", name, false, reason)
      end
    end)
  end

  # R6: invariants mention only declared components, channels, effects,
  # externals.
  defp r6(steps, m) do
    names =
      MapSet.new(
        Map.keys(m["components"]) ++
          Map.keys(m["channels"]) ++
          Map.keys(m["effects"]) ++
          Map.keys(m["externals"])
      )

    m["invariants"]
    |> Enum.sort_by(& &1["id"])
    |> Enum.reduce(steps, fn inv, acc ->
      unknown = Enum.reject(inv["about"], &MapSet.member?(names, &1))

      step(
        acc,
        "invariant-scope",
        inv["id"],
        unknown == [],
        if(unknown == [],
          do: "#{inv["kind"]} over #{Enum.join(inv["about"], ", ")}",
          else: "unknown names: #{Enum.join(unknown, ", ")}"
        )
      )
    end)
  end

  # R7: failure model entries are in the vocabulary (validation already
  # guarantees this; recorded so the derivation lists the model explicitly).
  defp r7(steps, m) do
    m["failure_model"]
    |> Enum.sort()
    |> Enum.reduce(steps, fn f, acc -> step(acc, "failure-model", f, true, "in vocabulary") end)
  end

  # Obligations: what later phases must discharge for an accepted manifest.
  defp obligations(m) do
    per_component =
      m["components"]
      |> sorted()
      |> Enum.flat_map(fn {name, _} ->
        [
          obligation("runtime", "replay-stable", name),
          obligation("runtime", "checkpoint-recovered", name)
        ]
      end)

    per_channel =
      m["channels"]
      |> sorted()
      |> Enum.map(fn {name, ch} -> obligation("tla", "delivery-#{ch["delivery"]}", name) end)

    per_effect =
      m["effects"]
      |> sorted()
      |> Enum.filter(fn {_, e} -> e["protocol"] == "durable-intent-commit" end)
      |> Enum.map(fn {name, _} -> obligation("runtime", "effects-exactly-once", name) end)

    per_invariant =
      m["invariants"]
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn inv ->
        case inv["kind"] do
          "forbidden-path" -> obligation("netkat", "isolated", Enum.join(inv["about"], "->"))
          "required-waypoint" -> obligation("netkat", "waypoint", Enum.join(inv["about"], "->"))
          "liveness" -> obligation("tla", "liveness", inv["id"])
          _ -> obligation("tla", "invariant", inv["id"])
        end
      end)

    per_failure =
      m["failure_model"]
      |> Enum.sort()
      |> Enum.map(&obligation("exploration", &1, m["system"]))

    per_component ++ per_channel ++ per_effect ++ per_invariant ++ per_failure
  end

  defp obligation(tool, kind, subject) do
    body = %{"tool" => tool, "kind" => kind, "subject" => subject, "discharged_by" => nil}
    Map.put(body, "id", "#{tool}:#{kind}:#{subject}")
  end

  # Detail formatting shared with the Shen elaborator: lists comma-joined,
  # absent values as "none".
  defp fmt(nil), do: "none"
  defp fmt(list) when is_list(list), do: Enum.join(list, ",")
  defp fmt(other), do: to_string(other)

  @doc """
  Flatten a validated manifest plus the substrate registry into the fixed
  shapes the typed Shen elaborator (`shen/critic/elaborate.shen`) takes.
  """
  def shen_request(m) do
    %{
      "system" => m["system"],
      "components" =>
        Enum.map(m["components"], fn {name, c} ->
          [
            name,
            c["contract"],
            c["substrate"],
            Enum.map(c["ports"] || %{}, fn {pn, p} -> [pn, p["direction"], p["type"]] end),
            Enum.map(c["requires"] || %{}, fn {k, v} -> [k, fmt(v)] end)
          ]
        end),
      "channels" =>
        Enum.map(m["channels"], fn {name, ch} ->
          [name, ch["from"], ch["to"], ch["delivery"], ch["ordering"]]
        end),
      "effects" =>
        Enum.map(m["effects"], fn {name, e} ->
          [name, e["owner"], e["protocol"], e["identity"], e["target"] || ""]
        end),
      "externals" => Map.keys(m["externals"]),
      "invariants" => Enum.map(m["invariants"], &[&1["id"], &1["kind"], &1["about"]]),
      "failures" => m["failure_model"],
      "profiles" =>
        Enum.map(Substrates.profiles(), fn {name, p} ->
          vector =
            p.vector
            |> Map.delete(:fault_controls)
            |> Enum.map(fn {k, v} -> [Atom.to_string(k), v] end)

          [name, p.claims, vector, p.vector.fault_controls]
        end),
      "orders" => Enum.map(Substrates.orders(), fn {dim, vals} -> [Atom.to_string(dim), vals] end)
    }
  end

  defp port(m, endpoint) do
    [comp, port] = String.split(endpoint, ".", parts: 2)
    get_in(m, ["components", comp, "ports", port])
  end

  defp sorted(map), do: Enum.sort_by(map, fn {k, _} -> k end)
end
