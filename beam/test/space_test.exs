defmodule LdHost.SpaceTest do
  use ExUnit.Case, async: true

  alias LdHost.Space

  defp space(opts \\ []) do
    {:ok, pid} = Space.start_link(opts)
    pid
  end

  defp events_space do
    me = self()
    space(record: fn kind, payload -> send(me, {:recorded, kind, payload}) end)
  end

  test "subset match is strict on types" do
    assert Space.subset_match(%{"n" => 2}, %{"n" => 2, "extra" => 1})
    refute Space.subset_match(%{"n" => 2}, %{"n" => "2"})
    refute Space.subset_match(%{"n" => 2}, %{"n" => 2.0})
    refute Space.subset_match(%{"flag" => true}, %{"flag" => 1})
    assert Space.subset_match(%{"xs" => [1, 2]}, %{"xs" => [1, 2]})
    refute Space.subset_match(%{"xs" => [1]}, %{"xs" => [1, 2]})
    assert Space.subset_match(%{"a" => %{"b" => 1}}, %{"a" => %{"b" => 1, "c" => 2}})
  end

  test "obligation kind is accepted (inverted from Layer B), unknown kinds refused" do
    s = space()
    assert {:ok, _} = Space.out(s, %{"kind" => "obligation", "id" => "ob-1", "goal" => "g"})
    assert {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "a"})
    assert {:ok, _} = Space.out(s, %{"no_kind" => true})
    assert {:error, reason} = Space.out(s, %{"kind" => "mystery"})
    assert reason =~ "unknown tuple kind"
  end

  test "rd is non-destructive, take removes, oldest-first" do
    s = space()
    {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "first"})
    {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "second"})

    assert %{"node" => "first"} = Space.rd(s, %{"kind" => "node.ready"})
    assert Space.bag_size(s) == 2

    claim = Space.take(s, %{"kind" => "node.ready"}, 5_000, "w1")
    assert claim.tuple["node"] == "first"
    assert Space.bag_size(s) == 1
    assert Space.leased_count(s) == 1
  end

  test "ack consumes; stale token after expiry is fenced" do
    s = events_space()
    {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "n"})

    claim = Space.take(s, %{"kind" => "node.ready"}, 30, "w1")
    assert claim.generation == 1

    # lease expires: tuple returns with bumped generation, event recorded
    Process.sleep(80)
    assert Space.bag_size(s) == 1
    assert_received {:recorded, "space.lease_expired", %{generation: 1}}

    # the old token can never ack
    refute Space.ack(s, claim.token)

    # re-take gets generation 2 and CAN ack
    claim2 = Space.take(s, %{"kind" => "node.ready"}, 5_000, "w2")
    assert claim2.generation == 2
    assert Space.ack(s, claim2.token)
    assert Space.leased_count(s) == 0
    assert_received {:recorded, "space.ack", %{worker: "w2"}}
  end

  test "renew extends the lease and defeats the old timer" do
    s = space()
    {:ok, _} = Space.out(s, %{"kind" => "node.ready"})
    claim = Space.take(s, %{"kind" => "node.ready"}, 50, "w1")

    Process.sleep(30)
    assert Space.renew(s, claim.token, 500)
    Process.sleep(100)
    # original 50ms timer must not have expired the renewed lease
    assert Space.leased_count(s) == 1
    assert Space.ack(s, claim.token)
  end

  test "blocking take is served by a later out" do
    s = space()

    task =
      Task.async(fn ->
        Space.take(s, %{"kind" => "node.ready", "wave" => 1}, 5_000, "w1", timeout: :infinity)
      end)

    Process.sleep(20)
    assert Space.waiter_count(s) == 1
    {:ok, _} = Space.out(s, %{"kind" => "node.ready", "wave" => 1, "node" => "x"})

    claim = Task.await(task)
    assert claim.tuple["node"] == "x"
  end

  test "take timeout returns nil" do
    s = space()
    assert Space.take(s, %{"kind" => "node.ready"}, 1_000, "w1", timeout: 50) == nil
    assert Space.waiter_count(s) == 0
  end

  test "specific waiter beats generic waiter" do
    s = space()

    generic = Task.async(fn -> Space.take(s, %{"kind" => "node.ready"}, 5_000, "generic", timeout: :infinity) end)
    Process.sleep(20)
    specific = Task.async(fn -> Space.take(s, %{"kind" => "node.ready", "node" => "x"}, 5_000, "specific", timeout: :infinity) end)
    Process.sleep(20)

    {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "x"})
    claim = Task.await(specific)
    assert claim.worker_id == "specific"

    {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "y"})
    assert Task.await(generic).worker_id == "generic"
  end

  test "dead waiter is dropped via monitor" do
    s = space()

    pid = spawn(fn -> Space.take(s, %{"kind" => "node.ready"}, 5_000, "doomed", timeout: :infinity) end)
    Process.sleep(20)
    assert Space.waiter_count(s) == 1
    Process.exit(pid, :kill)
    Process.sleep(20)
    assert Space.waiter_count(s) == 0

    # the tuple is not lost to the dead waiter
    {:ok, _} = Space.out(s, %{"kind" => "node.ready"})
    assert Space.bag_size(s) == 1
  end

  test "contention: 50 concurrent takers, no double-claim" do
    s = space()

    for i <- 1..50 do
      {:ok, _} = Space.out(s, %{"kind" => "node.ready", "node" => "n#{i}"})
    end

    claims =
      1..50
      |> Task.async_stream(
        fn i -> Space.take(s, %{"kind" => "node.ready"}, 5_000, "w#{i}", timeout: :infinity) end,
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, claim} -> claim end)

    ids = Enum.map(claims, & &1.tuple_id)
    assert length(Enum.uniq(ids)) == 50
    assert Space.bag_size(s) == 0
    assert Space.leased_count(s) == 50
  end

  test "space events carry the reference payload shape" do
    s = events_space()
    {:ok, tid} = Space.out(s, %{"kind" => "obligation", "id" => "ob-1"})

    assert_received {:recorded, "space.out",
                     %{worker: "host", tuple_id: ^tid, generation: 0, lease_s: 0, pattern_or_tuple: %{"id" => "ob-1"}}}

    _claim = Space.take(s, %{"kind" => "obligation"}, 1_000, "dispatcher")
    assert_received {:recorded, "space.take", %{worker: "dispatcher", generation: 1, pattern_or_tuple: %{"kind" => "obligation"}}}
  end
end
