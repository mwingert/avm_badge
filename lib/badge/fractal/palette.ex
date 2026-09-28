defmodule Badge.Fractal.Palette do
  @moduledoc """
  Colour palettes for `Badge.Fractal`, picked by name.

  Each palette has 16 escape colours and an inside colour, as the 17-tuple
  `Badge.Fractal.image/2` takes, plus a frame colour for the selected sector
  and a grid colour for the sector lines. Neither of those two appears in its
  own palette, so both stay visible over any image.

  The chosen name is kept in NVS under `fractal_pal`.
  """

  alias Badge.Nvs

  @nvs_key :fractal_pal

  # Host-only: builds the ramps at compile time.
  ramp = fn stops ->
    last = length(stops) - 1

    for i <- 0..15 do
      at = i / 15 * last
      index = min(trunc(at), last - 1)
      t = at - index
      a = Enum.at(stops, index)
      b = Enum.at(stops, index + 1)

      mix = fn shift ->
        from = Bitwise.band(Bitwise.bsr(a, shift), 0xFF)
        to = Bitwise.band(Bitwise.bsr(b, shift), 0xFF)
        round(from + (to - from) * t)
      end

      <<mix.(16), mix.(8), mix.(0), 255>>
    end
  end

  rainbow =
    for i <- 0..15 do
      h = i / 16 * 6
      x = round(255 * (1 - abs(:math.fmod(h, 2) - 1)))

      {r, g, b} =
        case trunc(h) do
          0 -> {255, x, 0}
          1 -> {x, 255, 0}
          2 -> {0, 255, x}
          3 -> {0, x, 255}
          4 -> {x, 0, 255}
          _ -> {255, 0, x}
        end

      <<r, g, b, 255>>
    end

  black = <<0, 0, 0, 255>>

  # {name, 16 escape colours, inside, frame, grid}
  @palettes [
    {"Rainbow", rainbow, black, 0xFFFFFF, 0x808080},
    {"Fire", ramp.([0x200000, 0xC00000, 0xFF8000, 0xFFFF00, 0xFFFFFF]), black, 0x00FFFF, 0x3060A0},
    {"Ocean", ramp.([0x000830, 0x0040C0, 0x00C0FF, 0xFFFFFF]), black, 0xFF8000, 0x806040},
    {"Mono", ramp.([0x202020, 0xFFFFFF]), black, 0xFF0000, 0x008B8B},
    {"Tokyo Night", ramp.([0x24283B, 0x7AA2F7, 0x7DCFFF, 0xBB9AF7, 0xF7768E]), <<0x1A, 0x1B, 0x26, 255>>, 0xFF9E64, 0x9ECE6A}
  ]

  @names for {name, _colours, _inside, _frame, _grid} <- @palettes, do: name
  @default hd(@names)

  @doc "Every palette name, in the order they are picked through."
  def names, do: @names

  @doc "The palette used when nothing has been chosen."
  def default, do: @default

  for {name, colours, inside, frame, grid} <- @palettes do
    @doc false
    def colours(unquote(name)), do: unquote(Macro.escape(List.to_tuple(colours ++ [inside])))
    def frame(unquote(name)), do: unquote(frame)
    def grid(unquote(name)), do: unquote(grid)
  end

  @doc "The palette `delta` steps along the list, stopping at either end."
  def shift(name, delta) do
    last = length(@names) - 1
    index = min(max(position(@names, name, 0) + delta, 0), last)

    :lists.nth(index + 1, @names)
  end

  @doc "The palette a stored name means, falling back to the default."
  def decode(name) do
    case :lists.member(name, @names) do
      true -> name
      false -> @default
    end
  end

  @doc "Reads the saved palette."
  def load, do: decode(Nvs.get(@nvs_key))

  @doc "Saves a palette so it survives a reboot."
  def store(name), do: Nvs.put(@nvs_key, name)

  defp position([name | _rest], name, index), do: index
  defp position([_other | rest], name, index), do: position(rest, name, index + 1)
  defp position([], _name, _index), do: 0
end
