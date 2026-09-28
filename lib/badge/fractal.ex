defmodule Badge.Fractal do
  @moduledoc """
  Escape-time fractals rendered to an `rgba8888` image.

  A view is `%{kind, cx, cy, span, depth}`: the centre on the complex plane,
  the width it covers, and how many zooms led there. `zoom/2` narrows a view
  to one of eight sectors, four across and two down.

  The iteration runs in fixed point with 12 fractional bits. Past about four
  zooms neighbouring pixels share a value and the image turns blocky.
  """

  import Bitwise

  @kinds [:mandelbrot, :julia, :burning_ship, :tricorn]

  @width 80
  @height 49

  @bits 12
  @one 1 <<< @bits
  @escape 4 <<< @bits

  @julia_re round(-0.8 * @one)
  @julia_im round(0.156 * @one)

  @doc "Every fractal kind, in list order."
  def kinds, do: @kinds

  @doc "Display name for a kind."
  def name(:mandelbrot), do: "Mandelbrot"
  def name(:julia), do: "Julia"
  def name(:burning_ship), do: "Burning Ship"
  def name(:tricorn), do: "Tricorn"

  @doc "Seconds the badge takes to render the starting view, measured on hardware."
  def seconds(:mandelbrot), do: 11
  def seconds(:julia), do: 10
  def seconds(:burning_ship), do: 8
  def seconds(:tricorn), do: 10

  @doc "Image width in pixels."
  def width, do: @width

  @doc "Image height in pixels."
  def height, do: @height

  @doc "The starting view for a kind."
  def view(:mandelbrot), do: %{kind: :mandelbrot, cx: -0.6, cy: 0.0, span: 3.6, depth: 0}
  def view(:julia), do: %{kind: :julia, cx: 0.0, cy: 0.0, span: 3.4, depth: 0}
  def view(:burning_ship), do: %{kind: :burning_ship, cx: -0.4, cy: 0.5, span: 3.6, depth: 0}
  def view(:tricorn), do: %{kind: :tricorn, cx: -0.3, cy: 0.0, span: 4.2, depth: 0}

  @doc "The view four times closer, centred on `sector` (0-3 top row, 4-7 bottom row)."
  def zoom(%{cx: cx, cy: cy, span: span, depth: depth} = view, sector) do
    tall = span * @height / @width
    fx = (rem(sector, 4) + 0.5) / 4
    fy = (div(sector, 4) + 0.5) / 2

    %{view | cx: cx - span / 2 + fx * span, cy: cy + tall / 2 - fy * tall, span: span / 4, depth: depth + 1}
  end

  @doc "Steps before the point `x + yi` leaves radius 2, or `max` if it never does."
  def escape(kind, x, y, max), do: point(kind, fixed(x), fixed(y), max)

  @doc "Renders a view in `colours`, a `Badge.Fractal.Palette.colours/1` tuple, as `{:rgba8888, width, height, pixels}`."
  def image(%{kind: kind, cx: cx, cy: cy, span: span, depth: depth}, colours) do
    step = span / @width
    left = cx - span / 2 + step / 2
    top = cy + step * @height / 2 - step / 2
    max = min(32 + 8 * depth, 128)

    # One float conversion per column and per row.
    xs = for col <- :lists.seq(0, @width - 1), do: fixed(left + col * step)
    rows = for row <- :lists.seq(0, @height - 1), do: row(kind, xs, fixed(top - row * step), max, colours)

    {:rgba8888, @width, @height, :erlang.list_to_binary(rows)}
  end

  defp row(kind, xs, y, max, palette) do
    :erlang.list_to_binary(for x <- xs, do: colour(point(kind, x, y, max), max, palette))
  end

  defp fixed(value), do: round(value * @one)

  defp point(:julia, x, y, max), do: iterate(:mandelbrot, x, y, @julia_re, @julia_im, 0, max)
  # Flipped so the ship sits upright, as it is usually drawn.
  defp point(:burning_ship, x, y, max), do: iterate(:burning_ship, 0, 0, x, -y, 0, max)
  defp point(kind, x, y, max), do: iterate(kind, 0, 0, x, y, 0, max)

  defp colour(max, max, palette), do: :erlang.element(17, palette)
  defp colour(n, _max, palette), do: :erlang.element(rem(n, 16) + 1, palette)

  defp iterate(_kind, _zr, _zi, _cr, _ci, max, max), do: max

  defp iterate(kind, zr, zi, cr, ci, n, max) do
    zr2 = zr * zr >>> @bits
    zi2 = zi * zi >>> @bits

    if zr2 + zi2 > @escape do
      n
    else
      iterate(kind, zr2 - zi2 + cr, cross(kind, zr, zi) + ci, cr, ci, n + 1, max)
    end
  end

  # One bit less shift doubles the product.
  defp cross(:mandelbrot, zr, zi), do: zr * zi >>> (@bits - 1)
  defp cross(:burning_ship, zr, zi), do: abs(zr * zi) >>> (@bits - 1)
  defp cross(:tricorn, zr, zi), do: -(zr * zi >>> (@bits - 1))
end
