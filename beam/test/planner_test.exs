defmodule LdHost.PlannerTest do
  use ExUnit.Case, async: true

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
