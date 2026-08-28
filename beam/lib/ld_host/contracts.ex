defmodule LdHost.Contracts do
  @moduledoc """
  Host-side reading of in-band word contracts: for each `: NAME ( ... )`
  in a program, the first paren group after the name. The critic is the
  authority on validity (it already proved body ⊨ contract at accept
  time); this module only recovers the text for rendering persisted
  words. Mirrors the Shen tokeniser's comment rule: `(` opens a group
  only when followed by whitespace.
  """

  @doc "Map of upcased word name -> raw contract text (inner, untrimmed)."
  def extract(source) do
    scan(String.graphemes(source), true, [], %{})
  end

  # State walk: emit tokens enough to spot `: NAME ( ... )` runs.
  defp scan([], _prev_space, _pending, acc), do: acc

  defp scan([c | rest], prev_space, pending, acc) do
    cond do
      c in [" ", "\t", "\n", "\r", "\f", "\v"] ->
        scan(rest, true, pending, acc)

      c == "\\" and prev_space ->
        scan(drop_line(rest), true, pending, acc)

      c == "(" and (rest == [] or ws?(hd(rest))) ->
        {inner, remaining} = take_paren(rest, [])

        case pending do
          [:after_name, name] -> scan(remaining, true, [], Map.put(acc, name, inner))
          _ -> scan(remaining, true, [], acc)
        end

      c in ["S", "s"] and match?(["\"" | _], rest) ->
        [_ | after_q] = rest
        scan(drop_string(after_q), false, [], acc)

      true ->
        {word_chars, remaining} = take_word([c | rest], [])
        word = Enum.join(Enum.reverse(word_chars))

        pending =
          case {pending, word} do
            {_, ":"} -> [:colon]
            {[:colon], _} -> [:after_name, String.upcase(word)]
            _ -> []
          end

        scan(remaining, false, pending, acc)
    end
  end

  defp ws?(c), do: c in [" ", "\t", "\n", "\r", "\f", "\v"]

  defp drop_line([]), do: []
  defp drop_line(["\n" | rest]), do: rest
  defp drop_line([_ | rest]), do: drop_line(rest)

  defp take_paren([], acc), do: {Enum.join(Enum.reverse(acc)), []}
  defp take_paren([")" | rest], acc), do: {Enum.join(Enum.reverse(acc)), rest}
  defp take_paren([c | rest], acc), do: take_paren(rest, [c | acc])

  defp drop_string([]), do: []
  defp drop_string(["\"" | rest]), do: rest
  defp drop_string([_ | rest]), do: drop_string(rest)

  defp take_word([], acc), do: {acc, []}

  defp take_word([c | rest], acc) do
    if ws?(c), do: {acc, [c | rest]}, else: take_word(rest, [c | acc])
  end

  @doc """
  Canonical contract rendering from raw inner text: single spaces,
  ` -- `, sorted comma-joined effects — matching the critic's
  format-contract so saved words are byte-stable.
  """
  def canonical(inner) do
    words =
      inner
      |> String.replace(",", " ")
      |> String.split(~r/\s+/, trim: true)

    case Enum.split_while(words, &(&1 != "--")) do
      {ins, ["--" | rest]} ->
        {outs, effs} =
          case Enum.split_while(rest, &(&1 != "|")) do
            {outs, ["|" | effects]} -> {outs, effects}
            {outs, []} -> {outs, []}
          end

        left = Enum.join(ins, " ")
        right = Enum.join(outs, " ")
        base = "( " <> pad(left) <> "--" <> pre(right)

        if effs == [] do
          base <> " )"
        else
          base <> " | " <> Enum.join(Enum.sort(effs), ", ") <> " )"
        end

      _ ->
        nil
    end
  end

  defp pad(""), do: ""
  defp pad(s), do: s <> " "
  defp pre(""), do: ""
  defp pre(s), do: " " <> s
end
