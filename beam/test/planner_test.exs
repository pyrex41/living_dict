defmodule LdHost.PlannerTest do
  use ExUnit.Case, async: false

  test "planner endpoint can be routed through a run-local recorder" do
    previous = System.get_env("LIVINGDICT_PLANNER_ENDPOINT")
    System.put_env("LIVINGDICT_PLANNER_ENDPOINT", "http://127.0.0.1:8765/v1/chat/completions")

    on_exit(fn ->
      if previous,
        do: System.put_env("LIVINGDICT_PLANNER_ENDPOINT", previous),
        else: System.delete_env("LIVINGDICT_PLANNER_ENDPOINT")
    end)

    assert LdHost.Planner.endpoint() == "http://127.0.0.1:8765/v1/chat/completions"
  end

  test "sanitize scrubs invalid utf-8 so JSON encoding cannot reject" do
    dirty = "price: " <> <<0xA3>> <> "10"
    clean = LdHost.Planner.sanitize(dirty)
    assert String.valid?(clean)
    assert is_binary(JSON.encode!(%{content: clean}))
    assert LdHost.Planner.sanitize("plain ascii") == "plain ascii"
  end

  test "gate-check output with invalid bytes survives to feedback" do
    tmp = System.tmp_dir!() |> Path.join("ldsan-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(tmp)
    result = LdHost.Cmd.sh(~s{printf 'ok \\243 bad-byte'}, tmp, 5_000)
    assert String.valid?(result.output)
    assert result.output =~ "bad-byte"
  end
end
