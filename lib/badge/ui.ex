defmodule Badge.UI do
  @moduledoc """
  Owns the display backend and decides what is on it.

  Pages are modules, not processes: this process holds the current page's
  state and calls `render/1`, `tick/1` and `handle_key/2` on it. Shape keys
  and Esc are intercepted here and never reach a page, so no page has to
  know that navigation exists.

  Rendering stays decoupled from input: key events only mutate page state
  and mark it dirty, and a linked ticker asks for a redraw at a bounded
  rate. The link is load-bearing — a silently dead ticker would freeze the
  panel behind a healthy-looking supervision tree.

  Each page sets its own frame rate through `refresh/0`. `tick/1` still
  runs on every base tick regardless, so a page that smooths its readings
  keeps averaging at full rate while repainting slowly. A page asking for
  frames faster than 100 ms makes the ticker run at 50 ms while it is on
  screen.

  After the sleep timeout the panel and the LED chain go dark and no frame is
  drawn, though pages keep ticking so nothing resets behind the blank screen.
  The key that wakes the badge is swallowed here rather than reaching the page,
  so waking never also does something.

  The title bar carries the page name, a clock and the battery and wifi
  icons. Its contents are compared like page state, so the clock ticks even
  on a page that never changes by itself.

  The saved `Badge.Skin` is activated here, because pages render inside this
  process and read their colours from its dictionary.

  Every call into a page goes through `Badge.UI.Guard`: a page that raises or
  exits is logged and replaced by Home. An installed app whose code is not
  loaded yet opens the Store page, which downloads it first.
  """

  use GenServer

  alias Badge.Backlight
  alias Badge.Battery
  alias Badge.Clock
  alias Badge.Display
  alias Badge.Display.AtomGL
  alias Badge.Keyboard
  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Page.Store, as: StorePage
  alias Badge.Pages
  alias Badge.Pixels
  alias Badge.Power
  alias Badge.Skin
  alias Badge.Sleep
  alias Badge.Store.Installed
  alias Badge.Theme
  alias Badge.UI.Guard
  alias Badge.Update
  alias Badge.Wifi

  @compile {:no_warn_undefined, :atomvm}

  # Ticker rate. A page renders at its own `refresh/0`, which must be a multiple of this.
  @base_interval 100

  # The rate for a page that asks to refresh faster than the base.
  @fast_interval 50

  # The clock in the title bar needs a second; battery and wifi change far more slowly.
  @status_ms 1_000

  @font_dogica File.read!("assets/fonts/dogica.uf")
  @font_pixel_operator File.read!("assets/fonts/pixel_operator.uf")
  # Loaded only while a page asks for it: 18 kB is more than this badge can
  # spare for a font used on one screen, so the bytes live in the assets
  # partition rather than in this image.
  @loadable %{w95fa: ~c"fonts/w95fa.uf"}

  def start_link(display) do
    GenServer.start_link(__MODULE__, display, name: __MODULE__)
  end

  @doc """
  Applies a decoded key event.

  Does not draw. Navigation is handled here; anything else goes to the
  current page, and the ticker turns the result into a frame.
  """
  def key_event(event) do
    GenServer.cast(__MODULE__, {:key, event})
  end

  @doc """
  Switches to a page, as opening it from the home grid would.

  Navigation by key can only reach the screen the grid is turned to, so a
  clustered host asks for the module instead.
  """
  @spec goto(module) :: :ok
  def goto(page), do: GenServer.cast(__MODULE__, {:goto, page})

  @doc "From `Badge.Keyboard`: the CPU slept for `ms`, or the sleep was refused."
  @spec slept({:ok, integer} | :refused) :: :ok
  def slept(result), do: GenServer.cast(__MODULE__, {:slept, result})

  @doc """
  Opens the AtomGL port and loads the fonts.

  Called once by `Badge`, not from `init/1`, so that restarting this process
  reuses the display rather than opening a second one. Each port carries a
  framebuffer; orphaning one costs about 32 kB, which is enough to turn a
  single restart into an out-of-memory reboot on a badge running wifi.
  """
  @spec open_display(term) :: Display.t()
  def open_display(spi) do
    display = {AtomGL, AtomGL.open(spi)}

    :ok = Display.register_font(display, :dogica, @font_dogica)
    :ok = Display.register_font(display, :pixel_operator, @font_pixel_operator)

    :io.format(~c"UI: AtomGL port open, ~p pages~n", [length(Pages.all())])

    display
  end

  @impl true
  def init(display) do
    Installed.load()
    page = first_page()

    state = %{
      display: display,
      page: page,
      page_state: page.init(),
      dirty: false,
      countdown: 0,
      status: placeholder_status(),
      status_countdown: 0,
      fonts: [],
      missing: [],
      idle: 0,
      asleep: false,
      napping: false,
      interval: @base_interval,
      ticker: nil
    }

    Skin.activate(Skin.load())

    # Renders once immediately so the home grid is up before the first tick.
    state = render(state)

    {:ok, pace(%{state | ticker: start_ticker(@base_interval)})}
  end

  @impl true
  def handle_cast({:goto, page}, state) do
    {:noreply, goto(%{state | idle: 0}, page)}
  end

  def handle_cast({:key, _event}, %{asleep: true} = state) do
    {:noreply, wake(state)}
  end

  # The only wake source is a key, so the screen comes on without waiting for its event.
  def handle_cast({:slept, {:ok, _ms}}, state) do
    Wifi.resume()

    {:noreply, wake(%{state | napping: false})}
  end

  def handle_cast({:slept, :refused}, state) do
    Wifi.resume()

    {:noreply, %{state | napping: false, idle: 0}}
  end

  # Offered to the page first, so a container can back out a level and the
  # home grid can lend the shape keys to its second screen; ignored, it navigates.
  def handle_cast({:key, {:nav, key}}, state) do
    state = %{state | idle: 0}

    case offer(state, :handle_key, [{:nav, key}]) do
      {:took, state} -> {:noreply, state}
      :ignore -> {:noreply, navigate(key, state)}
    end
  end

  def handle_cast({:key, event}, state) do
    state = %{state | idle: 0}

    case offer(state, :handle_key, [event]) do
      {:took, state} -> {:noreply, state}
      :ignore -> {:noreply, state}
    end
  end

  # A page that is finished with the screen hands over by returning `{:goto, page}`.
  @impl true
  def handle_info(:render_tick, %{page: page, page_state: page_state} = state) do
    next =
      case Guard.call(page, :tick, [page_state]) do
        {:ok, {:goto, page}} -> goto(state, page)
        {:ok, page_state} -> ticked(state, page_state)
        :crashed -> state |> crashed() |> pace()
      end

    # The ticker holds the next tick until this one is handled.
    send(next.ticker, :ticked)

    {:noreply, next}
  end

  # The IR link delivers here because this process owns the mailbox; only the
  # page on screen is offered the frame.
  def handle_info({:ir, from, payload}, state) do
    case offer(state, :handle_ir, [from, payload]) do
      {:took, state} -> {:noreply, state}
      :ignore -> {:noreply, state}
    end
  end

  # A page's own process can only send to this GenServer, which owns the
  # mailbox; anything it does not recognise is dropped rather than fatal.
  def handle_info(message, state) do
    case offer(state, :handle_info, [message]) do
      {:took, state} -> {:noreply, state}
      :ignore -> {:noreply, state}
    end
  end

  # Offers an event to the page on screen; a crash or an unexpected answer puts Home there instead.
  defp offer(%{page: page, page_state: old, dirty: dirty} = state, fun, args) do
    case Guard.call(page, fun, args ++ [old]) do
      {:ok, {:ok, page_state}} ->
        {:took, %{state | page_state: page_state, dirty: dirty or page_state != old}}

      {:ok, :ignore} ->
        :ignore

      _crashed ->
        {:took, crashed(state)}
    end
  end

  @doc "The state after the page on screen crashed: it is left, so it can release what it holds, and Home takes its place."
  def crashed(%{page: page, page_state: page_state} = state) do
    Guard.call(page, :leave, [page_state])
    %{state | page: Home, page_state: Home.init(), dirty: true, countdown: 0}
  end

  defp ticked(state, page_state) do
    {status, status_countdown} = refresh_status(state)
    dirty = state.dirty or page_state != state.page_state or status != state.status

    next = %{
      state
      | page_state: page_state,
        status: status,
        status_countdown: status_countdown,
        dirty: dirty
    }

    next = next |> pace() |> drowse()

    # Nothing is visible while asleep, and a repaint is the costliest thing here.
    case not next.asleep and next.dirty and next.countdown <= 0 do
      true ->
        drawn = render(sync_fonts(next))

        %{drawn | dirty: false, countdown: reload(drawn)}

      false ->
        %{next | countdown: max(next.countdown - 1, 0)}
    end
  end

  @doc false
  # The ticker interval for a page refreshing every `refresh` ms.
  @spec interval(pos_integer) :: pos_integer
  def interval(refresh) when refresh < @base_interval, do: @fast_interval
  def interval(_refresh), do: @base_interval

  # Retimes the ticker when the page on screen wants a different rate.
  defp pace(state) do
    case Guard.call(state.page, :refresh, [state.page_state]) do
      {:ok, ms} -> retime(state, interval(ms))
      :crashed -> pace(crashed(state))
    end
  end

  defp retime(%{interval: interval} = state, interval), do: state

  defp retime(state, interval) do
    send(state.ticker, {:interval, interval})
    %{state | interval: interval}
  end

  defp first_page do
    case Splash.wanted?() do
      true -> Splash
      false -> Home
    end
  end

  # Bring-up instrumentation: a restart is otherwise silent, and the reason
  # is the only thing that says which side of a link died first.
  @impl true
  def terminate(reason, _state) do
    :io.format(~c"UI: terminating ~p~n", [reason])

    :ok
  end

  # Screen off: count on towards the CPU sleep, unless one is already requested.
  @doc false
  def drowse(%{asleep: true, napping: true} = state), do: state

  def drowse(state) do
    case page_awake(state.page, state.page_state) do
      {:ok, awake} -> drift(state, drowsing(state.asleep, awake == true))
      :crashed -> state |> crashed() |> pace()
    end
  end

  @doc false
  # An app built before api 2 has no awake?/1, and lets the screen sleep.
  @spec page_awake(module, term) :: {:ok, term} | :crashed
  def page_awake(page, page_state) do
    case :erlang.function_exported(page, :awake?, 1) do
      true -> Guard.call(page, :awake?, [page_state])
      false -> {:ok, false}
    end
  end

  defp drift(state, :wake), do: wake(state)
  defp drift(state, :stay), do: %{state | idle: 0}
  defp drift(state, :nap), do: toward_nap(state)
  defp drift(state, :sleep), do: toward_sleep(state)

  @doc false
  # A tick's step: a page that must stay awake lights the screen, otherwise idle counts on.
  @spec drowsing(boolean, boolean) :: :wake | :stay | :nap | :sleep
  def drowsing(asleep, awake)
  def drowsing(true, true), do: :wake
  def drowsing(true, false), do: :nap
  def drowsing(false, true), do: :stay
  def drowsing(false, false), do: :sleep

  defp toward_nap(state) do
    idle = state.idle + 1

    case idle >= Sleep.ticks(state.interval) and Sleep.allowed?(holds()) do
      true -> nap(state)
      false -> %{state | idle: idle}
    end
  end

  # A badge set never to sleep counts on without ever reaching the timeout.
  defp toward_sleep(state) do
    idle = state.idle + 1

    case Backlight.sleep_ticks(Backlight.settings().sleep, state.interval) do
      ticks when is_integer(ticks) and idle >= ticks -> sleep(state)
      _awake -> %{state | idle: idle}
    end
  end

  defp sleep(state) do
    Backlight.sleep()
    Pixels.sleep()

    %{state | asleep: true, idle: 0}
  end

  defp holds do
    %{usb: Power.usb_present?(), downloading: Update.Link.status().state == :downloading}
  end

  # The radio is parked before the CPU, so the disconnect is out before it stops.
  defp nap(state) do
    Wifi.suspend()
    Keyboard.light_sleep()

    %{state | napping: true, idle: 0}
  end

  # Dirty, so the panel is right the moment the light comes back.
  defp wake(state) do
    Backlight.wake()
    Pixels.wake()

    %{state | asleep: false, idle: 0, dirty: true, countdown: 0}
  end

  # Fonts are settled before the frame, never from a page, because a page runs
  # inside this process and a message to itself would arrive after the draw.
  defp sync_fonts(state) do
    wanted =
      case Guard.call(state.page, :fonts, [state.page_state]) do
        {:ok, fonts} -> fonts
        :crashed -> []
      end

    state
    |> free_fonts(state.fonts -- wanted)
    |> load_fonts(wanted -- (state.fonts -- state.missing))
  end

  defp free_fonts(state, []), do: state

  defp free_fonts(state, [name | rest]) do
    :ok = Display.deregister_font(state.display, name)

    free_fonts(%{state | fonts: state.fonts -- [name]}, rest)
  end

  defp load_fonts(state, []), do: state

  defp load_fonts(state, [name | rest]) do
    case font_bytes(Map.fetch!(@loadable, name)) do
      nil ->
        :io.format(~c"UI: font ~p not in assets partition~n", [name])

        load_fonts(%{state | missing: [name | state.missing]}, rest)

      bytes ->
        :ok = Display.register_font(state.display, name, bytes)

        load_fonts(%{state | fonts: [name | state.fonts]}, rest)
    end
  end

  # An unflashed assets partition costs this one font, not the whole display.
  defp font_bytes(path) do
    :atomvm.read_priv(:assets, path)
  catch
    _, _ -> nil
  end

  defp reload(state) do
    case Guard.call(state.page, :refresh, [state.page_state]) do
      {:ok, ms} -> max(div(ms, state.interval), 1) - 1
      :crashed -> 0
    end
  end

  # Retries next tick while a source is down, rather than calling a process that is not there.
  defp refresh_status(%{status_countdown: 0} = state) do
    case sources_up?() do
      true -> {read_status(), div(@status_ms, state.interval) - 1}
      false -> {state.status, 0}
    end
  end

  defp refresh_status(state), do: {state.status, state.status_countdown - 1}

  # This process starts before Badge.Power and Badge.Wifi, and outlives a restart of either.
  defp sources_up? do
    Process.whereis(Badge.Power) != nil and Process.whereis(Badge.Wifi) != nil
  end

  defp read_status do
    power = Power.status()
    wifi = Wifi.status()

    %{
      battery: Battery.icon(power.battery_mv, power.usb),
      wifi: Wifi.icon(wifi.radio),
      clock: clock_face(wifi)
    }
  end

  # Uptime until SNTP sets the system clock, local wall time after.
  defp clock_face(%{synced: true, offset: offset}) do
    Clock.face(:erlang.system_time(:second), offset)
  end

  defp clock_face(_wifi), do: Clock.format(div(:erlang.monotonic_time(:millisecond), 1000))

  # Badge.Power and Badge.Wifi start after this process, so the first real reading waits for the first tick.
  defp placeholder_status do
    %{battery: :battery_0, wifi: Wifi.icon(:disabled), clock: Clock.format(0)}
  end

  defp navigate(:home, state), do: goto(state, Home)

  defp navigate(key, state) do
    case Pages.for_key(key) do
      nil -> state
      module -> goto(state, module)
    end
  end

  # Re-entering the current page would reset it, and key repeat fires a held key 8 times a second.
  defp goto(%{page: page} = state, page), do: state

  # A crashed app stays shut; an app whose code is not loaded opens the Store page, which fetches it.
  defp goto(state, page) do
    case Installed.route(page) do
      :disabled ->
        state

      {:fetch, id} ->
        :erlang.put(:store_fetch, id)
        open(state, StorePage)

      page ->
        open(state, page)
    end
  end

  defp open(%{page: current, page_state: page_state} = state, page) do
    Guard.call(current, :leave, [page_state])

    case Guard.call(page, :init, []) do
      {:ok, page_state} ->
        pace(%{state | page: page, page_state: page_state, dirty: true, countdown: 0})

      :crashed ->
        crashed(state)
    end
  end

  # Returns the state, which is Home's if the page crashed while drawing.
  defp render(%{page: page, page_state: page_state, display: display, status: status} = state) do
    with {:ok, items} <- Guard.call(page, :render, [page_state]),
         {:ok, title} <- Guard.call(page, :title, []) do
      :ok = Display.update(display, items ++ Theme.chrome(title, status))
      state
    else
      :crashed ->
        case page == Home do
          true -> state
          false -> render(crashed(state))
        end
    end
  end

  # Waits in a linked process, so this GenServer never sleeps in a callback and a dead ticker crashes loudly.
  defp start_ticker(interval) do
    ui = self()
    spawn_link(fn -> tick_loop(ui, interval) end)
  end

  @doc false
  def tick_loop(ui, interval) do
    receive do
      {:interval, next} -> tick_loop(ui, next)
    after
      interval ->
        send(ui, :render_tick)
        await_tick(ui, interval)
    end
  end

  # Sleeps again only once the UI has handled the tick, so ticks never queue up.
  defp await_tick(ui, interval) do
    receive do
      :ticked -> tick_loop(ui, interval)
      {:interval, next} -> await_tick(ui, next)
    end
  end
end
