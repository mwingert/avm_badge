defmodule Badge.Sim.FractalNvsTest do
  use ExUnit.Case, async: false

  alias Badge.Nvs
  alias Badge.Page.Fractal

  setup do
    start_supervised!(Badge.Sim.Nvs)
    :ok
  end

  test "the first tick loads the saved palette" do
    Nvs.put(:fractal_pal, "Ocean")

    assert Fractal.tick(Fractal.init()).palette == "Ocean"
  end

  test "a palette is saved once editing ends" do
    {:ok, state} = Fractal.handle_key({:move, :right}, Fractal.tick(Fractal.init()))
    {:ok, state} = Fractal.handle_key({:edit, :newline}, state)
    {:ok, state} = Fractal.handle_key({:move, :right}, state)

    state = Fractal.tick(state)
    assert Nvs.get(:fractal_pal) == nil

    {:ok, state} = Fractal.handle_key({:edit, :newline}, state)
    Fractal.tick(state)
    assert Nvs.get(:fractal_pal) == "Fire"
  end
end
