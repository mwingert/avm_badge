defmodule Badge.FractalTest do
  use ExUnit.Case, async: true

  alias Badge.Fractal
  alias Badge.Fractal.Palette

  describe "escape/4" do
    test "the origin never escapes the Mandelbrot set" do
      assert Fractal.escape(:mandelbrot, 0.0, 0.0, 50) == 50
    end

    test "a far point escapes at once" do
      for kind <- Fractal.kinds() do
        assert Fractal.escape(kind, 2.0, 2.0, 50) <= 1
      end
    end

    test "the tricorn differs from the Mandelbrot set" do
      assert Fractal.escape(:mandelbrot, -0.1, 0.9, 64) != Fractal.escape(:tricorn, -0.1, 0.9, 64)
    end
  end

  describe "zoom/2" do
    test "the top-left sector moves the centre up and left and quarters the span" do
      view = %{Fractal.view(:mandelbrot) | cx: 0.0, cy: 0.0, span: 4.0}
      next = Fractal.zoom(view, 0)

      assert next.span == 1.0
      assert next.depth == 1
      assert_in_delta next.cx, -1.5, 1.0e-9
      assert_in_delta next.cy, 4.0 * Fractal.height() / Fractal.width() / 4, 1.0e-9
    end

    test "the bottom-right sector moves the centre down and right" do
      view = %{Fractal.view(:mandelbrot) | cx: 0.0, cy: 0.0, span: 4.0}
      next = Fractal.zoom(view, 7)

      assert_in_delta next.cx, 1.5, 1.0e-9
      assert next.cy < 0
    end
  end

  describe "image/2" do
    test "is an rgba8888 image of the render size" do
      {:rgba8888, w, h, pixels} = Fractal.image(Fractal.view(:julia), Palette.colours("Fire"))

      assert {w, h} == {Fractal.width(), Fractal.height()}
      assert byte_size(pixels) == w * h * 4
    end
  end
end
