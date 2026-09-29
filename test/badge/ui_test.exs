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
end
