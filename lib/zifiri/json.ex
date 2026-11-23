defmodule Zifiri.JSON do
  @moduledoc """
  The smallest JSON codec that can carry the API.

  `jason` is deliberately not a dependency (see `mix.exs`: the list is the HTTP
  stack and the store, nothing more), and the API only ever exchanges strings,
  integers, lists and string-keyed maps. That is the whole supported grammar.

  Two rules matter for the anonymity goal:

    * **Encoding is deterministic.** Keys are sorted, so the same post always
      serialises to the same bytes. Two responses of the same shape differ only
      in their values, never in their key order.
    * **Decoding never echoes its input.** Every parse failure raises a
      constant message, because a parse error that quotes the body is a body in
      an error response.

  The decoder is a plain recursive descent parser and returns maps with string
  keys, which is what `Plug.Parsers` expects from a `:json_decoder`.
  """

  @type json :: nil | boolean() | number() | binary() | [json()] | %{optional(binary()) => json()}

  # -- encoding ---------------------------------------------------------------

  @doc "Serialises a term. Keys of a map are sorted for a stable byte layout."
  @spec encode(json()) :: binary()
  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(value) when is_integer(value), do: Integer.to_string(value)
  def encode(value) when is_float(value), do: Float.to_string(value)
  def encode(value) when is_binary(value), do: [?", escape(value), ?"] |> IO.iodata_to_binary()
  def encode(value) when is_atom(value), do: encode(Atom.to_string(value))

  def encode(value) when is_list(value) do
    items = value |> Enum.map(&encode/1) |> Enum.intersperse(?,)
    IO.iodata_to_binary([?[, items, ?]])
  end

  def encode(%{} = value) do
    pairs =
      value
      |> Enum.map(fn {key, val} -> [encode(to_key(key)), ?:, encode(val)] end)
      |> Enum.sort()
      |> Enum.intersperse(?,)

    IO.iodata_to_binary([?{, pairs, ?}])
  end

  defp to_key(key) when is_binary(key), do: key
  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key) when is_integer(key), do: Integer.to_string(key)

  # Byte-wise on purpose: a multi-byte UTF-8 sequence passes through unchanged,
  # while control characters and the two structural characters are escaped.
  defp escape(bin), do: escape(bin, [])

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<"\"", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<"\\", rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<"\n", rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<"\r", rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<"\t", rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<byte, rest::binary>>, acc) when byte < 0x20,
    do: escape(rest, [unicode_escape(byte) | acc])

  defp escape(<<byte, rest::binary>>, acc), do: escape(rest, [byte | acc])

  defp unicode_escape(byte) do
    hex = byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
    "\\u00" <> hex
  end

  # -- decoding ---------------------------------------------------------------

  @doc "Parses a JSON document. Raises `Plug.Parsers.ParseError` on bad input."
  @spec decode!(binary()) :: json()
  def decode!(bin) when is_binary(bin) do
    case value(skip(bin)) do
      {:ok, value, rest} ->
        case skip(rest) do
          "" -> value
          _ -> bad_input()
        end

      :error ->
        bad_input()
    end
  end

  @doc "Parses a JSON document into `{:ok, term}` or `{:error, :invalid}`."
  @spec decode(binary()) :: {:ok, json()} | {:error, :invalid}
  def decode(bin) when is_binary(bin) do
    case value(skip(bin)) do
      {:ok, value, rest} ->
        case skip(rest) do
          "" -> {:ok, value}
          _ -> {:error, :invalid}
        end

      :error ->
        {:error, :invalid}
    end
  end

  defp bad_input do
    raise Plug.Parsers.ParseError, message: "invalid json"
  end

  defp skip(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip(rest)
  defp skip(bin), do: bin

  defp value(<<"\"", rest::binary>>), do: string(rest, [])
  defp value(<<"{", rest::binary>>), do: object(skip(rest), %{})
  defp value(<<"[", rest::binary>>), do: array(skip(rest), [])
  defp value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp value(<<"null", rest::binary>>), do: {:ok, nil, rest}
  defp value(bin), do: number(bin)

  defp object(<<"}", rest::binary>>, acc), do: {:ok, acc, rest}

  defp object(<<"\"", rest::binary>>, acc) do
    with {:ok, key, rest} <- string(rest, []),
         <<":", rest::binary>> <- skip(rest),
         {:ok, value, rest} <- value(skip(rest)) do
      acc = Map.put(acc, key, value)

      case skip(rest) do
        <<",", rest::binary>> -> object(skip(rest), acc)
        <<"}", rest::binary>> -> {:ok, acc, rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp object(_bin, _acc), do: :error

  defp array(<<"]", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp array(bin, acc) do
    with {:ok, value, rest} <- value(bin) do
      case skip(rest) do
        <<",", rest::binary>> -> array(skip(rest), [value | acc])
        <<"]", rest::binary>> -> {:ok, Enum.reverse([value | acc]), rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp string(<<"\"", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string(<<"\\", esc, rest::binary>>, acc) do
    case esc do
      ?" -> string(rest, ["\"" | acc])
      ?\\ -> string(rest, ["\\" | acc])
      ?/ -> string(rest, ["/" | acc])
      ?b -> string(rest, ["\b" | acc])
      ?f -> string(rest, ["\f" | acc])
      ?n -> string(rest, ["\n" | acc])
      ?r -> string(rest, ["\r" | acc])
      ?t -> string(rest, ["\t" | acc])
      ?u -> unicode(rest, acc)
      _ -> :error
    end
  end

  defp string(<<byte, rest::binary>>, acc) when byte >= 0x20, do: string(rest, [byte | acc])
  defp string(_bin, _acc), do: :error

  defp unicode(<<hex::binary-size(4), rest::binary>>, acc) do
    with {:ok, code} <- hex4(hex) do
      cond do
        code in 0xD800..0xDBFF ->
          case rest do
            <<"\\u", low_hex::binary-size(4), rest::binary>> ->
              with {:ok, low} <- hex4(low_hex),
                   true <- low in 0xDC00..0xDFFF do
                combined = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                string(rest, [<<combined::utf8>> | acc])
              else
                _ -> :error
              end

            _ ->
              :error
          end

        code in 0xDC00..0xDFFF ->
          :error

        true ->
          string(rest, [<<code::utf8>> | acc])
      end
    end
  end

  defp unicode(_bin, _acc), do: :error

  defp hex4(hex) do
    case Integer.parse(hex, 16) do
      {code, ""} -> {:ok, code}
      _ -> :error
    end
  end

  defp number(bin) do
    {digits, rest} = take_number(bin, [])

    case digits |> Enum.reverse() |> List.to_string() do
      "" ->
        :error

      text ->
        if String.contains?(text, [".", "e", "E"]) do
          case Float.parse(text) do
            {float, ""} -> {:ok, float, rest}
            _ -> :error
          end
        else
          case Integer.parse(text) do
            {int, ""} -> {:ok, int, rest}
            _ -> :error
          end
        end
    end
  end

  defp take_number(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c == ?- or c == ?+ or c == ?. or c == ?e or c == ?E do
    take_number(rest, [c | acc])
  end

  defp take_number(rest, acc), do: {acc, rest}
end
