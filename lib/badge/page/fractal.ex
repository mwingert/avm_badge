defmodule Badge.Page.Fractal do
  @moduledoc """
  Pick a fractal, then zoom into it one sector at a time.

  The list opens first; Enter renders the chosen fractal. The view is split
  into eight sectors, four across and two down: arrows pick one and Enter
  zooms four times closer on it, as often as floats allow. Esc goes home.

  Rendering runs in a spawned worker started from `tick/1`, so the old image
  stays up until the new one arrives. A newer zoom or leaving the page kills
  a worker that is still busy.
  """

  use Badge.Page

  alias Badge.FontType
  alias Badge.Fractal
  alias Badge.Nav
  alias Badge.Readout
  alias Badge.Theme

  @top Theme.content_top()
  @scale 4
  @columns 4
  @rows 2
  @sector_w div(Fractal.width() * @scale, @columns)
  @sector_h div(Fractal.height() * @scale, @rows)

  @list_top @top + 14
  @pitch 24
  @hint_y 214

  @bar_y @top + @rows * @sector_h + 1
  @margin 8

  @impl true
  def title, do: "Fractals"

  @impl true
  def icon, do: :diamond

  @impl true
  def init, do: %{cursor: 0, view: nil, sector: 0, image: nil, stale: false, ref: nil, pid: nil}

  @impl true
  def handle_key({:move, :up}, %{view: nil} = state), do: {:ok, %{state | cursor: max(state.cursor - 1, 0)}}

  def handle_key({:move, :down}, %{view: nil} = state) do
    {:ok, %{state | cursor: min(state.cursor + 1, length(Fractal.kinds()) - 1)}}
  end

  def handle_key({:edit, :newline}, %{view: nil} = state) do
    view = Fractal.view(:lists.nth(state.cursor + 1, Fractal.kinds()))

    {:ok, %{state | view: view, sector: 0, image: nil, stale: true}}
  end

  def handle_key({:move, dir}, %{view: %{}} = state), do: {:ok, %{state | sector: move(state.sector, dir)}}

  def handle_key({:edit, :newline}, %{view: %{}} = state) do
    {:ok, %{state | view: Fractal.zoom(state.view, state.sector), stale: true}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def tick(%{stale: true} = state) do
    stop(state)

    parent = self()
    ref = make_ref()
    view = state.view
    pid = spawn(fn -> send(parent, {ref, Fractal.image(view)}) end)

    %{state | stale: false, ref: ref, pid: pid}
  end

  def tick(state), do: state

  @impl true
  def handle_info({ref, image}, %{ref: ref} = state), do: {:ok, %{state | image: image, pid: nil}}
  def handle_info(_message, _state), do: :ignore

  @impl true
  def leave(state), do: stop(state)

  @impl true
  def render(%{view: nil} = state) do
    entries = for kind <- Fractal.kinds(), do: %{value: Fractal.name(kind), trailing: wait(kind), trailing_colour: Theme.dim()}

    Nav.rows(entries, state.cursor, @list_top, @pitch) ++ Nav.hint([{"Enter", "open"}], @hint_y, Theme.dim(), :centre)
  end

  def render(state), do: status(state) ++ frame(state.sector) ++ grid() ++ bar(state.view) ++ image(state.image)

  defp wait(kind), do: "~" <> :erlang.integer_to_binary(Fractal.seconds(kind)) <> "s"

  defp move(sector, :left), do: if(rem(sector, @columns) > 0, do: sector - 1, else: sector)
  defp move(sector, :right), do: if(rem(sector, @columns) < @columns - 1, do: sector + 1, else: sector)
  defp move(sector, :up), do: if(sector >= @columns, do: sector - @columns, else: sector)
  defp move(sector, :down), do: if(sector < @columns * (@rows - 1), do: sector + @columns, else: sector)
  defp move(sector, _dir), do: sector

  defp status(%{image: nil}) do
    text = "Rendering..."
    [{:text, Readout.centre_x(text), @top + @sector_h - 8, FontType.body(), Theme.fg(), Theme.bg(), text}]
  end

  defp status(%{pid: nil}), do: []

  defp status(_state), do: [{:text, 4, @top + 4, FontType.body(), Theme.fg(), Theme.bg(), "Rendering..."}]

  defp frame(sector) do
    x = rem(sector, @columns) * @sector_w
    y = @top + div(sector, @columns) * @sector_h
    c = Theme.accent()

    [
      {:rect, x, y, @sector_w, 2, c},
      {:rect, x, y + @sector_h - 2, @sector_w, 2, c},
      {:rect, x, y, 2, @sector_h, c},
      {:rect, x + @sector_w - 2, y, 2, @sector_h, c}
    ]
  end

  defp bar(view) do
    keys = "Arrows sector  Enter zoom"
    where = Fractal.name(view.kind) <> "  Zoom " <> :erlang.integer_to_binary(view.depth)
    font = FontType.heading()

    Theme.rule(0, @bar_y, Theme.width()) ++
      [
        {:text, @margin, @bar_y + 2, font, Theme.dim(), Theme.bg(), keys},
        {:text, Readout.right_x(where, font), @bar_y + 2, font, Theme.fg(), Theme.bg(), where}
      ]
  end

  defp grid do
    c = Theme.muted()

    [{:rect, 0, @top + @sector_h, @columns * @sector_w, 1, c}] ++
      for(i <- :lists.seq(1, @columns - 1), do: {:rect, i * @sector_w, @top, 1, @rows * @sector_h, c})
  end

  defp image(nil), do: []

  defp image({:rgba8888, w, h, _pixels} = image) do
    [{:scaled_cropped_image, 0, @top, w * @scale, h * @scale, 0x000000, 0, 0, @scale, @scale, [], image}]
  end

  defp stop(%{pid: nil}), do: :ok

  defp stop(%{pid: pid}) do
    Process.exit(pid, :kill)

    :ok
  end
end
