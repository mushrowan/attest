defmodule Attest.Machine.Keyboard do
  @moduledoc """
  Keyboard character-to-QMP-key mapping

  Maps printable characters to QMP key names for `send_chars`.
  Handles lowercase letters, digits, uppercase (shift+letter),
  and common special characters
  """

  @special_keys %{
    "\n" => "ret",
    "\t" => "tab",
    " " => "spc",
    "-" => "0x0C",
    "=" => "0x0D",
    "[" => "0x1A",
    "]" => "0x1B",
    ";" => "0x27",
    "'" => "0x28",
    "`" => "0x29",
    "\\" => "0x2B",
    "," => "0x33",
    "." => "0x34",
    "/" => "0x35",
    "_" => "shift-0x0C",
    "+" => "shift-0x0D",
    "{" => "shift-0x1A",
    "}" => "shift-0x1B",
    ":" => "shift-0x27",
    "\"" => "shift-0x28",
    "~" => "shift-0x29",
    "|" => "shift-0x2B",
    "<" => "shift-0x33",
    ">" => "shift-0x34",
    "?" => "shift-0x35",
    "!" => "shift-0x02",
    "@" => "shift-0x03",
    "#" => "shift-0x04",
    "$" => "shift-0x05",
    "%" => "shift-0x06",
    "^" => "shift-0x07",
    "&" => "shift-0x08",
    "*" => "shift-0x09",
    "(" => "shift-0x0A",
    ")" => "shift-0x0B"
  }

  @doc """
  Map a single character to a QMP key name
  """
  @spec char_to_key(String.t()) :: String.t()
  def char_to_key(char) when byte_size(char) == 1 do
    Map.get(key_map(), char, char)
  end

  def char_to_key(char), do: char

  defp key_map do
    uppers =
      for c <- ?A..?Z, into: %{} do
        {<<c>>, "shift-#{<<c + 32>>}"}
      end

    Map.merge(uppers, @special_keys)
  end
end
