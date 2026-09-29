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

  defmodule Restless do
    def tick(_state), do: raise("boom")
    def awake?(_state), do: raise("boom")
    def leave(_state), do: :ok
  end

  describe "a page that crashes" do
    setup do
      %{
        state: %{
          page: Restless,
          page_state: nil,
          asleep: false,
          napping: false,
          dirty: false,
          countdown: 3,
          interval: 50,
          ticker: self()
        }
      }
    end

    test "in awake? is replaced by Home at the base interval", %{state: state} do
      state = capture_crash(fn -> Badge.UI.drowse(state) end)

      assert state.page == Badge.Page.Home
      assert state.interval == 100
      assert_received {:interval, 100}
    end

    test "in tick is replaced by Home at the base interval", %{state: state} do
      {:noreply, state} = capture_crash(fn -> Badge.UI.handle_info(:render_tick, state) end)

      assert state.page == Badge.Page.Home
      assert state.interval == 100
      assert_received {:interval, 100}
      assert_received :ticked
    end
  end

  # An app from api 1: every callback it had then, but no awake?/1.
  defmodule OldApp do
    def title, do: "Old"
    def init, do: :state
    def render(_state), do: []
    def leave(_state), do: :ok
  end

  describe "an app built before awake?/1" do
    test "lets the screen sleep, without counting as a crash" do
      {awake, log} = ExUnit.CaptureIO.with_io(fn -> Badge.UI.page_awake(OldApp, :state) end)

      assert awake == {:ok, false}
      assert log == ""
    end

    test "while a page that has it still decides, and a crash in it is still a crash" do
      assert Badge.UI.page_awake(Badge.Page.Home, Badge.Page.Home.init()) == {:ok, false}
      assert capture_crash(fn -> Badge.UI.page_awake(Restless, nil) end) == :crashed
    end
  end

  defp capture_crash(fun) do
    {result, log} = ExUnit.CaptureIO.with_io(fun)
    assert log =~ "crashed"
    result
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
