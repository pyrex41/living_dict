defmodule LdHost.PlannerTest do
  use ExUnit.Case, async: false

  defp with_env(values, fun) do
    previous = Map.new(Map.keys(values), &{&1, System.get_env(&1)})
    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  test "provider-specific defaults and request protocols remain distinct" do
    with_env(%{"LIVINGDICT_PROVIDER" => "openai", "LIVINGDICT_MODEL" => ""}, fn ->
      assert LdHost.Planner.provider() == "openai"
      assert LdHost.Planner.model() == "gpt-5"
      assert LdHost.Planner.endpoint() == "https://api.openai.com/v1/responses"
      {body, _meta, headers} = LdHost.Planner.request_shape("goal", "state")
      assert body.instructions =~ "Forth"
      assert Enum.at(body.input, 0).content =~ "GOAL"
      assert body.text.format.type == "json_object"
      assert headers == []
    end)

    with_env(%{"LIVINGDICT_PROVIDER" => "anthropic", "LIVINGDICT_MODEL" => ""}, fn ->
      {body, _meta, headers} = LdHost.Planner.request_shape("goal", "state")
      assert LdHost.Planner.model() == "claude-sonnet-4-5"
      assert body.system =~ "Forth"
      assert body.max_tokens == 16_384
      assert headers == []
    end)
  end

  test "OpenAI OAuth is represented without reading credential files" do
    with_env(
      %{
        "LIVINGDICT_PROVIDER" => "openai",
        "LIVINGDICT_OPENAI_AUTH" => "oauth",
        "OPENAI_API_KEY" => ""
      },
      fn -> assert LdHost.Planner.credentials() == {:ok, :codex_oauth} end
    )
  end

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

  test "run cache keys are private to a run and stable goal prefix survives observation changes" do
    {body1, meta1, headers1} =
      LdHost.Planner.request_shape("same goal", "first state", run_id: "run-a", cache_scope: :run)

    {body2, meta2, headers2} =
      LdHost.Planner.request_shape("same goal", "second state",
        run_id: "run-a",
        cache_scope: :run
      )

    assert meta1.message_prefix_sha256 == meta2.message_prefix_sha256
    assert headers1 == headers2
    assert Enum.at(body1.messages, 2) != Enum.at(body2.messages, 2)

    {_body, _meta, other_headers} =
      LdHost.Planner.request_shape("same goal", "first state", run_id: "run-b", cache_scope: :run)

    refute headers1 == other_headers
  end

  test "off scope omits provider affinity and research keeps tools during synthesis" do
    {_body, meta, headers} =
      LdHost.Planner.request_shape("goal", "state", run_id: "run-a", cache_scope: :off)

    assert headers == []
    assert meta.cache_key_fingerprint == nil

    auto = LdHost.Research.request_body([], :auto)
    closed = LdHost.Research.request_body([], :none)
    assert auto.tools == closed.tools
    assert auto.tool_choice == "auto"
    assert closed.tool_choice == "none"
  end
end
