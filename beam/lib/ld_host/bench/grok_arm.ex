defmodule LdHost.Bench.GrokArm do
  @moduledoc """
  The grok baseline arm, shared by every benchmark campaign: run the
  ReAct-style `grok` CLI on one goal in one workspace, capture its full
  output, and pull token usage + model-call counts out of the last JSON
  blob it prints. Extracted verbatim from `LdHost.Demo` so the eval-task
  demo and the polyglot campaign score the same baseline the same way.
  """

  @doc """
  Run grok on `goal` inside `ws`, teeing raw output to `output_path`.
  Returns `{usage_map, model_calls, exit_status}` where `usage_map` is
  `%{input_tokens: n, output_tokens: n}`.
  """
  def run(goal, ws, output_path) do
    grok = System.find_executable("grok") || Path.expand("~/.grok/bin/grok")

    port =
      Port.open({:spawn_executable, grok}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-p", goal, "--cwd", ws, "--output-format", "json", "--always-approve", "--max-turns", "6"]
      ])

    {output, exit_status} = drain(port, [])
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, "exit=#{inspect(exit_status)}\n" <> output)

    case last_json(output) do
      %{"usage" => usage} = blob ->
        calls =
          case blob["modelUsage"] do
            %{} = mu -> mu |> Map.values() |> Enum.map(&(&1["modelCalls"] || 0)) |> Enum.sum()
            _ -> blob["num_turns"] || blob["numTurns"] || 0
          end

        {%{
           input_tokens: usage["input_tokens"] || usage["prompt_tokens"] || 0,
           output_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0
         }, calls, exit_status}

      _ ->
        {%{input_tokens: 0, output_tokens: 0}, 0, exit_status}
    end
  end

  defp drain(port, acc) do
    receive do
      {^port, {:data, chunk}} -> drain(port, [acc, chunk])
      {^port, {:exit_status, code}} -> {IO.iodata_to_binary(acc), code}
    after
      900_000 ->
        {IO.iodata_to_binary(acc), nil}
    end
  end

  # The grok CLI emits pretty-printed multi-line JSON, sometimes followed
  # by trailer lines ("Error: max turns reached"): decode from the last
  # line-starting "{" that yields a valid object, trimming past the last
  # "}" when a straight decode fails.
  def last_json(output) do
    ~r/(?:\A|\n)\{/
    |> Regex.scan(output, return: :index)
    |> Enum.map(fn [{start, len}] -> start + len - 1 end)
    |> Enum.reverse()
    |> Enum.find_value(fn i ->
      slice = binary_part(output, i, byte_size(output) - i)
      decode_object(slice) || decode_object(cut_after_last_brace(slice))
    end)
  end

  defp decode_object(nil), do: nil

  defp decode_object(s) do
    case JSON.decode(String.trim(s)) do
      {:ok, %{} = blob} -> blob
      _ -> nil
    end
  end

  defp cut_after_last_brace(s) do
    case :binary.matches(s, "}") do
      [] -> nil
      matches -> {pos, _} = List.last(matches); binary_part(s, 0, pos + 1)
    end
  end
end
