defmodule Badge.Store.Job do
  @moduledoc """
  The store's background work, one unlinked process per job, ending with one
  message to the process that started it:

      {ref, {:manifest, {:ok, entries} | {:error, reason}}}
      {ref, {:loaded, entry}} | {ref, {:failed, entry, reason}}

  A pack job fetches, verifies and loads the pack, but records nothing: the
  page that started it writes the installed list.
  """

  @compile {:no_warn_undefined, :atomvm}

  alias Badge.Nvs
  alias Badge.Store
  alias Badge.Store.Fetch
  alias Badge.Wifi

  @max_manifest 32_768

  @doc "Runs `kind` in a new process that answers the caller with `{ref, result}`."
  @spec start(:manifest | {:pack, map}, reference) :: pid
  def start(kind, ref) do
    owner = self()
    spawn(fn -> send(owner, {ref, run(kind)}) end)
  end

  @doc "Does the work of one job in the calling process."
  def run(:manifest) do
    with :ok <- online(),
         {:ok, url} <- Store.url(base(), "manifest.json"),
         {:ok, body} <- Fetch.get(url, @max_manifest),
         {:ok, entries} <- Store.decode_manifest(body) do
      :io.format(~c"Store: manifest lists ~p apps~n", [length(entries)])
      {:manifest, {:ok, entries}}
    else
      {:error, reason} -> {:manifest, {:error, reason}}
    end
  end

  def run({:pack, entry}) do
    with :ok <- online(),
         {:ok, url} <- Store.url(base(), Store.pack_path(entry)),
         {:ok, pack} <- Fetch.get(url, Store.max_pack()),
         :ok <- Store.verify(entry, pack),
         :ok <-
           :atomvm.add_avm_pack_binary(pack,
             name: :erlang.binary_to_atom("app_" <> entry.id, :utf8)
           ) do
      :io.format(~c"Store: loaded ~s ~s~n", [entry.id, entry.version])
      {:loaded, entry}
    else
      {:error, reason} ->
        :io.format(~c"Store: ~s failed: ~p~n", [entry.id, reason])
        {:failed, entry, reason}
    end
  end

  # HTTPS needs a set clock; before SNTP every certificate is "not yet valid".
  defp online do
    case Wifi.status() do
      %{synced: true} -> :ok
      _status -> {:error, :offline}
    end
  catch
    _kind, _reason -> {:error, :offline}
  end

  defp base do
    Store.base(Nvs.get(:store_url))
  catch
    _kind, _reason -> Store.base(nil)
  end
end
