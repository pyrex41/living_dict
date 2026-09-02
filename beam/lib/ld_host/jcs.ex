defmodule LdHost.JCS do
  @moduledoc """
  RFC 8785 (JSON Canonicalization Scheme) encoder for the subset of JSON the
  runtime evidence uses: objects, arrays, strings, integers, booleans, null.

  Byte-for-byte compatible with the executor's `serde_jcs` output, which is
  what every `entry_hash`, checkpoint hash, and effect key is computed over.
  Floats are refused rather than approximated: evidence must not contain them.
  """

  @spec encode!(term()) :: binary()
  def encode!(value), do: IO.iodata_to_binary(encode(value))

  @doc "SHA-256 hex of the canonical encoding."
  def hash!(value), do: :crypto.hash(:sha256, encode!(value)) |> Base.encode16(case: :lower)

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(n) when is_integer(n), do: Integer.to_string(n)
  defp encode(f) when is_float(f), do: raise(ArgumentError, "floats are not canonical evidence")
  defp encode(s) when is_binary(s), do: [?", escape(s), ?"]
  defp encode(a) when is_atom(a), do: encode(Atom.to_string(a))

  defp encode(list) when is_list(list),
    do: [?[, Enum.map_join(list, ",", &encode!/1), ?]]

  defp encode(map) when is_map(map) do
    body =
      map
      |> Enum.map(fn {k, v} -> {key(k), v} end)
      |> Enum.sort_by(fn {k, _} -> :unicode.characters_to_binary(k, :utf8, :utf16) end)
      |> Enum.map_join(",", fn {k, v} ->
        [?", escape(k), ?", ?:, encode!(v)] |> IO.iodata_to_binary()
      end)

    [?{, body, ?}]
  end

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)

  # JCS string escaping: only `"`, `\\`, and U+0000..U+001F are escaped;
  # short forms for \b \t \n \f \r, lowercase \u00xx otherwise.
  defp escape(s), do: for(<<c <- s>>, into: "", do: esc(c))
  defp esc(?"), do: "\\\""
  defp esc(?\\), do: "\\\\"
  defp esc(?\b), do: "\\b"
  defp esc(?\t), do: "\\t"
  defp esc(?\n), do: "\\n"
  defp esc(?\f), do: "\\f"
  defp esc(?\r), do: "\\r"

  defp esc(c) when c < 0x20,
    do: "\\u00" <> String.pad_leading(Integer.to_string(c, 16) |> String.downcase(), 2, "0")

  defp esc(c), do: <<c>>
end
