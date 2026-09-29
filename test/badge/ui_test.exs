defmodule Badge.UITest do
  use ExUnit.Case, async: true

  defmodule Holder do
    def leave(owner) do
      send(owner, :left)
      :ok
    end
  end

  test "a page that crashed is left before Home takes its place" do
    state = Badge.UI.crashed(%{page: Holder, page_state: self(), dirty: false, countdown: 3})

    assert_received :left
    assert state.page == Badge.Page.Home
    assert state.dirty
  end

  describe "the tick interval" do
    test "is the base 100 ms for a page that refreshes no faster" do
      assert Badge.UI.interval(100) == 100
      assert Badge.UI.interval(333) == 100
    end

    test "halves for a page that asks for faster frames" do
      assert Badge.UI.interval(50) == 50
      assert Badge.UI.interval(20) == 50
    end
  end

  describe "a tick while drowsing" do
    test "lights a dark screen for a page that must stay awake" do
      assert Badge.UI.drowsing(true, true) == :wake
    end

    test "keeps a lit screen on without counting" do
      assert Badge.UI.drowsing(false, true) == :stay
    end

    test "counts on towards the timeout otherwise" do
      assert Badge.UI.drowsing(false, false) == :sleep
      assert Badge.UI.drowsing(true, false) == :nap
    end
  end

  describe "the ticker" do
    test "holds the next tick until the last one is handled" do
      me = self()
      ticker = spawn_link(fn -> Badge.UI.tick_loop(me, 20) end)

      assert_receive :render_tick, 200
      refute_receive :render_tick, 150

      send(ticker, :ticked)
      assert_receive :render_tick, 200
    end

    test "takes a new interval while it waits" do
      me = self()
      ticker = spawn_link(fn -> Badge.UI.tick_loop(me, 1_000) end)

      send(ticker, {:interval, 20})
      assert_receive :render_tick, 200

      send(ticker, {:interval, 30})
      refute_receive :render_tick, 100
      send(ticker, :ticked)
      assert_receive :render_tick, 200
    end
  end
end
