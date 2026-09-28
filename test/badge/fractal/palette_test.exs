defmodule Badge.Fractal.PaletteTest do
  use ExUnit.Case, async: true

  alias Badge.Fractal.Palette

  defp rgb(<<r, g, b, _a>>), do: r * 0x10000 + g * 0x100 + b

  test "offers five palettes, Rainbow first and default" do
    assert Palette.names() == ["Rainbow", "Fire", "Ocean", "Mono", "Tokyo Night"]
    assert Palette.default() == "Rainbow"
  end

  test "every palette has 16 escape colours and an inside colour" do
    for name <- Palette.names() do
      colours = Palette.colours(name)

      assert tuple_size(colours) == 17
      assert Enum.all?(Tuple.to_list(colours), &(byte_size(&1) == 4))
    end
  end

  test "the frame and grid colours never appear in their own palette" do
    for name <- Palette.names() do
      used = for colour <- Tuple.to_list(Palette.colours(name)), do: rgb(colour)

      refute Palette.frame(name) in used, name
      refute Palette.grid(name) in used, name
      assert Palette.frame(name) != Palette.grid(name)
    end
  end

  test "shift steps through the names and stops at both ends" do
    assert Palette.shift("Rainbow", 1) == "Fire"
    assert Palette.shift("Rainbow", -1) == "Rainbow"
    assert Palette.shift("Tokyo Night", 1) == "Tokyo Night"
  end

  test "decode falls back to the default" do
    assert Palette.decode(nil) == "Rainbow"
    assert Palette.decode("Plaid") == "Rainbow"
    assert Palette.decode("Ocean") == "Ocean"
  end
end
