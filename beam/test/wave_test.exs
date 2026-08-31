defmodule LdHost.WaveTest do
  use ExUnit.Case, async: false

  alias LdHost.{Forth, Host, Policy, Wave}

  defp tmp(prefix) do
    dir =
      System.tmp_dir!()
      |> Path.join(
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp host(ws, opts \\ []) do
    events = Keyword.get(opts, :events)

    emit =
      if events do
        fn type, data -> Agent.update(events, &(&1 ++ [%{type: type, data: data}])) end
      else
        fn _type, _data -> :ok end
      end

    Host.new(ws,
      allowed_effects: ["read", "write", "exec"],
      allowed_globs: ["**"],
      emit: emit,
      write_receipt?: false
    )
  end

  defp node(id, writes, deps \\ [], program \\ "") do
    %{id: id, writes: writes, depends_on: deps, program: program}
  end

  defp mark_string(colon) do
    case colon["MARK"] do
      tokens when is_list(tokens) ->
        Enum.find_value(tokens, fn
          %Forth.Token{kind: :string, value: v} -> v
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  test "kahn levels are lexicographic; cycle is fail-closed" do
    nodes = [
      node("registry", ["r.json"], ["ingest", "offset", "scale"]),
      node("verify", ["ok"], ["registry"]),
      node("ingest", ["a.txt"]),
      node("offset", ["b.txt"]),
      node("scale", ["c.txt"])
    ]

    assert {:ok, waves} = Wave.plan_waves(nodes)

    assert Enum.map(waves, fn w -> Enum.map(w, & &1.id) end) == [
             ["ingest", "offset", "scale"],
             ["registry"],
             ["verify"]
           ]

    cycle = [node("a", ["a.txt"], ["b"]), node("b", ["b.txt"], ["a"])]
    assert {:error, reason} = Wave.plan_waves(cycle)
    assert reason =~ "dependency cycle"
  end

  test "overlapping writes are refused with no mutation" do
    ws = tmp("ldwave-overlap")
    File.write!(Path.join(ws, "seed.txt"), "seed\n")
    h = host(ws)

    nodes = [
      node("a", ["shared.txt"], [], ~s{S" AAA" S" shared.txt" WRITE-FILE DROP}),
      node("b", ["shared.txt"], [], ~s{S" BBB" S" shared.txt" WRITE-FILE DROP})
    ]

    assert {:error, :overlap, errors} = Wave.execute(h, nodes, %{}, [])
    assert Enum.any?(errors, &String.contains?(&1, "overlapping writes"))
    refute File.exists?(Path.join(ws, "shared.txt"))
    assert File.read!(Path.join(ws, "seed.txt")) == "seed\n"
  end

  test "serial and waved programs hash equal trees and receipts; merge order is lex" do
    artifacts = %{"a.txt" => "A\n", "b.txt" => "B\n", "c.txt" => "C\n"}

    nodes = [
      node(
        "b",
        ["b.txt"],
        [],
        ~s{: MARK ( -- | ) S" b" ; S" b.txt" USE-ARTIFACT S" b.txt" WRITE-FILE DROP}
      ),
      node(
        "a",
        ["a.txt"],
        [],
        ~s{: MARK ( -- | ) S" a" ; S" a.txt" USE-ARTIFACT S" a.txt" WRITE-FILE DROP}
      ),
      node("c", ["c.txt"], [], ~s{S" c.txt" USE-ARTIFACT S" c.txt" WRITE-FILE DROP})
    ]

    run_once = fn name, workers ->
      ws = tmp("ldwave-#{name}")
      h = host(ws)
      assert {:ok, view, colon, metrics} = Wave.execute(h, nodes, artifacts, workers: workers)
      {_ok, receipt, _} = Host.receipt(view)
      stable = Map.take(receipt, [:workspace_after, :changed_files, :success, :effects_used])
      {Policy.snapshot(ws), Policy.sha256_hex(JSON.encode!(stable)), colon, metrics, receipt}
    end

    {serial_tree, serial_hash, serial_colon, serial_metrics, serial_receipt} =
      run_once.("serial", 1)

    {waved_tree, waved_hash, waved_colon, waved_metrics, waved_receipt} = run_once.("waved", 3)

    assert serial_tree == waved_tree
    assert serial_tree["a.txt"] == Policy.sha256_hex("A\n")
    assert serial_tree["b.txt"] == Policy.sha256_hex("B\n")
    assert serial_tree["c.txt"] == Policy.sha256_hex("C\n")
    assert serial_hash == waved_hash
    assert serial_receipt.workspace_after == waved_receipt.workspace_after
    assert serial_receipt.changed_files == waved_receipt.changed_files
    assert serial_metrics.wave_count == 1
    assert serial_metrics.max_wave_width == 3
    assert serial_metrics.conflicts == 0
    assert waved_metrics.wave_count == 1
    # Later lex id wins colon name clashes (b after a).
    assert mark_string(serial_colon) == "b"
    assert mark_string(waved_colon) == "b"
    assert waved_colon["MARK"] == serial_colon["MARK"]
  end

  test "independent nodes actually overlap when workers > 1" do
    ws = tmp("ldwave-par")
    artifacts = %{"a.txt" => "a\n", "b.txt" => "b\n", "c.txt" => "c\n"}

    nodes = [
      node("a", ["a.txt"]),
      node("b", ["b.txt"]),
      node("c", ["c.txt"])
    ]

    h = host(ws)
    {:ok, space_log} = Agent.start_link(fn -> [] end)

    assert {:ok, _view, _colon, metrics} =
             Wave.execute(h, nodes, artifacts,
               workers: 3,
               record: fn kind, payload -> Agent.update(space_log, &(&1 ++ [{kind, payload}])) end,
               node_start_hook: fn _id -> Process.sleep(180) end
             )

    assert metrics.nodes_parallel >= 2
    assert metrics.conflicts == 0
    assert metrics.wall_ms_actual < metrics.wall_ms_serial_estimate
    assert File.exists?(Path.join(ws, "a.txt"))
    assert File.exists?(Path.join(ws, "b.txt"))
    assert File.exists?(Path.join(ws, "c.txt"))

    log = Agent.get(space_log, & &1)

    outs =
      for {"space.out", payload} <- log,
          get_in(payload, [:pattern_or_tuple, "kind"]) == "node.ready",
          do: payload

    takes = for {"space.take", payload} <- log, do: payload
    acks = for {"space.ack", _payload} <- log, do: true

    assert length(outs) == 3
    assert length(takes) == 3
    assert length(acks) == 3
    assert Enum.map(outs, &get_in(&1, [:pattern_or_tuple, "wave"])) |> Enum.uniq() == [0]
  end

  test "trap completes siblings and blocks dependents" do
    artifacts = %{"ok.txt" => "ok\n", "dep.txt" => "dep\n"}

    nodes = [
      node("ok", ["ok.txt"], [], ~s{S" ok.txt" USE-ARTIFACT S" ok.txt" WRITE-FILE DROP}),
      node("trap", [], [], ~s{S" missing.txt" READ-FILE}),
      node(
        "dep",
        ["dep.txt"],
        ["trap"],
        ~s{S" dep.txt" USE-ARTIFACT S" dep.txt" WRITE-FILE DROP}
      )
    ]

    run_trap = fn name, workers ->
      {:ok, events} = Agent.start_link(fn -> [] end)
      ws = tmp("ldwave-trap-#{name}")
      h = host(ws, events: events)

      assert {:trap, "missing_file", _msg, _host, _colon, metrics} =
               Wave.execute(h, nodes, artifacts, workers: workers)

      started =
        events
        |> Agent.get(& &1)
        |> Enum.filter(&(&1.type == "graph.node.start"))
        |> Enum.map(& &1.data[:node])
        |> Enum.sort()

      finished =
        events
        |> Agent.get(& &1)
        |> Enum.filter(&(&1.type == "graph.node.finish"))
        |> Enum.map(&{&1.data[:node], &1.data[:status]})
        |> Enum.sort()

      {metrics.trap_node, File.exists?(Path.join(ws, "ok.txt")),
       File.exists?(Path.join(ws, "dep.txt")), started, finished}
    end

    serial = run_trap.("serial", 1)
    waved = run_trap.("waved", 2)

    assert serial == waved
    {trap_node, ok?, dep?, started, finished} = serial
    assert trap_node == "trap"
    assert ok?
    refute dep?
    assert started == ["ok", "trap"]
    refute Enum.any?(finished, fn {id, _status} -> id == "dep" end)
    assert {"ok", "ok"} in finished
    assert {"trap", "fail"} in finished
  end

  test "narrowed node_view refuses out-of-set write; sibling still completes" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    ws = tmp("ldwave-policy")
    h = host(ws, events: events)

    nodes = [
      node("writer-a", ["a.txt"], [], ~s{S" stolen" S" b.txt" WRITE-FILE DROP}),
      node("writer-b", ["b.txt"], [], ~s{S" ok" S" b.txt" WRITE-FILE DROP})
    ]

    assert {:trap, "policy", _msg, _host, _colon, metrics} =
             Wave.execute(h, nodes, %{"b.txt" => "ok\n"}, workers: 2)

    assert metrics.trap_node == "writer-a"
    assert File.read!(Path.join(ws, "b.txt")) == "ok"
    refute File.exists?(Path.join(ws, "a.txt"))
  end
end
