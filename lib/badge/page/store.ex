defmodule Badge.Page.Store do
  @moduledoc """
  Browses the app store, installs apps, and downloads an installed app's code
  the first time it is opened after a boot.

  The list is the manifest's apps plus any installed app it no longer lists.
  Enter opens an app's details, where Enter installs or updates it and `r`
  removes it. Updates and removals are saved at once and take effect after a
  restart, which Enter then offers.

  Key handlers only record the request in `want`; `tick/1` carries it out.
  Downloads run in a `Badge.Store.Job` process, which `leave/1` kills.
  """

  use Badge.Page

  @compile {:no_warn_undefined, :esp}

  alias Badge.FontType
  alias Badge.Nav
  alias Badge.Readout
  alias Badge.Store
  alias Badge.Store.Installed
  alias Badge.Store.Job
  alias Badge.Text
  alias Badge.Theme

  @top Theme.content_top() + 4
  @pitch 20
  @visible 8
  @hint_y Theme.height() - 20
  @notice_y Theme.height() - 44
  @columns 38

  @impl true
  def title, do: "Store"

  @impl true
  def refresh(_state), do: 200

  @impl true
  def init do
    fresh = %{
      view: :list,
      cursor: 0,
      entry: nil,
      entries: [],
      manifest: :loading,
      want: :manifest,
      job: nil,
      notice: nil,
      opening: nil,
      restart: false
    }

    with id when is_binary(id) <- :erlang.erase(:store_fetch),
         %{name: name} = entry <- Installed.find(id) do
      %{
        fresh
        | view: :opening,
          opening: id,
          want: {:pack, entry},
          notice: "Downloading " <> name
      }
    else
      _nothing_to_open -> fresh
    end
  end

  @doc "What the list shows: the manifest's apps, then installed apps it no longer lists."
  @spec rows(map) :: [map]
  def rows(%{entries: entries}), do: entries ++ delisted(Installed.all(), entries, [])

  @doc "The status a list row shows for `entry`."
  @spec mark(map) :: binary
  def mark(%{size: size} = entry) do
    case Store.installable(entry, Installed.all()) do
      :ok -> kb(size)
      :installed -> "installed"
      :update -> "update"
      {:no, :api} -> "newer fw"
      {:no, :storage} -> "newer fw"
      {:no, _full_or_space} -> "no room"
    end
  end

  @impl true
  def tick(%{want: nil} = state), do: state
  def tick(%{want: :manifest} = state), do: start(state, :manifest)
  def tick(%{want: {:pack, entry}} = state), do: start(state, {:pack, entry})

  def tick(%{want: {:open, %{id: id}}}) do
    Installed.mark_loaded(id)
    {:goto, Store.page_module(id)}
  end

  def tick(%{want: {:record, %{id: id} = entry}} = state) do
    Installed.put(entry)
    Installed.mark_loaded(id)
    %{state | want: nil, notice: "Installed, open it from Home"}
  end

  def tick(%{want: {:update, entry}} = state) do
    Installed.put(entry)
    %{state | want: nil, restart: true, notice: "Restart to finish"}
  end

  def tick(%{want: {:remove, id}} = state) do
    Installed.remove(id)
    %{state | want: nil, restart: true, notice: "Restart to finish"}
  end

  def tick(%{want: :restart} = state) do
    :esp.restart()
    %{state | want: nil}
  end

  @impl true
  def handle_info({ref, result}, %{job: {ref, _pid}} = state),
    do: {:ok, finished(%{state | job: nil}, result)}

  def handle_info(_message, _state), do: :ignore

  @doc "Applies what a `Badge.Store.Job` reported."
  @spec finished(map, term) :: map
  def finished(state, {:manifest, {:ok, entries}}),
    do: %{state | entries: entries, manifest: :ready}

  def finished(state, {:manifest, {:error, reason}}), do: %{state | manifest: {:error, reason}}

  def finished(%{opening: id} = state, {:loaded, %{id: id} = entry}),
    do: %{state | want: {:open, entry}}

  def finished(state, {:loaded, entry}), do: %{state | want: {:record, entry}}

  def finished(state, {:failed, _entry, reason}),
    do: %{state | notice: "Failed: " <> reason_text(reason)}

  @impl true
  def leave(%{job: {_ref, pid}}) do
    Process.exit(pid, :kill)
    :ok
  end

  def leave(_state), do: :ok

  @impl true
  def handle_key({:move, :up}, %{view: :list, cursor: cursor} = state) when cursor > 0,
    do: {:ok, %{state | cursor: cursor - 1}}

  def handle_key({:move, :down}, %{view: :list, cursor: cursor} = state) do
    case cursor < length(rows(state)) - 1 do
      true -> {:ok, %{state | cursor: cursor + 1}}
      false -> :ignore
    end
  end

  def handle_key({:edit, :newline}, %{view: :list, cursor: cursor} = state) do
    case rows(state) do
      [] ->
        :ignore

      rows ->
        {:ok, %{state | view: :detail, entry: :lists.nth(cursor + 1, rows), notice: nil}}
    end
  end

  def handle_key({:nav, :home}, %{view: :detail} = state),
    do: {:ok, %{state | view: :list, notice: nil}}

  def handle_key({:edit, :newline}, %{view: :detail, restart: true} = state),
    do: {:ok, %{state | want: :restart}}

  def handle_key({:edit, :newline}, %{view: :detail, job: nil, entry: entry} = state),
    do: act(state, entry)

  def handle_key({:char, c}, %{view: :detail, job: nil, entry: entry} = state)
      when c == ?r or c == ?R,
      do: remove(state, entry)

  def handle_key(_event, _state), do: :ignore

  @impl true
  def render(%{view: :opening, notice: notice}), do: [centred(notice, 100, Theme.fg())]
  def render(%{view: :detail, entry: entry} = state), do: detail_items(entry, state)
  def render(state), do: list_items(state)

  defp start(state, kind) do
    ref = make_ref()
    %{state | want: nil, job: {ref, Job.start(kind, ref)}}
  end

  defp act(state, entry) do
    case Store.installable(entry, Installed.all()) do
      :ok -> {:ok, %{state | want: {:pack, entry}, notice: "Downloading..."}}
      :update -> {:ok, %{state | want: {:update, entry}}}
      _no -> :ignore
    end
  end

  defp remove(state, %{id: id}) do
    case Installed.find(id) do
      nil -> :ignore
      _installed -> {:ok, %{state | want: {:remove, id}}}
    end
  end

  defp list_items(%{cursor: cursor, notice: notice} = state) do
    rows = rows(state)
    first = max(cursor - @visible + 1, 0)

    shown =
      for %{name: name} = entry <- :lists.sublist(rows, first + 1, @visible),
          do: %{value: Text.cp437(name), trailing: mark(entry)}

    free = "RAM " <> kb(Store.free(Installed.all())) <> " free"

    Nav.rows(shown, cursor - first, @top, @pitch) ++
      list_status(state, rows) ++
      notice_items(notice) ++
      [{:text, Readout.right_x(free), @hint_y, FontType.body(), Theme.dim(), Theme.bg(), free}] ++
      Nav.hint([{"Enter", "details"}], @hint_y, Theme.dim())
  end

  defp list_status(%{manifest: {:error, _reason}}, _rows),
    do: [centred("Store offline", @notice_y - 20, Theme.accent())]

  defp list_status(%{manifest: :loading}, []), do: [centred("Loading...", 100, Theme.dim())]
  defp list_status(_state, _rows), do: []

  defp detail_items(%{name: name} = entry, %{notice: notice} = state) do
    lines = Text.wrap(Text.cp437(Map.get(entry, :description, "")), @columns)

    [
      {:text, 8, @top, FontType.heading(), Theme.fg(), Theme.bg(), Text.cp437(name)},
      {:text, 8, @top + 22, FontType.body(), Theme.dim(), Theme.bg(), byline(entry)},
      {:text, 8, @notice_y - 22, FontType.body(), Theme.fg(), Theme.bg(), need(entry)}
    ] ++
      line_items(lines, @top + 48, []) ++
      notice_items(notice) ++
      Nav.hint(detail_hints(entry, state), @hint_y, Theme.dim())
  end

  defp byline(%{version: version} = entry) do
    case Map.get(entry, :author, "") do
      "" -> "v" <> version
      author -> Text.cp437("v" <> version <> " by " <> author)
    end
  end

  defp need(%{size: size}),
    do: "Needs " <> kb(size) <> ", " <> kb(Store.free(Installed.all())) <> " free"

  defp detail_hints(_entry, %{restart: true}), do: [{"Enter", "restart"}]

  defp detail_hints(%{id: id} = entry, _state) do
    remove = if Installed.find(id) == nil, do: [], else: [{"R", "remove"}]

    case Store.installable(entry, Installed.all()) do
      :ok -> [{"Enter", "install"}]
      :update -> [{"Enter", "update"} | remove]
      _installed_or_no -> remove
    end
  end

  defp line_items([], _y, acc), do: :lists.reverse(acc)

  defp line_items([line | rest], y, acc),
    do:
      line_items(rest, y + 18, [
        {:text, 8, y, FontType.body(), Theme.fg(), Theme.bg(), line} | acc
      ])

  defp notice_items(nil), do: []

  defp notice_items(notice),
    do: [{:text, 8, @notice_y, FontType.body(), Theme.accent(), Theme.bg(), notice}]

  defp centred(text, y, colour),
    do: {:text, Readout.centre_x(text), y, FontType.body(), colour, Theme.bg(), text}

  defp delisted([], _entries, acc), do: :lists.reverse(acc)

  defp delisted([%{id: id} = app | rest], entries, acc) do
    case listed?(entries, id) do
      true -> delisted(rest, entries, acc)
      false -> delisted(rest, entries, [app | acc])
    end
  end

  defp listed?([], _id), do: false
  defp listed?([%{id: id} | _rest], id), do: true
  defp listed?([_entry | rest], id), do: listed?(rest, id)

  defp kb(bytes), do: :erlang.integer_to_binary(div(bytes + 1023, 1024)) <> "K"

  defp reason_text(reason) when is_atom(reason), do: :erlang.atom_to_binary(reason, :utf8)

  defp reason_text({:status, code}) when is_integer(code),
    do: "HTTP " <> :erlang.integer_to_binary(code)

  defp reason_text(_reason), do: "error"
end
