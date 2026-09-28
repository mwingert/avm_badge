defmodule Badge.Page.Fractal do
  @moduledoc """
  Pick a fractal, then zoom into it one sector at a time.

  The list opens first; Enter renders the chosen fractal. The view is split
  into eight sectors, four across and two down: arrows pick one and Enter
  zooms four times closer on it. Esc goes home.

  Left and right on the list slide to a Settings tab, where the palette is
  changed the way Display changes the theme: Enter starts editing, left and
  right step, Enter or Esc finishes. The palette is loaded on the first tick
  and saved once editing ends.

  Rendering runs in a spawned worker started from `tick/1`, so the old image
  stays up until the new one arrives. A newer zoom or leaving the page kills
  a worker that is still busy.
  """

  use Badge.Page

  alias Badge.FontType
  alias Badge.Fractal
  alias Badge.Fractal.Palette
  alias Badge.Nav
  alias Badge.Readout
  alias Badge.Theme

  @top Theme.content_top()
  @scale 4
  @columns 4
  @rows 2
  @sector_w div(Fractal.width() * @scale, @columns)
  @sector_h div(Fractal.height() * @scale, @rows)

  @rule_y @top + 22
  @content_y @rule_y + 8
  @tabs ["Fractals", "Settings"]

  @list_top @content_y
  @pitch 24

  @swatch_x 16
  @swatch_y @content_y + 40
  @swatch_w 18
  @swatch_h 24
  @hint_y 214

  @bar_y @top + @rows * @sector_h + 1
  @margin 8

  @impl true
  def title, do: "Fractals"

  @impl true
  def icon, do: :diamond

  @impl true
  def init do
    %{
      tab: 0,
      cursor: 0,
      palette: Palette.default(),
      editing: false,
      loaded: false,
      saved: nil,
      view: nil,
      sector: 0,
      image: nil,
      stale: false,
      ref: nil,
      pid: nil
    }
  end

  @impl true
  def handle_key({:move, dir}, %{view: nil, tab: 1, editing: true} = state) when dir == :left or dir == :right do
    {:ok, %{state | palette: Palette.shift(state.palette, if(dir == :right, do: 1, else: -1))}}
  end

  def handle_key({:edit, :newline}, %{view: nil, tab: 1} = state), do: {:ok, %{state | editing: not state.editing}}
  def handle_key({:nav, :home}, %{view: nil, editing: true} = state), do: {:ok, %{state | editing: false}}
  def handle_key({:move, :right}, %{view: nil, tab: 0} = state), do: {:ok, %{state | tab: 1}}
  def handle_key({:move, :left}, %{view: nil, tab: 1} = state), do: {:ok, %{state | tab: 0}}
  def handle_key({:move, :up}, %{view: nil, tab: 0} = state), do: {:ok, %{state | cursor: max(state.cursor - 1, 0)}}

  def handle_key({:move, :down}, %{view: nil, tab: 0} = state) do
    {:ok, %{state | cursor: min(state.cursor + 1, length(Fractal.kinds()) - 1)}}
  end

  def handle_key({:edit, :newline}, %{view: nil, tab: 0} = state) do
    view = Fractal.view(:lists.nth(state.cursor + 1, Fractal.kinds()))

    {:ok, %{state | view: view, sector: 0, image: nil, stale: true}}
  end

  def handle_key({:move, dir}, %{view: %{}} = state), do: {:ok, %{state | sector: move(state.sector, dir)}}

  def handle_key({:edit, :newline}, %{view: %{}} = state) do
    {:ok, %{state | view: Fractal.zoom(state.view, state.sector), stale: true}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def tick(state), do: state |> load() |> persist() |> start()

  defp load(%{loaded: true} = state), do: state

  defp load(state) do
    palette = Palette.load()

    %{state | palette: palette, saved: palette, loaded: true}
  end

  defp persist(%{editing: true} = state), do: state
  defp persist(%{palette: palette, saved: palette} = state), do: state

  defp persist(state) do
    Palette.store(state.palette)

    %{state | saved: state.palette}
  end

  defp start(%{stale: true} = state) do
    stop(state)

    parent = self()
    ref = make_ref()
    view = state.view
    palette = state.palette
    pid = spawn(fn -> send(parent, {ref, Fractal.image(view, Palette.colours(palette))}) end)

    %{state | stale: false, ref: ref, pid: pid}
  end

  defp start(state), do: state

  @impl true
  def handle_info({ref, image}, %{ref: ref} = state), do: {:ok, %{state | image: image, pid: nil}}
  def handle_info(_message, _state), do: :ignore

  @impl true
  def leave(state), do: stop(state)

  @impl true
  def render(%{view: nil} = state) do
    Nav.tabs(@tabs, state.tab, @top) ++ Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin) ++ tab(state)
  end

  def render(state) do
    status(state) ++ frame(state.sector, state.palette) ++ grid(state.palette) ++ bar(state.view) ++ image(state.image)
  end

  defp tab(%{tab: 0} = state) do
    entries = for kind <- Fractal.kinds(), do: %{value: Fractal.name(kind), trailing: wait(kind), trailing_colour: Theme.dim()}

    Nav.rows(entries, state.cursor, @list_top, @pitch) ++ Nav.hint([{"Enter", "open"}], @hint_y, Theme.dim(), :centre)
  end

  defp tab(state) do
    colour = if state.editing, do: Theme.accent(), else: Theme.select()

    [
      {:text, 0, @content_y, FontType.body(), colour, Theme.bg(), ">"},
      {:text, @margin, @content_y, FontType.body(), colour, Theme.bg(), "Palette"},
      {:text, Readout.right_x(state.palette), @content_y, FontType.body(), colour, Theme.bg(), state.palette}
    ] ++ swatch(state.palette) ++ help(state.editing)
  end

  # The strip of escape colours, crossed by a grid line and boxed in the frame colour.
  defp swatch(palette) do
    colours = Palette.colours(palette)
    w = 16 * @swatch_w
    f = Palette.frame(palette)

    [{:rect, @swatch_x, @swatch_y + div(@swatch_h, 2), w, 1, Palette.grid(palette)}] ++
      for(i <- :lists.seq(0, 15), do: {:rect, @swatch_x + i * @swatch_w, @swatch_y, @swatch_w, @swatch_h, swatch_colour(colours, i)}) ++
      [
        {:rect, @swatch_x - 4, @swatch_y - 4, w + 8, 2, f},
        {:rect, @swatch_x - 4, @swatch_y + @swatch_h + 2, w + 8, 2, f},
        {:rect, @swatch_x - 4, @swatch_y - 4, 2, @swatch_h + 8, f},
        {:rect, @swatch_x + w + 2, @swatch_y - 4, 2, @swatch_h + 8, f}
      ]
  end

  defp swatch_colour(colours, i) do
    <<r, g, b, _a>> = :erlang.element(i + 1, colours)

    r * 0x10000 + g * 0x100 + b
  end

  defp help(true), do: Nav.hint([{"left/right", "change"}, {"Enter", "done"}], @hint_y, Theme.accent())
  defp help(false), do: Nav.hint([{"Enter", "change"}, {"left", "list"}], @hint_y, Theme.dim())

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

  defp frame(sector, palette) do
    x = rem(sector, @columns) * @sector_w
    y = @top + div(sector, @columns) * @sector_h
    c = Palette.frame(palette)

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

  defp grid(palette) do
    c = Palette.grid(palette)

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
