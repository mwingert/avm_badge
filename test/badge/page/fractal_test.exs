defmodule Badge.Page.FractalTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Fractal

  defp keys(state, events) do
    :lists.foldl(
      fn event, acc ->
        {:ok, next} = Fractal.handle_key(event, acc)
        next
      end,
      state,
      events
    )
  end

  defp open(events \\ []), do: keys(Fractal.init(), events ++ [{:edit, :newline}])

  test "opens on the list" do
    state = Fractal.init()

    assert state.view == nil
    assert is_list(Fractal.render(state))
  end

  test "the list shows each fractal's render time" do
    texts = for {:text, _x, _y, _font, _fg, _bg, text} <- Fractal.render(Fractal.init()), do: text

    assert "Mandelbrot" in texts
    assert "~11s" in texts
    assert "~8s" in texts
  end

  test "enter opens the selected fractal" do
    assert open([{:move, :down}]).view.kind == :julia
  end

  test "the list cursor stops at both ends" do
    assert open([{:move, :up}]).view.kind == :mandelbrot
    assert open([{:move, :down}, {:move, :down}, {:move, :down}, {:move, :down}]).view.kind == :tricorn
  end

  test "arrows move the sector and stop at the edges" do
    state = keys(open(), [{:move, :right}, {:move, :down}, {:move, :down}])
    assert state.sector == 5

    assert keys(state, [{:move, :left}, {:move, :left}, {:move, :left}]).sector == 4
  end

  test "enter zooms into the selected sector and queues a render" do
    state = keys(open(), [{:move, :right}, {:edit, :newline}])

    assert state.view.depth == 1
    assert state.stale
  end

  test "tick starts a render and handle_info takes its image" do
    state = Fractal.tick(open())
    ref = state.ref

    refute state.stale
    assert_receive {^ref, {:rgba8888, _w, _h, _pixels} = image}, 5_000

    {:ok, done} = Fractal.handle_info({ref, image}, state)
    assert done.image == image
    assert done.pid == nil
    assert is_list(Fractal.render(done))
  end

  test "the bottom bar shows the keys, the fractal and the zoom level" do
    texts = fn state -> for {:text, _x, _y, _font, _fg, _bg, text} <- Fractal.render(state), do: text end

    state = open([{:move, :down}, {:move, :down}])
    assert "Arrows sector  Enter zoom" in texts.(state)
    assert "Burning Ship  Zoom 0" in texts.(state)

    assert "Burning Ship  Zoom 1" in texts.(keys(state, [{:edit, :newline}]))
  end

  test "a stale render result is ignored" do
    assert Fractal.handle_info({make_ref(), :image}, Fractal.tick(open())) == :ignore
  end
end
