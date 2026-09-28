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
end
