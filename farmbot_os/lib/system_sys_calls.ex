defmodule Farmbot.System.SysCalls do
  alias Farmbot.CeleryScript.AST
  alias Farmbot.System.SysCalls.SendMessage
  alias Farmbot.Firmware
  @behaviour Farmbot.CeleryScript.SysCalls

  defdelegate send_message(level, message, channels), to: SendMessage

  def read_status do
    :ok = Farmbot.AMQP.BotStateNGTransport.force()
  end

  def set_user_env(key, value) do
    Farmbot.BotState.set_user_env(key, value)
  end

  def get_current_x do
    get_position(:x)
  end

  def get_current_y do
    get_position(:y)
  end

  def get_current_z do
    get_position(:z)
  end

  def read_pin(pin_number, mode) do
    case Firmware.request({nil, {:pin_read, [p: pin_number, m: mode]}}) do
      {:ok, {_, {:report_pin_value, [p: _, v: val]}}} ->
        val

      {:error, reason} ->
        {:error, reason}
    end
  end

  def point(kind, id) do
    case Farmbot.Asset.get_point(id: id) do
      nil -> {:error, "#{kind} not found"}
      %{x: x, y: y, z: z} -> %{x: x, y: y, z: z}
    end
  end

  defp get_position(axis) do
    case Farmbot.Firmware.request({nil, {:position_read, []}}) do
      {:ok, {nil, {:report_position, params}}} ->
        Keyword.fetch!(params, axis)

      _ ->
        {:error, "firmware error"}
    end
  end

  def move_absolute(x, y, z, speed) do
    params = [x: x / 1.0, y: y / 1.0, z: z / 1.0, s: speed / 1.0]

    case Farmbot.Firmware.command({nil, {:command_movement, params}}) do
      :ok -> :ok
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def get_sequence(id) do
    case Farmbot.Asset.get_sequence(id: id) do
      nil -> {:error, "sequence not found"}
      %{} = sequence -> AST.decode(sequence)
    end
  end

  require Farmbot.Logger
  alias Farmbot.{Asset.Repo, Asset.Sync, API}
  alias API.{Reconciler, SyncGroup}
  alias Ecto.{Changeset, Multi}

  def sync() do
    Farmbot.Logger.busy(3, "Syncing")
    sync_changeset = API.get_changeset(Sync)
    sync = Changeset.apply_changes(sync_changeset)
    multi = Multi.new()

    :ok = Farmbot.BotState.set_sync_status("syncing")

    with {:ok, multi} <- Reconciler.sync_group(multi, sync, SyncGroup.group_1()),
         {:ok, multi} <- Reconciler.sync_group(multi, sync, SyncGroup.group_2()),
         {:ok, multi} <- Reconciler.sync_group(multi, sync, SyncGroup.group_3()),
         {:ok, multi} <- Reconciler.sync_group(multi, sync, SyncGroup.group_4()) do
      Multi.insert(multi, :syncs, sync_changeset)
      |> Repo.transaction()

      Farmbot.Logger.success(3, "Synced")
      :ok = Farmbot.BotState.set_sync_status("synced")
      :ok
    else
      error ->
        :ok = Farmbot.BotState.set_sync_status("sync_error")
        {:error, inspect(error)}
    end
  end
end