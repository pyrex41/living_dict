defmodule LdHost.Forth do
  @moduledoc """
  Tiny hosted Forth. Control flow and tool order, not a payload language.

  Port of `harness/src/livingdict/forth.py` (the frozen Python reference):
  same tokens, same error codes and messages, same truthiness. Paren
  groups and backslash comments are discarded at runtime — only the Shen
  critic reads contracts.

  The host is anything implementing `LdHost.Capability`; capability traps
  surface as `LdHost.Forth.Error` with the trap's code, exactly as the
  Python VM converts CapabilityError to ForthError.
  """

  defmodule Error do
    defexception [:code, :message]
  end

  defmodule Token do
    @enforce_keys [:kind, :value, :index]
    defstruct [:kind, :value, :index]
    @type t :: %__MODULE__{kind: :string | :number | :word, value: String.t() | integer(), index: non_neg_integer()}
  end

  defmodule VM do
    defstruct stack: [], colon: %{}, host: nil, artifacts: %{}
  end

  # BEGIN GENERATED PRIMITIVES v1
  # primitive_contract f22443470fafc4af4669003a41e2238513a5dc0f53fca95bad56d0a013c0101e
  # python3 tools/gen_primitives.py spec/primitives.v1.json
  # Python/Lua/JS HOST_DICTIONARY is documented drift (not generated).
  @primitive_contract "f22443470fafc4af4669003a41e2238513a5dc0f53fca95bad56d0a013c0101e"
  @host_words ~w(READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES RECEIPT USE-ARTIFACT)
  @stack_words ~w(DUP DROP SWAP OVER + - *)
  # END GENERATED PRIMITIVES v1

  def primitive_contract, do: @primitive_contract
  def host_words, do: @host_words
  def stack_words, do: @stack_words

  # ---- tokenizer --------------------------------------------------------

  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(source) do
    toks = tok(String.graphemes(source), true, [])
    toks |> Enum.reverse() |> Enum.with_index() |> Enum.map(fn {{kind, value}, i} -> %Token{kind: kind, value: value, index: i} end)
  end

  defp tok([], _prev_space, acc), do: acc

  defp tok([c | rest], prev_space, acc) do
    cond do
      ws?(c) ->
        tok(rest, true, acc)

      c == "\\" and prev_space ->
        tok(skip_line(rest), true, acc)

      c == "(" and (rest == [] or ws?(hd(rest))) ->
        tok(skip_paren(rest), true, acc)

      (c == "S" or c == "s") and match?(["\"" | _], rest) ->
        [_dq | after_q] = rest
        after_q = case after_q do
          [" " | more] -> more
          other -> other
        end

        case take_string(after_q, []) do
          {:ok, chars, remaining} ->
            tok(remaining, false, [{:string, Enum.join(Enum.reverse(chars))} | acc])

          :unterminated ->
            raise Error, code: "syntax", message: "unterminated S\" string"
        end

      true ->
        {word_chars, remaining} = take_word([c | rest], [])
        raw = Enum.join(Enum.reverse(word_chars))

        token =
          case parse_number(raw) do
            {:ok, n} -> {:number, n}
            :error -> {:word, raw}
          end

        tok(remaining, false, [token | acc])
    end
  end

  defp ws?(c), do: c in [" ", "\t", "\n", "\r", "\f", "\v"]

  defp skip_line([]), do: []
  defp skip_line(["\n" | rest]), do: ["\n" | rest]
  defp skip_line([_ | rest]), do: skip_line(rest)

  defp skip_paren([]), do: []
  defp skip_paren([")" | rest]), do: rest
  defp skip_paren([_ | rest]), do: skip_paren(rest)

  defp take_string([], _acc), do: :unterminated
  defp take_string(["\"" | rest], acc), do: {:ok, acc, rest}
  defp take_string([c | rest], acc), do: take_string(rest, [c | acc])

  defp take_word([], acc), do: {acc, []}

  defp take_word([c | rest], acc) do
    if ws?(c), do: {acc, [c | rest]}, else: take_word(rest, [c | acc])
  end

  defp parse_number(raw) when raw in ["+", "-"], do: :error

  defp parse_number(raw) do
    body = case raw do
      "-" <> tail -> tail
      _ -> raw
    end

    if body != "" and body =~ ~r/^\d+$/ do
      {:ok, String.to_integer(raw)}
    else
      :error
    end
  end

  # ---- interpreter ------------------------------------------------------

  @doc "Run source on a VM; returns the final VM. Raises LdHost.Forth.Error on traps."
  def interpret(%VM{} = vm, source), do: run_tokens(vm, tokenize(source))

  def run_tokens(%VM{} = vm, tokens), do: run_at(vm, tokens, 0)

  defp run_at(vm, tokens, i) when i >= length(tokens), do: vm

  defp run_at(vm, tokens, i) do
    token = Enum.at(tokens, i)

    case token.kind do
      :string ->
        run_at(push(vm, token.value), tokens, i + 1)

      :number ->
        run_at(push(vm, token.value), tokens, i + 1)

      :word ->
        name = token.value
        key = String.upcase(name)

        cond do
          key == ":" ->
            {vm, next} = compile_colon(vm, tokens, i)
            run_at(vm, tokens, next)

          key == "IF" ->
            {vm, next} = run_if(vm, tokens, i)
            run_at(vm, tokens, next)

          key in ["ELSE", "THEN", ";"] ->
            raise Error, code: "syntax", message: "#{key} without matching opener"

          true ->
            run_at(exec_word(vm, key, name), tokens, i + 1)
        end
    end
  end

  defp exec_word(vm, key, original) do
    cond do
      Map.has_key?(vm.colon, key) ->
        run_tokens(vm, vm.colon[key])

      key == "USE-ARTIFACT" ->
        {path, vm} = pop_str(vm, "USE-ARTIFACT")

        case Map.fetch(vm.artifacts, path) do
          {:ok, content} -> push(vm, content)
          :error -> raise Error, code: "missing_artifact", message: "no artifact: #{path}"
        end

      key in @stack_words ->
        stack_word(vm, key)

      key in @host_words ->
        host_word(vm, key)

      true ->
        raise Error, code: "unknown", message: "unknown word #{original}"
    end
  end

  defp stack_word(vm, "DUP"), do: push(vm, peek(vm, "DUP"))
  defp stack_word(vm, "DROP"), do: elem(pop(vm, "DROP"), 1)

  defp stack_word(vm, "SWAP") do
    {b, vm} = pop(vm, "SWAP")
    {a, vm} = pop(vm, "SWAP")
    vm |> push(b) |> push(a)
  end

  defp stack_word(vm, "OVER") do
    case vm.stack do
      [_a, b | _] -> push(vm, b)
      _ -> raise Error, code: "underflow", message: "stack underflow at OVER"
    end
  end

  defp stack_word(vm, op) when op in ["+", "-", "*"] do
    {b, vm} = pop_int(vm, op)
    {a, vm} = pop_int(vm, op)

    push(vm, case op do
      "+" -> a + b
      "-" -> a - b
      "*" -> a * b
    end)
  end

  defp host_word(vm, word) do
    {args, vm} =
      case word do
        "READ-FILE" -> one_str(vm, word)
        "LIST-DIR" -> one_str(vm, word)
        "SEARCH" -> one_str(vm, word)
        "WRITE-FILE" ->
          {path, vm} = pop_str(vm, word)
          {content, vm} = pop_str(vm, word)
          {[content, path], vm}

        _ -> {[], vm}
      end

    case LdHost.Capability.call(vm.host, word, args) do
      {:ok, value, host} -> %{push(vm, value) | host: host}
      {:trap, code, message} -> raise Error, code: code, message: message
    end
  end

  defp one_str(vm, word) do
    {s, vm} = pop_str(vm, word)
    {[s], vm}
  end

  defp compile_colon(vm, tokens, i) do
    name_tok = Enum.at(tokens, i + 1)

    if name_tok == nil or name_tok.kind != :word do
      raise Error, code: "syntax", message: "expected name after :"
    end

    name = String.upcase(name_tok.value)
    collect_body(vm, tokens, i + 2, name, [])
  end

  defp collect_body(_vm, tokens, j, name, _body) when j >= length(tokens) do
    _ = tokens
    raise Error, code: "syntax", message: "unterminated definition of #{name}"
  end

  defp collect_body(vm, tokens, j, name, body) do
    token = Enum.at(tokens, j)

    cond do
      token.kind == :word and String.upcase(token.value) == ";" ->
        {%{vm | colon: Map.put(vm.colon, name, Enum.reverse(body))}, j + 1}

      token.kind == :word and String.upcase(token.value) == ":" ->
        raise Error, code: "syntax", message: "nested colon definitions are not supported"

      true ->
        collect_body(vm, tokens, j + 1, name, [token | body])
    end
  end

  defp run_if(vm, tokens, i) do
    {flag, vm} = pop(vm, "IF")
    {else_at, then_at} = match_if(tokens, i)

    vm =
      cond do
        truthy?(flag) ->
          stop = else_at || then_at
          run_tokens(vm, Enum.slice(tokens, (i + 1)..(stop - 1)//1))

        else_at != nil ->
          run_tokens(vm, Enum.slice(tokens, (else_at + 1)..(then_at - 1)//1))

        true ->
          vm
      end

    {vm, then_at + 1}
  end

  defp match_if(tokens, start) do
    match_if(tokens, start, 0, nil)
  end

  defp match_if(tokens, i, _depth, _else_at) when i >= length(tokens) do
    _ = tokens
    raise Error, code: "syntax", message: "IF without THEN"
  end

  defp match_if(tokens, i, depth, else_at) do
    token = Enum.at(tokens, i)

    if token.kind != :word do
      match_if(tokens, i + 1, depth, else_at)
    else
      case String.upcase(token.value) do
        "IF" -> match_if(tokens, i + 1, depth + 1, else_at)
        "ELSE" when depth == 1 -> match_if(tokens, i + 1, depth, i)
        "THEN" when depth == 1 -> {else_at, i}
        "THEN" -> match_if(tokens, i + 1, depth - 1, else_at)
        _ -> match_if(tokens, i + 1, depth, else_at)
      end
    end
  end

  # ---- stack primitives -------------------------------------------------

  defp push(vm, value), do: %{vm | stack: [value | vm.stack]}

  defp pop(%VM{stack: []}, word), do: raise(Error, code: "underflow", message: "stack underflow at #{word}")
  defp pop(%VM{stack: [top | rest]} = vm, _word), do: {top, %{vm | stack: rest}}

  defp peek(%VM{stack: []}, word), do: raise(Error, code: "underflow", message: "stack underflow at #{word}")
  defp peek(%VM{stack: [top | _]}, _word), do: top

  defp pop_str(vm, word) do
    {value, vm} = pop(vm, word)

    if is_binary(value) do
      {value, vm}
    else
      raise Error, code: "type", message: "#{word} expected string, got #{type_name(value)}"
    end
  end

  defp pop_int(vm, word) do
    {value, vm} = pop(vm, word)

    if is_integer(value) and not is_boolean(value) do
      {value, vm}
    else
      raise Error, code: "type", message: "#{word} expected integer, got #{type_name(value)}"
    end
  end

  defp type_name(v) when is_binary(v), do: "str"
  defp type_name(v) when is_boolean(v), do: "bool"
  defp type_name(v) when is_integer(v), do: "int"
  defp type_name(v) when is_list(v), do: "list"
  defp type_name(v) when is_map(v), do: "dict"
  defp type_name(_), do: "value"

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?(_), do: true

  def defined_names(%VM{colon: colon}), do: colon |> Map.keys() |> Enum.sort()
end
